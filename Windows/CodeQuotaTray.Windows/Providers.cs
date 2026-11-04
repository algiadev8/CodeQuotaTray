using System.Text.Json;

namespace CodeQuotaTray;

// 使用量プロバイダの拡張ポイント。
// 新しいサービス（OpenCode など）を追加するには:
//   1. IQuotaProvider を実装した型を作り（FetchAsync で QuotaResult を返す）
//   2. ProviderRegistry.All に追加するだけ。トレイアイコン・メニュー・ログイン項目・
//      「トレイにアイコンを表示」切替は自動で増えます。
internal interface IQuotaProvider
{
    /// <summary>永続キー（設定の保存に使用）。変更しないこと。</summary>
    string Id { get; }
    string DisplayName { get; }
    /// <summary>トレイアイコン左に描く1文字ラベル</summary>
    string Letter { get; }
    /// <summary>アイコンに描く枠の Id（最大2本。上から順）</summary>
    string[] BarWindowIds => new[] { "5h", "week" };
    bool SupportsLogin => false;
    /// <summary>アプリ自身のログイン情報（トークン）が保存されているか</summary>
    bool HasStoredLogin => false;
    Task<QuotaResult> FetchAsync();
    Task LoginAsync(CancellationToken cancellation) => Task.CompletedTask;
    void Logout() { }
}

internal sealed class CodexProvider : IQuotaProvider
{
    public string Id => "codex";
    public string DisplayName => "Codex";
    public string Letter => "C";
    public bool SupportsLogin => true;
    public bool HasStoredLogin => CredentialStore.Load(Provider.Codex) is not null;
    public Task<QuotaResult> FetchAsync() => UsageClient.FetchCodexAsync();
    public Task LoginAsync(CancellationToken cancellation) => OAuthManager.LoginAsync(Provider.Codex, cancellation);
    public void Logout() => CredentialStore.Delete(Provider.Codex);
}

internal sealed class ClaudeProvider : IQuotaProvider
{
    public string Id => "claude";
    public string DisplayName => "Claude";
    public string Letter => "A";
    public bool SupportsLogin => true;
    public bool HasStoredLogin => CredentialStore.Load(Provider.Claude) is not null;
    public Task<QuotaResult> FetchAsync() => UsageClient.FetchClaudeAsync();
    public Task LoginAsync(CancellationToken cancellation) => OAuthManager.LoginAsync(Provider.Claude, cancellation);
    public void Logout() => CredentialStore.Delete(Provider.Claude);
}

internal static class ProviderRegistry
{
    /// <summary>表示順。ここに追加すれば UI に反映される。</summary>
    public static readonly IReadOnlyList<IQuotaProvider> All = new IQuotaProvider[]
    {
        new CodexProvider(),
        new ClaudeProvider()
    };
}

/// <summary>ユーザー設定（%LOCALAPPDATA%\CodeQuotaTray\settings.json）</summary>
internal static class Preferences
{
    private sealed class Data { public List<string> Hidden { get; set; } = new(); }

    private static string FilePath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "CodeQuotaTray", "settings.json");

    private static Data Load()
    {
        try { return JsonSerializer.Deserialize<Data>(File.ReadAllText(FilePath)) ?? new Data(); }
        catch (Exception) { return new Data(); }
    }

    public static bool IsVisibleInTray(string id) => !Load().Hidden.Contains(id);

    public static void SetVisibleInTray(string id, bool visible)
    {
        var data = Load();
        data.Hidden.Remove(id);
        if (!visible) data.Hidden.Add(id);
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(FilePath)!);
            File.WriteAllText(FilePath, JsonSerializer.Serialize(data));
        }
        catch (IOException) { }
    }
}
