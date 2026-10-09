import Foundation
import Testing

@testable import FoundationModelsACP

/// `SessionMergeEngine.cancelUnfinishedToolCalls()`: after `session/cancel`,
/// the client marks each tool call that did not finish as `cancelled`.
///
/// The spec says that the client SHOULD do this immediately when it sends
/// `session/cancel`. Updates that the agent sends after the cancel still
/// apply on top of the `cancelled` status.
@Suite struct SessionMergeEngineCancellationTests {
    private typealias Fixtures = SessionMergeEngineFixtures

    /// A tool call that has the `pending` status.
    private static let pendingCall = ToolCallId(rawValue: "call-pending")

    /// A tool call that has the `in_progress` status.
    private static let runningCall = ToolCallId(rawValue: "call-running")

    /// A tool call that the agent sent with no status.
    private static let statuslessCall = ToolCallId(rawValue: "call-statusless")

    /// A tool call that has the `completed` status.
    private static let completedCall = ToolCallId(rawValue: "call-completed")

    /// A tool call that has the `failed` status.
    private static let failedCall = ToolCallId(rawValue: "call-failed")

    /// A tool call that has the `cancelled` status already.
    private static let cancelledCall = ToolCallId(rawValue: "call-cancelled")

    /// The title that the agent gives to each tool call.
    private static let title = "Read a file"

    /// The tool calls that did not finish, in transcript order.
    private static let unfinishedCalls = [pendingCall, runningCall, statuslessCall]

    /// The tool calls in a terminal status, with that status.
    private static let finishedCalls: [(id: ToolCallId, status: ToolCallStatus)] = [
        (completedCall, .completed), (failedCall, .failed), (cancelledCall, .cancelled),
    ]

    /// Makes an engine whose transcript holds each tool call of this suite.
    ///
    /// - Returns: The engine.
    private static func engineWithToolCalls() -> SessionMergeEngine {
        var engine = SessionMergeEngine()
        let statuses: [(id: ToolCallId, status: PatchField<ToolCallStatus>)] = [
            (pendingCall, .value(.pending)), (runningCall, .value(.inProgress)), (statuslessCall, .unchanged),
        ]
        let finished = finishedCalls.map { (id: $0.id, status: PatchField.value($0.status)) }
        for call in statuses + finished {
            engine.apply(.toolCallUpdate(ToolCallUpdate(toolCallId: call.id, status: call.status, title: .value(title))))
        }
        return engine
    }

    @Test func eachUnfinishedToolCallBecomesCancelled() throws {
        var engine = Self.engineWithToolCalls()
        engine.cancelUnfinishedToolCalls()
        for id in Self.unfinishedCalls {
            #expect(try Fixtures.toolCall(id, in: engine).status == .value(.cancelled))
        }
    }

    @Test func aToolCallInATerminalStatusKeepsItsStatus() throws {
        var engine = Self.engineWithToolCalls()
        engine.cancelUnfinishedToolCalls()
        for call in Self.finishedCalls {
            #expect(try Fixtures.toolCall(call.id, in: engine).status == .value(call.status))
        }
    }

    @Test func theChangesNameEachCancelledEntryInTranscriptOrder() throws {
        var engine = Self.engineWithToolCalls()
        let changes = engine.cancelUnfinishedToolCalls()
        let expected = try Self.unfinishedCalls.map { id in
            let index = try #require(engine.entries.firstIndex { $0.id == .toolCall(id) })
            return SessionMergeEngine.Change.entryChanged(index: index, entry: engine.entries[index])
        }
        #expect(changes == expected)
    }

    @Test func cancellingKeepsTheOtherFieldsOfTheToolCall() throws {
        var engine = Self.engineWithToolCalls()
        engine.cancelUnfinishedToolCalls()
        #expect(try Fixtures.toolCall(Self.runningCall, in: engine).title == .value(Self.title))
    }

    @Test func aTranscriptWithNoUnfinishedToolCallGivesNoChange() {
        var engine = SessionMergeEngine()
        engine.apply(.toolCallUpdate(ToolCallUpdate(toolCallId: Self.completedCall, status: .value(.completed))))
        #expect(engine.cancelUnfinishedToolCalls().isEmpty)
    }

    @Test func anUpdateAfterTheCancelStillApplies() throws {
        var engine = Self.engineWithToolCalls()
        engine.cancelUnfinishedToolCalls()
        engine.apply(.toolCallUpdate(ToolCallUpdate(toolCallId: Self.runningCall, status: .value(.completed))))
        #expect(try Fixtures.toolCall(Self.runningCall, in: engine).status == .value(.completed))
    }
}
