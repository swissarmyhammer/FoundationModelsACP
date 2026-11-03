import CryptoKit
import Foundation
import Testing

@testable import ACPGenerateCore

/// Pins the vendored unstable schema document.
///
/// No schema set reads `Schema/acp-v2.unstable.json`: upstream made the only
/// part of it this package emitted (the compaction and notice session updates)
/// stable in `schema-v2.0.0-alpha.8`. The document stays vendored beside the
/// stable artifacts of the same release, and this suite makes sure that its
/// bytes are the release asset.
@Suite struct UnstableVendoredSchemaTests {
    /// The tree-relative path of the vendored unstable schema document.
    private static let schemaPath = "Schema/acp-v2.unstable.json"

    /// The SHA-256 digest that the `schema-v2.0.0-alpha.8` release gives for
    /// its `schema.unstable.json` asset.
    private static let releaseAssetDigest = "49e10f8c1935854363ed5b176cc6560d856642ba5020c97d264d34de4b6f1b31"

    @Test func vendoredUnstableSchemaMatchesTheReleaseAssetByteForByte() throws {
        let digest = SHA256.hash(data: try VendoredSchemaTests.packageFile(Self.schemaPath))
        #expect(digest.map { String(format: "%02x", $0) }.joined() == Self.releaseAssetDigest)
    }

    @Test func noSchemaSetReadsTheUnstableDocument() {
        #expect(!SchemaSet.all.map(\.schemaPath).contains(Self.schemaPath))
    }
}
