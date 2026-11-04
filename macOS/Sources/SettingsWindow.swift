import AppKit

// プロバイダ設定ウィンドウ。プロバイダ一覧（ProviderRegistry）から行を自動生成するので、
// 新しいプロバイダを追加してもこのファイルの変更は不要。

enum LoginState {
    case checking
    case app               // このアプリのログイン情報で取得できている
    case cli               // CLIの認証情報（読み取り専用）で取得できている
    case working           // ログイン不要のプロバイダで取得できている
    case loggedOut
    case failing(String)
}

struct ProviderStatus {
    var state: LoginState
    var summary: String
    var loggingIn: Bool
    var hasStoredLogin: Bool
}

@MainActor
protocol SettingsHost: AnyObject {
    var providers: [any QuotaProvider] { get }
    func status(for provider: any QuotaProvider) -> ProviderStatus
    func settingsLogin(_ provider: any QuotaProvider)
    func settingsLogout(_ provider: any QuotaProvider)
    func settingsVisibilityChanged()
    var appVersion: String { get }
    var autoUpdate: Bool { get set }
    func settingsCheckForUpdates()
}

/// 角丸の枠つきカード。内容の NSStackView を余白つきで固定する。
@MainActor
class CardView: NSView {
    init() {
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
    }

    func install(_ stack: NSStackView, fillingWidth fill: [NSView] = []) {
        stack.translatesAutoresizingMaskIntoConstraints = false
        fill.forEach { $0.translatesAutoresizingMaskIntoConstraints = false }
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14)
        ] + fill.map { $0.widthAnchor.constraint(equalTo: stack.widthAnchor) })
    }
}

@MainActor
final class UpdateRowView: CardView {
    private weak var host: SettingsHost?
    private let versionLabel = NSTextField(labelWithString: "")
    private let autoCheck = NSButton(checkboxWithTitle: "自動でアップデートする", target: nil, action: nil)
    private let checkButton = NSButton(title: "今すぐ確認", target: nil, action: nil)

    init(host: SettingsHost) {
        self.host = host
        super.init()
        let name = NSTextField(labelWithString: "アップデート")
        name.font = .boldSystemFont(ofSize: 14)
        versionLabel.font = .systemFont(ofSize: 12)
        versionLabel.textColor = .secondaryLabelColor
        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        let header = NSStackView(views: [name, spacer, checkButton])
        header.orientation = .horizontal
        let stack = NSStackView(views: [header, versionLabel, autoCheck])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        install(stack, fillingWidth: [header])
        checkButton.target = self
        checkButton.action = #selector(checkClicked)
        autoCheck.target = self
        autoCheck.action = #selector(autoClicked)
        reload()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func checkClicked() { host?.settingsCheckForUpdates() }
    @objc private func autoClicked() { host?.autoUpdate = autoCheck.state == .on }

    func reload() {
        guard let host else { return }
        versionLabel.stringValue = "現在のバージョン \(host.appVersion)"
        autoCheck.state = host.autoUpdate ? .on : .off
    }
}

@MainActor
final class ProviderRowView: CardView {
    private let provider: any QuotaProvider
    private weak var host: SettingsHost?
    private let statusLabel = NSTextField(labelWithString: "")
    private let summaryLabel = NSTextField(labelWithString: "")
    private let loginButton = NSButton(title: "", target: nil, action: nil)
    private let logoutButton = NSButton(title: "ログアウト", target: nil, action: nil)
    private let visibleCheck = NSButton(checkboxWithTitle: "メニューバーに表示", target: nil, action: nil)

    init(provider: any QuotaProvider, host: SettingsHost) {
        self.provider = provider
        self.host = host
        super.init()

        let name = NSTextField(labelWithString: provider.displayName)
        name.font = .boldSystemFont(ofSize: 14)
        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        let header = NSStackView(views: [name, spacer, visibleCheck])
        header.orientation = .horizontal

        statusLabel.font = .systemFont(ofSize: 12)
        summaryLabel.font = .systemFont(ofSize: 11)
        summaryLabel.textColor = .secondaryLabelColor

        let buttons = NSStackView(views: [loginButton, logoutButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let stack = NSStackView(views: [header, statusLabel, summaryLabel, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        install(stack, fillingWidth: [header])

        loginButton.target = self
        loginButton.action = #selector(loginClicked)
        logoutButton.target = self
        logoutButton.action = #selector(logoutClicked)
        visibleCheck.target = self
        visibleCheck.action = #selector(visibilityClicked)
        reload()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func loginClicked() { host?.settingsLogin(provider) }
    @objc private func logoutClicked() { host?.settingsLogout(provider) }
    @objc private func visibilityClicked() {
        Preferences.setVisibleInMenuBar(provider.id, visibleCheck.state == .on)
        host?.settingsVisibilityChanged()
    }

    private func dotted(_ text: String, _ color: NSColor) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "● ", attributes: [.foregroundColor: color])
        result.append(NSAttributedString(string: text, attributes: [.foregroundColor: NSColor.labelColor]))
        return result
    }

    func reload() {
        guard let status = host?.status(for: provider) else { return }
        var showLogin = provider.supportsLogin
        var loginTitle = status.hasStoredLogin ? "再ログイン…" : "ログイン…"
        switch status.state {
        case .checking:
            statusLabel.attributedStringValue = dotted("確認中…", .secondaryLabelColor)
        case .app:
            statusLabel.attributedStringValue = dotted("ログイン済み", .systemGreen)
            showLogin = false
        case .cli:
            statusLabel.attributedStringValue = dotted("ログイン済み（CLIの認証情報を使用中）", .systemGreen)
            loginTitle = "アプリ専用のログインに切り替え…"
        case .working:
            statusLabel.attributedStringValue = dotted("取得できています", .systemGreen)
        case .loggedOut:
            statusLabel.attributedStringValue = dotted("未ログイン", .secondaryLabelColor)
        case .failing(let message):
            statusLabel.attributedStringValue = dotted(message, .systemOrange)
        }
        if status.loggingIn {
            statusLabel.attributedStringValue = dotted("ブラウザでログインを完了してください…", .systemBlue)
        }
        loginButton.title = loginTitle
        loginButton.isHidden = !showLogin
        loginButton.isEnabled = !status.loggingIn
        logoutButton.isHidden = !(provider.supportsLogin && status.hasStoredLogin)
        summaryLabel.stringValue = status.summary
        summaryLabel.isHidden = status.summary.isEmpty
        visibleCheck.state = Preferences.isVisibleInMenuBar(provider.id) ? .on : .off
    }
}

@MainActor
final class SettingsWindowController: NSWindowController {
    private let rows: [ProviderRowView]
    private let updateRow: UpdateRowView
    private static let width: CGFloat = 520

    init(host: SettingsHost) {
        rows = host.providers.map { ProviderRowView(provider: $0, host: host) }
        updateRow = UpdateRowView(host: host)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 300),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "CodeQuota Tray 設定"
        window.isReleasedWhenClosed = false
        super.init(window: window)

        let heading = NSTextField(labelWithString: "プロバイダ")
        heading.font = .boldSystemFont(ofSize: 15)
        let stack = NSStackView(views: [heading] + rows + [updateRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        let inset: CGFloat = 20
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: Self.width),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: inset),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -inset),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: inset),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -inset)
        ] + (rows + [updateRow]).map { $0.widthAnchor.constraint(equalTo: stack.widthAnchor) })
        window.contentView = container
        resizeToFit()
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show() {
        reload()
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    var isVisible: Bool { window?.isVisible ?? false }

    func reload() {
        rows.forEach { $0.reload() }
        updateRow.reload()
        resizeToFit()
    }

    /// 内容の高さに合わせてウィンドウを調整（上端は固定）。
    private func resizeToFit() {
        guard let window, let content = window.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let target = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: Self.width, height: content.fittingSize.height))
        var frame = window.frame
        frame.origin.y += frame.height - target.height
        frame.size = target.size
        window.setFrame(frame, display: true)
    }
}
