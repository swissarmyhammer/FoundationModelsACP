import Foundation
import Testing

import FoundationModelsACP

/// The package-root `Sources/FoundationModelsACP/` directory, located relative
/// to this source file.
private let wireSourcesDirectory = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()  // PackageSmokeTests.swift
    .deletingLastPathComponent()  // FoundationModelsACPTests
    .deletingLastPathComponent()  // Tests
    .appendingPathComponent("Sources")
    .appendingPathComponent("FoundationModelsACP")

/// Verifies the package scaffold exposes its placeholder `ACP` namespace.
@Test func packageExposesACPNamespace() {
    // The placeholder public symbol from the scaffold task must be reachable
    // through the package's public surface under its expected type name.
    #expect(String(describing: ACP.self) == "ACP")
}

/// Guards the wire target's zero-model-dependency invariant: no source file
/// under `Sources/FoundationModelsACP` may import the FoundationModels
/// framework — including submodule (`import FoundationModels.X`) and scoped
/// (`import struct FoundationModels.X`) spellings, hence the optional kind
/// keyword and the negative lookahead instead of a trailing `\b` (whose
/// default Unicode word boundary would not break before a `.`).
/// `import Foundation` and `import FoundationModelsACP`-style module names
/// are unaffected — the lookahead fails on the following identifier character.
@Test func wireTargetImportsNoModelFramework() throws {
    let modelImport = try Regex(#"\bimport\s+(?:\w+\s+)?FoundationModels(?![A-Za-z0-9_])"#)
    let enumerator = try #require(
        FileManager.default.enumerator(
            at: wireSourcesDirectory,
            includingPropertiesForKeys: nil
        )
    )
    var swiftFilesSeen = 0
    for case let url as URL in enumerator where url.pathExtension == "swift" {
        swiftFilesSeen += 1
        let source = try String(contentsOf: url, encoding: .utf8)
        for line in source.split(separator: "\n", omittingEmptySubsequences: false)
        where line.contains(modelImport) {
            Issue.record(
                "Wire target file \(url.lastPathComponent) imports the model framework: \(line)"
            )
        }
    }
    // Guard the guard: an empty walk (e.g. after a directory rename) must not
    // vacuously pass.
    #expect(swiftFilesSeen > 0)
}
