// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PollyKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "PollyKit", targets: ["PollyKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "6.0.0"),
    ],
    targets: [
        .target(
            name: "PollyKit",
            dependencies: ["Yams"]
        ),
        .testTarget(name: "PollyKitTests", dependencies: ["PollyKit"]),
    ]
)
