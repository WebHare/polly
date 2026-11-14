// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NaggieKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "NaggieKit", targets: ["NaggieKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "6.0.0"),
    ],
    targets: [
        .target(
            name: "NaggieKit",
            dependencies: ["Yams"],
            // Only used to import settings from the old SQLite database (LegacySQLiteImport).
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(name: "NaggieKitTests", dependencies: ["NaggieKit"]),
    ]
)
