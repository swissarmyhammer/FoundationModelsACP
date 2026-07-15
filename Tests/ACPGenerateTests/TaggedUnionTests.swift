import Foundation
import FoundationModelsACP
import Testing

@testable import ACPGenerateCore

/// Reduces JSON bytes to a canonical sorted-keys form so byte comparisons
/// ignore key order (and nothing else).
///
/// - Parameter data: The JSON bytes to canonicalize.
/// - Returns: The same JSON re-serialized with sorted keys.
/// - Throws: Rethrows `JSONSerialization` failures.
private func canonicalized(_ data: Data) throws -> Data {
    let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .fragmentsAllowed])
}

/// Decodes a fixture, re-encodes it, and asserts byte-equivalence modulo
/// key order plus decode-back equality.
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

/// Round-trips every discriminator variant of the generated tagged unions
/// against wire fixtures: decode picks the right case, and re-encoding is
/// byte-equivalent modulo key order.
@Suite struct TaggedUnionRoundTripTests {
    @Test(arguments: [
        #"{"type":"text","text":"Hello"}"#,
        #"{"type":"image","data":"aGk=","mimeType":"image/png"}"#,
        #"{"type":"audio","data":"aGk=","mimeType":"audio/wav"}"#,
        #"{"type":"resource_link","name":"main.swift","uri":"file:///main.swift"}"#,
        #"{"type":"resource","resource":{"uri":"file:///main.swift","text":"let x = 1"}}"#,
    ])
    func contentBlockVariantsRoundTrip(fixture: String) throws {
        try assertRoundTrips(ContentBlock.self, fixture: fixture)
    }

    @Test func contentBlockDecodesToTheMatchingCase() throws {
        let block = try assertRoundTrips(ContentBlock.self, fixture: #"{"type":"text","text":"Hello"}"#)
        guard case .text(let payload) = block else {
            Issue.record("expected .text, got \(block)")
            return
        }
        #expect(payload.text == "Hello")
    }

    @Test(arguments: [
        #"{"sessionUpdate":"user_message_chunk","content":{"type":"text","text":"Hi"}}"#,
        #"{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Hi"}}"#,
        #"{"sessionUpdate":"agent_thought_chunk","content":{"type":"text","text":"Hmm"}}"#,
        #"{"sessionUpdate":"tool_call","toolCallId":"call-1","title":"Read file","kind":"read","status":"pending"}"#,
        #"{"sessionUpdate":"tool_call_update","toolCallId":"call-1","status":"in_progress"}"#,
        #"{"sessionUpdate":"plan","entries":[{"content":"Ship it","priority":"high","status":"pending"}]}"#,
        #"{"sessionUpdate":"available_commands_update","availableCommands":[]}"#,
        #"{"sessionUpdate":"current_mode_update","currentModeId":"architect"}"#,
        #"{"sessionUpdate":"config_option_update","configOptions":[]}"#,
        #"{"sessionUpdate":"session_info_update","title":"Chat"}"#,
        #"{"sessionUpdate":"usage_update","used":1000,"size":200000}"#,
    ])
    func sessionUpdateVariantsRoundTrip(fixture: String) throws {
        try assertRoundTrips(SessionUpdate.self, fixture: fixture)
    }

    @Test func sessionUpdatePayloadFieldsDecodeTyped() throws {
        let update = try assertRoundTrips(
            SessionUpdate.self,
            fixture: #"{"sessionUpdate":"tool_call","toolCallId":"call-1","title":"Read file","kind":"read","status":"pending"}"#
        )
        guard case .toolCall(let payload) = update else {
            Issue.record("expected .toolCall, got \(update)")
            return
        }
        #expect(payload.toolCallId == ToolCallId(rawValue: "call-1"))
        #expect(payload.kind == .read)
        #expect(payload.status == .pending)
    }

    @Test(arguments: [
        #"{"type":"content","content":{"type":"text","text":"done"}}"#,
        #"{"type":"diff","path":"/a.txt","newText":"b"}"#,
        #"{"type":"terminal","terminalId":"term-1"}"#,
    ])
    func toolCallContentVariantsRoundTrip(fixture: String) throws {
        try assertRoundTrips(ToolCallContent.self, fixture: fixture)
    }

    @Test(arguments: [
        #"{"outcome":"cancelled"}"#,
        #"{"outcome":"selected","optionId":"allow"}"#,
    ])
    func requestPermissionOutcomeVariantsRoundTrip(fixture: String) throws {
        try assertRoundTrips(RequestPermissionOutcome.self, fixture: fixture)
    }

    @Test func payloadFreeCancelledDecodesToBareCase() throws {
        let outcome = try assertRoundTrips(RequestPermissionOutcome.self, fixture: #"{"outcome":"cancelled"}"#)
        #expect(outcome == .cancelled)
    }

    @Test(arguments: [
        #"{"type":"select","currentValue":"fast","options":[]}"#,
        #"{"type":"boolean","currentValue":true}"#,
    ])
    func sessionConfigOptionVariantsRoundTrip(fixture: String) throws {
        try assertRoundTrips(SessionConfigOption.self, fixture: fixture)
    }
}

/// Tests the tagged-union generator stage: `oneOf` definitions whose object
/// variants carry a const discriminator emit Swift enums with associated
/// values and hand-rolled `Codable` keyed on that discriminator.
@Suite struct TaggedUnionEmissionTests {
    @Test func contentBlockEmitsEnumWithAssociatedValues() throws {
        let source = try vendoredOutput(named: "Unions.generated.swift")
        #expect(source.contains("public enum ContentBlock: Codable, Hashable, Sendable"))
        #expect(source.contains("case text(TextContent)"))
        #expect(source.contains("case resourceLink(ResourceLink)"))
        #expect(source.contains("self = .text(try TextContent(from: decoder))"))
    }

    @Test func sessionUpdateDecodesOnSessionUpdateDiscriminator() throws {
        let source = try vendoredOutput(named: "Unions.generated.swift")
        #expect(source.contains("public enum SessionUpdate: Codable, Hashable, Sendable"))
        #expect(source.contains("case userMessageChunk(ContentChunk)"))
        #expect(source.contains("case usageUpdate(UsageUpdate)"))
        #expect(source.contains("case currentModeUpdate(CurrentModeUpdate)"))
        #expect(source.contains("forKey: .sessionUpdate"))
    }

    @Test func payloadFreeVariantEmitsBareCase() throws {
        let source = try vendoredOutput(named: "Unions.generated.swift")
        // RequestPermissionOutcome's discriminator is `outcome`; its
        // `cancelled` variant carries no payload struct.
        #expect(source.contains("case cancelled\n"))
        #expect(source.contains("case selected(SelectedPermissionOutcome)"))
        #expect(source.contains("try container.encode(\"cancelled\", forKey: .outcome)"))
    }

    @Test func payloadEncodesFlattenedAlongsideDiscriminator() throws {
        let source = try vendoredOutput(named: "Unions.generated.swift")
        // The payload's fields sit at the same JSON level as the
        // discriminator (serde's internally-tagged representation).
        #expect(source.contains("try container.encode(\"diff\", forKey: .type)"))
        #expect(source.contains("try payload.encode(to: encoder)"))
    }

    @Test func resolvedOneOfSeamsLeaveUnresolvedToAnyOfOnly() throws {
        let source = try vendoredOutput(named: "Unresolved.generated.swift")
        #expect(!source.contains("typealias ContentBlock"))
        #expect(!source.contains("typealias SessionUpdate"))
        #expect(!source.contains("typealias ToolKind"))
        // `anyOf` unions stay deferred as placeholder seams for a later stage.
        #expect(source.contains("public typealias McpServer = JSONValue"))
        #expect(source.contains("public typealias RequestID = JSONValue"))
    }

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
