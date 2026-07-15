import Foundation
import FoundationModelsACP
import Testing

@testable import ACPGenerateCore

/// The package-root `Schema/acp-v1.json`, located relative to this file.
private let vendoredSchemaURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()  // UnknownFallbackTests.swift
    .deletingLastPathComponent()  // ACPGenerateTests
    .deletingLastPathComponent()  // Tests
    .appendingPathComponent("Schema")
    .appendingPathComponent("acp-v1.json")

/// Generates from the vendored schema and returns one file's contents.
///
/// - Parameter name: The generated file name to look up.
/// - Returns: The Swift source text of that file.
/// - Throws: A test failure when generation fails or the file is missing.
private func vendoredOutput(named name: String) throws -> String {
    let data = try Data(contentsOf: vendoredSchemaURL)
    let files = try SchemaGenerator().generate(schemaJSON: data)
    let file = files.first { $0.name == name }
    return try #require(file, "expected generated file \(name)").contents
}

/// Tests the string-enum generator stage and the `unknown(String)` fallback:
/// snake_case wire strings map to camelCase Swift cases, and any value a
/// newer peer sends routes to `unknown(String)` instead of failing decode.
@Suite struct UnknownFallbackEmissionTests {
    @Test func stringEnumEmitsCamelCaseCasesWithUnknownFallback() throws {
        let source = try vendoredOutput(named: "Unions.generated.swift")
        #expect(source.contains("public enum ToolKind: Codable, Hashable, Sendable"))
        #expect(source.contains("case switchMode"))
        #expect(source.contains("case unknown(String)"))
        #expect(source.contains("case \"switch_mode\": self = .switchMode"))
        #expect(source.contains("default: self = .unknown(wireValue)"))
    }

    @Test func stringEnumEncodesItsWireValue() throws {
        let source = try vendoredOutput(named: "Unions.generated.swift")
        #expect(source.contains("case .maxTurnRequests: \"max_turn_requests\""))
        #expect(source.contains("case .unknown(let value): value"))
        #expect(source.contains("try container.encode(wireValue)"))
    }

    @Test func allVendoredStringEnumsEmit() throws {
        let source = try vendoredOutput(named: "Unions.generated.swift")
        let names = [
            "ToolKind", "ToolCallStatus", "StopReason", "PermissionOptionKind",
            "PlanEntryPriority", "PlanEntryStatus", "Role",
        ]
        for name in names {
            #expect(
                source.contains("public enum \(name): Codable, Hashable, Sendable"),
                "expected string enum \(name)"
            )
        }
    }

    @Test func taggedUnionRoutesUnknownDiscriminatorToUnknownCase() throws {
        let source = try vendoredOutput(named: "Unions.generated.swift")
        #expect(source.contains("case let other:"))
        #expect(source.contains("self = .unknown(other)"))
        #expect(source.contains("case .unknown(let discriminator):"))
    }
}

/// Decodes wire JSON into a generated type.
///
/// - Parameters:
///   - type: The generated type to decode.
///   - json: The wire JSON, fragments allowed.
/// - Returns: The decoded value.
/// - Throws: Rethrows `DecodingError`.
private func decode<T: Decodable>(_ type: T.Type, from json: String) throws -> T {
    try JSONDecoder().decode(T.self, from: Data(json.utf8))
}

/// Encodes a generated value back to a wire JSON string.
///
/// - Parameter value: The value to encode.
/// - Returns: The encoded JSON text.
/// - Throws: Rethrows `EncodingError`.
private func encodeToJSON(_ value: some Encodable) throws -> String {
    String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
}

/// Runtime acceptance of the `unknown(String)` fallback against the
/// checked-in generated types: unrecognized string-enum values and union
/// discriminators decode to `.unknown` and re-encode their captured string,
/// so a newer peer can never crash decoding.
@Suite struct UnknownFallbackRoundTripTests {
    @Test func unknownToolKindRoundTripsItsWireString() throws {
        let kind = try decode(ToolKind.self, from: #""telepathy""#)
        #expect(kind == .unknown("telepathy"))
        #expect(try encodeToJSON(kind) == #""telepathy""#)
    }

    @Test func unknownStopReasonRoundTripsItsWireString() throws {
        let reason = try decode(StopReason.self, from: #""cosmic_ray""#)
        #expect(reason == .unknown("cosmic_ray"))
        #expect(try encodeToJSON(reason) == #""cosmic_ray""#)
    }

    /// Asserts every (wire string, Swift case) pair of a string enum decodes
    /// to the expected case and re-encodes the exact wire string.
    ///
    /// - Parameter pairs: The enum's complete wire↔case table.
    private func assertExhaustiveRoundTrip<T: Codable & Equatable>(_ pairs: [(wire: String, expected: T)]) throws {
        for (wire, expected) in pairs {
            let decoded = try decode(T.self, from: "\"\(wire)\"")
            #expect(decoded == expected, "\"\(wire)\" decoded to \(decoded), expected \(expected)")
            #expect(try encodeToJSON(decoded) == "\"\(wire)\"")
        }
    }

    @Test func everyToolKindValueRoundTrips() throws {
        try assertExhaustiveRoundTrip([
            ("read", ToolKind.read), ("edit", .edit), ("delete", .delete),
            ("move", .move), ("search", .search), ("execute", .execute),
            ("think", .think), ("fetch", .fetch), ("switch_mode", .switchMode),
            ("other", .other),
        ])
    }

    @Test func everyToolCallStatusValueRoundTrips() throws {
        try assertExhaustiveRoundTrip([
            ("pending", ToolCallStatus.pending), ("in_progress", .inProgress),
            ("completed", .completed), ("failed", .failed),
        ])
    }

    @Test func everyStopReasonValueRoundTrips() throws {
        try assertExhaustiveRoundTrip([
            ("end_turn", StopReason.endTurn), ("max_tokens", .maxTokens),
            ("max_turn_requests", .maxTurnRequests), ("refusal", .refusal),
            ("cancelled", .cancelled),
        ])
    }

    @Test func everyPermissionOptionKindValueRoundTrips() throws {
        try assertExhaustiveRoundTrip([
            ("allow_once", PermissionOptionKind.allowOnce), ("allow_always", .allowAlways),
            ("reject_once", .rejectOnce), ("reject_always", .rejectAlways),
        ])
    }

    @Test func everyPlanEntryPriorityValueRoundTrips() throws {
        try assertExhaustiveRoundTrip([
            ("high", PlanEntryPriority.high), ("medium", .medium), ("low", .low)
        ])
    }

    @Test func everyPlanEntryStatusValueRoundTrips() throws {
        try assertExhaustiveRoundTrip([
            ("pending", PlanEntryStatus.pending), ("in_progress", .inProgress),
            ("completed", .completed),
        ])
    }

    @Test func everyRoleValueRoundTrips() throws {
        try assertExhaustiveRoundTrip([
            ("assistant", Role.assistant), ("user", .user)
        ])
    }

    @Test func unknownStringEnumInsidePayloadRoundTrips() throws {
        // A sibling path to bare-fragment decoding: the enum sits inside a
        // generated struct inside a tagged union.
        let update = try decode(
            SessionUpdate.self,
            from: #"{"sessionUpdate":"tool_call","toolCallId":"c1","title":"t","kind":"telepathy"}"#
        )
        guard case .toolCall(let payload) = update else {
            Issue.record("expected .toolCall, got \(update)")
            return
        }
        #expect(payload.kind == .unknown("telepathy"))
        let reencoded = try encodeToJSON(update)
        #expect(reencoded.contains(#""kind":"telepathy""#))
    }

    @Test func unknownSessionUpdateDiscriminatorDecodesToUnknown() throws {
        let update = try decode(
            SessionUpdate.self,
            from: #"{"sessionUpdate":"hologram_update","payload":{"depth":3}}"#
        )
        #expect(update == .unknown("hologram_update"))
        // Re-encoding preserves the discriminator; the unrecognized
        // variant's payload fields are documented as not preserved.
        #expect(try encodeToJSON(update) == #"{"sessionUpdate":"hologram_update"}"#)
    }

    @Test func unknownContentBlockTypeRoundTrips() throws {
        let block = try decode(ContentBlock.self, from: #"{"type":"telepathy"}"#)
        #expect(block == .unknown("telepathy"))
        #expect(try encodeToJSON(block) == #"{"type":"telepathy"}"#)
    }

    @Test func missingDiscriminatorIsADecodeError() throws {
        // The fallback covers unrecognized values, not malformed envelopes:
        // an object with no discriminator at all must still fail loudly.
        #expect(throws: DecodingError.self) {
            _ = try decode(SessionUpdate.self, from: #"{"content":{"type":"text","text":"Hi"}}"#)
        }
    }
}
