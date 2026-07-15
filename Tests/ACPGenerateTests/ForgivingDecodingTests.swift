import Foundation
import Testing

@testable import FoundationModelsACP

/// A compile-time fixture mirroring the generator's output for a capability
/// object: a defaulted forgiving scalar plus a forgiving optional `_meta`,
/// with nil-omitting encoding.
private struct CapabilityFixture: Codable, Hashable {
    var readTextFile: Bool
    var meta: JSONValue?

    init(readTextFile: Bool = false, meta: JSONValue? = nil) {
        self.readTextFile = readTextFile
        self.meta = meta
    }

    private enum CodingKeys: String, CodingKey {
        case readTextFile
        case meta = "_meta"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.readTextFile = container.forgivingDecode(Bool.self, forKey: .readTextFile, default: false)
        self.meta = container.forgivingDecodeIfPresent(JSONValue.self, forKey: .meta)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(readTextFile, forKey: .readTextFile)
        try container.encodeIfPresent(meta, forKey: .meta)
    }
}

/// A compile-time fixture mirroring the generator's output for lossy arrays:
/// a defaulted skip-invalid-items array plus an optional one, and a forgiving
/// optional scalar.
private struct ListFixture: Codable, Hashable {
    var names: [String]
    var extras: [String]?
    var limit: Int?

    init(names: [String] = [], extras: [String]? = nil, limit: Int? = nil) {
        self.names = names
        self.extras = extras
        self.limit = limit
    }

    private enum CodingKeys: String, CodingKey {
        case names
        case extras
        case limit
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.names = container.forgivingDecodeArray(of: String.self, forKey: .names)
        self.extras = container.forgivingDecodeArrayIfPresent(of: String.self, forKey: .extras)
        self.limit = container.forgivingDecodeIfPresent(Int.self, forKey: .limit)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(names, forKey: .names)
        try container.encodeIfPresent(extras, forKey: .extras)
        try container.encodeIfPresent(limit, forKey: .limit)
    }
}

/// Decodes a fixture or generated value from a JSON string — shared by both
/// suites in this file.
///
/// - Parameters:
///   - type: The type to decode.
///   - from: The JSON document text.
/// - Returns: The decoded value.
/// - Throws: Any decoding error, which most tests expect not to happen.
private func decode<T: Decodable>(_ type: T.Type, from json: String) throws -> T {
    try JSONDecoder().decode(T.self, from: Data(json.utf8))
}

/// Tests the forgiving-decoding runtime helpers through compile-time fixture
/// types shaped like generator output: defaults-on-error, skip-invalid-items,
/// and nil-omitting encoding.
@Suite struct ForgivingDecodingTests {
    /// Encodes a value to a JSON object dictionary for key-presence checks.
    ///
    /// - Parameter value: The value to encode.
    /// - Returns: The encoded JSON as a dictionary.
    /// - Throws: Any encoding or JSON parsing error.
    private func encodeToObject<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        let object = try JSONSerialization.jsonObject(with: data)
        return try #require(object as? [String: Any])
    }

    // MARK: - Defaults on error

    @Test func validCapabilityFieldDecodes() throws {
        let value = try decode(CapabilityFixture.self, from: #"{"readTextFile": true}"#)
        #expect(value.readTextFile == true)
    }

    @Test func malformedCapabilityFieldFallsBackToDefault() throws {
        let value = try decode(CapabilityFixture.self, from: #"{"readTextFile": "yes"}"#)
        #expect(value.readTextFile == false)
    }

    @Test func absentCapabilityFieldUsesDefault() throws {
        let value = try decode(CapabilityFixture.self, from: "{}")
        #expect(value.readTextFile == false)
    }

    @Test func nullCapabilityFieldUsesDefault() throws {
        let value = try decode(CapabilityFixture.self, from: #"{"readTextFile": null}"#)
        #expect(value.readTextFile == false)
    }

    @Test func validOptionalScalarDecodes() throws {
        let value = try decode(ListFixture.self, from: #"{"limit": 7}"#)
        #expect(value.limit == 7)
    }

    @Test func malformedOptionalScalarFallsBackToNil() throws {
        let value = try decode(ListFixture.self, from: #"{"limit": "many"}"#)
        #expect(value.limit == nil)
    }

    // MARK: - Skip invalid items

    @Test func validArrayItemsAllDecode() throws {
        let value = try decode(ListFixture.self, from: #"{"names": ["a", "b"]}"#)
        #expect(value.names == ["a", "b"])
    }

    @Test func invalidArrayItemsAreSkipped() throws {
        let value = try decode(ListFixture.self, from: #"{"names": [1, "a", true, "b"]}"#)
        #expect(value.names == ["a", "b"])
    }

    @Test func malformedArrayFallsBackToEmpty() throws {
        let value = try decode(ListFixture.self, from: #"{"names": "nope"}"#)
        #expect(value.names == [])
    }

    @Test func absentArrayFallsBackToEmpty() throws {
        let value = try decode(ListFixture.self, from: "{}")
        #expect(value.names == [])
    }

    @Test func optionalArrayDecodesValidItems() throws {
        let value = try decode(ListFixture.self, from: #"{"extras": ["x", 2, "y"]}"#)
        #expect(value.extras == ["x", "y"])
    }

    @Test func absentOptionalArrayDecodesToNil() throws {
        let value = try decode(ListFixture.self, from: "{}")
        #expect(value.extras == nil)
    }

    @Test func malformedOptionalArrayDecodesToNil() throws {
        let value = try decode(ListFixture.self, from: #"{"extras": 42}"#)
        #expect(value.extras == nil)
    }

    // MARK: - Nil omission on encode

    @Test func encodeOmitsNilOptionalFields() throws {
        let original = CapabilityFixture(readTextFile: true)
        let object = try encodeToObject(original)
        #expect(object.keys.sorted() == ["readTextFile"])
        // Round-trip: the omitted key decodes back to nil.
        let decoded = try JSONDecoder().decode(CapabilityFixture.self, from: JSONEncoder().encode(original))
        #expect(decoded == original)
        #expect(decoded.meta == nil)
    }

    @Test func encodeIncludesPresentOptionalFields() throws {
        let original = CapabilityFixture(readTextFile: false, meta: .object(["k": .string("v")]))
        let object = try encodeToObject(original)
        #expect(object.keys.sorted() == ["_meta", "readTextFile"])
        // Round-trip: the present optional survives encode → decode intact.
        let decoded = try JSONDecoder().decode(CapabilityFixture.self, from: JSONEncoder().encode(original))
        #expect(decoded == original)
        #expect(decoded.meta == .object(["k": .string("v")]))
    }

    @Test func forgivingRoundTripPreservesValidData() throws {
        let original = ListFixture(names: ["a"], extras: ["x"], limit: 3)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ListFixture.self, from: data)
        #expect(decoded == original)
    }
}

/// Acceptance tests against the checked-in generated types: a malformed
/// capability field degrades to defaults instead of failing the `initialize`
/// handshake, wire-invariant fields stay strict, and encoding omits nil.
@Suite struct GeneratedTypeAcceptanceTests {
    @Test func malformedCapabilityFieldsDecodeToDefaults() throws {
        let response = try decode(
            InitializeResponse.self,
            from: #"{"protocolVersion": 1, "agentCapabilities": {"loadSession": "yes", "promptCapabilities": 42}}"#
        )
        #expect(response.agentCapabilities.loadSession == false)
        #expect(response.agentCapabilities.promptCapabilities == PromptCapabilities())
    }

    @Test func garbageCapabilitiesObjectDoesNotFailHandshake() throws {
        let response = try decode(
            InitializeResponse.self,
            from: #"{"protocolVersion": 1, "agentCapabilities": "garbage", "authMethods": "nope"}"#
        )
        #expect(response.agentCapabilities == AgentCapabilities())
        #expect(response.authMethods == [])
    }

    @Test func relativeCwdIsADecodeError() throws {
        #expect(throws: DecodingError.self) {
            _ = try decode(NewSessionRequest.self, from: #"{"cwd": "relative/path", "mcpServers": []}"#)
        }
    }

    @Test func absoluteCwdDecodes() throws {
        let request = try decode(NewSessionRequest.self, from: #"{"cwd": "/workspace", "mcpServers": []}"#)
        #expect(request.cwd.rawValue == "/workspace")
    }

    @Test func zeroLineIsADecodeError() throws {
        #expect(throws: DecodingError.self) {
            _ = try decode(ToolCallLocation.self, from: #"{"path": "/a.txt", "line": 0}"#)
        }
    }

    @Test func oneBasedLineDecodes() throws {
        let location = try decode(ToolCallLocation.self, from: #"{"path": "/a.txt", "line": 3}"#)
        #expect(location.line == LineNumber(rawValue: 3))
    }

    @Test func generatedEncodeOmitsAbsentOptionalFields() throws {
        let request = NewSessionRequest(
            cwd: try #require(AbsolutePath(rawValue: "/workspace")),
            mcpServers: []
        )
        let data = try JSONEncoder().encode(request)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object.keys.sorted() == ["cwd", "mcpServers"])
    }
}
