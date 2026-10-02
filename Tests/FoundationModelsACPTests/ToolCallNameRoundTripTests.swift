import Testing

@testable import FoundationModelsACP

/// The wire shape of `ToolCallUpdate.name`.
///
/// The schema gives `name` patch semantics in its prose: an omitted key means
/// "no change", `null` clears the name, and a string replaces it. These tests
/// prove that the three states stay distinct when they decode, and that each
/// state encodes back to the same document.
@Suite struct ToolCallNameRoundTripTests {
    @Test func anOmittedNameDecodesToUnchangedAndEncodesWithoutTheKey() throws {
        let update = try WireRoundTrip.expectLossless(ToolCallUpdate.self, #"{"toolCallId":"call-1"}"#)
        #expect(update.name == .unchanged)
    }

    @Test func aNullNameDecodesToClearedAndEncodesAnExplicitNull() throws {
        let update = try WireRoundTrip.expectLossless(ToolCallUpdate.self, #"{"toolCallId":"call-1","name":null}"#)
        #expect(update.name == .cleared)
    }

    @Test func aStringNameDecodesToAValueAndEncodesTheString() throws {
        let update = try WireRoundTrip.expectLossless(
            ToolCallUpdate.self,
            #"{"toolCallId":"call-1","name":"read_file"}"#
        )
        #expect(update.name == .value("read_file"))
    }

    @Test func aMalformedNameDegradesToUnchangedRatherThanFailingTheUpdate() throws {
        // `x-deserialize-default-on-error`: a bad `name` must not drop the
        // rest of the tool call update.
        let update = try WireRoundTrip.decode(ToolCallUpdate.self, from: #"{"toolCallId":"call-1","name":42}"#)
        #expect(update.name == .unchanged)
        #expect(update.toolCallId == ToolCallId(rawValue: "call-1"))
    }
}
