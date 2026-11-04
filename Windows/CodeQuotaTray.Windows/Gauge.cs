using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;

namespace CodeQuotaTray;

// 残量ゲージ（緑のバー）の描画。5時間枠と週次枠の2本を上下に並べる。
internal static class Gauge
{
    public static readonly Color Green = Color.FromArgb(46, 199, 112);
    public static readonly Color Low = Color.FromArgb(222, 72, 72);

    /// <summary>残量20%以下のみ赤。それ以外は緑。</summary>
    public static Color FillColor(double remaining) => remaining <= 20 ? Low : Green;

    public static GraphicsPath RoundedRect(RectangleF rect, float radius)
    {
        float d = Math.Min(radius * 2, Math.Min(rect.Width, rect.Height));
        var path = new GraphicsPath();
        path.AddArc(rect.X, rect.Y, d, d, 180, 90);
        path.AddArc(rect.Right - d, rect.Y, d, d, 270, 90);
        path.AddArc(rect.Right - d, rect.Bottom - d, d, d, 0, 90);
        path.AddArc(rect.X, rect.Bottom - d, d, d, 90, 90);
        path.CloseFigure();
        return path;
    }

    /// <summary>角丸のトラックに、左から残量ぶんだけ塗る。remaining が null ならトラックのみ。</summary>
    public static void DrawBar(Graphics g, RectangleF rect, double? remaining, Color track)
    {
        float radius = rect.Height / 2;
        using (var trackBrush = new SolidBrush(track))
        using (var trackPath = RoundedRect(rect, radius))
            g.FillPath(trackBrush, trackPath);
        if (remaining is not { } value) return;
        double ratio = Math.Clamp(value, 0, 100) / 100;
        if (ratio <= 0) return;
        var fill = new RectangleF(rect.X, rect.Y, Math.Max(rect.Height, (float)(rect.Width * ratio)), rect.Height);
        using var fillBrush = new SolidBrush(FillColor(value));
        using var fillPath = RoundedRect(fill, radius);
        g.FillPath(fillBrush, fillPath);
    }

    /// <summary>トレイアイコン：左にラベル、右に最大2本のバー（上から順）。</summary>
    public static Icon MakeTrayIcon(string letter, double?[] values)
    {
        using var bitmap = new Bitmap(64, 64);
        using (var g = Graphics.FromImage(bitmap))
        {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.AntiAliasGridFit;
            g.Clear(Color.Transparent);
            using (var background = new SolidBrush(Color.FromArgb(235, 34, 36, 42)))
            using (var path = RoundedRect(new RectangleF(0, 0, 64, 64), 12))
                g.FillPath(background, path);
            using (var font = new Font("Segoe UI", 26, FontStyle.Bold, GraphicsUnit.Pixel))
            using (var format = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center })
                g.DrawString(letter, font, Brushes.White, new RectangleF(1, 0, 24, 64), format);
            var track = Color.FromArgb(255, 88, 91, 99);
            const float x = 27, width = 34, height = 15;
            if (values.Length >= 2)
            {
                DrawBar(g, new RectangleF(x, 12, width, height), values[0], track);
                DrawBar(g, new RectangleF(x, 37, width, height), values[1], track);
            }
            else
            {
                DrawBar(g, new RectangleF(x, 24.5f, width, height), values.Length == 1 ? values[0] : null, track);
            }
        }
        IntPtr handle = bitmap.GetHicon();
        try { using var temp = Icon.FromHandle(handle); return (Icon)temp.Clone(); }
        finally { DestroyIcon(handle); }
    }

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool DestroyIcon(IntPtr icon);
}

/// <summary>メニュー内に表示する、プロバイダ1つぶんの「5時間 / 週次」ゲージ（枠は任意個数）。</summary>
internal sealed class QuotaPanelControl : Control
{
    private const int PanelWidth = 280;
    private const int Pad = 12;
    private const int HeaderHeight = 28;
    private const int RowHeight = 42;

    private readonly string title;
    private readonly Font titleFont;
    private readonly Font smallFont;
    private QuotaSnapshot? snapshot;
    private string? error = "未取得";

    public QuotaPanelControl(string title)
    {
        this.title = title;
        titleFont = new Font(SystemFonts.MenuFont ?? SystemFonts.DefaultFont, FontStyle.Bold);
        smallFont = new Font(SystemFonts.MenuFont ?? SystemFonts.DefaultFont, FontStyle.Regular);
        SetStyle(ControlStyles.SupportsTransparentBackColor | ControlStyles.OptimizedDoubleBuffer
                 | ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.ResizeRedraw, true);
        BackColor = Color.Transparent;
        Size = new Size(PanelWidth, HeaderHeight + 60);
    }

    public void SetResult(QuotaResult result)
    {
        snapshot = result.Snapshot;
        error = result.Snapshot is null ? (result.Error ?? "取得失敗") : null;
        int rows = Math.Max(1, snapshot?.Windows.Count ?? 0);
        Size = new Size(PanelWidth, error is not null ? HeaderHeight + 60 : HeaderHeight + rows * RowHeight + 4);
        Invalidate();
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.ClearTypeGridFit;
        using var textBrush = new SolidBrush(SystemColors.MenuText);
        using var grayBrush = new SolidBrush(SystemColors.GrayText);
        g.DrawString(title, titleFont, textBrush, Pad, 6);

        if (error is not null)
        {
            g.DrawString(error, smallFont, grayBrush, new RectangleF(Pad, HeaderHeight, Width - Pad * 2, 56));
            return;
        }
        var track = Color.FromArgb(70, 128, 128, 128);
        using var far = new StringFormat { Alignment = StringAlignment.Far };
        float inner = Width - Pad * 2;
        for (int i = 0; i < (snapshot?.Windows.Count ?? 0); i++)
        {
            var window = snapshot!.Windows[i];
            float y = HeaderHeight + i * RowHeight;
            g.DrawString(window.Label, smallFont, textBrush, Pad, y);
            g.DrawString($"残り {window.Percent}", titleFont, textBrush, new RectangleF(Pad, y, inner, 20), far);
            if (window.ResetsAt is { } reset)
                g.DrawString($"復活 {reset.ToLocalTime():MM/dd HH:mm}", smallFont, grayBrush, Pad + 52, y + 1);
            Gauge.DrawBar(g, new RectangleF(Pad, y + 22, inner, 9), window.Remaining, track);
        }
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing) { titleFont.Dispose(); smallFont.Dispose(); }
        base.Dispose(disposing);
    }
}
