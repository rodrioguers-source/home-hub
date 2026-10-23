// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SamsungTV",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(name: "SamsungTV", path: "Sources/SamsungTV")
    ]
)
