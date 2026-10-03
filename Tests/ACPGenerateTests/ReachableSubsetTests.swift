import Foundation
import Testing

@testable import ACPGenerateCore

/// The generator can emit a subset of a schema document: only the definitions
/// that `GeneratorConfig.rootDefinitions` reaches through `$ref`.
///
/// A definition in `GeneratorConfig.sharedDefinitions` is a type that another
/// set already emits at the top level. The generator does not emit it again,
/// it does not walk into it, and a reference to it resolves to its name.
@Suite struct ReachableSubsetTests {
    /// A miniature document: one root that reaches an identifier, a leaf and a
    /// shared type, beside definitions that the root does not reach. One of
    /// them has a shape that the generator refuses, so a run that classifies
    /// it fails.
    private static let schema = Data(
        #"""
        {
          "$defs": {
            "Root": {
              "type": "object",
              "properties": {
                "id": {"$ref": "#/$defs/RootId"},
                "shared": {"$ref": "#/$defs/Shared"},
                "leaves": {"type": "array", "items": {"$ref": "#/$defs/Leaf"}}
              },
              "required": ["id", "shared"]
            },
            "RootId": {"type": "string"},
            "Leaf": {"type": "object", "properties": {"label": {"type": "string"}}},
            "Shared": {"type": "object", "properties": {"inner": {"$ref": "#/$defs/SharedInner"}}},
            "SharedInner": {"type": "object", "properties": {}},
            "Unreached": {"type": "object", "properties": {}},
            "UnsupportedUnreached": {"type": "number"}
          }
        }
        """#.utf8
    )

    /// The namespace the subset nests in.
    private static let namespace = "Subset"

    /// The configuration that roots the subset at `Root` and shares `Shared`.
    private static let config = GeneratorConfig(
        rootDefinitions: ["Root"],
        sharedDefinitions: ["Shared"]
    )

    /// Generates the subset into the namespace.
    ///
    /// - Parameter config: The configuration to generate with.
    /// - Returns: The generated files.
    /// - Throws: `GeneratorError` when generation fails.
    private static func generate(config: GeneratorConfig = config) throws -> [GeneratedFile] {
        try SchemaGenerator(config: config).generate(schemaJSON: schema, namespace: namespace)
    }

    /// Every generated source joined, in file name order.
    ///
    /// - Returns: The joined source text.
    /// - Throws: `GeneratorError` when generation fails.
    private static func joinedSource() throws -> String {
        try generate().sorted { $0.name < $1.name }.map(\.contents).joined()
    }

    @Test func onlyTheDefinitionsTheRootsReachAreEmitted() throws {
        let source = try Self.joinedSource()
        #expect(source.contains("public struct Root: Codable, Hashable, Sendable {"))
        #expect(source.contains("public struct RootId: "))
        #expect(source.contains("public struct Leaf: Codable, Hashable, Sendable {"))
        #expect(!source.contains("Unreached"))
    }

    @Test func anUnreachedDefinitionIsNeverClassified() throws {
        // `UnsupportedUnreached` has a shape the generator refuses. The full
        // document fails, so the subset run passes only when it skips it.
        #expect(throws: GeneratorError.self) {
            try SchemaGenerator(config: GeneratorConfig()).generate(schemaJSON: Self.schema)
        }
        #expect(throws: Never.self) { try Self.generate() }
    }

    @Test func aSharedDefinitionIsNotEmittedAndItsClosureIsNotWalked() throws {
        let source = try Self.joinedSource()
        #expect(!source.contains("struct Shared"))
        #expect(!source.contains("SharedInner"))
    }

    @Test func aReferenceToASharedDefinitionResolvesToItsName() throws {
        #expect(try Self.joinedSource().contains("public var shared: Shared"))
    }

    @Test func aRootThatTheSchemaDoesNotDefineFailsGeneration() {
        let stale = GeneratorConfig(rootDefinitions: ["Root", "Missing"], sharedDefinitions: ["Shared"])
        #expect(
            throws: GeneratorError.invalidSchema(
                "root definition \"Missing\" is not a definition the schema declares"
            )
        ) {
            try Self.generate(config: stale)
        }
    }

    @Test func aSharedDefinitionThatTheSchemaDoesNotDefineFailsGeneration() {
        let stale = GeneratorConfig(rootDefinitions: ["Root"], sharedDefinitions: ["Shared", "Missing"])
        #expect(
            throws: GeneratorError.invalidSchema(
                "shared definition \"Missing\" is not a definition the schema declares"
            )
        ) {
            try Self.generate(config: stale)
        }
    }

    @Test func aSharedDefinitionThatNoRootReachesFailsGeneration() {
        let stale = GeneratorConfig(rootDefinitions: ["Root"], sharedDefinitions: ["Shared", "Unreached"])
        #expect(
            throws: GeneratorError.invalidSchema(
                "shared definition \"Unreached\" is not reached from the root definitions"
            )
        ) {
            try Self.generate(config: stale)
        }
    }

    @Test func namespacedFilesExtendTheNamespaceAndNeverDeclareIt() throws {
        let files = try Self.generate()
        #expect(!files.isEmpty)
        for file in files {
            #expect(file.contents.contains("extension \(Self.namespace) {"), "\(file.name) does not extend the namespace")
            #expect(!file.contents.contains("enum \(Self.namespace)"), "\(file.name) declares the namespace")
        }
    }

    @Test func aNamespacedSetEmitsNoFileForAnEmptyDeclarationList() throws {
        // The subset holds no placeholder, so no `Unresolved` file exists.
        let names = try Self.generate().map(\.name)
        #expect(!names.contains { $0.contains("Unresolved") })
        #expect(names.contains("\(Self.namespace).Models.generated.swift"))
    }

    @Test func theTopLevelSetEmitsEachBaseFileForAnEmptyDeclarationList() throws {
        let names = try SchemaGenerator(config: Self.config).generate(schemaJSON: Self.schema).map(\.name)
        #expect(names.contains("Unresolved.generated.swift"))
    }
}
