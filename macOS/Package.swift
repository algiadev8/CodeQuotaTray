// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "CodeQuotaMac",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "CodeQuotaMac", targets: ["CodeQuotaMac"])],
    targets: [.executableTarget(name: "CodeQuotaMac", path: "Sources")]
)
