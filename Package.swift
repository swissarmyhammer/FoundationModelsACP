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
        .testTarget(
            name: "FoundationModelsACPTests",
            dependencies: ["FoundationModelsACP"],
            path: "Tests/FoundationModelsACPTests"
        ),
    ]
)
