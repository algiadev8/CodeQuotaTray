namespace CodeQuotaTray;

// プロバイダ設定ウィンドウ。プロバイダ一覧（ProviderRegistry）から行を自動生成するので、
// 新しいプロバイダを追加してもこのファイルの変更は不要。

internal enum LoginState
{
    Checking,
    App,        // このアプリのログイン情報で取得できている
    Cli,        // CLIの認証情報（読み取り専用）で取得できている
    Working,    // ログイン不要のプロバイダで取得できている
    LoggedOut,
    Failing
}

internal sealed record ProviderStatus(LoginState State, string? Message, string Summary, bool LoggingIn, bool HasStoredLogin);

internal sealed class SettingsForm : Form
{
    private sealed class Row
    {
        public required IQuotaProvider Provider;
        public required Label Status;
        public required Label Summary;
        public required Button Login;
        public required Button Logout;
        public required CheckBox Visible;
    }

    private readonly Func<IQuotaProvider, ProviderStatus> statusOf;
    private readonly Func<IQuotaProvider, Task> login;
    private readonly Func<IQuotaProvider, Task> logout;
    private readonly Func<IQuotaProvider, bool, bool> setVisible;
    private readonly List<Row> rows = new();
    private bool reloading;

    public SettingsForm(
        IReadOnlyList<IQuotaProvider> providers,
        Func<IQuotaProvider, ProviderStatus> statusOf,
        Func<IQuotaProvider, Task> login,
        Func<IQuotaProvider, Task> logout,
        Func<IQuotaProvider, bool, bool> setVisible)
    {
        this.statusOf = statusOf;
        this.login = login;
        this.logout = logout;
        this.setVisible = setVisible;

        Text = "CodeQuota Tray 設定";
        Font = SystemFonts.MessageBoxFont ?? SystemFonts.DefaultFont;
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = false;
        MinimizeBox = false;
        ShowInTaskbar = true;
        StartPosition = FormStartPosition.CenterScreen;
        AutoScaleMode = AutoScaleMode.Dpi;
        AutoScaleDimensions = new SizeF(96F, 96F);

        var flow = new FlowLayoutPanel
        {
            Dock = DockStyle.Fill,
            FlowDirection = FlowDirection.TopDown,
            WrapContents = false,
            AutoScroll = true,
            Padding = new Padding(14)
        };
        flow.Controls.Add(new Label
        {
            Text = "プロバイダ",
            AutoSize = true,
            Font = new Font(Font.FontFamily, Font.Size + 2, FontStyle.Bold),
            Margin = new Padding(0, 0, 0, 8)
        });
        foreach (var provider in providers) flow.Controls.Add(BuildRow(provider));
        Controls.Add(flow);

        int height = 56 + providers.Count * 138 + 28;
        ClientSize = new Size(520, Math.Min(height, 640));
        ReloadStatus();
    }

    private GroupBox BuildRow(IQuotaProvider provider)
    {
        var box = new GroupBox { Text = provider.DisplayName, Size = new Size(488, 126), Margin = new Padding(0, 0, 0, 12) };
        var status = new Label { Location = new Point(12, 24), Size = new Size(464, 20), AutoEllipsis = true };
        var summary = new Label { Location = new Point(12, 46), Size = new Size(464, 18), ForeColor = SystemColors.GrayText };
        var loginButton = new Button { Location = new Point(12, 72), Size = new Size(230, 28), UseVisualStyleBackColor = true };
        var logoutButton = new Button { Text = "ログアウト", Location = new Point(250, 72), Size = new Size(110, 28), UseVisualStyleBackColor = true };
        var visible = new CheckBox { Text = "トレイにアイコンを表示", Location = new Point(12, 102), AutoSize = true };

        var row = new Row { Provider = provider, Status = status, Summary = summary, Login = loginButton, Logout = logoutButton, Visible = visible };
        loginButton.Click += async (_, _) => { await login(provider); ReloadStatus(); };
        logoutButton.Click += async (_, _) => { await logout(provider); ReloadStatus(); };
        visible.CheckedChanged += (_, _) =>
        {
            if (reloading) return;
            setVisible(provider, visible.Checked);
            ReloadStatus(); // 拒否された場合（最後の1つ）はチェックを戻す
        };
        box.Controls.AddRange(new Control[] { status, summary, loginButton, logoutButton, visible });
        rows.Add(row);
        return box;
    }

    public void ReloadStatus()
    {
        reloading = true;
        try
        {
            foreach (var row in rows)
            {
                var s = statusOf(row.Provider);
                bool showLogin = row.Provider.SupportsLogin;
                string loginTitle = s.HasStoredLogin ? "再ログイン…" : "ログイン…";
                string text;
                Color color;
                switch (s.State)
                {
                    case LoginState.App: text = "ログイン済み"; color = Gauge.Green; showLogin = false; break;
                    case LoginState.Cli: text = "ログイン済み（CLIの認証情報を使用中）"; color = Gauge.Green; loginTitle = "アプリ専用のログインに切り替え…"; break;
                    case LoginState.Working: text = "取得できています"; color = Gauge.Green; break;
                    case LoginState.LoggedOut: text = "未ログイン"; color = SystemColors.GrayText; break;
                    case LoginState.Failing: text = s.Message ?? "取得失敗"; color = Color.DarkOrange; break;
                    default: text = "確認中…"; color = SystemColors.GrayText; break;
                }
                if (s.LoggingIn) { text = "ブラウザでログインを完了してください…"; color = Color.RoyalBlue; }
                row.Status.Text = "● " + text;
                row.Status.ForeColor = color;
                row.Summary.Text = s.Summary;
                row.Login.Text = loginTitle;
                row.Login.Visible = showLogin;
                row.Login.Enabled = !s.LoggingIn;
                row.Logout.Visible = row.Provider.SupportsLogin && s.HasStoredLogin;
                row.Visible.Checked = Preferences.IsVisibleInTray(row.Provider.Id);
            }
        }
        finally { reloading = false; }
    }
}
