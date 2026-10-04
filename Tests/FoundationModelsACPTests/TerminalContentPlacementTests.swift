import Foundation
import Testing

@testable import FoundationModelsACP

/// `Terminal` is a display-only reference variant of `ToolCallContent`, not
/// of `ContentBlock`. `ContentBlock` is `text` / `image` / `audio` /
/// `resource_link` / `resource`, and it has no `terminal` case.
///
/// These tests show that placement: a `terminal` payload decodes to the
/// known `.terminal` case as `ToolCallContent`, but it decodes to the
/// generated `.unknown` fallback as a `ContentBlock`.
@Suite struct TerminalContentPlacementTests {
    /// The terminal identifier in the payload.
    private static let terminalId = "term-1"

    /// A `terminal` payload on the wire.
    private static let terminalPayload = """
        {"type":"terminal","terminalId":"\(terminalId)"}
        """

    @Test func terminalToolCallContentRoundTrips() throws {
        let content = try WireRoundTrip.expectLossless(ToolCallContent.self, Self.terminalPayload)
        #expect(content == .terminal(Terminal(terminalId: TerminalId(rawValue: Self.terminalId))))
    }

    @Test func aTerminalPayloadOfferedAsAContentBlockDoesNotDecodeAsAKnownVariant() throws {
        let block = try WireRoundTrip.expectLossless(ContentBlock.self, Self.terminalPayload)
        #expect(block == .unknown("terminal", .object(["terminalId": .string(Self.terminalId)])))
    }
}
