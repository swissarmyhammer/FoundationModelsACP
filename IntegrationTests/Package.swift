// swift-tools-version: 6.4
import PackageDescription

/// SwiftPM manifest for the ACP wire-conformance integration suite.
///
/// **Why this is a package of its own.** `swift test` at the repository root
/// must run the unit suite and nothing else. SwiftPM has no manifest-level
/// way to hold a target out of the default run, so a nested package the root
/// manifest never names gives that property structurally rather than by
/// convention. This suite spawns the real `acp-test-agent` helper as a child
/// process and validates its raw wire bytes against the vendored
/// `Schema/acp-v2.json` document with a hand-rolled JSON Schema validator —
/// heavier than anything that belongs in the default `swift test` run, and
/// independent of `../Tests/ACPGenerateTests/VendoredSchemaTests.swift`,
/// which proves the generator's Swift *output* matches the schema's shape
/// declaratively but never checks that real encoded or decoded JSON on the
/// wire actually validates against the schema's own Draft 2020-12 rules.
///
/// Run it with:
///
///     swift test --package-path IntegrationTests
///
/// **Why `acp-test-agent` is a declared product.** A SwiftPM test target
/// cannot depend on another package's executable *target*, only its
/// *product* — `../Package.swift` exposes `acp-test-agent` as an
/// `.executable` product for exactly this reason.
///
/// **Why the dependency list restates the root manifest's.** A SwiftPM
/// manifest cannot import code from another manifest, and a package may only
/// name the products of packages it declares itself, so `../Package.swift`
/// is named here by path rather than shared.
let package = Package(
    name: "FoundationModelsACPIntegrationTests",
    // Commits to macOS 27, exactly as `../Package.swift` does; a lower floor
    // here would not resolve against it.
    platforms: [
        .macOS(.v27)
    ],
    dependencies: [
        .package(path: "..")
    ],
    targets: [
        .testTarget(
            name: "FoundationModelsACPIntegrationTests",
            dependencies: [
                .product(name: "FoundationModelsACP", package: "FoundationModelsACP"),
                .product(name: "acp-test-agent", package: "FoundationModelsACP"),
            ],
            path: "Tests/FoundationModelsACPIntegrationTests"
        )
    ]
)
