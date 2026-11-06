import AppKit

@main
struct GaugeTests {
    static func main() {
        for (count, expectedWidth) in [(0, 55), (1, 55), (2, 55), (3, 43), (4, 35), (5, 75), (8, 75), (9, 115)] {
            let groups = (0..<count).map { _ in (color: NSColor.systemBlue, values: [Double?(100), Double?(50)]) }
            let image = Gauge.statusImage(groups: groups)
            precondition(image.size.width == CGFloat(expectedWidth), "wrong width for count: \(count)")
            precondition(image.size.height == 18 && !image.isTemplate)
        }
        func bytes(_ value: Double?, _ color: NSColor) -> Data {
            let image = Gauge.statusImage(groups: [(color: color, values: [value, 100])])
            guard let data = image.tiffRepresentation else { fatalError("image rendering failed") }
            return data
        }
        precondition(bytes(nil, .systemBlue) != bytes(0, .systemBlue), "missing and zero must differ")
        precondition(bytes(100, .systemBlue) != bytes(100, .systemOrange), "provider colors must differ")
        print("Gauge rendering tests passed")
    }
}
