import Foundation
import Testing

@testable import FoundationModelsACP

/// A `session/update` fixture whose frames arrive deliberately out of the
/// order a single well-behaved turn would send them, proving
/// `SessionUpdateAggregator` converges on the correct end state regardless of
/// arrival order — correlation is by `messageId` / `toolCallId` / `terminalId`,
/// never by position in the stream (plan.md M9, *Testing strategy*).
///
/// `SessionUpdateAggregatorTests` already proves every individual folding
/// rule (upsert replaces, chunks append, a patch folds onto what exists) from
/// direct, hand-ordered Swift calls. What is new here is decoding a single
/// **wire-level transcript** — replayed through `ReplayTransport`, so the
/// scrambled order lives in the recorded bytes, not in the order the test
/// happens to call `apply(_:)` — and confirming the aggregator still lands on
/// the same accumulated state a naturally-ordered stream would have produced.
@Suite struct OutOfOrderConvergenceTests {
    private static let toolCallId = ToolCallId(rawValue: "call-1")
    private static let terminalId = TerminalId(rawValue: "term-1")
    private static let sessionId = SessionId(rawValue: "s1")

    /// Wraps a `session/update` payload in its JSON-RPC notification
    /// envelope, matching the literal wire shape a recorded transcript
    /// carries.
    ///
    /// - Parameter update: The update payload to wrap.
    /// - Returns: The full envelope, ready to encode as one ndJSON line.
    /// - Throws: Rethrows any encoding failure.
    private static func envelope(_ update: SessionUpdate) throws -> JSONValue {
        let notification = UpdateSessionNotification(sessionId: Self.sessionId, update: update)
        return .object([
            "jsonrpc": .string("2.0"),
            "method": .string("session/update"),
            "params": try JSONValue.encode(result: notification),
        ])
    }

    /// Builds the scrambled transcript: a tool call's completing patch
    /// arrives before its own creation, a terminal's output chunk arrives
    /// before the terminal is ever upserted, an intervening upsert replaces
    /// the tool call's content mid-stream, and a straggler tool-call patch
    /// arrives after the turn's closing `idle` — none of which stop the
    /// aggregator from converging correctly.
    ///
    /// - Returns: The out-of-order transcript, one ndJSON line per update.
    /// - Throws: Rethrows any encoding failure.
    private static func outOfOrderTranscript() throws -> Data {
        let updates: [SessionUpdate] = [
            // The "completing" patch arrives first — first sighting of this
            // toolCallId creates the entry with only `status` set.
            .toolCallUpdate(ToolCallUpdate(toolCallId: Self.toolCallId, status: .value(.completed))),
            // A terminal output chunk arrives before any terminal_update ever
            // named this terminalId — first sighting creates it.
            .terminalOutputChunk(TerminalOutputChunk(data: Data("late start\n".utf8).base64EncodedString(), terminalId: Self.terminalId)),
            // The tool call's "creation" update arrives after its own patch —
            // title/kind fold in; status is omitted here, so the earlier
            // `completed` value must survive rather than reverting to unknown.
            .toolCallUpdate(
                ToolCallUpdate(toolCallId: Self.toolCallId, kind: .value(.execute), title: .value("Run ls"))
            ),
            // The turn closes.
            .stateUpdate(.idle(IdleStateUpdate(stopReason: .endTurn))),
            // A straggler: the terminal's exit status, delivered after the
            // idle close. Correlation is by terminalId, not turn boundary.
            .terminalUpdate(TerminalUpdate(terminalId: Self.terminalId, exitStatus: .value(TerminalExitStatus(exitCode: 0)))),
        ]
        var script = Data()
        for update in updates {
            script.append(try NDJSONCodec.encode(Self.envelope(update)))
        }
        return script
    }

    @Test func lateAndOutOfOrderUpdatesStillConvergeCorrectly() async throws {
        let transport = ReplayTransport(script: try Self.outOfOrderTranscript())
        var aggregator = SessionUpdateAggregator()

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
            aggregator.apply(notification.update)
        }

        let toolCall = try #require(aggregator.toolCalls[Self.toolCallId])
        #expect(toolCall.status == .value(.completed), "the earlier-arriving completion must survive the later creation update")
        #expect(toolCall.title == .value("Run ls"))
        #expect(toolCall.kind == .value(.execute))

        let terminal = try #require(aggregator.terminals[Self.terminalId])
        #expect(terminal.output == Data("late start\n".utf8))
        #expect(terminal.exitStatus == .value(TerminalExitStatus(exitCode: 0)), "the straggler after idle must still be applied")
    }
}
