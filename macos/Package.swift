// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Barback",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "BarbackApp", targets: ["BarbackApp"]),
        .library(name: "BarbackCore", targets: ["BarbackCore"])
    ],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(
            name: "BarbackCore",
            dependencies: ["CSQLite"],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "BarbackApp",
            dependencies: ["BarbackCore"]
        ),
        .executableTarget(
            name: "testchild",
            path: "Fixtures/testchild"
        ),
        .testTarget(
            name: "CoreTests",
            dependencies: ["BarbackCore"]
        ),
        .testTarget(
            name: "ProcessTests",
            dependencies: ["BarbackCore"]
        ),
        .testTarget(
            name: "IntegrationTests",
            dependencies: ["BarbackCore"]
        )
    ]
)
