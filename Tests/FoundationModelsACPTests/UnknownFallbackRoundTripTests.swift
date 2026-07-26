import Foundation
import Testing

@testable import FoundationModelsACP

/// Runtime proof that unrecognized wire values survive a decode/encode round
/// trip intact.
///
/// ACP v2 states the rule the generated fallbacks exist to keep: values a peer
/// does not recognize are accepted and preserved, so a newer peer can talk to
/// an older one — or be proxied by one — without data loss. `_`-prefixed values
/// are implementation-specific extensions; unprefixed unknown values are
/// reserved for future revisions. Both take the same path.
///
/// The generator-side suites pin the *shape* these fallbacks emit. This suite
/// runs them: it is the difference between preservation asserted and
/// preservation real, and every case here would have passed against a fallback
/// that captured the tag and dropped the payload beside it.
@Suite struct UnknownFallbackRoundTripTests {
    @Test func unrecognizedStringEnumValueKeepsItsSpelling() throws {
        // A string enum has nothing beside the value to preserve, so the whole
        // claim is that the spelling comes back unchanged rather than
        // normalizing or failing the message.
        let stopReason = try WireRoundTrip.decode(StopReason.self, from: "\"_vendor_interrupted\"")
        #expect(stopReason == .unknown("_vendor_interrupted"))
        #expect(try WireRoundTrip.encode(stopReason) == .string("_vendor_interrupted"))
    }

    @Test func unrecognizedTaggedUnionVariantKeepsEveryMember() throws {
        // `AuthMethod`'s catch-all requires `methodId` and `name` beside the
        // unrecognized tag, and v2 tells clients to "preserve the raw payload
        // when storing, replaying, proxying, or forwarding initialization
        // data". A fallback holding the tag alone drops all three of the
        // members below.
        let json = """
            {"type":"_vendor_sso","methodId":"sso","name":"Single sign-on","_meta":{"issuer":"acme"}}
            """
        let method = try WireRoundTrip.expectLossless(AuthMethod.self, json)
        guard case .unknown(let tag, let payload) = method else {
            Issue.record("expected the unknown fallback, got \(method)")
            return
        }
        #expect(tag == "_vendor_sso")
        // The tag lives on the case, not in the captured payload, so there is
        // exactly one copy of it and re-encoding cannot disagree with itself.
        #expect(payload == .object([
            "methodId": .string("sso"),
            "name": .string("Single sign-on"),
            "_meta": .object(["issuer": .string("acme")]),
        ]))
    }

    @Test func unrecognizedPlanUpdateContentKeepsItsPlanId() throws {
        // `PlanUpdateContent` is required on every `plan_update`, so an
        // unrecognized content type that lost `planId` would leave the receiver
        // unable to say which plan the update was even about.
        let json = """
            {"type":"_vendor_outline","planId":"plan-7"}
            """
        let content = try WireRoundTrip.expectLossless(PlanUpdateContent.self, json)
        #expect(content == .unknown("_vendor_outline", .object(["planId": .string("plan-7")])))
    }

    @Test func unrecognizedReplayCursorKeepsItsMeta() throws {
        let json = """
            {"type":"_vendor_checkpoint","_meta":{"cursor":42}}
            """
        let cursor = try WireRoundTrip.expectLossless(ReplayFrom.self, json)
        #expect(cursor == .unknown("_vendor_checkpoint", .object(["_meta": .object(["cursor": .number(42)])])))
    }

    @Test func unrecognizedConfigOptionValueKeepsBothTagAndValue() throws {
        // The inverse shape: `session/set_config_option` carries its value
        // union on the request object itself, so the catch-all re-declares the
        // discriminator beside `value`. Losing either member makes the request
        // unroutable — and this is the one routed stable method whose entire
        // params object was raw JSON until the default case could carry a tag.
        let json = """
            {"sessionId":"sess-1","configId":"cfg-1","type":"_vendor_slider","value":42}
            """
        let request = try WireRoundTrip.expectLossless(SetSessionConfigOptionRequest.self, json)
        #expect(request.sessionId == SessionId(rawValue: "sess-1"))
        #expect(request.configId == SessionConfigId(rawValue: "cfg-1"))
        #expect(request.value == .other("_vendor_slider", .number(42)))
    }

    @Test func unrecognizedConfigOptionValueKeepsAContainerPayload() throws {
        // The catch-all's `value` places no shape constraints at all, so the
        // payload can be any JSON — a scalar is the easy case, and a nested
        // container is where a hand-rolled `Codable` tends to flatten or
        // stringify.
        let json = """
            {"sessionId":"s","configId":"c","type":"_vendor_matrix","value":{"rows":[1,2],"label":null}}
            """
        let request = try WireRoundTrip.expectLossless(SetSessionConfigOptionRequest.self, json)
        #expect(
            request.value
                == .other(
                    "_vendor_matrix",
                    .object(["rows": .array([.number(1), .number(2)]), "label": .null])
                )
        )
    }

    @Test func unprefixedUnknownTagTakesTheSamePath() throws {
        // v2 reserves unprefixed unknown values for future protocol revisions
        // rather than for vendors, but the receiving rule is identical: accept
        // and preserve. A fallback that only tolerated `_`-prefixed values
        // would reject exactly the payloads a *newer ACP* sends.
        let json = """
            {"type":"oauth2","methodId":"oauth","name":"OAuth"}
            """
        let method = try WireRoundTrip.expectLossless(AuthMethod.self, json)
        #expect(method == .unknown("oauth2", .object(["methodId": .string("oauth"), "name": .string("OAuth")])))
    }

    @Test func recognizedVariantsStillTakeTheirOwnCase() throws {
        // The fallback must not swallow tags the schema does list — the failure
        // mode where "nothing fails to decode" hides a union that decodes
        // everything to `.unknown`.
        let method = try WireRoundTrip.expectLossless(AuthMethod.self, """
            {"type":"agent","methodId":"builtin","name":"Built in"}
            """)
        guard case .agent(let payload) = method else {
            Issue.record("expected the modeled agent variant, got \(method)")
            return
        }
        #expect(payload.methodId == AuthMethodId(rawValue: "builtin"))
    }

    @Test func recognizedConfigOptionValuesStillTakeTheirOwnCase() throws {
        let boolean = try WireRoundTrip.expectLossless(SetSessionConfigOptionRequest.self, """
            {"sessionId":"s","configId":"c","type":"boolean","value":true}
            """)
        #expect(boolean.value == .boolean(true))
        let id = try WireRoundTrip.expectLossless(SetSessionConfigOptionRequest.self, """
            {"sessionId":"s","configId":"c","type":"id","value":"fast"}
            """)
        #expect(id.value == .id(SessionConfigValueId(rawValue: "fast")))
    }

    @Test func aFallbackPayloadThatIsNotAnObjectFailsLoudly() throws {
        // The captured payload is the rest of the variant's object, so nothing
        // decoded can be a scalar. A hand-built value can, and flattening one
        // into the enclosing object is not defined — so it is an encoding
        // error rather than a silently dropped member.
        #expect(throws: EncodingError.self) {
            _ = try JSONEncoder().encode(AuthMethod.unknown("_vendor_x", .string("not an object")))
        }
    }
}
