// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PollyWeb",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "polly-web", targets: ["PollyWebServer"])],
    dependencies: [
        .package(path: "../PollyKit"),
        .package(url: "https://github.com/vapor/vapor.git", exact: "4.122.3"),
        // Newer swift-log uses @nonexhaustive, which the native Swift 6.2 compiler cannot build.
        .package(url: "https://github.com/apple/swift-log.git", exact: "1.8.0"),
    ],
    targets: [
        .target(name: "PollyWeb", dependencies: ["PollyKit", .product(name: "Vapor", package: "vapor"),
                                               .product(name: "Logging", package: "swift-log")],
                resources: [.copy("Public")]),
        .executableTarget(name: "PollyWebServer", dependencies: ["PollyWeb", .product(name: "Vapor", package: "vapor")]),
        .testTarget(name: "PollyWebTests", dependencies: ["PollyWeb", .product(name: "VaporTesting", package: "vapor")]),
    ]
)
