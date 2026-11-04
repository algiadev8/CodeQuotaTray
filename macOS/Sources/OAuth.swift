import Foundation
import Network
import Security
import CryptoKit

// アプリ内蔵のOAuth（Authorization Code + PKCE）実装。
// ブラウザでログインし、ループバック(localhost)で認可コードを受け取り、
// 自前のトークンをファイルに保存・自動更新する。CLIのトークンには触れない。

struct OAuthCredential: Codable, Sendable {
    var access: String
    var refresh: String
    /// 有効期限（Unix epoch ミリ秒）
    var expires: Double
    var accountId: String?

    var needsRefresh: Bool { Date().timeIntervalSince1970 * 1000 >= expires - 300_000 }
    var isExpired: Bool { Date().timeIntervalSince1970 * 1000 >= expires }
}

extension Provider {
    var keychainAccount: String { rawValue.lowercased() }
}

// MARK: - PKCE

enum PKCE {
    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes)
    }

    static func generate() -> (verifier: String, challenge: String) {
        let verifier = base64URL(randomBytes(32))
        let challenge = base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        return (verifier, challenge)
    }
}

// MARK: - ファイル保存（Keychainは使わない）
// ~/Library/Application Support/CodeQuota Tray/<provider>.json（ディレクトリ0700・ファイル0600）。
// Keychainは未署名/ad-hoc署名アプリだとビルドごとに許可ダイアログが出て、操作を妨げるため使わない。

enum CredentialStore {
    private static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CodeQuota Tray", isDirectory: true)
    }

    private static func file(_ provider: Provider) -> URL {
        directory.appendingPathComponent(provider.keychainAccount + ".json")
    }

    /// 保存の有無だけを軽く確認（メニュー表示のたびに呼んでも安全）
    static func exists(_ provider: Provider) -> Bool {
        FileManager.default.fileExists(atPath: file(provider).path)
    }

    static func load(_ provider: Provider) -> OAuthCredential? {
        guard let data = try? Data(contentsOf: file(provider)) else { return nil }
        return try? JSONDecoder().decode(OAuthCredential.self, from: data)
    }

    static func save(_ credential: OAuthCredential, for provider: Provider) throws {
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
            let data = try JSONEncoder().encode(credential)
            let temp = directory.appendingPathComponent(".\(provider.keychainAccount).tmp")
            try? manager.removeItem(at: temp)
            // 最初から0600で作成し、アトミックに置き換える。
            guard manager.createFile(atPath: temp.path, contents: data,
                                     attributes: [.posixPermissions: 0o600]) else {
                throw UsageError("ログイン情報を保存できませんでした")
            }
            guard rename(temp.path, file(provider).path) == 0 else {
                try? manager.removeItem(at: temp)
                throw UsageError("ログイン情報を保存できませんでした")
            }
        } catch let error as UsageError {
            throw error
        } catch {
            throw UsageError("ログイン情報を保存できませんでした")
        }
    }

    static func delete(_ provider: Provider) {
        try? FileManager.default.removeItem(at: file(provider))
    }
}

// MARK: - ループバックHTTPサーバー（認可コード受信）

final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

final class LoopbackServer: @unchecked Sendable {
    private let providerName: String
    private let path: String
    private let expectedState: String
    private let queue = DispatchQueue(label: "codequota.oauth.loopback")
    private let lock = NSLock()
    private var listener: NWListener?
    private var outcome: Result<String, Error>?
    private var waiter: CheckedContinuation<String, Error>?

    init(providerName: String, path: String, state: String) {
        self.providerName = providerName
        self.path = path
        self.expectedState = state
    }

    /// port=0 で空きポートを使用。バインドしたポート番号を返す。
    func start(port: UInt16) async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        let endpointPort: NWEndpoint.Port = port == 0 ? .any : NWEndpoint.Port(rawValue: port)!
        let listener = try NWListener(using: parameters, on: endpointPort)
        self.listener = listener
        return try await withCheckedThrowingContinuation { continuation in
            let once = ResumeOnce()
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    if once.claim() {
                        continuation.resume(returning: listener.port?.rawValue ?? port)
                    }
                case .failed(let error):
                    if once.claim() {
                        continuation.resume(throwing: error)
                    } else {
                        self?.finish(.failure(UsageError("ローカル受信サーバーが停止しました")))
                    }
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }
            listener.start(queue: queue)
        }
    }

    func waitForCode(timeout: TimeInterval) async throws -> String {
        queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.finish(.failure(UsageError("ログインがタイムアウトしました。もう一度お試しください")))
        }
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let outcome {
                lock.unlock()
                continuation.resume(with: outcome)
            } else {
                waiter = continuation
                lock.unlock()
            }
        }
    }

    func stop() {
        finish(.failure(UsageError("ログインをキャンセルしました")))
        listener?.cancel()
        listener = nil
    }

    private func finish(_ result: Result<String, Error>) {
        lock.lock()
        guard outcome == nil else { lock.unlock(); return }
        outcome = result
        let pending = waiter
        waiter = nil
        lock.unlock()
        pending?.resume(with: result)
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            guard let self, let data, let text = String(data: data, encoding: .utf8) else {
                connection.cancel()
                return
            }
            let requestLine = text.components(separatedBy: "\r\n").first ?? ""
            let parts = requestLine.split(separator: " ")
            guard parts.count >= 2, parts[0] == "GET",
                  let components = URLComponents(string: "http://localhost" + String(parts[1])),
                  components.path == self.path else {
                self.respond(connection, status: 404, message: "Callback route not found.", ok: false)
                return
            }
            let items = Dictionary(
                (components.queryItems ?? []).map { ($0.name, $0.value ?? "") },
                uniquingKeysWith: { first, _ in first }
            )
            guard items["state"] == self.expectedState else {
                self.respond(connection, status: 400, message: "State mismatch.", ok: false)
                return
            }
            if let error = items["error"] {
                let detail = items["error_description"] ?? error
                self.respond(connection, status: 400, message: "\(self.providerName) authorization failed: \(detail)", ok: false)
                self.finish(.failure(UsageError("\(self.providerName) の認可に失敗しました：\(detail)")))
                return
            }
            guard let code = items["code"], !code.isEmpty else {
                self.respond(connection, status: 400, message: "Missing authorization code.", ok: false)
                return
            }
            self.respond(connection, status: 200,
                         message: "Signed in to \(self.providerName). You may now close this page.", ok: true)
            self.finish(.success(code))
        }
    }

    private func respond(_ connection: NWConnection, status: Int, message: String, ok: Bool) {
        let escaped = message
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        let title = ok ? "ログイン完了" : "ログイン失敗"
        let body = "<!doctype html><html><head><meta charset=\"utf-8\"><title>CodeQuota Tray</title>"
            + "<style>body{font-family:-apple-system,sans-serif;text-align:center;margin-top:20vh}</style></head>"
            + "<body><h2>\(title)</h2><p>\(escaped)</p></body></html>"
        let bytes = Data(body.utf8)
        let reason = status == 200 ? "OK" : (status == 404 ? "Not Found" : "Bad Request")
        let head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: text/html; charset=utf-8\r\n"
            + "Content-Length: \(bytes.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + bytes, completion: .contentProcessed { _ in connection.cancel() })
    }
}

// MARK: - プロバイダ別OAuth定義

enum OAuthConfig {
    // Claude (Pro/Max)
    static let claudeClientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let claudeAuthorize = "https://claude.ai/oauth/authorize"
    static let claudeToken = "https://platform.claude.com/v1/oauth/token"
    static let claudePreferredPort: UInt16 = 53692
    static let claudeScopes = "org:create_api_key user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload"

    // Codex (ChatGPT Plus/Pro)
    static let codexClientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    static let codexAuthorize = "https://auth.openai.com/oauth/authorize"
    static let codexToken = "https://auth.openai.com/oauth/token"
    static let codexPort: UInt16 = 1455
    static let codexRedirect = "http://localhost:1455/auth/callback"
    static let codexScope = "openid profile email offline_access"
}

enum OAuthManager {
    private static let loginTimeout: TimeInterval = 300

    // MARK: ログイン

    @MainActor
    static func login(_ provider: Provider, openURL: @escaping (URL) -> Void) async throws -> OAuthCredential {
        let credential: OAuthCredential
        switch provider {
        case .claude: credential = try await loginClaude(openURL: openURL)
        case .codex: credential = try await loginCodex(openURL: openURL)
        }
        try CredentialStore.save(credential, for: provider)
        return credential
    }

    @MainActor
    private static func loginClaude(openURL: (URL) -> Void) async throws -> OAuthCredential {
        let (verifier, challenge) = PKCE.generate()
        // Anthropic は任意のループバックポートを許可する。優先ポートが使用中なら空きポートへ。
        var server = LoopbackServer(providerName: "Anthropic", path: "/callback", state: verifier)
        var port: UInt16
        do {
            port = try await server.start(port: OAuthConfig.claudePreferredPort)
        } catch {
            server.stop()
            server = LoopbackServer(providerName: "Anthropic", path: "/callback", state: verifier)
            port = try await server.start(port: 0)
        }
        defer { server.stop() }
        let redirect = "http://localhost:\(port)/callback"
        let query = formEncode([
            ("code", "true"),
            ("client_id", OAuthConfig.claudeClientID),
            ("response_type", "code"),
            ("redirect_uri", redirect),
            ("scope", OAuthConfig.claudeScopes),
            ("code_challenge", challenge),
            ("code_challenge_method", "S256"),
            ("state", verifier)
        ])
        guard let url = URL(string: OAuthConfig.claudeAuthorize + "?" + query) else {
            throw UsageError("認可URLを作成できません")
        }
        openURL(url)
        let code = try await server.waitForCode(timeout: loginTimeout)
        let json = try await postJSON(OAuthConfig.claudeToken, body: [
            "grant_type": "authorization_code",
            "client_id": OAuthConfig.claudeClientID,
            "code": code,
            "state": verifier,
            "redirect_uri": redirect,
            "code_verifier": verifier
        ])
        return try credential(from: json, previous: nil, accountFromJWT: false)
    }

    @MainActor
    private static func loginCodex(openURL: (URL) -> Void) async throws -> OAuthCredential {
        let (verifier, challenge) = PKCE.generate()
        let state = PKCE.randomBytes(16).map { String(format: "%02x", $0) }.joined()
        let server = LoopbackServer(providerName: "OpenAI", path: "/auth/callback", state: state)
        do {
            _ = try await server.start(port: OAuthConfig.codexPort)
        } catch {
            server.stop()
            throw UsageError("ポート1455が使用中です。Codex CLIのログインを終了してから再試行してください")
        }
        defer { server.stop() }
        let query = formEncode([
            ("response_type", "code"),
            ("client_id", OAuthConfig.codexClientID),
            ("redirect_uri", OAuthConfig.codexRedirect),
            ("scope", OAuthConfig.codexScope),
            ("code_challenge", challenge),
            ("code_challenge_method", "S256"),
            ("state", state),
            ("id_token_add_organizations", "true"),
            ("codex_cli_simplified_flow", "true"),
            ("originator", "codequota-tray")
        ])
        guard let url = URL(string: OAuthConfig.codexAuthorize + "?" + query) else {
            throw UsageError("認可URLを作成できません")
        }
        openURL(url)
        let code = try await server.waitForCode(timeout: loginTimeout)
        let json = try await postForm(OAuthConfig.codexToken, fields: [
            ("grant_type", "authorization_code"),
            ("client_id", OAuthConfig.codexClientID),
            ("code", code),
            ("code_verifier", verifier),
            ("redirect_uri", OAuthConfig.codexRedirect)
        ])
        return try credential(from: json, previous: nil, accountFromJWT: true)
    }

    // MARK: トークン取得・更新

    /// 自前ログイン済みなら有効なトークンを返す（期限間近なら更新）。未ログインなら nil。
    static func credential(for provider: Provider, forceRefresh: Bool = false) async throws -> OAuthCredential? {
        guard let stored = CredentialStore.load(provider) else { return nil }
        if !forceRefresh && !stored.needsRefresh { return stored }
        do {
            let fresh = try await refresh(provider, stored)
            try CredentialStore.save(fresh, for: provider)
            return fresh
        } catch let error as UsageError {
            throw error
        } catch {
            // 通信エラー。まだ実際には期限内ならそのまま使う。
            if !forceRefresh && !stored.isExpired { return stored }
            throw UsageError("トークン更新の通信に失敗しました")
        }
    }

    private static func refresh(_ provider: Provider, _ stored: OAuthCredential) async throws -> OAuthCredential {
        switch provider {
        case .claude:
            let json = try await postJSON(OAuthConfig.claudeToken, body: [
                "grant_type": "refresh_token",
                "client_id": OAuthConfig.claudeClientID,
                "refresh_token": stored.refresh
            ], refreshing: true)
            return try credential(from: json, previous: stored, accountFromJWT: false)
        case .codex:
            let json = try await postForm(OAuthConfig.codexToken, fields: [
                ("grant_type", "refresh_token"),
                ("refresh_token", stored.refresh),
                ("client_id", OAuthConfig.codexClientID)
            ], refreshing: true)
            return try credential(from: json, previous: stored, accountFromJWT: true)
        }
    }

    private static func credential(from json: [String: Any], previous: OAuthCredential?, accountFromJWT: Bool) throws -> OAuthCredential {
        guard let access = json["access_token"] as? String, !access.isEmpty,
              let expiresIn = (json["expires_in"] as? NSNumber)?.doubleValue else {
            throw UsageError("トークン応答の形式が不正です")
        }
        guard let refresh = (json["refresh_token"] as? String) ?? previous?.refresh, !refresh.isEmpty else {
            throw UsageError("トークン応答にrefresh tokenがありません")
        }
        var accountID = previous?.accountId
        if accountFromJWT {
            accountID = jwtAccountID(access) ?? accountID
            if accountID == nil { throw UsageError("アカウントIDをトークンから取得できません") }
        }
        return OAuthCredential(
            access: access,
            refresh: refresh,
            expires: Date().timeIntervalSince1970 * 1000 + expiresIn * 1000,
            accountId: accountID
        )
    }

    private static func jwtAccountID(_ token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var base64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: base64),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let auth = payload["https://api.openai.com/auth"] as? [String: Any],
              let id = auth["chatgpt_account_id"] as? String, !id.isEmpty else { return nil }
        return id
    }

    // MARK: HTTP

    private static func formEncode(_ pairs: [(String, String)]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return pairs.map {
            "\($0.0.addingPercentEncoding(withAllowedCharacters: allowed)!)=\($0.1.addingPercentEncoding(withAllowedCharacters: allowed)!)"
        }.joined(separator: "&")
    }

    private static func postJSON(_ address: String, body: [String: String], refreshing: Bool = false) async throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: body)
        return try await post(address, contentType: "application/json", body: data, refreshing: refreshing)
    }

    private static func postForm(_ address: String, fields: [(String, String)], refreshing: Bool = false) async throws -> [String: Any] {
        try await post(address, contentType: "application/x-www-form-urlencoded",
                       body: Data(formEncode(fields).utf8), refreshing: refreshing)
    }

    private static func post(_ address: String, contentType: String, body: Data, refreshing: Bool) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: address)!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.httpBody = body
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw UsageError("応答が不正です") }
        guard (200..<300).contains(http.statusCode) else {
            if refreshing && (http.statusCode == 400 || http.statusCode == 401) {
                throw UsageError("ログインの有効期限が切れました。メニューから再ログインしてください", authFailure: true)
            }
            // 応答本文にトークンや個人情報が含まれ得るためUIには出さない。
            throw UsageError("トークン取得に失敗しました（HTTP \(http.statusCode)）")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageError("トークン応答を読み取れません")
        }
        return json
    }
}
