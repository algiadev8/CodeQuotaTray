using System.Diagnostics;
using System.Net;
using System.Net.Http.Headers;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Web;

namespace CodeQuotaTray;

// アプリ内蔵のOAuth（Authorization Code + PKCE）実装。
// 既定ブラウザでログインし、localhost で認可コードを受け取り、
// 自前のトークンを DPAPI で暗号化して保存・自動更新する。CLIのトークンには触れない。

internal enum Provider { Codex, Claude }

internal sealed record OAuthCredential(string Access, string Refresh, long Expires, string? AccountId)
{
    public bool NeedsRefresh => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() >= Expires - 300_000;
    public bool IsExpired => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() >= Expires;
}

internal static class CredentialStore
{
    private static readonly byte[] Entropy = Encoding.UTF8.GetBytes("CodeQuotaTray.v1");

    private static string PathFor(Provider provider) => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "CodeQuotaTray", provider.ToString().ToLowerInvariant() + ".cred");

    public static OAuthCredential? Load(Provider provider)
    {
        try
        {
            string path = PathFor(provider);
            if (!File.Exists(path)) return null;
            byte[] plain = ProtectedData.Unprotect(File.ReadAllBytes(path), Entropy, DataProtectionScope.CurrentUser);
            return JsonSerializer.Deserialize<OAuthCredential>(plain);
        }
        catch (Exception) { return null; }
    }

    public static void Save(Provider provider, OAuthCredential credential)
    {
        string path = PathFor(provider);
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        byte[] plain = JsonSerializer.SerializeToUtf8Bytes(credential);
        string temp = path + ".tmp";
        File.WriteAllBytes(temp, ProtectedData.Protect(plain, Entropy, DataProtectionScope.CurrentUser));
        File.Move(temp, path, overwrite: true);
    }

    public static void Delete(Provider provider)
    {
        try { File.Delete(PathFor(provider)); } catch (IOException) { }
    }
}

internal static class Pkce
{
    public static string Base64Url(byte[] data) =>
        Convert.ToBase64String(data).Replace('+', '-').Replace('/', '_').TrimEnd('=');

    public static (string Verifier, string Challenge) Generate()
    {
        string verifier = Base64Url(RandomNumberGenerator.GetBytes(32));
        string challenge = Base64Url(SHA256.HashData(Encoding.ASCII.GetBytes(verifier)));
        return (verifier, challenge);
    }
}

/// <summary>localhost で OAuth の認可コードを1回だけ受け取る簡易HTTPサーバー。</summary>
internal sealed class LoopbackServer : IDisposable
{
    private readonly HttpListener listener = new();
    private readonly string providerName;
    private readonly string path;
    private readonly string state;

    /// <exception cref="HttpListenerException">ポート使用中など</exception>
    public LoopbackServer(int port, string providerName, string path, string state)
    {
        this.providerName = providerName;
        this.path = path;
        this.state = state;
        listener.Prefixes.Add($"http://localhost:{port}/");
        listener.Start();
    }

    public static int FreePort()
    {
        var probe = new System.Net.Sockets.TcpListener(IPAddress.Loopback, 0);
        probe.Start();
        try { return ((IPEndPoint)probe.LocalEndpoint).Port; }
        finally { probe.Stop(); }
    }

    public async Task<string> WaitForCodeAsync(TimeSpan timeout, CancellationToken cancellation)
    {
        using var cts = CancellationTokenSource.CreateLinkedTokenSource(cancellation);
        cts.CancelAfter(timeout);
        using var registration = cts.Token.Register(() => { try { listener.Close(); } catch (Exception) { } });
        while (true)
        {
            HttpListenerContext context;
            try { context = await listener.GetContextAsync(); }
            catch (Exception) when (cts.IsCancellationRequested)
            {
                if (cancellation.IsCancellationRequested) throw new OperationCanceledException(cancellation);
                throw new QuotaException("ログインがタイムアウトしました。もう一度お試しください");
            }

            var request = context.Request;
            if (request.HttpMethod != "GET" || request.Url?.AbsolutePath != path)
            {
                Respond(context, 404, "Callback route not found.", false);
                continue;
            }
            var query = HttpUtility.ParseQueryString(request.Url.Query);
            if (query["state"] != state)
            {
                Respond(context, 400, "State mismatch.", false);
                continue;
            }
            if (query["error"] is { Length: > 0 } error)
            {
                string detail = query["error_description"] ?? error;
                Respond(context, 400, $"{providerName} authorization failed: {detail}", false);
                throw new QuotaException($"{providerName} の認可に失敗しました：{detail}");
            }
            if (query["code"] is not { Length: > 0 } code)
            {
                Respond(context, 400, "Missing authorization code.", false);
                continue;
            }
            Respond(context, 200, $"Signed in to {providerName}. You may now close this page.", true);
            return code;
        }
    }

    private static void Respond(HttpListenerContext context, int status, string message, bool ok)
    {
        string title = ok ? "ログイン完了" : "ログイン失敗";
        string html = "<!doctype html><html><head><meta charset=\"utf-8\"><title>CodeQuota Tray</title>"
            + "<style>body{font-family:'Segoe UI',sans-serif;text-align:center;margin-top:20vh}</style></head>"
            + $"<body><h2>{title}</h2><p>{WebUtility.HtmlEncode(message)}</p></body></html>";
        byte[] bytes = Encoding.UTF8.GetBytes(html);
        try
        {
            context.Response.StatusCode = status;
            context.Response.ContentType = "text/html; charset=utf-8";
            context.Response.Headers["Cache-Control"] = "no-store";
            context.Response.ContentLength64 = bytes.Length;
            context.Response.OutputStream.Write(bytes, 0, bytes.Length);
        }
        finally { context.Response.Close(); }
    }

    public void Dispose()
    {
        try { listener.Close(); } catch (Exception) { }
    }
}

internal static class OAuthManager
{
    // Claude (Pro/Max)
    private const string ClaudeClientId = "9d1c250a-e61b-44d9-88ed-5944d1962f5e";
    private const string ClaudeAuthorize = "https://claude.ai/oauth/authorize";
    private const string ClaudeToken = "https://platform.claude.com/v1/oauth/token";
    private const int ClaudePreferredPort = 53692;
    private const string ClaudeScopes =
        "org:create_api_key user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload";

    // Codex (ChatGPT Plus/Pro)
    private const string CodexClientId = "app_EMoamEEZ73f0CkXaXp7hrann";
    private const string CodexAuthorize = "https://auth.openai.com/oauth/authorize";
    private const string CodexToken = "https://auth.openai.com/oauth/token";
    private const int CodexPort = 1455;
    private const string CodexRedirect = "http://localhost:1455/auth/callback";
    private const string CodexScope = "openid profile email offline_access";

    private static readonly TimeSpan LoginTimeout = TimeSpan.FromMinutes(5);
    private static readonly HttpClient Http = new() { Timeout = TimeSpan.FromSeconds(30) };

    // ---- ログイン ----

    public static async Task LoginAsync(Provider provider, CancellationToken cancellation = default)
    {
        var credential = provider == Provider.Claude
            ? await LoginClaudeAsync(cancellation)
            : await LoginCodexAsync(cancellation);
        CredentialStore.Save(provider, credential);
    }

    private static async Task<OAuthCredential> LoginClaudeAsync(CancellationToken cancellation)
    {
        var (verifier, challenge) = Pkce.Generate();
        // Anthropic は任意のループバックポートを許可する。優先ポートが使用中なら空きポートへ。
        int port = ClaudePreferredPort;
        LoopbackServer server;
        try { server = new LoopbackServer(port, "Anthropic", "/callback", verifier); }
        catch (HttpListenerException)
        {
            port = LoopbackServer.FreePort();
            server = new LoopbackServer(port, "Anthropic", "/callback", verifier);
        }
        using (server)
        {
            string redirect = $"http://localhost:{port}/callback";
            string url = ClaudeAuthorize + "?" + Query(
                ("code", "true"),
                ("client_id", ClaudeClientId),
                ("response_type", "code"),
                ("redirect_uri", redirect),
                ("scope", ClaudeScopes),
                ("code_challenge", challenge),
                ("code_challenge_method", "S256"),
                ("state", verifier));
            OpenBrowser(url);
            string code = await server.WaitForCodeAsync(LoginTimeout, cancellation);
            using var json = await PostJsonAsync(ClaudeToken, new Dictionary<string, string>
            {
                ["grant_type"] = "authorization_code",
                ["client_id"] = ClaudeClientId,
                ["code"] = code,
                ["state"] = verifier,
                ["redirect_uri"] = redirect,
                ["code_verifier"] = verifier
            }, refreshing: false);
            return ToCredential(json.RootElement, previous: null, accountFromJwt: false);
        }
    }

    private static async Task<OAuthCredential> LoginCodexAsync(CancellationToken cancellation)
    {
        var (verifier, challenge) = Pkce.Generate();
        string state = Convert.ToHexString(RandomNumberGenerator.GetBytes(16)).ToLowerInvariant();
        LoopbackServer server;
        try { server = new LoopbackServer(CodexPort, "OpenAI", "/auth/callback", state); }
        catch (HttpListenerException)
        {
            throw new QuotaException("ポート1455が使用中です。Codex CLIのログインを終了してから再試行してください");
        }
        using (server)
        {
            string url = CodexAuthorize + "?" + Query(
                ("response_type", "code"),
                ("client_id", CodexClientId),
                ("redirect_uri", CodexRedirect),
                ("scope", CodexScope),
                ("code_challenge", challenge),
                ("code_challenge_method", "S256"),
                ("state", state),
                ("id_token_add_organizations", "true"),
                ("codex_cli_simplified_flow", "true"),
                ("originator", "codequota-tray"));
            OpenBrowser(url);
            string code = await server.WaitForCodeAsync(LoginTimeout, cancellation);
            using var json = await PostFormAsync(CodexToken, new Dictionary<string, string>
            {
                ["grant_type"] = "authorization_code",
                ["client_id"] = CodexClientId,
                ["code"] = code,
                ["code_verifier"] = verifier,
                ["redirect_uri"] = CodexRedirect
            }, refreshing: false);
            return ToCredential(json.RootElement, previous: null, accountFromJwt: true);
        }
    }

    // ---- トークン取得・更新 ----

    /// <summary>自前ログイン済みなら有効なトークンを返す（期限間近なら更新）。未ログインなら null。</summary>
    public static async Task<OAuthCredential?> GetAsync(Provider provider, bool forceRefresh = false)
    {
        var stored = CredentialStore.Load(provider);
        if (stored is null) return null;
        if (!forceRefresh && !stored.NeedsRefresh) return stored;
        try
        {
            var fresh = await RefreshAsync(provider, stored);
            CredentialStore.Save(provider, fresh);
            return fresh;
        }
        catch (Exception ex) when (ex is HttpRequestException or TaskCanceledException)
        {
            // 通信エラー。まだ実際には期限内ならそのまま使う。
            if (!forceRefresh && !stored.IsExpired) return stored;
            throw;
        }
    }

    private static async Task<OAuthCredential> RefreshAsync(Provider provider, OAuthCredential stored)
    {
        if (provider == Provider.Claude)
        {
            using var json = await PostJsonAsync(ClaudeToken, new Dictionary<string, string>
            {
                ["grant_type"] = "refresh_token",
                ["client_id"] = ClaudeClientId,
                ["refresh_token"] = stored.Refresh
            }, refreshing: true);
            return ToCredential(json.RootElement, stored, accountFromJwt: false);
        }
        using var codex = await PostFormAsync(CodexToken, new Dictionary<string, string>
        {
            ["grant_type"] = "refresh_token",
            ["refresh_token"] = stored.Refresh,
            ["client_id"] = CodexClientId
        }, refreshing: true);
        return ToCredential(codex.RootElement, stored, accountFromJwt: true);
    }

    private static OAuthCredential ToCredential(JsonElement json, OAuthCredential? previous, bool accountFromJwt)
    {
        string? access = Str(json, "access_token");
        if (string.IsNullOrEmpty(access) || !json.TryGetProperty("expires_in", out var expiresIn) || !expiresIn.TryGetDouble(out double seconds))
            throw new QuotaException("トークン応答の形式が不正です");
        string? refresh = Str(json, "refresh_token") ?? previous?.Refresh;
        if (string.IsNullOrEmpty(refresh)) throw new QuotaException("トークン応答にrefresh tokenがありません");
        string? account = previous?.AccountId;
        if (accountFromJwt)
        {
            account = JwtAccountId(access) ?? account;
            if (account is null) throw new QuotaException("アカウントIDをトークンから取得できません");
        }
        long expires = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() + (long)(seconds * 1000);
        return new OAuthCredential(access, refresh, expires, account);
    }

    private static string? Str(JsonElement json, string name) =>
        json.ValueKind == JsonValueKind.Object && json.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.String
            ? v.GetString() : null;

    private static string? JwtAccountId(string token)
    {
        try
        {
            string[] parts = token.Split('.');
            if (parts.Length != 3) return null;
            string b64 = parts[1].Replace('-', '+').Replace('_', '/');
            b64 = b64.PadRight(b64.Length + (4 - b64.Length % 4) % 4, '=');
            using var doc = JsonDocument.Parse(Convert.FromBase64String(b64));
            return doc.RootElement.TryGetProperty("https://api.openai.com/auth", out var auth)
                ? Str(auth, "chatgpt_account_id") : null;
        }
        catch (Exception) { return null; }
    }

    // ---- HTTP ----

    private static string Query(params (string Key, string Value)[] pairs) =>
        string.Join("&", pairs.Select(p => $"{Uri.EscapeDataString(p.Key)}={Uri.EscapeDataString(p.Value)}"));

    private static Task<JsonDocument> PostJsonAsync(string url, Dictionary<string, string> body, bool refreshing) =>
        PostAsync(url, new StringContent(JsonSerializer.Serialize(body), Encoding.UTF8, "application/json"), refreshing);

    private static Task<JsonDocument> PostFormAsync(string url, Dictionary<string, string> body, bool refreshing) =>
        PostAsync(url, new FormUrlEncodedContent(body), refreshing);

    private static async Task<JsonDocument> PostAsync(string url, HttpContent content, bool refreshing)
    {
        using var request = new HttpRequestMessage(HttpMethod.Post, url) { Content = content };
        request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
        using var response = await Http.SendAsync(request);
        if (!response.IsSuccessStatusCode)
        {
            if (refreshing && response.StatusCode is HttpStatusCode.BadRequest or HttpStatusCode.Unauthorized)
                throw new QuotaException("ログインの有効期限が切れました。メニューから再ログインしてください", authFailure: true);
            // 応答本文にトークンや個人情報が含まれ得るためUIには出さない。
            throw new QuotaException($"トークン取得に失敗しました（HTTP {(int)response.StatusCode}）");
        }
        try { return JsonDocument.Parse(await response.Content.ReadAsStringAsync()); }
        catch (JsonException) { throw new QuotaException("トークン応答を読み取れません"); }
    }

    private static void OpenBrowser(string url)
    {
        try { Process.Start(new ProcessStartInfo(url) { UseShellExecute = true }); }
        catch (Exception) { throw new QuotaException("ブラウザを開けませんでした"); }
    }
}
