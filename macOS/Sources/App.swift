import AppKit
import Foundation
import Sparkle

@MainActor
final class TrayApp: NSObject, NSApplicationDelegate, SettingsHost, SPUUpdaterDelegate {
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var fetching = false
    let providers = ProviderRegistry.all
    private var results: [String: QuotaResult] = [:]
    private var panels: [String: QuotaMenuView] = [:]
    private var loggingIn = Set<String>()
    private var settings: SettingsWindowController?
    private var updaterController: SPUStandardUpdaterController!
    private var pendingInstall: (() -> Void)?

    private let menu = NSMenu()
    private let refreshed = NSMenuItem(title: "未更新", action: nil, keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // No Dock icon; menu-bar only.
        // 自動アップデート（Sparkle）。ダウンロードと検証はバックグラウンドで行う。
        updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.imagePosition = .imageOnly
        for provider in providers { results[provider.id] = .failure("未取得") }
        buildMenu()
        updateStatusImage()
        statusItem.menu = menu
        timer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refreshNow() }
        }
        Task { await refreshNow() }
        if CommandLine.arguments.contains("--settings") { openSettings() }
    }

    // MARK: メニュー（プロバイダ一覧から自動生成）

    private func buildMenu() {
        menu.autoenablesItems = false
        for provider in providers {
            let view = QuotaMenuView(title: provider.displayName)
            panels[provider.id] = view
            let item = NSMenuItem()
            item.view = view
            menu.addItem(item)
            menu.addItem(.separator())
        }
        refreshed.isEnabled = false
        menu.addItem(refreshed)
        menu.addItem(action("今すぐ更新", #selector(refreshClicked), key: "r"))
        menu.addItem(.separator())

        menu.addItem(action("設定…", #selector(openSettings), key: ","))
        menu.addItem(.separator())
        menu.addItem(action("終了", #selector(quit), key: "q"))
    }

    private func action(_ title: String, _ selector: Selector, key: String = "", id: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = self
        item.representedObject = id
        return item
    }

    @objc private func refreshClicked() { Task { await refreshNow() } }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func openSettings() {
        if settings == nil { settings = SettingsWindowController(host: self) }
        settings?.show()
    }

    // MARK: SettingsHost

    func status(for provider: any QuotaProvider) -> ProviderStatus {
        let stored = provider.hasStoredLogin
        let loggingIn = loggingIn.contains(provider.id)
        switch results[provider.id] {
        case .success(let snapshot)?:
            let summary = snapshot.windows.map { "\($0.label) \($0.percentage)" }.joined(separator: " / ")
            let state: LoginState = stored ? .app : (provider.supportsLogin ? .cli : .working)
            return ProviderStatus(state: state, summary: summary, loggingIn: loggingIn, hasStoredLogin: stored)
        case .failure(let message)?:
            let state: LoginState
            if message == "未取得" { state = .checking }
            else if !stored && message.hasPrefix("要ログイン") { state = .loggedOut }
            else { state = .failing(message) }
            return ProviderStatus(state: state, summary: "", loggingIn: loggingIn, hasStoredLogin: stored)
        case nil:
            return ProviderStatus(state: .checking, summary: "", loggingIn: loggingIn, hasStoredLogin: stored)
        }
    }

    func settingsLogin(_ provider: any QuotaProvider) { Task { await login(provider) } }

    func settingsLogout(_ provider: any QuotaProvider) {
        provider.logout()
        settings?.reload()
        Task { await refreshNow() }
    }

    func settingsVisibilityChanged() { updateStatusImage() }

    var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    var autoUpdate: Bool {
        get { updaterController.updater.automaticallyDownloadsUpdates }
        set {
            updaterController.updater.automaticallyChecksForUpdates = newValue
            updaterController.updater.automaticallyDownloadsUpdates = newValue
        }
    }

    func settingsCheckForUpdates() { updaterController.checkForUpdates(nil) }

    // MARK: 自動アップデート
    // ダウンロード済みの更新を、ユーザーに確認せず即時に適用して自動で再起動する。
    // ログイン操作の途中だけは、終わるまで待つ。

    nonisolated func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                             immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        Task { @MainActor in
            self.pendingInstall = immediateInstallHandler
            self.installPendingUpdateIfIdle()
        }
        return true
    }

    private func installPendingUpdateIfIdle() {
        guard loggingIn.isEmpty, let install = pendingInstall else { return }
        pendingInstall = nil
        install()
    }

    // アプリ内蔵のOAuth（PKCE）。既定ブラウザで認可し、localhostで認可コードを受け取る。
    private func login(_ provider: any QuotaProvider) async {
        guard loggingIn.insert(provider.id).inserted else { return }
        settings?.reload()
        defer {
            loggingIn.remove(provider.id)
            settings?.reload()
            installPendingUpdateIfIdle()
        }
        do {
            try await provider.login { url in NSWorkspace.shared.open(url) }
            await refreshNow()
        } catch let error as UsageError {
            showAlert(error.message)
        } catch {
            showAlert("\(provider.displayName)のログインに失敗しました。もう一度お試しください。")
        }
    }

    private func showAlert(_ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "CodeQuota Tray"
        alert.informativeText = text
        alert.runModal()
    }

    // MARK: 取得と描画

    private func refreshNow() async {
        guard !fetching else { return }
        fetching = true
        refreshed.title = "更新中…"
        let targets = providers
        await withTaskGroup(of: (String, QuotaResult).self) { group in
            for provider in targets {
                group.addTask { (provider.id, await provider.fetch()) }
            }
            for await (id, result) in group { results[id] = result }
        }
        fetching = false
        render()
    }

    private func render() {
        updateStatusImage()
        settings?.reload()
        for provider in providers {
            panels[provider.id]?.update(results[provider.id] ?? .failure("未取得"))
        }
        refreshed.title = "確認日時：\(DateFormatter.localizedString(from: .now, dateStyle: .none, timeStyle: .short))（10分ごとに更新）"
    }

    private func updateStatusImage() {
        let visible = providers.filter { Preferences.isVisibleInMenuBar($0.id) }
        if visible.isEmpty {
            // 全て非表示でもメニューに到達できるよう、汎用アイコンを出す。
            statusItem.button?.image = NSImage(systemSymbolName: "chart.bar.fill", accessibilityDescription: "CodeQuota Tray")
        } else {
            let groups = visible.map { provider -> (name: String, values: [Double?]) in
                var snapshot: UsageSnapshot?
                if case let .success(value)? = results[provider.id] { snapshot = value }
                return (provider.shortName, provider.barWindowIDs.map { snapshot?.window($0)?.remaining })
            }
            statusItem.button?.image = Gauge.statusImage(groups: groups)
        }
        statusItem.button?.toolTip = providers.map { provider -> String in
            switch results[provider.id] {
            case .success(let snapshot)?:
                let parts = snapshot.windows.map { "\($0.label) \($0.percentage)" }.joined(separator: " / ")
                return "\(provider.displayName)  \(parts)"
            case .failure(let message)?:
                return "\(provider.displayName)  \(message)"
            case nil:
                return provider.displayName
            }
        }.joined(separator: "\n")
    }
}

@MainActor
@main
struct CodeQuotaMac {
    static func main() {
        let app = NSApplication.shared
        let delegate = TrayApp()
        app.delegate = delegate
        app.run()
    }
}
