import Foundation
import Testing

@testable import FoundationModelsACP

/// `ReplayTransport` — a static, recorded script replayed deterministically:
/// no model, no network, no clock (plan.md M9).
///
/// The mechanics tests below pin the transport primitive on its own, exactly
/// as `Data` in, `Data` out — the same coverage this transport carried in v1,
/// since the mechanism is protocol-version-agnostic. The transcript test pins
/// the acceptance criterion this milestone adds: a full recorded
/// *session*-level transcript containing unrecognized enum values and
/// `_`-prefixed extensions round-trips losslessly, not just one decoded value
/// at a time (`UnknownFallbackRoundTripTests` already covers that unit level
/// exhaustively).
///
/// Every test here drives `ReplayTransport` with a manual, single-`Task`
/// decode/re-encode loop rather than a live `Connection` — see
/// `ReplayTransport`'s own doc comment for why: the whole script is queued up
/// front, so anything requiring a live peer's *reactive* answer (a
/// `session/request_permission` round trip) would race the read loop instead
/// of being decided by it. Nothing replayed here needs one: every frame is a
/// notification, answered by nothing.
@Suite struct ReplayTransportTests {
    // MARK: - Mechanics

    /// Collects every chunk from a byte stream until it finishes.
    ///
    /// - Parameter stream: The stream to drain.
    /// - Returns: The chunks in delivery order.
    /// - Throws: Rethrows any stream failure.
    private static func collectChunks(_ stream: AsyncThrowingStream<Data, any Error>) async throws -> [Data] {
        var chunks: [Data] = []
        for try await chunk in stream {
            chunks.append(chunk)
        }
        return chunks
    }

    @Test func scriptIsFedLineByLineThenStreamFinishes() async throws {
        let transport = ReplayTransport(script: Data("{\"a\":1}\n{\"b\":2}\n".utf8))
        // Returning at all proves the stream finished after the script ran out.
        let chunks = try await Self.collectChunks(transport.bytes)
        #expect(chunks == [Data("{\"a\":1}\n".utf8), Data("{\"b\":2}\n".utf8)])
    }

    @Test func unterminatedFinalScriptLineIsFedAsIs() async throws {
        let transport = ReplayTransport(script: Data("{\"a\":1}\n{\"b\":2}".utf8))
        let chunks = try await Self.collectChunks(transport.bytes)
        #expect(chunks == [Data("{\"a\":1}\n".utf8), Data("{\"b\":2}".utf8)])
    }

    @Test func emptyScriptFinishesImmediately() async throws {
        let transport = ReplayTransport(script: Data())
        let chunks = try await Self.collectChunks(transport.bytes)
        #expect(chunks.isEmpty)
    }

    @Test func writesAccumulateAsRawNDJSONInOrder() async throws {
        let transport = ReplayTransport(script: Data())
        #expect(transport.capturedOutput.isEmpty)
        try await transport.write(Data("{\"x\":1}\n".utf8))
        try await transport.write(Data("{\"y\":2}\n".utf8))
        #expect(transport.capturedOutput == Data("{\"x\":1}\n{\"y\":2}\n".utf8))
    }

    @Test func replayedFixtureCapturesEmissionsMatchingGoldenFile() async throws {
        let transport = ReplayTransport(script: try fixture("replay-script.ndjson"))
        // A toy agent loop: decode each scripted client message and emit one
        // deterministic response per message through the codec's encoder.
        for try await frame in NDJSONCodec.frames(from: transport.bytes, logger: .disabled) {
            guard
                case .message(let message) = frame,
                case .object(let fields) = message,
                let id = fields["id"],
                case .string(let method) = fields["method", default: .null]
            else {
                Issue.record("script message missing id/method: \(frame)")
                continue
            }
            let response = JSONValue.object([
                "id": id,
                "result": .object(["echoedMethod": .string(method)]),
            ])
            try await transport.write(NDJSONCodec.encode(response))
        }
        try expectGolden(transport.capturedOutput, matchesFixture: "replay-golden.ndjson")
    }

    // MARK: - Session-level unknown-value preservation

    /// A fixed session id shared by every notification in the transcript —
    /// its value is incidental; only its stability across frames matters.
    private static let sessionId = SessionId(rawValue: "s1")

    /// Wraps a `session/update` payload in its JSON-RPC notification envelope
    /// — the literal wire shape a recorded transcript carries, `method` and
    /// all, not just the bare params object.
    ///
    /// - Parameter notification: The notification payload to wrap.
    /// - Returns: The full envelope, ready to encode as one ndJSON line.
    /// - Throws: Rethrows any encoding failure.
    private static func sessionUpdateEnvelope(_ notification: UpdateSessionNotification) throws -> JSONValue {
        .object([
            "jsonrpc": .string("2.0"),
            "method": .string("session/update"),
            "params": try JSONValue.encode(result: notification),
        ])
    }

    /// Builds a fresh transcript mixing known `session/update` variants with
    /// unrecognized enum values and `_`-prefixed extensions, so the test
    /// below exercises real decode/encode logic rather than merely replaying
    /// bytes verbatim.
    ///
    /// - Returns: The transcript, one ndJSON line per notification.
    /// - Throws: Rethrows any encoding failure.
    private static func unknownValuesTranscript() throws -> Data {
        let notifications: [UpdateSessionNotification] = [
            // A known variant, so the transcript is a session, not only a
            // pile of edge cases.
            UpdateSessionNotification(sessionId: Self.sessionId, update: .stateUpdate(.running(RunningStateUpdate()))),
            // An unrecognized `session/update` variant entirely — a future
            // revision's addition, or a vendor extension, this build has
            // never heard of.
            UpdateSessionNotification(
                sessionId: Self.sessionId,
                update: .unknown(
                    "_vendor_progress",
                    .object(["percent": .number(42), "_meta": .object(["phase": .string("warming_up")])])
                )
            ),
            // A known variant carrying an unrecognized enum value in one of
            // its own fields, plus a vendor `_meta` extension.
            UpdateSessionNotification(
                sessionId: Self.sessionId,
                update: .toolCallUpdate(
                    ToolCallUpdate(
                        toolCallId: ToolCallId(rawValue: "call-1"),
                        status: .value(.unknown("_vendor_queued")),
                        meta: .value(.object(["vendor.example/priority": .number(1)]))
                    )
                )
            ),
            // A known variant whose own nested union carries an unrecognized
            // tag — `PlanUpdateContent`'s catch-all must still carry `planId`.
            UpdateSessionNotification(
                sessionId: Self.sessionId,
                update: .planUpdate(PlanUpdate(plan: .unknown("_vendor_outline", .object(["planId": .string("plan-1")]))))
            ),
            // Closes with a known `idle` carrying an unrecognized stopReason.
            UpdateSessionNotification(
                sessionId: Self.sessionId,
                update: .stateUpdate(.idle(IdleStateUpdate(stopReason: .unknown("_vendor_paused"))))
            ),
        ]
        var script = Data()
        for notification in notifications {
            script.append(try NDJSONCodec.encode(Self.sessionUpdateEnvelope(notification)))
        }
        return script
    }

    /// Decodes a full session transcript containing unrecognized enum cases
    /// and `_`-prefixed extensions, re-encodes every frame, and diffs the
    /// result against the original transcript — losslessness proven at the
    /// session/transcript level, not one decoded value in isolation.
    @Test func aFullSessionTranscriptWithUnknownValuesRoundTripsLosslessly() async throws {
        let script = try Self.unknownValuesTranscript()
        let transport = ReplayTransport(script: script)

        for try await frame in NDJSONCodec.frames(from: transport.bytes, logger: .disabled) {
            guard
                case .message(let envelope) = frame,
                case .object(let fields) = envelope,
                let params = fields["params"]
            else {
                Issue.record("transcript line was not a session/update envelope: \(frame)")
                continue
            }
            let notification = try params.decoded(as: UpdateSessionNotification.self)
            let reencoded = try Self.sessionUpdateEnvelope(notification)
            try await transport.write(NDJSONCodec.encode(reencoded))
        }

        // The strongest form of the claim: re-encoding reproduced the exact
        // scripted bytes, not merely bytes equivalent to some other fixture.
        #expect(transport.capturedOutput == script)
        try expectGolden(transport.capturedOutput, matchesFixture: "unknown-values-transcript.ndjson")
    }
}
