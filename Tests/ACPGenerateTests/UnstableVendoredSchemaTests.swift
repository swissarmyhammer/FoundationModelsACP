import CryptoKit
import Foundation
import Testing

@testable import ACPGenerateCore
import FoundationModelsACP

/// Emission assertions for the vendored unstable schema document.
///
/// The generator emits only the subset of `schema.unstable.json` that the
/// unstable session updates `compaction_update`, `compaction_summary_chunk`
/// and `notice` reach, into the `Unstable` namespace. `VendoredSchemaTests`
/// compares the checked-in output and stamp of every set with a fresh run;
/// this suite pins what the unstable subset holds.
@Suite struct UnstableVendoredSchemaTests {
    /// The vendored unstable set.
    private static let set = SchemaSet.acpV2Unstable

    /// The SHA-256 digest that the `schema-v2.0.0-alpha.7` release gives for
    /// its `schema.unstable.json` asset.
    private static let releaseAssetDigest = "75b2aa359dd26cd9d0468674be96482b14a2d181bc8e3ea8c91a8e598f63e3b5"

    /// The marker that upstream puts at the start of each unstable
    /// definition's description.
    private static let unstableMarker = "**UNSTABLE**"

    /// The indentation of a declaration that a namespace extension holds.
    private static let nestedIndent = "    "

    /// Every generated source of the unstable set, joined in file name order.
    ///
    /// - Returns: The joined source text.
    /// - Throws: `GeneratorError` when generation fails, or an error when an
    ///   artifact cannot be read.
    private static func generatedSource() throws -> String {
        try VendoredSchemaTests.generateFromVendoredArtifacts(of: set)
            .sorted { $0.key < $1.key }
            .map(\.value)
            .joined()
    }

    /// The names of the types that the namespace extensions declare, in
    /// declaration order.
    ///
    /// - Parameter source: Generated source of the unstable set.
    /// - Returns: The declared type names.
    private static func namespacedTypeNames(in source: String) -> [String] {
        let unindented = source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.hasPrefix(nestedIndent) ? $0.dropFirst(nestedIndent.count) : $0 }
            .joined(separator: "\n")
        return VendoredSchemaTests.declaredTypeNames(in: unindented)
    }

    /// The doc comment lines directly above each nested type declaration,
    /// keyed by the declaration line.
    ///
    /// - Parameter source: Generated source of the unstable set.
    /// - Returns: The doc comment of each nested declaration.
    private static func nestedDocComments(in source: String) -> [String: String] {
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let declarationPrefixes = ["public struct ", "public enum "].map { nestedIndent + $0 }
        var comments: [String: String] = [:]
        for (index, line) in lines.enumerated() where declarationPrefixes.contains(where: line.hasPrefix) {
            let docLines = lines[..<index].reversed().prefix { $0.hasPrefix(nestedIndent + "///") }
            comments[line] = docLines.reversed().joined(separator: "\n")
        }
        return comments
    }

    /// Reads one vendored schema document's definitions.
    ///
    /// - Parameter path: The tree-relative schema path.
    /// - Returns: The `$defs` object.
    /// - Throws: An error when the file cannot be read or parsed, or a test
    ///   failure when it has no `$defs` object.
    private static func definitions(at path: String) throws -> [String: JSONValue] {
        let schema = try JSONDecoder().decode(JSONValue.self, from: VendoredSchemaTests.packageFile(path))
        return try #require(schema["$defs"]?.objectValue)
    }

    /// The same fragment with every `description` member removed, at every
    /// depth.
    ///
    /// - Parameter fragment: A schema fragment.
    /// - Returns: The fragment without descriptions.
    private static func strippingDescriptions(_ fragment: JSONValue) -> JSONValue {
        switch fragment {
        case .object(let members):
            .object(members.filter { $0.key != "description" }.mapValues(strippingDescriptions))
        case .array(let elements):
            .array(elements.map(strippingDescriptions))
        case .null, .bool, .number, .string:
            fragment
        }
    }

    /// Every definition name that a `$ref` inside a fragment points at.
    ///
    /// - Parameter fragment: A schema fragment.
    /// - Returns: The referenced definition names, with repeats.
    private static func referencedNames(in fragment: JSONValue) -> [String] {
        switch fragment {
        case .object(let members):
            members.flatMap { key, value in
                key == "$ref" ? [value.stringValue?.components(separatedBy: "/").last ?? ""] : referencedNames(in: value)
            }
        case .array(let elements):
            elements.flatMap(referencedNames)
        case .null, .bool, .number, .string:
            []
        }
    }

    /// The definitions that a set of roots reaches through `$ref`, the roots
    /// included.
    ///
    /// - Parameters:
    ///   - roots: The definitions to start from.
    ///   - definitions: The schema's `$defs` object.
    /// - Returns: The reached definition names, sorted.
    private static func closure(of roots: Set<String>, in definitions: [String: JSONValue]) -> [String] {
        var reached: Set<String> = []
        var pending = roots.sorted()
        while let name = pending.popLast() {
            guard reached.insert(name).inserted, let fragment = definitions[name] else { continue }
            pending += referencedNames(in: fragment)
        }
        return reached.sorted()
    }

    /// A compaction ID for the sample payloads.
    private static let sampleCompactionId = "compaction-1"

    /// A minimal wire payload of each root definition, beside the case of the
    /// typed view that the payload reads as.
    private static let samples: [String: (payload: JSONValue, update: Unstable.SessionUpdate)] = [
        "CompactionUpdate": (
            .object(["compactionId": .string(sampleCompactionId), "status": .string("in_progress")]),
            .compactionUpdate(
                Unstable.CompactionUpdate(compactionId: Unstable.CompactionId(rawValue: sampleCompactionId), status: .inProgress)
            )
        ),
        "CompactionSummaryChunk": (
            .object([
                "compactionId": .string(sampleCompactionId),
                "content": .object(["type": .string("text"), "text": .string("Part.")]),
            ]),
            .compactionSummaryChunk(
                Unstable.CompactionSummaryChunk(
                    compactionId: Unstable.CompactionId(rawValue: sampleCompactionId),
                    content: .text(TextContent(text: "Part."))
                )
            )
        ),
        "Notice": (
            .object(["severity": .string("info"), "title": .string("Compacted")]),
            .notice(Unstable.Notice(severity: .info, title: "Compacted"))
        ),
    ]

    @Test func eachUnstableSessionUpdateTagReadsAsTheCaseOfItsPayload() throws {
        // The typed view keeps the wire tags by hand. Each tag that the
        // vendored `SessionUpdate` union gives to a root payload must read as
        // the case of that payload, and encode back to the same tag.
        let sessionUpdate = try #require(Self.definitions(at: Self.set.schemaPath)["SessionUpdate"])
        let variants = try #require(sessionUpdate["anyOf"]?.arrayValue)
        let routed = variants
            .compactMap { variant -> (tag: String, definition: String)? in
                let tag = variant["properties"]?["sessionUpdate"]?["const"]?.stringValue
                let definition = variant["allOf"]?.arrayValue?.first?["$ref"]?.stringValue
                    .flatMap { $0.components(separatedBy: "/").last }
                return tag.flatMap { tag in definition.map { (tag, $0) } }
            }
            .filter { Self.set.config.rootDefinitions.contains($0.definition) }
        #expect(Set(routed.map(\.definition)) == Self.set.config.rootDefinitions)
        for (tag, definition) in routed {
            let sample = try #require(Self.samples[definition], "no sample payload for \(definition)")
            #expect(try Unstable.SessionUpdate(.unknown(tag, sample.payload)) == sample.update, "\(tag)")
            #expect(try SessionUpdate(sample.update) == .unknown(tag, sample.payload), "\(tag)")
        }
    }

    @Test func unstableSetIsTheNamespacedVendoredUnstableSchema() {
        #expect(Self.set.versionLabel == "v2-unstable")
        #expect(Self.set.outputNamespace == "Unstable")
        #expect(Self.set.schemaPath == "Schema/acp-v2.unstable.json")
        #expect(Self.set.metaPath == nil)
        #expect(Self.set.unstableMetaPath == nil)
        #expect(Self.set.config.rootDefinitions == ["CompactionUpdate", "CompactionSummaryChunk", "Notice"])
        #expect(Self.set.config.sharedDefinitions == ["ContentBlock"])
    }

    @Test func vendoredUnstableSchemaMatchesTheReleaseAssetByteForByte() throws {
        let digest = SHA256.hash(data: try VendoredSchemaTests.packageFile(Self.set.schemaPath))
        #expect(digest.map { String(format: "%02x", $0) }.joined() == Self.releaseAssetDigest)
    }

    @Test func emitsExactlyTheTypesTheUnstableSessionUpdatesReach() throws {
        #expect(
            Self.namespacedTypeNames(in: try Self.generatedSource()).sorted() == [
                "CompactionId", "CompactionStatus", "CompactionSummaryChunk", "CompactionUpdate", "Notice",
                "NoticeSeverity",
            ]
        )
    }

    @Test func everyEmittedTypeIsMarkedUnstableInItsDocumentation() throws {
        let comments = Self.nestedDocComments(in: try Self.generatedSource())
        #expect(!comments.isEmpty)
        for (declaration, comment) in comments {
            #expect(comment.contains(Self.unstableMarker), "\(declaration) is not marked unstable")
        }
    }

    @Test func compactionUpdateCarriesPatchFieldsAndAFold() throws {
        let source = try Self.generatedSource()
        #expect(source.contains("        public var summary: PatchField<[ContentBlock]>"))
        #expect(source.contains("        public var error: PatchField<String>"))
        #expect(source.contains("        public var meta: PatchField<JSONValue>"))
        #expect(source.contains("        public func folded(onto existing: CompactionUpdate) -> CompactionUpdate {"))
    }

    @Test func statusAndSeverityKeepUnknownValues() throws {
        let source = try Self.generatedSource()
        #expect(source.contains("    public enum CompactionStatus: Codable, Hashable, Sendable {"))
        #expect(source.contains("    public enum NoticeSeverity: Codable, Hashable, Sendable {"))
        // Each of the two scalar enums keeps an unknown wire value, so the
        // fallback case occurs exactly two times.
        #expect(source.components(separatedBy: "        case unknown(String)\n").count - 1 == 2)
    }

    @Test func sharedDefinitionsMatchTheStableSchemaApartFromDescriptions() throws {
        // A shared definition resolves to the stable type. That is correct
        // only while the unstable document describes the same shape, so the
        // whole closure of each shared definition must agree.
        let unstable = try Self.definitions(at: Self.set.schemaPath)
        let stable = try Self.definitions(at: SchemaSet.acpV2.schemaPath)
        let closure = Self.closure(of: Self.set.config.sharedDefinitions, in: unstable)
        #expect(closure.contains("TextContent"))
        for name in closure {
            let unstableFragment = try #require(unstable[name], "\(name) is missing from the unstable schema")
            let stableFragment = try #require(stable[name], "\(name) is missing from the stable schema")
            #expect(
                Self.strippingDescriptions(unstableFragment) == Self.strippingDescriptions(stableFragment),
                "\(name) differs between the stable and the unstable schema"
            )
        }
    }
}
