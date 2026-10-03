// swift-tools-version:6.0
import PackageDescription

// Everything that isn't UI or the background upload session: walking the card,
// hashing, building the upload body and talking to Immich. Kept free of UIKit so
// it builds and tests on Linux as well as in the app.
let package = Package(
    name: "OffloadCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "OffloadCore", targets: ["OffloadCore"]),
        .executable(name: "offloadcheck", targets: ["offloadcheck"]),
    ],
    targets: [
        .target(name: "OffloadCore"),
        .executableTarget(name: "offloadcheck", dependencies: ["OffloadCore"]),
        .testTarget(name: "OffloadCoreTests", dependencies: ["OffloadCore"]),
    ],
    swiftLanguageModes: [.v5]
)
