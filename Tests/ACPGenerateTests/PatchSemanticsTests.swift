import Foundation
import Testing

@testable import ACPGenerateCore

/// The generator side of three-state patch semantics: `GeneratorConfig.patchSemanticsFields`
/// names which `(type, field)` pairs the schema describes only in prose
/// ("omitted fields leave the stored value unchanged, `null` clears it, and
/// concrete values replace it"), and the emitter renders those fields as
/// `PatchField<Wrapped>` instead of a plain `Optional`.
///
/// A miniature schema exercises all three decode strategies a configured
/// field can carry — strict, forgiving scalar, forgiving array — plus a
/// nullable field left out of the config, which must keep the plain
/// `Optional` shape: patch semantics is never the default for "nullable",
/// only for what the table names.
@Suite struct PatchSemanticsTests {
    private static let schema = Data(
        """
        {
          "$defs": {
            "Widget": {
              "type": "object",
              "properties": {
                "id": { "type": "string" },
                "note": {
                  "type": ["string", "null"],
                  "x-deserialize-default-on-error": true
                },
                "tags": {
                  "type": ["array", "null"],
                  "items": { "type": "string" },
                  "x-deserialize-default-on-error": true,
                  "x-deserialize-skip-invalid-items": true
                },
                "code": {
                  "type": ["integer", "null"]
                },
                "color": {
                  "type": ["string", "null"],
                  "x-deserialize-default-on-error": true
                }
              },
              "required": ["id"]
            }
          }
        }
        """.utf8)

    /// `note`/`tags`/`code` have patch semantics; `color` deliberately does
    /// not, despite being just as nullable, to prove the config — not
    /// nullability — decides.
    private static let config = GeneratorConfig(
        patchSemanticsFields: ["Widget.note", "Widget.tags", "Widget.code"]
    )

    private func modelsSource() throws -> String {
        let files = try SchemaGenerator(config: Self.config).generate(schemaJSON: Self.schema)
        return try #require(files.first { $0.name == "Models.generated.swift" }).contents
    }

    @Test func patchFieldsEmitAsThePatchFieldWrapperNotOptional() throws {
        let source = try modelsSource()
        #expect(source.contains("public var note: PatchField<String>"))
        #expect(source.contains("public var tags: PatchField<[String]>"))
        #expect(source.contains("public var code: PatchField<Int>"))
        // Never the bare-Optional shape for a configured field.
        #expect(!source.contains("public var note: String?"))
        #expect(!source.contains("public var tags: [String]?"))
        #expect(!source.contains("public var code: Int?"))
    }

    @Test func nonConfiguredNullableFieldKeepsThePlainOptionalShape() throws {
        // `color` is exactly as nullable as `note`, and is not configured —
        // patch semantics must not become the default for every nullable
        // field.
        let source = try modelsSource()
        #expect(source.contains("public var color: String?"))
        #expect(!source.contains("public var color: PatchField<String>"))
    }

    @Test func forgivingScalarPatchFieldsDecodeAndEncodeThroughThePatchHelpers() throws {
        let source = try modelsSource()
        #expect(source.contains("self.note = container.forgivingDecodePatchField(String.self, forKey: .note)"))
        #expect(source.contains("try container.encodePatch(note, forKey: .note)"))
    }

    @Test func forgivingArrayPatchFieldsDecodeAndEncodeThroughThePatchArrayHelper() throws {
        let source = try modelsSource()
        #expect(source.contains("self.tags = container.forgivingDecodePatchArray(of: String.self, forKey: .tags)"))
        #expect(source.contains("try container.encodePatch(tags, forKey: .tags)"))
    }

    @Test func strictPatchFieldsDecodeAndEncodeThroughTheStrictPatchHelper() throws {
        // `code` carries no forgiving annotation, so it decodes strictly —
        // patch semantics does not imply forgiving decoding.
        let source = try modelsSource()
        #expect(source.contains("self.code = try container.decodePatchField(Int.self, forKey: .code)"))
        #expect(source.contains("try container.encodePatch(code, forKey: .code)"))
    }

    @Test func nonConfiguredNullableFieldStillUsesThePlainForgivingHelpers() throws {
        let source = try modelsSource()
        #expect(source.contains("self.color = container.forgivingDecodeIfPresent(String.self, forKey: .color)"))
        #expect(source.contains("try container.encodeIfPresent(color, forKey: .color)"))
    }

    @Test func memberwiseInitDefaultsAPatchFieldToUnchanged() throws {
        let source = try modelsSource()
        #expect(source.contains("note: PatchField<String> = .unchanged"))
        #expect(source.contains("tags: PatchField<[String]> = .unchanged"))
        #expect(source.contains("code: PatchField<Int> = .unchanged"))
    }

    @Test func staleConfigEntryNamingAMissingFieldFailsGeneration() {
        let config = GeneratorConfig(patchSemanticsFields: ["Widget.doesNotExist"])
        #expect(throws: GeneratorError.self) {
            _ = try SchemaGenerator(config: config).generate(schemaJSON: Self.schema)
        }
    }

    @Test func staleConfigEntryNamingAMissingDefinitionFailsGeneration() {
        let config = GeneratorConfig(patchSemanticsFields: ["Ghost.field"])
        #expect(throws: GeneratorError.self) {
            _ = try SchemaGenerator(config: config).generate(schemaJSON: Self.schema)
        }
    }
}
