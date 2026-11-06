import AppKit
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
    /// メニューバーに描く枠の id（最大2本。左から順）
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

    private static func colorKey(_ id: String) -> String { "menubar.color.\(id)" }

    /// 安定した ID から既定色を決める（Swift のランダム化された hashValue は使わない）。
    private static func defaultMenuBarColor(for id: String) -> NSColor {
        switch id {
        case "codex": return NSColor(srgbRed: 0.06, green: 0.65, blue: 0.48, alpha: 1)
        case "claude": return NSColor(srgbRed: 0.83, green: 0.43, blue: 0.29, alpha: 1)
        default:
            let hash = id.utf8.reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1)) &* 1099511628211 }
            return NSColor(calibratedHue: CGFloat(hash % 360) / 360, saturation: 0.65, brightness: 0.8, alpha: 1)
                .usingColorSpace(.sRGB) ?? NSColor(srgbRed: 0.3, green: 0.5, blue: 0.8, alpha: 1)
        }
    }

    static func menuBarColor(for provider: any QuotaProvider) -> NSColor {
        guard let components = UserDefaults.standard.array(forKey: colorKey(provider.id)) as? [Double],
              components.count == 3,
              components.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
            return defaultMenuBarColor(for: provider.id)
        }
        return NSColor(srgbRed: CGFloat(components[0]), green: CGFloat(components[1]),
                       blue: CGFloat(components[2]), alpha: 1)
    }

    static func setMenuBarColor(_ color: NSColor, for provider: any QuotaProvider) {
        guard let rgb = color.usingColorSpace(.sRGB) else { return }
        let components = [Double(rgb.redComponent), Double(rgb.greenComponent), Double(rgb.blueComponent)]
        guard components.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { return }
        UserDefaults.standard.set(components, forKey: colorKey(provider.id))
    }

    static func isVisibleInMenuBar(_ id: String) -> Bool {
        !UserDefaults.standard.bool(forKey: key(id))
    }

    static func setVisibleInMenuBar(_ id: String, _ visible: Bool) {
        UserDefaults.standard.set(!visible, forKey: key(id))
    }
}
