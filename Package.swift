// swift-tools-version: 6.4
import PackageDescription

// The test targets that carry ndJSON transcript fixtures load them via
// #filePath, not as bundle resources, so each excludes its `Fixtures`
// directory. (ACPGenerateTests has none and needs no exclude.)
let fixturesExclude = ["Fixtures"]

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
    dependencies: [
        // Plugin-only dependency: powers `swift package generate-documentation`
        // (the CI DocC build gate). It is a build-time command plugin, not
        // linked into the library product.
        .package(url: "https://github.com/apple/swift-docc-plugin", from: "1.0.0")
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
        .executableTarget(
            name: "acp-test-agent",
            dependencies: ["FoundationModelsACP"],
            path: "Sources/acp-test-agent"
        ),
        .plugin(
            name: "GenerateACP",
            capability: .command(
                intent: .custom(
                    verb: "generate-acp",
                    description: "Regenerate ACP Swift types from the vendored JSON schema."
                ),
                permissions: [
                    .writeToPackageDirectory(
                        reason: "Writes generated Swift sources into Sources/FoundationModelsACP/Generated."
                    )
                ]
            ),
            dependencies: ["acp-generate"],
            path: "Plugins/GenerateACP"
        ),
        .testTarget(
            name: "FoundationModelsACPTests",
            dependencies: ["FoundationModelsACP", "acp-test-agent"],
            path: "Tests/FoundationModelsACPTests",
            exclude: fixturesExclude
        ),
        .testTarget(
            name: "ACPGenerateTests",
            dependencies: ["ACPGenerateCore", "FoundationModelsACP"],
            path: "Tests/ACPGenerateTests"
        ),
        .testTarget(
            name: "FoundationModelsACPEvals",
            dependencies: ["FoundationModelsACP"],
            path: "Tests/FoundationModelsACPEvals",
            exclude: fixturesExclude
        ),
    ]
)
