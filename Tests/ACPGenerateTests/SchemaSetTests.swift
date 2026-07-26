import Foundation
import Testing

@testable import ACPGenerateCore

/// The generator's inputs are a `SchemaSet` descriptor, not constants: the
/// primary set emits at the top level, and a second toy set — described purely
/// as data — emits into its own namespace with no generator code change.
///
/// The vendored primary set itself is covered by `VendoredSchemaTests`.
@Suite struct SchemaSetTests {
    /// A toy second schema set: one object definition, its own version label
    /// and namespace. Standing in for a hypothetical second vendoring
    /// alongside the primary ACP v2 set.
    private static let toySchema = Data(
        #"{"$defs": {"ToyThing": {"type": "object", "properties": {"label": {"type": "string"}}, "required": ["label"]}}}"#.utf8
    )

    /// The generator configured for the toy set (no renames or invariants).
    private var toyGenerator: SchemaGenerator {
        SchemaGenerator(config: GeneratorConfig())
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
