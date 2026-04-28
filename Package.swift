// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "WorkoutImporter",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "WorkoutImporter", targets: ["WorkoutImporter"]),
    ],
    targets: [
        .target(name: "WorkoutImporter"),
        .testTarget(
            name: "WorkoutImporterTests",
            dependencies: ["WorkoutImporter"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
