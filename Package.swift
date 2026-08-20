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
        ),
        // Consumed by `IntegrationTests/Package.swift`, which cannot depend on
        // this package's `acp-test-agent` *target* from outside this
        // manifest — only a declared product lets a sibling package build it
        // and locate the resulting binary.
        .executable(
            name: "acp-test-agent",
            targets: ["acp-test-agent"]
        ),
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
            exclude: ["Generated/.gitkeep"]
        ),
        .target(
            name: "ACPGenerateCore",
            dependencies: ["FoundationModelsACP"],
            path: "Sources/ACPGenerateCore"
        ),
        .executableTarget(
            name: "acp-generate",
            dependencies: ["ACPGenerateCore"],
            path: "Sources/acp-generate",
            resources: [.copy("Documentation.docc")]
        ),
        .executableTarget(
            name: "acp-test-agent",
            dependencies: ["FoundationModelsACP"],
            path: "Sources/acp-test-agent",
            resources: [.copy("Documentation.docc")]
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
            exclude: ["Fixtures"]
        ),
        .testTarget(
            name: "ACPGenerateTests",
            dependencies: ["ACPGenerateCore"],
            path: "Tests/ACPGenerateTests"
        ),
    ]
)
