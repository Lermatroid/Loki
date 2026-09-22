// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Loki",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Loki", targets: ["LokiApp"]), .library(name: "LokiCore", targets: ["LokiCore"])],
    targets: [
        .target(name: "LokiCore"),
        .executableTarget(name: "LokiApp", dependencies: ["LokiCore"]),
        .testTarget(name: "LokiCoreTests", dependencies: ["LokiCore"])
    ]
)
