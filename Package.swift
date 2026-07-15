// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "FoundationModelsACP",
    platforms: [
        .macOS(.v27)
    ],
    products: [
        .library(
            name: "FoundationModelsACP",
            targets: ["FoundationModelsACP"]
        )
    ],
    targets: [
        .target(
            name: "FoundationModelsACP",
            path: "Sources/FoundationModelsACP",
            exclude: [
                "Generated/.gitkeep",
                "Transport/.gitkeep",
                "Connection/.gitkeep",
                "Bridge/.gitkeep",
            ]
        ),
        .target(
            name: "ACPGenerateCore",
            dependencies: ["FoundationModelsACP"],
            path: "Sources/ACPGenerateCore"
        ),
        .executableTarget(
            name: "acp-generate",
            dependencies: ["ACPGenerateCore"],
            path: "Sources/acp-generate"
        ),
        .testTarget(
            name: "FoundationModelsACPTests",
            dependencies: ["FoundationModelsACP"],
            path: "Tests/FoundationModelsACPTests",
            // Replay fixtures are loaded via #filePath, not as bundle resources.
            exclude: ["Fixtures"]
        ),
        .testTarget(
            name: "ACPGenerateTests",
            dependencies: ["ACPGenerateCore", "FoundationModelsACP"],
            path: "Tests/ACPGenerateTests"
        ),
    ]
)
