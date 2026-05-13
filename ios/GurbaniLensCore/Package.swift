// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "GurbaniLensCore",
    platforms: [
        .iOS(.v15),
        .macOS(.v13),
    ],
    products: [
        .library(
            name: "GurbaniLensCore",
            targets: ["GurbaniLensCore"]
        ),
        .executable(
            name: "port-parity-run",
            targets: ["PortParityRun"]
        ),
    ],
    targets: [
        .target(
            name: "GurbaniLensCore",
            dependencies: [],
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]
        ),
        .executableTarget(
            name: "PortParityRun",
            dependencies: ["GurbaniLensCore"]
        ),
        .testTarget(
            name: "GurbaniLensCoreTests",
            dependencies: ["GurbaniLensCore"],
            resources: [
                .copy("Resources/test_vectors.json"),
            ]
        ),
    ]
)
