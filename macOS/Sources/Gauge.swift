import AppKit

// 残量ゲージ（緑のバー）の描画。
enum Gauge {
    static let green = NSColor(srgbRed: 0.18, green: 0.78, blue: 0.44, alpha: 1)
    static let low = NSColor(srgbRed: 0.87, green: 0.28, blue: 0.28, alpha: 1)

    /// 残量20%以下のみ赤。それ以外は緑。
    static func fillColor(_ remaining: Double) -> NSColor { remaining <= 20 ? low : green }

    /// 角丸のトラックに、左から残量ぶんだけ塗る。remaining が nil ならトラックのみ。
    static func drawBar(in rect: NSRect, remaining: Double?) {
        let radius = rect.height / 2
        NSColor.labelColor.withAlphaComponent(0.22).setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        guard let remaining else { return }
        let ratio = CGFloat(max(0, min(100, remaining)) / 100)
        guard ratio > 0 else { return }
        var fill = rect
        fill.size.width = max(rect.height, rect.width * ratio)
        fillColor(remaining).setFill()
        NSBezierPath(roundedRect: fill, xRadius: radius, yRadius: radius).fill()
    }

    /// 色はプロバイダの識別用。1列に4段まで並べ、以降は右に折り返す。
    /// 各段の左が5時間枠、右が週次枠。低残量はバーの右端の点で示す。
    static func statusImage(groups: [(color: NSColor, values: [Double?])]) -> NSImage {
        let height: CGFloat = 18
        let maxRows = 4
        let rows = max(1, min(groups.count, maxRows))
        // 段数が少ないほどバーを太く・長くする（2段: 太さ5.5 / 幅26、4段: 太さ3 / 幅16）。
        let pitch = min(height / CGFloat(rows), 9)
        let barHeight = (pitch * 0.62).rounded(.up)
        let barWidth: CGFloat = rows <= 2 ? 26 : (rows == 3 ? 20 : 16)
        let barGap: CGFloat = 3
        let columnGap: CGFloat = 5
        let groupWidth = barWidth * 2 + barGap
        let columns = max(1, (groups.count + maxRows - 1) / maxRows)
        let width = CGFloat(columns) * groupWidth + CGFloat(columns - 1) * columnGap
        let topInset = (height - pitch * CGFloat(rows)) / 2
        return NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            for (index, group) in groups.enumerated() {
                let column = index / maxRows
                let row = index % maxRows
                let x = CGFloat(column) * (groupWidth + columnGap)
                let y = height - topInset - CGFloat(row + 1) * pitch + (pitch - barHeight) / 2
                for (windowIndex, value) in group.values.prefix(2).enumerated() {
                    let rect = NSRect(x: x + CGFloat(windowIndex) * (barWidth + barGap),
                                      y: y, width: barWidth, height: barHeight)
                    drawStatusBar(in: rect, remaining: value, color: group.color)
                }
            }
            return true
        }
    }

    /// 未取得は点線、残量0は空のトラック。20%以下は右端に目印を付ける。
    private static func drawStatusBar(in rect: NSRect, remaining: Double?, color: NSColor) {
        let radius = rect.height / 2
        NSColor.labelColor.withAlphaComponent(0.25).setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        guard let remaining, remaining.isFinite else {
            color.withAlphaComponent(0.65).setFill()
            for offset in stride(from: CGFloat(0), to: rect.width, by: 4) {
                NSBezierPath(ovalIn: NSRect(x: rect.minX + offset, y: rect.midY - 0.5, width: 1, height: 1)).fill()
            }
            return
        }
        let ratio = CGFloat(max(0, min(100, remaining)) / 100)
        if ratio > 0 {
            let fill = NSRect(x: rect.minX, y: rect.minY, width: max(rect.height, rect.width * ratio), height: rect.height)
            color.setFill()
            NSBezierPath(roundedRect: fill, xRadius: radius, yRadius: radius).fill()
        }
        if remaining <= 20 {
            NSColor.black.setFill()
            NSBezierPath(ovalIn: NSRect(x: rect.maxX - 3, y: rect.midY - 1.5, width: 3, height: 3)).fill()
            NSColor.white.setFill()
            NSBezierPath(ovalIn: NSRect(x: rect.maxX - 2.25, y: rect.midY - 0.75, width: 1.5, height: 1.5)).fill()
        }
    }
}

/// メニュー内に表示する、プロバイダ1つぶんの「5時間 / 週次」2本ゲージ。
final class QuotaMenuView: NSView {
    private let title: String
    private var snapshot: UsageSnapshot?
    private var errorText: String? = "未取得"

    init(title: String) {
        self.title = title
        super.init(frame: NSRect(x: 0, y: 0, width: 270, height: 104))
        resize()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    func update(_ result: QuotaResult) {
        switch result {
        case .success(let value):
            snapshot = value
            errorText = nil
        case .failure(let message):
            snapshot = nil
            errorText = message
        }
        resize()
        needsDisplay = true
    }

    private let rowHeight: CGFloat = 38
    private let headerHeight: CGFloat = 30

    private func resize() {
        let rows = CGFloat(max(1, snapshot?.windows.count ?? 0))
        let height = errorText != nil ? headerHeight + 60 : headerHeight + rows * rowHeight + 4
        setFrameSize(NSSize(width: 270, height: height))
    }

    override func draw(_ dirtyRect: NSRect) {
        let pad: CGFloat = 14
        NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.labelColor
        ]).draw(at: NSPoint(x: pad, y: 6))

        if let errorText {
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byWordWrapping
            NSAttributedString(string: errorText, attributes: [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: style
            ]).draw(in: NSRect(x: pad, y: headerHeight, width: bounds.width - pad * 2, height: 56))
            return
        }
        for (index, window) in (snapshot?.windows ?? []).enumerated() {
            drawRow(caption: window.label, window: window, y: headerHeight + CGFloat(index) * rowHeight, pad: pad)
        }
    }

    private func drawRow(caption: String, window: QuotaWindow?, y: CGFloat, pad: CGFloat) {
        let width = bounds.width - pad * 2
        NSAttributedString(string: caption, attributes: [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.labelColor
        ]).draw(at: NSPoint(x: pad, y: y))

        let percent = NSAttributedString(
            string: window.map { "残り \($0.percentage)" } ?? "データなし",
            attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
                         .foregroundColor: NSColor.labelColor])
        percent.draw(at: NSPoint(x: pad + width - percent.size().width, y: y))

        if let reset = window?.resetsAt {
            let when = DateFormatter.localizedString(from: reset, dateStyle: .short, timeStyle: .short)
            NSAttributedString(string: "復活 \(when)", attributes: [
                .font: NSFont.systemFont(ofSize: 10),
                .foregroundColor: NSColor.secondaryLabelColor
            ]).draw(at: NSPoint(x: pad + 38, y: y + 2))
        }
        Gauge.drawBar(in: NSRect(x: pad, y: y + 19, width: width, height: 8), remaining: window?.remaining)
    }
}
