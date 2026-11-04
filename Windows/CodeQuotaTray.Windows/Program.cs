namespace CodeQuotaTray;

internal static class Program
{
    [STAThread]
    private static void Main()
    {
        ApplicationConfiguration.Initialize();
        Application.Run(new TrayContext());
    }
}

/// <summary>プロバイダ一覧（ProviderRegistry）から、トレイアイコンとメニューを自動生成する。</summary>
internal sealed class TrayContext : ApplicationContext
{
    private sealed class MenuParts
    {
        public required ContextMenuStrip Menu;
        public required Dictionary<string, QuotaPanelControl> Panels;
        public required Dictionary<string, ToolStripControlHost> Hosts;
        public required ToolStripMenuItem Updated;
    }

    private sealed class ProviderIcon
    {
        public required IQuotaProvider Provider;
        public required NotifyIcon Icon;
        public required MenuParts Parts;
    }

    private readonly IReadOnlyList<IQuotaProvider> providers = ProviderRegistry.All;
    private readonly List<ProviderIcon> icons = new();
    private readonly Dictionary<string, QuotaResult> results = new();
    private readonly HashSet<string> loggingIn = new();
    private SettingsForm? settingsForm;
    private readonly System.Windows.Forms.Timer timer;
    private bool fetching;

    public TrayContext()
    {
        foreach (var provider in providers) results[provider.Id] = new QuotaResult(null, "未取得");
        foreach (var provider in providers) icons.Add(CreateIcon(provider));
        ApplyVisibility();
        Render();
        timer = new System.Windows.Forms.Timer { Interval = 600_000 }; // 10 minutes
        timer.Tick += async (_, _) => await RefreshAsync();
        timer.Start();
        _ = RefreshAsync();
    }

    private ProviderIcon CreateIcon(IQuotaProvider provider)
    {
        var parts = BuildMenu();
        var notify = new NotifyIcon
        {
            Text = $"{provider.DisplayName}: 読み込み中",
            Icon = Gauge.MakeTrayIcon(provider.Letter, new double?[] { null, null }),
            ContextMenuStrip = parts.Menu,
            Visible = true
        };
        // Windows normally opens a tray context menu on right-click.
        // Also expose the same native menu on left-click for convenience.
        notify.MouseClick += (_, e) =>
        {
            if (e.Button == MouseButtons.Left) parts.Menu.Show(Cursor.Position);
        };
        return new ProviderIcon { Provider = provider, Icon = notify, Parts = parts };
    }

    private MenuParts BuildMenu()
    {
        var menu = new ContextMenuStrip();
        var parts = new MenuParts
        {
            Menu = menu,
            Panels = new(), Hosts = new(), 
            Updated = new ToolStripMenuItem("確認日時：未取得") { Enabled = false }
        };

        foreach (var provider in providers)
        {
            var panel = new QuotaPanelControl(provider.DisplayName);
            var host = new ToolStripControlHost(panel) { AutoSize = false, Size = panel.Size, Margin = Padding.Empty };
            parts.Panels[provider.Id] = panel;
            parts.Hosts[provider.Id] = host;
            menu.Items.Add(host);
            menu.Items.Add(new ToolStripSeparator());
        }
        menu.Items.Add(parts.Updated);
        menu.Items.Add("今すぐ更新", null, async (_, _) => await RefreshAsync());
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("設定…", null, (_, _) => OpenSettings());
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("終了", null, (_, _) => ExitThread());

        return parts;
    }

    private void OpenSettings()
    {
        if (settingsForm is null || settingsForm.IsDisposed)
        {
            settingsForm = new SettingsForm(providers, StatusOf, LoginAsync, LogoutAsync, TrySetVisibility);
            settingsForm.FormClosed += (_, _) => settingsForm = null;
        }
        settingsForm.ReloadStatus();
        settingsForm.Show();
        settingsForm.Activate();
    }

    private ProviderStatus StatusOf(IQuotaProvider provider)
    {
        bool stored = provider.HasStoredLogin;
        bool logging = loggingIn.Contains(provider.Id);
        results.TryGetValue(provider.Id, out var result);
        if (result?.Snapshot is { } snapshot)
        {
            string summary = string.Join(" / ", snapshot.Windows.Select(w => $"{w.Label} {w.Percent}"));
            var state = stored ? LoginState.App : (provider.SupportsLogin ? LoginState.Cli : LoginState.Working);
            return new ProviderStatus(state, null, summary, logging, stored);
        }
        string? message = result?.Error;
        LoginState failing =
            message is null or "未取得" ? LoginState.Checking
            : !stored && message.StartsWith("要ログイン", StringComparison.Ordinal) ? LoginState.LoggedOut
            : LoginState.Failing;
        return new ProviderStatus(failing, message, "", logging, stored);
    }

    /// <summary>全て隠すとメニューに到達できなくなるため、最後の1つは隠せない（false を返す）。</summary>
    private bool TrySetVisibility(IQuotaProvider provider, bool visible)
    {
        if (!visible && providers.Count(p => Preferences.IsVisibleInTray(p.Id)) <= 1
            && Preferences.IsVisibleInTray(provider.Id)) return false;
        Preferences.SetVisibleInTray(provider.Id, visible);
        ApplyVisibility();
        return true;
    }

    private void ApplyVisibility()
    {
        foreach (var item in icons) item.Icon.Visible = Preferences.IsVisibleInTray(item.Provider.Id);
    }

    private async Task LoginAsync(IQuotaProvider provider)
    {
        if (!loggingIn.Add(provider.Id)) return;
        settingsForm?.ReloadStatus();
        try
        {
            var owner = icons.First(i => i.Provider.Id == provider.Id).Icon;
            owner.ShowBalloonTip(3000, "CodeQuota Tray", "ブラウザでログインを完了してください", ToolTipIcon.Info);
            await provider.LoginAsync(CancellationToken.None);
            await RefreshAsync();
        }
        catch (QuotaException ex) { ShowError(ex.PublicMessage); }
        catch (OperationCanceledException) { }
        catch (Exception) { ShowError($"{provider.DisplayName}のログインに失敗しました。もう一度お試しください。"); }
        finally
        {
            loggingIn.Remove(provider.Id);
            settingsForm?.ReloadStatus();
        }
    }

    private async Task LogoutAsync(IQuotaProvider provider)
    {
        provider.Logout();
        await RefreshAsync();
    }

    private static void ShowError(string message) =>
        MessageBox.Show(message, "CodeQuota Tray", MessageBoxButtons.OK, MessageBoxIcon.Warning);

    private async Task RefreshAsync()
    {
        if (fetching) return;
        fetching = true;
        try
        {
            var fetched = await Task.WhenAll(providers.Select(async p => (p.Id, Result: await p.FetchAsync())));
            foreach (var (id, result) in fetched) results[id] = result;
            Render();
        }
        catch (Exception)
        {
            // Avoid displaying private HTTP responses or secrets in errors.
            foreach (var item in icons) item.Parts.Updated.Text = "通信処理が失敗しました";
        }
        finally { fetching = false; }
    }

    private void Render()
    {
        settingsForm?.ReloadStatus();
        string stamp = $"取得：{DateTime.Now:MM/dd HH:mm}（10分ごと）";
        foreach (var item in icons)
        {
            // メニュー内ゲージ（全プロバイダぶん）
            foreach (var provider in providers)
            {
                var panel = item.Parts.Panels[provider.Id];
                panel.SetResult(results[provider.Id]);
                item.Parts.Hosts[provider.Id].Size = panel.Size;
            }
            item.Parts.Updated.Text = stamp;

            // トレイアイコン（自分のプロバイダの2本ゲージ）
            var own = results[item.Provider.Id];
            var values = item.Provider.BarWindowIds.Select(id => own.Snapshot?.Window(id)?.Remaining).ToArray();
            var previous = item.Icon.Icon;
            item.Icon.Icon = Gauge.MakeTrayIcon(item.Provider.Letter, values);
            previous?.Dispose();

            string tooltip = own.Snapshot is { } snapshot
                ? $"{item.Provider.DisplayName} " + string.Join(" ", snapshot.Windows.Select(w => $"{w.Label}{w.Percent}"))
                : $"{item.Provider.DisplayName} {own.Error ?? "取得失敗"}";
            item.Icon.Text = tooltip.Length > 63 ? tooltip[..63] : tooltip;
        }
    }

    protected override void ExitThreadCore()
    {
        timer.Stop();
        timer.Dispose();
        foreach (var item in icons)
        {
            item.Icon.Visible = false;
            item.Icon.Dispose();
            item.Parts.Menu.Dispose();
        }
        base.ExitThreadCore();
    }
}
