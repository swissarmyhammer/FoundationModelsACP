import Foundation
import Testing

@testable import FoundationModelsACP

/// A valid version-00 `traceparent`. It is the example value of the W3C Trace
/// Context specification.
private let validTraceparent = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"

/// A `tracestate` value. The codec does not parse it.
private let sampleTracestate = "rojo=00f067aa0ba902b7,congo=t61rcWkgMzE"

/// Tests for `TraceContextMeta`, the codec for the W3C `traceparent` and
/// `tracestate` members of an ACP `_meta` object.
@Suite struct TraceContextMetaTests {
    // MARK: - traceparent validation

    @Test func aValidTraceparentWithoutTracestateIsAccepted() throws {
        let context = try #require(TraceContextMeta(traceparent: validTraceparent))
        #expect(context.traceparent == validTraceparent)
        #expect(context.tracestate == nil)
    }

    @Test func aValidTraceparentWithTracestateIsAccepted() throws {
        let context = try #require(
            TraceContextMeta(traceparent: validTraceparent, tracestate: sampleTracestate)
        )
        #expect(context.traceparent == validTraceparent)
        #expect(context.tracestate == sampleTracestate)
    }

    @Test(
        arguments: [
            // Wrong length: the trace id has 31 characters.
            "00-4bf92f3577b34da6a3ce929d0e0e473-00f067aa0ba902b7-01",
            // Uppercase hexadecimal.
            "00-4BF92F3577B34DA6A3CE929D0E0E4736-00f067aa0ba902b7-01",
            // A character that is not hexadecimal.
            "00-4bf92f3577b34da6a3ce929d0e0e473g-00f067aa0ba902b7-01",
            // All-zero trace id.
            "00-00000000000000000000000000000000-00f067aa0ba902b7-01",
            // All-zero parent id.
            "00-4bf92f3577b34da6a3ce929d0e0e4736-0000000000000000-01",
            // Version `ff` is not valid.
            "ff-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01",
            // Missing field: no flags.
            "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7",
            // Extra separator after the flags of a version-00 value.
            "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01-",
            // A separator that is not `-`.
            "00_4bf92f3577b34da6a3ce929d0e0e4736_00f067aa0ba902b7_01",
            // Empty value.
            "",
            // A higher version whose extra text does not start with `-`.
            "01-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01x",
        ]
    )
    func aMalformedTraceparentIsRejected(traceparent: String) {
        #expect(TraceContextMeta(traceparent: traceparent) == nil)
    }

    @Test(
        arguments: [
            // A higher version with the version-00 length.
            "01-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01",
            // A higher version with more fields after a `-`.
            "cc-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01-future-field",
        ]
    )
    func aHigherVersionWithAValidVersionZeroPrefixIsAccepted(traceparent: String) throws {
        let context = try #require(TraceContextMeta(traceparent: traceparent))
        #expect(context.traceparent == traceparent)
    }

    // MARK: - tracestate limit

    @Test func aTracestateAtTheLimitIsKept() throws {
        let atLimit = String(repeating: "a", count: TraceContextMeta.maximumTracestateLength)
        let context = try #require(TraceContextMeta(traceparent: validTraceparent, tracestate: atLimit))
        #expect(context.tracestate == atLimit)
    }

    @Test func aTracestateAboveTheLimitIsDropped() throws {
        let tooLong = String(repeating: "a", count: TraceContextMeta.maximumTracestateLength + 1)
        let context = try #require(TraceContextMeta(traceparent: validTraceparent, tracestate: tooLong))
        #expect(context.traceparent == validTraceparent)
        #expect(context.tracestate == nil)

        let extracted = try #require(
            TraceContextMeta.extract(
                from: .object([
                    TraceContextMeta.traceparentKey: .string(validTraceparent),
                    TraceContextMeta.tracestateKey: .string(tooLong),
                ])
            )
        )
        #expect(extracted.tracestate == nil)
    }

    // MARK: - extract

    @Test func extractReadsTraceparentAndTracestateFromTheTopLevelOfMeta() throws {
        let meta: JSONValue = .object([
            "traceparent": .string(validTraceparent),
            "tracestate": .string(sampleTracestate),
            "vendor.example/other": .bool(true),
        ])
        let context = try #require(TraceContextMeta.extract(from: meta))
        #expect(context.traceparent == validTraceparent)
        #expect(context.tracestate == sampleTracestate)
    }

    @Test func extractIgnoresATracestateThatIsNotAString() throws {
        let meta: JSONValue = .object([
            "traceparent": .string(validTraceparent),
            "tracestate": .number(1),
        ])
        let context = try #require(TraceContextMeta.extract(from: meta))
        #expect(context.tracestate == nil)
    }

    @Test(
        arguments: [
            nil,
            JSONValue.null,
            .string(validTraceparent),
            .array([.string(validTraceparent)]),
            .object([:]),
            .object(["traceparent": .number(1)]),
            .object(["traceparent": .null]),
            .object(["traceparent": .string("not a traceparent")]),
        ] as [JSONValue?]
    )
    func extractReturnsNilWhenMetaHasNoValidTraceparent(meta: JSONValue?) {
        #expect(TraceContextMeta.extract(from: meta) == nil)
    }

    // MARK: - inject

    @Test func injectIntoNilStartsFromAnEmptyObject() throws {
        let context = try #require(
            TraceContextMeta(traceparent: validTraceparent, tracestate: sampleTracestate)
        )
        #expect(
            context.inject(into: nil)
                == .object([
                    "traceparent": .string(validTraceparent),
                    "tracestate": .string(sampleTracestate),
                ])
        )
    }

    @Test func injectIntoJSONNullStartsFromAnEmptyObject() throws {
        let context = try #require(TraceContextMeta(traceparent: validTraceparent))
        #expect(context.inject(into: .null) == .object(["traceparent": .string(validTraceparent)]))
    }

    @Test func injectKeepsEveryOtherMemberOfMeta() throws {
        let context = try #require(
            TraceContextMeta(traceparent: validTraceparent, tracestate: sampleTracestate)
        )
        let meta: JSONValue = .object([
            "vendor.example/flag": .bool(true),
            "nested": .object(["id": .string("abc")]),
        ])
        #expect(
            context.inject(into: meta)
                == .object([
                    "vendor.example/flag": .bool(true),
                    "nested": .object(["id": .string("abc")]),
                    "traceparent": .string(validTraceparent),
                    "tracestate": .string(sampleTracestate),
                ])
        )
    }

    @Test func injectReplacesAnEarlierTraceContext() throws {
        let context = try #require(TraceContextMeta(traceparent: validTraceparent))
        let meta: JSONValue = .object([
            "traceparent": .string("01-11111111111111111111111111111111-2222222222222222-00"),
            "tracestate": .string("stale=value"),
            "keep": .string("me"),
        ])
        // A stale `tracestate` must not pair with the new `traceparent`, so
        // the codec removes it when this context has no `tracestate`.
        #expect(
            context.inject(into: meta)
                == .object([
                    "traceparent": .string(validTraceparent),
                    "keep": .string("me"),
                ])
        )
    }

    @Test(
        arguments: [
            JSONValue.string("not an object"),
            .array([.number(1)]),
            .number(1),
            .bool(false),
        ]
    )
    func injectIntoANonObjectReturnsMetaUnchanged(meta: JSONValue) throws {
        let context = try #require(TraceContextMeta(traceparent: validTraceparent))
        #expect(context.inject(into: meta) == meta)
    }

    @Test func injectThenExtractGivesTheSameValue() throws {
        let context = try #require(
            TraceContextMeta(traceparent: validTraceparent, tracestate: sampleTracestate)
        )
        let meta = context.inject(into: .object(["other": .string("value")]))
        #expect(TraceContextMeta.extract(from: meta) == context)
    }

    // MARK: - Wire round trip

    @Test func aPromptRequestWithInjectedMetaRoundTripsOnTheWire() throws {
        let context = try #require(
            TraceContextMeta(traceparent: validTraceparent, tracestate: sampleTracestate)
        )
        let request = PromptRequest(
            prompt: [.text(TextContent(text: "hi"))],
            sessionId: SessionId(rawValue: "s1"),
            meta: context.inject(into: .object(["vendor.example/flag": .bool(true)]))
        )

        let wire = try WireRoundTrip.encode(request)
        let expectedMeta: JSONValue = .object([
            "vendor.example/flag": .bool(true),
            "traceparent": .string(validTraceparent),
            "tracestate": .string(sampleTracestate),
        ])
        #expect(wire == .object([
            "prompt": .array([.object(["type": .string("text"), "text": .string("hi")])]),
            "sessionId": .string("s1"),
            "_meta": expectedMeta,
        ]))

        let decoded = try JSONDecoder().decode(PromptRequest.self, from: JSONEncoder().encode(request))
        #expect(decoded == request)
        #expect(TraceContextMeta.extract(from: decoded.meta) == context)
    }
}
