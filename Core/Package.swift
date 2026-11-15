// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClaudeUsageMonitorCore",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .library(name: "ClaudeUsageMonitorCore", targets: ["ClaudeUsageMonitorCore"])
    ],
    targets: [
        .target(name: "ClaudeUsageMonitorCore"),
        .testTarget(name: "ClaudeUsageMonitorCoreTests", dependencies: ["ClaudeUsageMonitorCore"])
    ],
    swiftLanguageModes: [.v6]
)
