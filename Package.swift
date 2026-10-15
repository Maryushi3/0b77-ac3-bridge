// swift-tools-version: 6.0
import PackageDescription

// Product is "0B77"; the target/type prefix is ZeroB77 because Swift
// identifiers can't start with a digit.
let package = Package(
    name: "0B77",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "0B77", targets: ["ZeroB77"])
    ],
    targets: [
        .executableTarget(
            name: "ZeroB77",
            path: "Sources/ZeroB77"
        )
    ]
)
