import Foundation
import Testing

@testable import ACPGenerateCore

/// The generator's inputs are a `SchemaSet` descriptor, not constants: the
/// primary set emits at the top level, and a second toy set — described purely
/// as data — emits into its own namespace with no generator code change.
@Suite struct SchemaSetTests {
    /// A toy second schema set: one object definition, its own version label
    /// and namespace. Standing in for a hypothetical ACP v2 vendoring.
    private static let toySchema = Data(
        #"{"$defs": {"ToyThing": {"type": "object", "properties": {"label": {"type": "string"}}, "required": ["label"]}}}"#.utf8
    )

    /// The generator configured for the toy set (no v1 renames or invariants).
    private var toyGenerator: SchemaGenerator {
        SchemaGenerator(config: GeneratorConfig())
    }

    @Test func primarySetIsTopLevelACPv1() {
        let set = SchemaSet.acpV1
        #expect(set.versionLabel == "v1")
        #expect(set.outputNamespace == nil)
        #expect(set.schemaPath == "Schema/acp-v1.json")
        #expect(set.metaPath == "Schema/acp-v1.meta.json")
        #expect(set.unstableMetaPath == "Schema/acp-v1.meta.unstable.json")
        #expect(SchemaSet.all.contains { $0.versionLabel == set.versionLabel })
    }

    @Test func namespacedSetNestsTypesAndPrefixesFileNames() throws {
        let files = try toyGenerator.generate(schemaJSON: Self.toySchema, namespace: "ToyV2")
        let models = try #require(files.first { $0.name == "ToyV2.Models.generated.swift" })
        #expect(models.contents.contains("public enum ToyV2 {"))
        // The struct is nested one level inside the namespace enum.
        #expect(models.contents.contains("    public struct ToyThing: Codable, Hashable, Sendable {"))
    }

    @Test func topLevelSetEmitsWithoutNamespaceWrapperOrPrefix() throws {
        let files = try toyGenerator.generate(schemaJSON: Self.toySchema)
        let models = try #require(files.first { $0.name == "Models.generated.swift" })
        #expect(!models.contents.contains("public enum ToyV2"))
        #expect(models.contents.contains("public struct ToyThing: Codable, Hashable, Sendable {"))
    }

    @Test func namespacedRegenerationStampsUnderTheNamespace() throws {
        let outcome = try toyGenerator.generateIfChanged(
            schemaJSON: Self.toySchema,
            namespace: "ToyV2",
            previousHash: nil
        )
        guard case .regenerated(let files, _) = outcome else {
            Issue.record("expected regeneration for a first run with no stamp")
            return
        }
        #expect(files.contains { $0.name == ".ToyV2.schema-hash" })
    }
}
