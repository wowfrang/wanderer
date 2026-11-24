// swift-tools-version: 5.10
import PackageDescription

// Pure Swift domain logic for Wanderer: models, persistence, import, geometry,
// visit detection and session state. No UIKit/MapKit/CoreLocation so it can be
// unit tested quickly with `swift test` (macOS or Linux).
let package = Package(
    name: "WandererCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "WandererCore", targets: ["WandererCore"]),
    ],
    targets: [
        // Only used on Linux, where the SQLite3 module isn't built in.
        .systemLibrary(
            name: "CSQLite",
            path: "Sources/CSQLite",
            providers: [.apt(["libsqlite3-dev"])]
        ),
        .target(
            name: "WandererCore",
            dependencies: [.target(name: "CSQLite", condition: .when(platforms: [.linux]))],
            resources: [.copy("Resources/milan-sample.json")]
        ),
        .testTarget(
            name: "WandererCoreTests",
            dependencies: ["WandererCore"]
        ),
    ]
)
