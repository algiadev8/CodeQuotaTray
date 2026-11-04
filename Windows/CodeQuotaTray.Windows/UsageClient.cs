using System.Net;
using System.Net.Http.Headers;
using System.Text.Json;
using System.Security.Cryptography;
using System.Text;
using System.Runtime.InteropServices;

namespace CodeQuotaTray;

/// <summary>1つの制限枠（例：5時間枠、週次枠）。Id はトレイアイコンのバー割り当てに、Label は表示に使う。</summary>
internal record QuotaWindow(double Remaining, DateTimeOffset? ResetsAt)
{
    public string Id { get; init; } = "";
    public string Label { get; init; } = "";
    public string Percent => $"{Math.Round(Remaining, MidpointRounding.AwayFromZero):0}%";
}

/// <summary>プロバイダ1つぶんの取得結果。制限枠は任意個数（表示順）。</summary>
internal record QuotaSnapshot(IReadOnlyList<QuotaWindow> Windows, DateTimeOffset CapturedAt)
{
    /// <summary>Codex / Claude 共通の「5時間 + 週次」形式</summary>
    public QuotaSnapshot(QuotaWindow? fiveHour, QuotaWindow? weekly, DateTimeOffset capturedAt)
        : this(new QuotaWindow?[]
        {
            fiveHour is null ? null : fiveHour with { Id = "5h", Label = "5時間" },
            weekly is null ? null : weekly with { Id = "week", Label = "週次" }
        }.OfType<QuotaWindow>().ToList(), capturedAt) { }

    public QuotaWindow? Window(string id) => Windows.FirstOrDefault(w => w.Id == id);
}

internal record QuotaResult(QuotaSnapshot? Snapshot, string? Error);

internal static class UsageClient
{
    // 自前OAuthログイン（OAuth.cs）を優先。未ログイン時のみ公式CLIの認証情報を読み取り専用で利用し、
    // CLI所有のトークンは書き換え・更新しない。
    private static readonly HttpClient Http = new() { Timeout = TimeSpan.FromSeconds(15) };

    public static async Task<QuotaResult> FetchCodexAsync()
    {
        try
        {
            var own = await OAuthManager.GetAsync(Provider.Codex);
            if (own is not null)
            {
                try { return await QueryCodexAsync(own.Access, own.AccountId); }
                catch (QuotaException ex) when (ex.AuthFailure)
                {
                    var fresh = await OAuthManager.GetAsync(Provider.Codex, forceRefresh: true) ?? throw ex;
                    return await QueryCodexAsync(fresh.Access, fresh.AccountId);
                }
            }

            // 未ログイン：Codex CLI の認証情報を読み取り専用で利用
            string dir = Environment.GetEnvironmentVariable("CODEX_HOME")
                ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".codex");
            string? access = null;
            string? account = null;
            try
            {
                using var auth = ReadCodexCredentials(Environment.ExpandEnvironmentVariables(dir));
                var tokens = Child(auth.RootElement, "tokens");
                access = StringValue(tokens, "access_token");
                account = StringValue(tokens, "account_id");
            }
            catch (QuotaException) { /* 未ログイン */ }
            if (string.IsNullOrWhiteSpace(access))
                return new(null, "要ログイン：メニューから「Codexにログイン」");
            return await QueryCodexAsync(access, account);
        }
        catch (QuotaException ex) { return new(null, ex.PublicMessage); }
        catch (HttpRequestException) { return new(null, "通信エラー（ネットワークを確認）"); }
        catch (TaskCanceledException) { return new(null, "通信タイムアウト"); }
        catch (Exception) { return new(null, "読み取りエラー（ログイン状態を確認）"); }
    }

    private static async Task<QuotaResult> QueryCodexAsync(string access, string? account)
    {
        var headers = new Dictionary<string, string>();
        if (!string.IsNullOrEmpty(account)) headers.Add("ChatGPT-Account-Id", account);

        using var result = await RequestAsync("https://chatgpt.com/backend-api/wham/usage", access, headers);
        var rate = Child(result.RootElement, "rate_limit");
        if (rate.ValueKind != JsonValueKind.Object) rate = Child(result.RootElement, "rate_limits");
        QuotaWindow? five = null;
        QuotaWindow? week = null;
        foreach (var (names, defaultWeekly) in new[]
        {
            (new[] { "five_hour", "primary_window", "primary" }, false),
            (new[] { "weekly", "secondary_window", "secondary" }, true)
        })
        {
            var value = FirstObject(rate, names);
            var parsed = ParseCodexWindow(value);
            if (parsed is null) continue;
            // The only window returned may be 7 days even under primary_window.
            double? seconds = Number(value, "limit_window_seconds");
            bool isWeekly = seconds.HasValue ? seconds.Value >= 172800 : defaultWeekly;
            if (isWeekly) week = parsed;
            else five = parsed;
        }
        if (five is null && week is null) return new(null, "使用量JSONの形式が変更された可能性があります");
        return new(new QuotaSnapshot(five, week, DateTimeOffset.Now), null);
    }

    public static async Task<QuotaResult> FetchClaudeAsync()
    {
        try
        {
            var own = await OAuthManager.GetAsync(Provider.Claude);
            if (own is not null)
            {
                try { return await QueryClaudeAsync(own.Access); }
                catch (QuotaException ex) when (ex.AuthFailure)
                {
                    var fresh = await OAuthManager.GetAsync(Provider.Claude, forceRefresh: true) ?? throw ex;
                    return await QueryClaudeAsync(fresh.Access);
                }
            }

            // 未ログイン：Claude Code の認証情報を読み取り専用で利用（更新はしない）
            string home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
            string configDir = (Environment.GetEnvironmentVariable("CLAUDE_CONFIG_DIR") ?? "")
                .Split(',', StringSplitOptions.RemoveEmptyEntries).FirstOrDefault()
                ?? Path.Combine(home, ".claude");
            string? access = null;
            double? expiresAt = null;
            try
            {
                using var credentials = ReadJson(Path.Combine(Environment.ExpandEnvironmentVariables(configDir), ".credentials.json"));
                var oauth = Child(credentials.RootElement, "claudeAiOauth");
                access = StringValue(oauth, "accessToken");
                expiresAt = Number(oauth, "expiresAt");
            }
            catch (QuotaException) { /* 未ログイン */ }
            if (string.IsNullOrWhiteSpace(access)) return new(null, "要ログイン：メニューから「Claudeにログイン」");
            if (expiresAt.HasValue && DateTimeOffset.FromUnixTimeMilliseconds((long)expiresAt.Value) < DateTimeOffset.UtcNow)
                return new(null, "Claudeの認証期限切れ：メニューから「Claudeにログイン」");
            return await QueryClaudeAsync(access);
        }
        catch (QuotaException ex) { return new(null, ex.PublicMessage); }
        catch (HttpRequestException) { return new(null, "通信エラー（ネットワークを確認）"); }
        catch (TaskCanceledException) { return new(null, "通信タイムアウト"); }
        catch (Exception) { return new(null, "読み取りエラー（ログイン状態を確認）"); }
    }

    private static async Task<QuotaResult> QueryClaudeAsync(string access)
    {
        var headers = new Dictionary<string, string> { ["anthropic-beta"] = "oauth-2025-04-20" };
        using var result = await RequestAsync("https://api.anthropic.com/api/oauth/usage", access, headers);
        var five = ParseClaudeWindow(Child(result.RootElement, "five_hour"));
        var week = ParseClaudeWindow(Child(result.RootElement, "seven_day"));
        if (five is null && week is null) return new(null, "使用量が取得できません（契約またはAPIの変更）");
        return new(new QuotaSnapshot(five, week, DateTimeOffset.Now), null);
    }

    private static JsonDocument ReadCodexCredentials(string directory)
    {
        // The official CLI can save credentials in Windows Credential Manager.
        // Keyring-rs uses target "{account}.{service}", where account is
        // cli|SHA256(canonical CODEX_HOME)[0..16] and service is "Codex Auth".
        string fullPath = Path.GetFullPath(directory);
        var candidates = new HashSet<string>(StringComparer.Ordinal) { fullPath };
        if (fullPath.StartsWith(@"\\", StringComparison.Ordinal))
            candidates.Add(@"\\?\UNC\" + fullPath.TrimStart('\\'));
        else
            candidates.Add(@"\\?\" + fullPath);
        foreach (string candidate in candidates)
        {
            string hash = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(candidate)))
                .Substring(0, 16).ToLowerInvariant();
            string target = $"cli|{hash}.Codex Auth";
            if (!CredRead(target, 1, 0, out IntPtr pointer)) continue;
            try
            {
                var native = Marshal.PtrToStructure<NativeCredential>(pointer);
                if (native.CredentialBlobSize is 0 or > 65536) continue;
                byte[] blob = new byte[(int)native.CredentialBlobSize];
                Marshal.Copy(native.CredentialBlob, blob, 0, blob.Length);
                // keyring-rs writes its password as UTF-16LE, but also accept UTF-8
                // for compatibility with a different keyring backend.
                foreach (var value in new[] { Encoding.Unicode.GetString(blob), Encoding.UTF8.GetString(blob) })
                {
                    try { return JsonDocument.Parse(value.TrimEnd('\0')); }
                    catch (JsonException) { /* Try the other encoding. */ }
                }
            }
            finally { CredFree(pointer); }
        }
        return ReadJson(Path.Combine(fullPath, "auth.json"));
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct FileTime { public uint Low; public uint High; }

    [StructLayout(LayoutKind.Sequential)]
    private struct NativeCredential
    {
        public uint Flags;
        public uint Type;
        public IntPtr TargetName;
        public IntPtr Comment;
        public FileTime LastWritten;
        public uint CredentialBlobSize;
        public IntPtr CredentialBlob;
        public uint Persist;
        public uint AttributeCount;
        public IntPtr Attributes;
        public IntPtr TargetAlias;
        public IntPtr UserName;
    }

    [DllImport("advapi32.dll", EntryPoint = "CredReadW", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CredRead(string target, uint type, uint flags, out IntPtr credential);

    [DllImport("advapi32.dll")]
    private static extern void CredFree(IntPtr buffer);

    private static JsonDocument ReadJson(string file)
    {
        if (!File.Exists(file)) throw new QuotaException("認証ファイルがありません。メニューからログインしてください");
        // Never write the credentials file, including refreshed tokens.
        return JsonDocument.Parse(File.ReadAllText(file));
    }

    private static async Task<JsonDocument> RequestAsync(string address, string bearer, Dictionary<string, string> headers)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, address);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", bearer);
        request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
        request.Headers.UserAgent.ParseAdd("CodeQuotaTray/1.0");
        foreach (var pair in headers) request.Headers.TryAddWithoutValidation(pair.Key, pair.Value);
        using var response = await Http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead);
        if (response.StatusCode is HttpStatusCode.Unauthorized or HttpStatusCode.Forbidden)
            throw new QuotaException("認証期限切れ / 権限不足（再ログインしてください）", authFailure: true);
        if (response.StatusCode == HttpStatusCode.TooManyRequests)
            throw new QuotaException("APIの回数制限（後で再更新してください）");
        if (!response.IsSuccessStatusCode)
            throw new QuotaException($"APIエラー（HTTP {(int)response.StatusCode}）");
        using var stream = await response.Content.ReadAsStreamAsync();
        return await JsonDocument.ParseAsync(stream);
    }

    private static JsonElement Child(JsonElement obj, string name)
        => obj.ValueKind == JsonValueKind.Object && obj.TryGetProperty(name, out var value) ? value : default;

    private static JsonElement FirstObject(JsonElement obj, IEnumerable<string> names)
    {
        foreach (var name in names)
        {
            var value = Child(obj, name);
            if (value.ValueKind == JsonValueKind.Object) return value;
        }
        return default;
    }

    private static string? StringValue(JsonElement obj, string name)
    {
        var value = Child(obj, name);
        return value.ValueKind == JsonValueKind.String ? value.GetString() : null;
    }

    private static double? Number(JsonElement obj, string name)
    {
        var value = Child(obj, name);
        if (value.ValueKind == JsonValueKind.Number && value.TryGetDouble(out double number)) return number;
        if (value.ValueKind == JsonValueKind.String && double.TryParse(value.GetString(), System.Globalization.NumberStyles.Float,
            System.Globalization.CultureInfo.InvariantCulture, out double parsed)) return parsed;
        return null;
    }

    private static QuotaWindow? ParseCodexWindow(JsonElement value)
    {
        if (value.ValueKind != JsonValueKind.Object) return null;
        double? remaining = Number(value, "percent_left");
        if (!remaining.HasValue)
        {
            double? used = Number(value, "used_percent") ?? Number(value, "usedPercent");
            if (used.HasValue) remaining = 100 - used.Value;
        }
        if (!remaining.HasValue || remaining.Value < 0 || remaining.Value > 100) return null;
        DateTimeOffset? reset = ParseDate(Child(value, "reset_time_ms"), forceMilliseconds: true)
            ?? ParseDate(Child(value, "resetsAt"))
            ?? ParseDate(Child(value, "reset_at"));
        return new QuotaWindow(remaining.Value, reset);
    }

    private static QuotaWindow? ParseClaudeWindow(JsonElement value)
    {
        double? used = Number(value, "utilization");
        if (!used.HasValue || used.Value < 0 || used.Value > 100) return null;
        return new QuotaWindow(100 - used.Value, ParseDate(Child(value, "resets_at")));
    }

    private static DateTimeOffset? ParseDate(JsonElement value, bool forceMilliseconds = false)
    {
        try
        {
            if (value.ValueKind == JsonValueKind.Number && value.TryGetInt64(out var epoch))
                return forceMilliseconds || epoch > 10_000_000_000
                    ? DateTimeOffset.FromUnixTimeMilliseconds(epoch)
                    : DateTimeOffset.FromUnixTimeSeconds(epoch);
            if (value.ValueKind == JsonValueKind.String && DateTimeOffset.TryParse(value.GetString(), out var date))
                return date;
        }
        catch (ArgumentOutOfRangeException) { /* No reset time */ }
        return null;
    }
}

internal sealed class QuotaException(string message, bool authFailure = false) : Exception
{
    public string PublicMessage { get; } = message;
    /// <summary>401/403 など、トークン更新で回復し得る認証エラー</summary>
    public bool AuthFailure { get; } = authFailure;
}
