// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AC3Bridge",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "AC3Bridge",
            path: "Sources/AC3Bridge"
        )
    ]
)
