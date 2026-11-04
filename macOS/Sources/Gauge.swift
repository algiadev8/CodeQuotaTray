import AppKit

// 残量ゲージ（緑のバー）の描画。5時間枠と週次枠の2本を上下に並べる。
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

    /// メニューバー用：プロバイダごとに「ラベル + 最大2本のバー（上から順）」を横に並べる。
    static func statusImage(groups: [(name: String, values: [Double?])]) -> NSImage {
        let height: CGFloat = 18
        let barWidth: CGFloat = 30
        let barHeight: CGFloat = 5
        let barGap: CGFloat = 3
        let groupGap: CGFloat = 9
        let labelGap: CGFloat = 3
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9, weight: .semibold),
            .foregroundColor: NSColor.labelColor
        ]
        let labels = groups.map { NSAttributedString(string: $0.name, attributes: attributes) }
        let labelWidths = labels.map { ceil($0.size().width) }
        let total = zip(labelWidths, groups).reduce(CGFloat(0)) { $0 + $1.0 + labelGap + barWidth }
            + groupGap * CGFloat(max(0, groups.count - 1))
        return NSImage(size: NSSize(width: max(total, 1), height: height), flipped: false) { _ in
            var x: CGFloat = 0
            for (index, group) in groups.enumerated() {
                let label = labels[index]
                label.draw(at: NSPoint(x: x, y: (height - label.size().height) / 2))
                let barX = x + labelWidths[index] + labelGap
                let values = Array(group.values.prefix(2))
                if values.count >= 2 {
                    drawBar(in: NSRect(x: barX, y: height / 2 + barGap / 2, width: barWidth, height: barHeight), remaining: values[0])
                    drawBar(in: NSRect(x: barX, y: height / 2 - barGap / 2 - barHeight, width: barWidth, height: barHeight), remaining: values[1])
                } else {
                    drawBar(in: NSRect(x: barX, y: (height - barHeight) / 2, width: barWidth, height: barHeight), remaining: values.first ?? nil)
                }
                x += labelWidths[index] + labelGap + barWidth + groupGap
            }
            return true
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
