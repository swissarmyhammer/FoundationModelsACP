import Foundation
import Testing

@testable import FoundationModelsACP

/// `_meta` — the reserved extension member — scoped to its parent object.
///
/// The vendored schema types every `_meta` as `["object", "null"]` with
/// `x-deserialize-default-on-error`, and its prose divides them in two.
///
/// Of the ninety `_meta` fragments the document declares, **five state that
/// omitted and `null` are equivalent and seventy-nine state nothing either
/// way** — which is what the generated `JSONValue?` expresses: both decode to
/// `nil`, and `nil` encodes by omitting the key rather than writing `null`.
/// That last part is what keeps an absent `_meta` from reading as a deliberate
/// clear on the far side. The five are `Terminal`, `CommandPermissionSubject`,
/// `TerminalOutput`, `TerminalExitStatus`, and `TerminalOutputChunk`; the last
/// of them wraps the phrase across a newline, so a substring search for it has
/// to normalize whitespace first or it reports four.
///
/// **The remaining six say the opposite.** `AgentMessage`, `AgentThought`,
/// `SessionInfoUpdate`, `TerminalUpdate`, `ToolCallUpdate`, and `UserMessage`
/// are upserts, and on those the schema says "Omitted means no metadata
/// update; `null` is an explicit clear signal" — three states, where
/// `JSONValue?` has only two. The same three-state patch rule governs their
/// other fields ("omitted fields leave the stored value unchanged, `null`
/// clears it, and concrete values replace it"), so these six `_meta`
/// properties and every other patch-semantics field on those definitions
/// generate as `PatchField<Wrapped>` — see `GeneratorConfig.patchSemanticsFields`
/// — rather than plain `Optional`. `upsertMetaDistinguishesOmittedFromNullFromAValue`
/// and `sessionInfoUpdateTitleDistinguishesOmittedFromNullFromAValue` below
/// prove the three states survive both directions; they replace this suite's
/// former `upsertMetaCannotYetDistinguishOmittedFromNull`, which pinned the gap
/// while it was still open.
@Suite struct MetaFieldTests {
    @Test func anOmittedMetaDecodesToNil() throws {
        let location = try WireRoundTrip.expectLossless(ToolCallLocation.self, """
            {"path":"/a.txt"}
            """)
        #expect(location.meta == nil)
    }

    @Test func anExplicitNullMetaDecodesToNilAndIsNotWrittenBack() throws {
        // Where the schema says omitted and `null` are equivalent, collapsing
        // them on decode is correct — and re-encoding must then omit the key,
        // not restore the `null`, or the two would stop being equivalent the
        // moment a proxy passed the message on.
        let location = try WireRoundTrip.decode(ToolCallLocation.self, from: """
            {"path":"/a.txt","_meta":null}
            """)
        #expect(location.meta == nil)
        #expect(try WireRoundTrip.encode(location) == .object(["path": .string("/a.txt")]))
    }

    @Test func aPresentMetaRoundTripsVerbatim() throws {
        // "Implementations MUST NOT make assumptions about values at these
        // keys" — so whatever is in there comes back unchanged, containers
        // and nulls included.
        let json = """
            {"path":"/a.txt","_meta":{"vendor.example/trace":{"id":"abc","spans":[1,2]},"empty":{},"cleared":null}}
            """
        let location = try WireRoundTrip.expectLossless(ToolCallLocation.self, json)
        #expect(
            location.meta
                == .object([
                    "vendor.example/trace": .object(["id": .string("abc"), "spans": .array([.number(1), .number(2)])]),
                    "empty": .object([:]),
                    "cleared": .null,
                ])
        )
    }

    @Test func aMalformedMetaDegradesRatherThanFailingTheMessage() throws {
        // `_meta` carries `x-deserialize-default-on-error` everywhere, so a
        // peer's malformed extension metadata costs the metadata, never the
        // message it rode in on.
        let location = try WireRoundTrip.decode(ToolCallLocation.self, from: """
            {"path":"/a.txt","_meta":"not an object"}
            """)
        // `JSONValue` accepts any JSON, so a string is not in fact malformed
        // for this field's Swift type — it is the schema, not the decoder,
        // that calls it an object. What matters is that the message survived.
        #expect(location.meta == .string("not an object"))
        #expect(location.path == AbsolutePath(rawValue: "/a.txt"))
    }

    @Test func metaIsScopedToItsOwnObject() throws {
        // Each `_meta` belongs to the object that declares it. A nested one
        // must not be hoisted into, or merged with, its parent's.
        let content = try WireRoundTrip.expectLossless(ToolCallContent.self, """
            {"type":"terminal","terminalId":"t1","_meta":{"scope":"inner"}}
            """)
        guard case .terminal(let terminal) = content else {
            Issue.record("expected .terminal, got \(content)")
            return
        }
        #expect(terminal.meta == .object(["scope": .string("inner")]))
    }

    @Test func upsertMetaDistinguishesOmittedFromNullFromAValue() throws {
        // The inverse of the former `upsertMetaCannotYetDistinguishOmittedFromNull`:
        // on `ToolCallUpdate`, `null` is now a distinct wire state from
        // omitted, and a client that means "clear" is no longer
        // indistinguishable from one that means "leave unchanged".
        let omitted = try WireRoundTrip.decode(ToolCallUpdate.self, from: """
            {"toolCallId":"call-1"}
            """)
        let cleared = try WireRoundTrip.decode(ToolCallUpdate.self, from: """
            {"toolCallId":"call-1","_meta":null}
            """)
        let valued = try WireRoundTrip.decode(ToolCallUpdate.self, from: """
            {"toolCallId":"call-1","_meta":{"vendor.example/trace":"abc"}}
            """)
        #expect(omitted.meta == .unchanged)
        #expect(cleared.meta == .cleared)
        #expect(valued.meta == .value(.object(["vendor.example/trace": .string("abc")])))

        // The inverse direction: three distinct wire documents come back out.
        // `null` survives as `null`, not as an omitted key — which is exactly
        // what would make an explicit clear read as "no metadata update" the
        // moment a proxy passed the message on.
        #expect(try WireRoundTrip.encode(omitted) == .object(["toolCallId": .string("call-1")]))
        #expect(
            try WireRoundTrip.encode(cleared)
                == .object(["toolCallId": .string("call-1"), "_meta": .null])
        )
        #expect(
            try WireRoundTrip.encode(valued)
                == .object([
                    "toolCallId": .string("call-1"),
                    "_meta": .object(["vendor.example/trace": .string("abc")]),
                ])
        )
    }

    @Test func sessionInfoUpdateTitleDistinguishesOmittedFromNullFromAValue() throws {
        // The same three-state rule governs a patch-semantics field beyond
        // `_meta`: `SessionInfoUpdate.title` is "Omitted fields leave the
        // existing session info unchanged. `null` clears the corresponding
        // value."
        let omitted = try WireRoundTrip.decode(SessionInfoUpdate.self, from: "{}")
        let cleared = try WireRoundTrip.decode(SessionInfoUpdate.self, from: #"{"title":null}"#)
        let valued = try WireRoundTrip.decode(SessionInfoUpdate.self, from: #"{"title":"New Session"}"#)
        #expect(omitted.title == .unchanged)
        #expect(cleared.title == .cleared)
        #expect(valued.title == .value("New Session"))

        #expect(try WireRoundTrip.encode(omitted) == .object([:]))
        #expect(try WireRoundTrip.encode(cleared) == .object(["title": .null]))
        #expect(try WireRoundTrip.encode(valued) == .object(["title": .string("New Session")]))
    }

    @Test func nonPatchNullableFieldStillCollapsesOmittedAndNullAndStillOmitsOnEncode() throws {
        // The other half of the acceptance criteria: patch semantics must not
        // become the default for every nullable field. `ToolCallLocation.line`
        // is nullable and carries no patch-semantics prose, so it keeps the
        // plain `Optional` collapse this suite's other tests already pin for
        // `_meta` — restated here for a non-`_meta` field.
        let omitted = try WireRoundTrip.decode(ToolCallLocation.self, from: """
            {"path":"/a.txt"}
            """)
        let cleared = try WireRoundTrip.decode(ToolCallLocation.self, from: """
            {"path":"/a.txt","line":null}
            """)
        #expect(omitted.line == nil)
        #expect(cleared.line == nil)
        #expect(try WireRoundTrip.encode(omitted) == WireRoundTrip.encode(cleared))
        #expect(try WireRoundTrip.encode(omitted) == .object(["path": .string("/a.txt")]))
    }
}
