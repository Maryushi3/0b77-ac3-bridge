// swift-tools-version: 6.0
import PackageDescription

// Product is "0B77"; the target/type prefix is ZeroB77 because Swift
// identifiers can't start with a digit.
//
// Static ffmpeg libs (ThirdParty/lib, built by Scripts/build-ffmpeg.sh) link
// via relative -L: always build from the package root (Scripts do this).
let package = Package(
    name: "0B77",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "0B77", targets: ["ZeroB77"])
    ],
    targets: [
        .target(
            name: "CZeroB77",
            path: "Sources/CZeroB77",
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("../../ThirdParty/include")
            ]
        ),
        .executableTarget(
            name: "ZeroB77",
            dependencies: ["CZeroB77"],
            path: "Sources/ZeroB77",
            linkerSettings: [
                .unsafeFlags([
                    "-LThirdParty/lib",
                    "-lavformat", "-lavcodec", "-lavutil",
                ])
            ]
        ),
    ]
)
