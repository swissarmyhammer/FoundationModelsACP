import Foundation
import Testing

@testable import FoundationModelsACP

/// What the wire types check at decode time, what they carry through as the
/// schema states it, and the one rule v1 enforced that v2 does not state.
@Suite struct WireInvariantTests {
    @Test func relativePathDecodesAsTheSchemaSays() throws {
        // The schema types `AbsolutePath` as a bare string and states the
        // absolute-path rule in prose only. The agent owns the file system,
        // so the agent validates the path and answers invalid params. This
        // package carries the value as sent, so that check can run.
        let location = try WireRoundTrip.expectLossless(ToolCallLocation.self, """
            {"path":"src/main.swift"}
            """)
        #expect(location.path.rawValue == "src/main.swift")
    }

    @Test func anyStringIsAnAbsolutePathValue() {
        // The initializer mirrors the schema: a named string type with no
        // guard. An empty string and a relative path are values, not `nil`.
        #expect(AbsolutePath(rawValue: "").rawValue == "")
        #expect(AbsolutePath(rawValue: "src").rawValue == "src")
    }

    @Test func absolutePathDecodesAndRoundTripsAsABareString() throws {
        let location = try WireRoundTrip.expectLossless(ToolCallLocation.self, """
            {"path":"/src/main.swift","line":12}
            """)
        #expect(location.path == AbsolutePath(rawValue: "/src/main.swift"))
        #expect(location.line == 12)
    }

    @Test func aLineNumberIsOneBased() throws {
        // Since `schema-v2.0.0-alpha.10` the schema says that `line` is
        // 1-based (`minimum: 1`, "`0` is invalid"), so `LineNumber` refuses `0`.
        #expect(LineNumber(rawValue: 0) == nil)
        #expect(LineNumber(rawValue: 1)?.rawValue == 1)
    }

    @Test func aLineOfZeroDegradesToOmittedRatherThanFailingTheMessage() throws {
        // `line` is also `x-deserialize-default-on-error`: the invalid `0`
        // costs the line number, not the whole tool call.
        let location = try WireRoundTrip.decode(ToolCallLocation.self, from: """
            {"path":"/a.txt","line":0}
            """)
        #expect(location.path == AbsolutePath(rawValue: "/a.txt"))
        #expect(location.line == nil)
    }

    @Test func aTerminalExitCodeMayBeNegative() throws {
        // `exitCode` is `int64` since `schema-v2.0.0-alpha.10`: signed Windows
        // exit codes are values.
        let status = try WireRoundTrip.expectLossless(TerminalExitStatus.self, """
            {"exitCode":-1073741819}
            """)
        #expect(status.exitCode == -1_073_741_819)
    }

    @Test func aCostCurrencyMayBeAnyUnit() throws {
        let cost = try WireRoundTrip.expectLossless(Cost.self, """
            {"amount":12.5,"currency":"credits"}
            """)
        #expect(cost.currency == "credits")
    }

    @Test func toolCallLocationAcceptsAnOmittedLine() throws {
        let location = try WireRoundTrip.expectLossless(ToolCallLocation.self, """
            {"path":"/a.txt"}
            """)
        #expect(location.line == nil)
    }

    @Test func toolCallLocationAcceptsAnExplicitNullLine() throws {
        // The schema types it `["integer", "null"]`, so an explicit null is
        // well-formed and means the same as omitting it. Re-encoding drops the
        // key rather than writing null back, which is why this one asserts on
        // the encoded form directly instead of round-tripping.
        let location = try WireRoundTrip.decode(ToolCallLocation.self, from: """
            {"path":"/a.txt","line":null}
            """)
        #expect(location.line == nil)
        #expect(try WireRoundTrip.encode(location) == .object(["path": .string("/a.txt")]))
    }

    @Test func aMalformedLineDegradesRatherThanFailingTheMessage() throws {
        // `line` carries `x-deserialize-default-on-error`, so a peer sending
        // nonsense there costs the line number, not the whole tool call.
        let location = try WireRoundTrip.decode(ToolCallLocation.self, from: """
            {"path":"/a.txt","line":"twelve"}
            """)
        #expect(location.line == nil)
    }

    @Test func aMalformedPathStillFailsTheMessage() throws {
        // The inverse of the case above, and the reason it is safe: forgiving
        // decoding is opt-in per field. `path` is not annotated, so it decodes
        // strictly and a value that is not a string fails the message.
        #expect(throws: DecodingError.self) {
            try WireRoundTrip.decode(ToolCallLocation.self, from: """
                {"path":42}
                """)
        }
    }
}
