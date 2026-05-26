// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TunnelProbe",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "TunnelProbe", path: "Sources/TunnelProbe")
    ]
)
