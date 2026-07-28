import Foundation
import Testing

@testable import FoundationModelsACP

/// `PatchField` — the three-state wrapper behind ACP v2's patch-semantics
/// fields (schema prose, e.g. `ToolCallUpdate`: "omitted fields leave the
/// existing tool call value unchanged, `null` clears or unsets the value,
/// and concrete values replace the previous value").
///
/// A plain `Optional` cannot express this: `decodeIfPresent` collapses
/// "absent" and "null" to the same `nil`, and `encodeIfPresent(nil)` always
/// omits the key. These tests exercise the container helpers directly on a
/// hand-written probe, the same way `ForgivingDecodingTests` tests the
/// forgiving-decode helpers, so a failure names the helper rather than
/// whichever generated type happened to use it.
@Suite struct PatchFieldTests {
    /// A container-shaped probe: one field per decode strategy a generated
    /// type actually uses (strict, forgiving scalar, forgiving array).
    private struct Probe: Codable, Equatable {
        var strict: PatchField<Int>
        var forgiving: PatchField<Int>
        var items: PatchField<[Int]>

        private enum CodingKeys: String, CodingKey {
            case strict, forgiving, items
        }

        init(
            strict: PatchField<Int> = .unchanged,
            forgiving: PatchField<Int> = .unchanged,
            items: PatchField<[Int]> = .unchanged
        ) {
            self.strict = strict
            self.forgiving = forgiving
            self.items = items
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            strict = try container.decodePatchField(Int.self, forKey: .strict)
            forgiving = container.forgivingDecodePatchField(Int.self, forKey: .forgiving)
            items = container.forgivingDecodePatchArray(of: Int.self, forKey: .items)
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encodePatch(strict, forKey: .strict)
            try container.encodePatch(forgiving, forKey: .forgiving)
            try container.encodePatch(items, forKey: .items)
        }
    }

    // MARK: - Decode: three distinct states

    @Test func anOmittedFieldDecodesToUnchanged() throws {
        let probe = try WireRoundTrip.decode(Probe.self, from: "{}")
        #expect(probe.strict == .unchanged)
        #expect(probe.forgiving == .unchanged)
        #expect(probe.items == .unchanged)
    }

    @Test func anExplicitNullDecodesToCleared() throws {
        let probe = try WireRoundTrip.decode(
            Probe.self,
            from: #"{"strict":null,"forgiving":null,"items":null}"#
        )
        #expect(probe.strict == .cleared)
        #expect(probe.forgiving == .cleared)
        #expect(probe.items == .cleared)
    }

    @Test func aConcreteValueDecodesToValue() throws {
        let probe = try WireRoundTrip.decode(
            Probe.self,
            from: #"{"strict":1,"forgiving":2,"items":[3,4]}"#
        )
        #expect(probe.strict == .value(1))
        #expect(probe.forgiving == .value(2))
        #expect(probe.items == .value([3, 4]))
    }

    // MARK: - Encode: the inverse

    @Test func unchangedOmitsTheKeyOnEncode() throws {
        let encoded = try WireRoundTrip.encode(Probe())
        #expect(encoded == .object([:]))
    }

    @Test func clearedEncodesAnExplicitNull() throws {
        let encoded = try WireRoundTrip.encode(Probe(strict: .cleared, forgiving: .cleared, items: .cleared))
        #expect(encoded == .object(["strict": .null, "forgiving": .null, "items": .null]))
    }

    @Test func valueEncodesTheWrappedValue() throws {
        let encoded = try WireRoundTrip.encode(Probe(strict: .value(1), forgiving: .value(2), items: .value([3, 4])))
        #expect(
            encoded
                == .object([
                    "strict": .number(1),
                    "forgiving": .number(2),
                    "items": .array([.number(3), .number(4)]),
                ])
        )
    }

    // MARK: - Round trip: null survives as null, not omitted

    @Test func allThreeStatesRoundTripAsDistinctDocuments() throws {
        try WireRoundTrip.expectLossless(Probe.self, "{}")
        try WireRoundTrip.expectLossless(Probe.self, #"{"strict":null}"#)
        try WireRoundTrip.expectLossless(Probe.self, #"{"strict":1}"#)
    }

    // MARK: - Strict decode fails loudly

    @Test func strictPatchFieldThrowsOnAMalformedPresentValue() throws {
        #expect(throws: DecodingError.self) {
            _ = try WireRoundTrip.decode(Probe.self, from: #"{"strict":"nope"}"#)
        }
    }

    // MARK: - Forgiving decode degrades instead of failing the message

    @Test func forgivingPatchFieldDegradesAMalformedValueToUnchanged() throws {
        let probe = try WireRoundTrip.decode(Probe.self, from: #"{"forgiving":"nope"}"#)
        #expect(probe.forgiving == .unchanged)
    }

    @Test func forgivingPatchArraySkipsInvalidElementsButKeepsTheValueState() throws {
        let probe = try WireRoundTrip.decode(Probe.self, from: #"{"items":[1,"two",3]}"#)
        #expect(probe.items == .value([1, 3]))
    }

    @Test func forgivingPatchArrayDegradesAnEntirelyMalformedValueToUnchanged() throws {
        let probe = try WireRoundTrip.decode(Probe.self, from: #"{"items":"not an array"}"#)
        #expect(probe.items == .unchanged)
    }
}
