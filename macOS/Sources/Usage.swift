import Foundation

// The two quota APIs are undocumented and may change. The app uses its own OAuth
// login (see OAuth.swift). If the user has not logged in, it falls back to
// read-only use of the official CLIs' credentials; CLI tokens are never modified.
/// 1つの制限枠（例：5時間枠、週次枠）。id はメニューバーのバー割り当てに、label は表示に使う。
struct QuotaWindow: Sendable {
    let remaining: Double
    let resetsAt: Date?
    var id: String = ""
    var label: String = ""

    var percentage: String { "\(Int(remaining.rounded()))%" }

    func with(id: String, label: String) -> QuotaWindow {
        var copy = self
        copy.id = id
        copy.label = label
        return copy
    }
}

/// プロバイダ1つぶんの取得結果。制限枠は任意個数（表示順）。
struct UsageSnapshot: Sendable {
    let windows: [QuotaWindow]
    let capturedAt: Date

    init(windows: [QuotaWindow], capturedAt: Date) {
        self.windows = windows
        self.capturedAt = capturedAt
    }

    /// Codex / Claude 共通の「5時間 + 週次」形式
    init(fiveHour: QuotaWindow?, weekly: QuotaWindow?, capturedAt: Date) {
        self.init(windows: [fiveHour?.with(id: "5h", label: "5時間"),
                            weekly?.with(id: "week", label: "週次")].compactMap { $0 },
                  capturedAt: capturedAt)
    }

    func window(_ id: String) -> QuotaWindow? { windows.first { $0.id == id } }
}

enum QuotaResult: Sendable {
    case success(UsageSnapshot)
    case failure(String)
}

enum Provider: String {
    case codex = "Codex"
    case claude = "Claude"
}

enum UsageClient {
    static func fetch(_ provider: Provider) async -> QuotaResult {
        do {
            switch provider {
            case .codex: return .success(try await fetchCodex())
            case .claude: return .success(try await fetchClaude())
            }
        } catch let error as UsageError {
            return .failure(error.message)
        } catch {
            // Do not surface network bodies or credential data in UI/logs.
            return .failure("通信エラー（接続環境を確認）")
        }
    }

    private static func fetchCodex() async throws -> UsageSnapshot {
        if let own = try await OAuthManager.credential(for: .codex) {
            do {
                return try await queryCodex(token: own.access, accountID: own.accountId)
            } catch let error as UsageError where error.authFailure {
                guard let fresh = try await OAuthManager.credential(for: .codex, forceRefresh: true) else { throw error }
                return try await queryCodex(token: fresh.access, accountID: fresh.accountId)
            }
        }
        // 未ログイン：Codex CLI の認証情報を読み取り専用で利用
        let configHome = ProcessInfo.processInfo.environment["CODEX_HOME"]
            .map { NSString(string: $0).expandingTildeInPath }
            ?? NSHomeDirectory() + "/.codex"
        guard let auth = try? codexCredentials(configHome: configHome),
              let tokens = auth["tokens"] as? [String: Any],
              let token = tokens["access_token"] as? String, !token.isEmpty else {
            throw UsageError("要ログイン：メニューから「Codexにログイン」")
        }
        return try await queryCodex(token: token, accountID: tokens["account_id"] as? String)
    }

    private static func queryCodex(token: String, accountID: String?) async throws -> UsageSnapshot {
        var headers: [String: String] = [:]
        if let accountID, !accountID.isEmpty { headers["ChatGPT-Account-Id"] = accountID }
        let json = try await requestJSON(
            "https://chatgpt.com/backend-api/wham/usage",
            bearer: token,
            headers: headers
        )
        let root = (json["rate_limit"] ?? json["rate_limits"]) as? [String: Any] ?? [:]
        var five: QuotaWindow?
        var week: QuotaWindow?
        // In 2026 the primary window can be weekly when the 5h window is absent.
        for (keys, defaultWeekly) in [(["five_hour", "primary_window", "primary"], false),
                                       (["weekly", "secondary_window", "secondary"], true)] {
            guard let object = keys.compactMap({ root[$0] as? [String: Any] }).first,
                  let parsed = parseCodexWindow(object) else { continue }
            let seconds = number(object["limit_window_seconds"])
            let isWeekly = seconds.map { $0 >= 172_800 } ?? defaultWeekly
            if isWeekly { week = parsed } else { five = parsed }
        }
        guard five != nil || week != nil else { throw UsageError("使用量の形式が変更された可能性があります") }
        return UsageSnapshot(fiveHour: five, weekly: week, capturedAt: .now)
    }

    private static func fetchClaude() async throws -> UsageSnapshot {
        if let own = try await OAuthManager.credential(for: .claude) {
            do {
                return try await queryClaude(token: own.access)
            } catch let error as UsageError where error.authFailure {
                guard let fresh = try await OAuthManager.credential(for: .claude, forceRefresh: true) else { throw error }
                return try await queryClaude(token: fresh.access)
            }
        }
        // 未ログイン：Claude Code の認証情報を読み取り専用で利用（更新はしない）
        guard let oauth = try? claudeCredentials(),
              let token = oauth["accessToken"] as? String, !token.isEmpty else {
            throw UsageError("要ログイン：メニューから「Claudeにログイン」")
        }
        if let expiry = number(oauth["expiresAt"]),
           Date(timeIntervalSince1970: expiry / 1000) < .now {
            throw UsageError("Claudeの認証期限切れ：メニューから「Claudeにログイン」")
        }
        return try await queryClaude(token: token)
    }

    private static func queryClaude(token: String) async throws -> UsageSnapshot {
        let json = try await requestJSON(
            "https://api.anthropic.com/api/oauth/usage",
            bearer: token,
            headers: ["anthropic-beta": "oauth-2025-04-20"]
        )
        let five = (json["five_hour"] as? [String: Any]).flatMap(parseClaudeWindow)
        let week = (json["seven_day"] as? [String: Any]).flatMap(parseClaudeWindow)
        guard five != nil || week != nil else { throw UsageError("使用量が取得できません（契約またはAPIの変更）") }
        return UsageSnapshot(fiveHour: five, weekly: week, capturedAt: .now)
    }

    // 未ログイン時のみ使う、CLIの認証ファイルの読み取り専用フォールバック。
    // Keychainは読まない（他アプリの項目へのアクセスで許可ダイアログが出るため）。
    private static func codexCredentials(configHome: String) throws -> [String: Any] {
        try jsonFile(at: configHome + "/auth.json")
    }

    private static func claudeCredentials() throws -> [String: Any] {
        // Honor the CLI's custom home before the conventional path.
        let configDirs = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]
            .map { $0.split(separator: ",").map(String.init) } ?? []
        let base = configDirs.first.map { NSString(string: $0).expandingTildeInPath }
            ?? NSHomeDirectory() + "/.claude"
        if let data = try? Data(contentsOf: URL(fileURLWithPath: base + "/.credentials.json")),
           let oauth = oauthFrom(data) {
            return oauth
        }
        throw UsageError("要ログイン")
    }

    private static func oauthFrom(_ data: Data) -> [String: Any]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return root["claudeAiOauth"] as? [String: Any]
    }

    private static func jsonFile(at path: String) throws -> [String: Any] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageError("認証ファイルがありません。メニューからログインしてください")
        }
        return value
    }

    private static func requestJSON(
        _ address: String,
        bearer: String,
        headers: [String: String]
    ) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: address)!)
        request.timeoutInterval = 15
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("CodeQuotaTray/1.0", forHTTPHeaderField: "User-Agent")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw UsageError("応答が不正です") }
        switch http.statusCode {
        case 200: break
        case 401, 403: throw UsageError("認証期限切れ / 権限不足（再ログインしてください）", authFailure: true)
        case 429: throw UsageError("APIの回数制限（後で再更新してください）")
        default: throw UsageError("APIエラー（HTTP \(http.statusCode)）")
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageError("JSONの読み取りに失敗しました")
        }
        return root
    }

    private static func parseCodexWindow(_ object: [String: Any]) -> QuotaWindow? {
        let remaining: Double?
        if let left = number(object["percent_left"]) {
            remaining = left
        } else if let used = number(object["used_percent"] ?? object["usedPercent"]) {
            remaining = 100 - used
        } else { remaining = nil }
        guard let value = remaining, (0...100).contains(value) else { return nil }
        let reset = dateFromAny(object["reset_time_ms"], milliseconds: true)
            ?? dateFromAny(object["resetsAt"])
            ?? dateFromAny(object["reset_at"])
        return QuotaWindow(remaining: value, resetsAt: reset)
    }

    private static func parseClaudeWindow(_ object: [String: Any]) -> QuotaWindow? {
        guard let used = number(object["utilization"]), (0...100).contains(used) else { return nil }
        return QuotaWindow(remaining: 100 - used, resetsAt: dateFromAny(object["resets_at"]))
    }

    private static func number(_ value: Any?) -> Double? {
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s) }
        return nil
    }

    private static func dateFromAny(_ value: Any?, milliseconds: Bool = false) -> Date? {
        if let n = number(value) {
            return Date(timeIntervalSince1970: milliseconds ? n / 1000 : (n > 10_000_000_000 ? n / 1000 : n))
        }
        guard let str = value as? String else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: str) { return date }
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: str)
    }
}

struct UsageError: Error {
    let message: String
    /// 401/403 など、トークン更新で回復し得る認証エラー
    let authFailure: Bool
    init(_ message: String, authFailure: Bool = false) {
        self.message = message
        self.authFailure = authFailure
    }
}
