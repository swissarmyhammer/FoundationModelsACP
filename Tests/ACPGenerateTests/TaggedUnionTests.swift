import Foundation
import Testing

@testable import ACPGenerateCore

/// Reduces JSON bytes to a canonical sorted-keys form.
///
/// Byte comparisons of canonicalized JSON ignore key order and nothing else.
///
/// - Parameter data: The JSON bytes to canonicalize.
/// - Returns: The same JSON re-serialized with sorted keys.
/// - Throws: Rethrows `JSONSerialization` failures.
private func canonicalized(_ data: Data) throws -> Data {
    let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .fragmentsAllowed])
}

/// Decodes a fixture and asserts it re-encodes byte-equivalent.
///
/// Byte-equivalence is modulo key order; the re-encoded bytes must also
/// decode back equal to the first decode.
///
/// - Parameters:
///   - type: The generated type to round-trip.
///   - fixture: The wire JSON.
/// - Returns: The decoded value for further case assertions.
/// - Throws: Rethrows decoding/encoding failures as test failures.
@discardableResult
private func assertRoundTrips<T: Codable & Equatable>(_ type: T.Type, fixture: String) throws -> T {
    let data = Data(fixture.utf8)
    let decoded = try JSONDecoder().decode(T.self, from: data)
    let reencoded = try JSONEncoder().encode(decoded)
    #expect(try canonicalized(reencoded) == canonicalized(data), "re-encoding \(fixture) changed the wire form")
    let decodedAgain = try JSONDecoder().decode(T.self, from: reencoded)
    #expect(decodedAgain == decoded)
    return decoded
}

/// on that discriminator.
@Suite struct TaggedUnionEmissionTests {
    @Test func oneOfMixingStringAndObjectVariantsFailsLoudly() throws {
        let schema = Data(
            """
            {
              "$defs": {
                "Mixed": {
                  "oneOf": [
                    { "type": "string", "const": "plain" },
                    {
                      "type": "object",
                      "properties": { "type": { "type": "string", "const": "fancy" } },
                      "required": ["type"]
                    }
                  ]
                }
              }
            }
            """.utf8)
        #expect(throws: GeneratorError.self) {
            _ = try SchemaGenerator().generate(schemaJSON: schema)
        }
    }

    @Test func variantsWithDifferingDiscriminatorKeysFailLoudly() throws {
        let schema = Data(
            """
            {
              "$defs": {
                "Torn": {
                  "oneOf": [
                    {
                      "type": "object",
                      "properties": { "type": { "type": "string", "const": "a" } },
                      "required": ["type"]
                    },
                    {
                      "type": "object",
                      "properties": { "kind": { "type": "string", "const": "b" } },
                      "required": ["kind"]
                    }
                  ]
                }
              }
            }
            """.utf8)
        #expect(throws: GeneratorError.self) {
            _ = try SchemaGenerator().generate(schemaJSON: schema)
        }
    }

    @Test func quoteBearingTagEscapesInEmittedSource() throws {
        // `swiftCaseName` rejects such tags at the generator boundary, but
        // the emitter must be safe on its own terms: a quote or backslash
        // in a tag may never break out of the generated string literal.
        let model = TaggedUnionModel(
            name: "Weird",
            documentation: nil,
            discriminator: "type",
            cases: [
                UnionCaseModel(tag: #"a"b\c"#, swiftName: "aBC", payloadType: nil, documentation: nil)
            ]
        )
        let source = Emitter.taggedUnionDeclaration(model)
        #expect(source.contains(#"case "a\"b\\c":"#))
        #expect(source.contains(#"try container.encode("a\"b\\c", forKey: .type)"#))
        #expect(!source.contains(#"case "a"b\c":"#))
    }

    @Test func swiftKeywordWireValueFailsLoudly() throws {
        // `case default` would not compile; the generator must throw at
        // generation time instead of emitting a broken file.
        let schema = Data(
            """
            {
              "$defs": {
                "Keyworded": {
                  "oneOf": [
                    { "type": "string", "const": "default" }
                  ]
                }
              }
            }
            """.utf8)
        #expect(throws: GeneratorError.self) {
            _ = try SchemaGenerator().generate(schemaJSON: schema)
        }
    }

    @Test func variantWithPropertiesBeyondDiscriminatorFailsLoudly() throws {
        // Inline payload fields beyond the discriminator are a shape this
        // stage does not model; emitting an enum would silently drop them.
        let schema = Data(
            """
            {
              "$defs": {
                "Fat": {
                  "oneOf": [
                    {
                      "type": "object",
                      "properties": {
                        "type": { "type": "string", "const": "a" },
                        "extra": { "type": "string" }
                      },
                      "required": ["type"]
                    }
                  ]
                }
              }
            }
            """.utf8)
        #expect(throws: GeneratorError.self) {
            _ = try SchemaGenerator().generate(schemaJSON: schema)
        }
    }
}
