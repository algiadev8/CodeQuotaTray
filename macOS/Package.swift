// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "CodeQuotaMac",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "CodeQuotaMac", targets: ["CodeQuotaMac"])],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")
    ],
    targets: [
        .executableTarget(
            name: "CodeQuotaMac",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources"
        )
    ]
)
