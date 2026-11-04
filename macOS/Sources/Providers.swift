import Foundation

// 使用量プロバイダの拡張ポイント。
// 新しいサービス（OpenCode など）を追加するには:
//   1. QuotaProvider に準拠した型を作り（fetch で QuotaResult を返す）
//   2. ProviderRegistry.all に追加するだけ。メニュー・メニューバー・ログイン項目・
//      「メニューバーに表示」切替は自動で増えます。
protocol QuotaProvider: Sendable {
    /// 永続キー（設定の保存に使用）。変更しないこと。
    var id: String { get }
    var displayName: String { get }
    /// メニューバーのバー横に出す短いラベル（2文字程度）
    var shortName: String { get }
    /// メニューバーに描く枠の id（最大2本。上から順）
    var barWindowIDs: [String] { get }
    var supportsLogin: Bool { get }
    /// アプリ自身のログイン情報（トークン）が保存されているか
    var hasStoredLogin: Bool { get }
    func fetch() async -> QuotaResult
    @MainActor func login(openURL: @escaping (URL) -> Void) async throws
    func logout()
}

extension QuotaProvider {
    var barWindowIDs: [String] { ["5h", "week"] }
    var supportsLogin: Bool { false }
    var hasStoredLogin: Bool { false }
    @MainActor func login(openURL: @escaping (URL) -> Void) async throws {}
    func logout() {}
}

struct CodexProvider: QuotaProvider {
    let id = "codex"
    let displayName = "Codex"
    let shortName = "Cx"
    var supportsLogin: Bool { true }
    var hasStoredLogin: Bool { CredentialStore.exists(.codex) }
    func fetch() async -> QuotaResult { await UsageClient.fetch(.codex) }
    @MainActor func login(openURL: @escaping (URL) -> Void) async throws {
        _ = try await OAuthManager.login(.codex, openURL: openURL)
    }
    func logout() { CredentialStore.delete(.codex) }
}

struct ClaudeProvider: QuotaProvider {
    let id = "claude"
    let displayName = "Claude"
    let shortName = "Cl"
    var supportsLogin: Bool { true }
    var hasStoredLogin: Bool { CredentialStore.exists(.claude) }
    func fetch() async -> QuotaResult { await UsageClient.fetch(.claude) }
    @MainActor func login(openURL: @escaping (URL) -> Void) async throws {
        _ = try await OAuthManager.login(.claude, openURL: openURL)
    }
    func logout() { CredentialStore.delete(.claude) }
}

enum ProviderRegistry {
    /// 表示順。ここに追加すれば UI に反映される。
    static let all: [any QuotaProvider] = [CodexProvider(), ClaudeProvider()]
}

/// ユーザー設定（UserDefaults）
enum Preferences {
    private static func key(_ id: String) -> String { "menubar.hidden.\(id)" }

    static func isVisibleInMenuBar(_ id: String) -> Bool {
        !UserDefaults.standard.bool(forKey: key(id))
    }

    static func setVisibleInMenuBar(_ id: String, _ visible: Bool) {
        UserDefaults.standard.set(!visible, forKey: key(id))
    }
}
