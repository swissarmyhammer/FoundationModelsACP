import Foundation
import Testing

@testable import ACPGenerateCore

/// The hash-stamp short-circuit: a run whose artifacts match the recorded
/// stamp regenerates nothing, a differing hash regenerates and re-stamps, and
/// the hash is a stable function of the artifact bytes.
@Suite struct HashStampTests {
    /// A SHA-256 hex string that no real artifact set will hash to.
    private static let bogusHash = String(repeating: "0", count: 64)

    /// The vendored artifact hash.
    ///
    /// - Returns: The hash of the vendored schema and both manifests.
    /// - Throws: A test failure when an artifact cannot be read.
    private func vendoredHash() throws -> String {
        let artifacts = try vendoredArtifacts()
        return SchemaGenerator.artifactHash(
            schemaJSON: artifacts.schema,
            metaJSON: artifacts.meta,
            unstableMetaJSON: artifacts.unstableMeta
        )
    }

    @Test func matchingHashRegeneratesNothing() throws {
        let artifacts = try vendoredArtifacts()
        let hash = try vendoredHash()
        let outcome = try SchemaGenerator().generateIfChanged(
            schemaJSON: artifacts.schema,
            metaJSON: artifacts.meta,
            unstableMetaJSON: artifacts.unstableMeta,
            previousHash: hash
        )
        #expect(outcome == .unchanged(hash: hash))
    }

    @Test func differingHashRegeneratesAndStamps() throws {
        let artifacts = try vendoredArtifacts()
        let outcome = try SchemaGenerator().generateIfChanged(
            schemaJSON: artifacts.schema,
            metaJSON: artifacts.meta,
            unstableMetaJSON: artifacts.unstableMeta,
            previousHash: Self.bogusHash
        )
        guard case .regenerated(let files, let hash) = outcome else {
            Issue.record("expected regeneration when the recorded hash differs")
            return
        }
        #expect(hash == (try vendoredHash()))
        let stamp = try #require(files.first { $0.name == SchemaGenerator.stampFileName(namespace: nil) })
        #expect(stamp.contents == "\(hash)\n")
        #expect(files.contains { $0.name == "Models.generated.swift" })
        #expect(files.contains { $0.name == "MethodTable.generated.swift" })
    }

    @Test func noRecordedHashRegenerates() throws {
        let artifacts = try vendoredArtifacts()
        let outcome = try SchemaGenerator().generateIfChanged(
            schemaJSON: artifacts.schema,
            metaJSON: artifacts.meta,
            unstableMetaJSON: artifacts.unstableMeta,
            previousHash: nil
        )
        guard case .regenerated = outcome else {
            Issue.record("expected regeneration when no stamp has been recorded yet")
            return
        }
    }

    @Test func stampFileNameIsAHiddenDotfile() {
        #expect(SchemaGenerator.stampFileName(namespace: nil) == ".schema-hash")
        #expect(SchemaGenerator.stampFileName(namespace: "ToyV2") == ".ToyV2.schema-hash")
    }

    @Test func hashIsStableAcrossCalls() throws {
        #expect(try vendoredHash() == (try vendoredHash()))
    }

    @Test func hashChangesWhenSchemaBytesChange() throws {
        let artifacts = try vendoredArtifacts()
        var mutated = artifacts.schema
        mutated.append(0x20)  // A trailing space is enough to change the bytes.
        let changed = SchemaGenerator.artifactHash(
            schemaJSON: mutated,
            metaJSON: artifacts.meta,
            unstableMetaJSON: artifacts.unstableMeta
        )
        #expect(changed != (try vendoredHash()))
    }

    @Test func presentAndAbsentManifestsHashDifferently() throws {
        let artifacts = try vendoredArtifacts()
        let withMeta = SchemaGenerator.artifactHash(
            schemaJSON: artifacts.schema,
            metaJSON: artifacts.meta,
            unstableMetaJSON: nil
        )
        let withoutMeta = SchemaGenerator.artifactHash(
            schemaJSON: artifacts.schema,
            metaJSON: nil,
            unstableMetaJSON: nil
        )
        #expect(withMeta != withoutMeta)
    }
}
