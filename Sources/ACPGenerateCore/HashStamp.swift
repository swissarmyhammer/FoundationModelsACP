import CryptoKit
import Foundation

/// The outcome of a hash-gated generation run.
public enum GenerationOutcome: Equatable, Sendable {
    /// The artifacts match the recorded stamp; nothing was regenerated.
    case unchanged(hash: String)

    /// The artifacts differ from the recorded stamp; these files (the stamp
    /// among them) were regenerated.
    case regenerated(files: [GeneratedFile], hash: String)
}

extension SchemaGenerator {
    /// The stamp file name for a top-level schema set.
    private static let defaultStampFileName = ".schema-hash"

    /// The marker byte prefixing a present artifact in the hash preimage.
    private static let presentArtifactMarker: UInt8 = 1

    /// The marker byte standing in for an absent artifact in the hash preimage.
    private static let absentArtifactMarker: UInt8 = 0

    /// Returns the content-hash stamp file name for a set's output namespace.
    ///
    /// A namespaced set gets its own stamp so multiple sets sharing an output
    /// directory never overwrite one another's stamps.
    ///
    /// - Parameter namespace: The set's output namespace, or `nil` for the
    ///   top-level set.
    /// - Returns: `.schema-hash` for the top-level set, or
    ///   `.<namespace>.schema-hash` for a namespaced set.
    public static func stampFileName(namespace: String?) -> String {
        guard let namespace else { return defaultStampFileName }
        return ".\(namespace).schema-hash"
    }

    /// Computes the stable content hash of a schema set's artifacts.
    ///
    /// Each artifact is framed with a presence marker and a little-endian byte
    /// count before its bytes, so distinct artifact boundaries — and a present
    /// empty artifact versus an absent one — can never collide.
    ///
    /// - Parameters:
    ///   - schemaJSON: The schema document bytes.
    ///   - metaJSON: The stable routing manifest bytes, or `nil`.
    ///   - unstableMetaJSON: The unstable routing manifest bytes, or `nil`.
    /// - Returns: The lowercase hex-encoded SHA-256 of the framed artifacts.
    public static func artifactHash(
        schemaJSON: Data,
        metaJSON: Data?,
        unstableMetaJSON: Data?
    ) -> String {
        var hasher = SHA256()
        for artifact in [schemaJSON, metaJSON, unstableMetaJSON] {
            guard let artifact else {
                hasher.update(data: Data([absentArtifactMarker]))
                continue
            }
            hasher.update(data: Data([presentArtifactMarker]))
            var byteCount = UInt64(artifact.count).littleEndian
            withUnsafeBytes(of: &byteCount) { hasher.update(data: Data($0)) }
            hasher.update(data: artifact)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Generates output only when the artifacts differ from the recorded stamp.
    ///
    /// This is the hash-stamp short-circuit: the artifact hash is stamped into
    /// the output as a `.schema-hash` file, and a run whose freshly computed
    /// hash equals `previousHash` regenerates nothing, so the writer can leave
    /// every file — and its mtime — untouched. Regeneration fires only when a
    /// new schema is dropped in.
    ///
    /// - Parameters:
    ///   - schemaJSON: The raw bytes of the schema document.
    ///   - metaJSON: The raw bytes of the stable routing manifest, or `nil`.
    ///   - unstableMetaJSON: The raw bytes of the unstable routing manifest,
    ///     or `nil`.
    ///   - namespace: The set's output namespace, threaded through to both the
    ///     generated types and the stamp file name.
    ///   - previousHash: The hash recorded by the last run, or `nil` when no
    ///     stamp exists yet.
    /// - Returns: `.unchanged` when the fresh hash equals `previousHash`;
    ///   otherwise `.regenerated` carrying the files (the stamp among them) and
    ///   the new hash.
    /// - Throws: `GeneratorError` when generation fails.
    public func generateIfChanged(
        schemaJSON: Data,
        metaJSON: Data? = nil,
        unstableMetaJSON: Data? = nil,
        namespace: String? = nil,
        previousHash: String?
    ) throws -> GenerationOutcome {
        let hash = Self.artifactHash(
            schemaJSON: schemaJSON,
            metaJSON: metaJSON,
            unstableMetaJSON: unstableMetaJSON
        )
        guard hash != previousHash else {
            return .unchanged(hash: hash)
        }
        var files = try generate(
            schemaJSON: schemaJSON,
            metaJSON: metaJSON,
            unstableMetaJSON: unstableMetaJSON,
            namespace: namespace
        )
        files.append(
            GeneratedFile(
                name: Self.stampFileName(namespace: namespace),
                contents: "\(hash)\n"
            )
        )
        return .regenerated(files: files, hash: hash)
    }
}
