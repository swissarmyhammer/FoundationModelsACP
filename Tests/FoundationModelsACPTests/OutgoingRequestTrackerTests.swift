import Synchronization
import Testing

@testable import FoundationModelsACP

/// The session observer of `OutgoingRequestTracker`: the tracker calls it
/// synchronously when a request whose params name a session finishes.
@Suite(.timeLimit(.minutes(1))) struct OutgoingRequestTrackerTests {
    /// The session that the session-scoped requests name.
    private static let sessionId = SessionId(rawValue: "tracker-session")

    /// The wire method of the session-scoped request.
    private static let promptMethod = "session/prompt"

    /// The wire method of the request that names no session.
    private static let initializeMethod = "initialize"

    /// The wire ID of the session-scoped request.
    private static let sessionRequestId: RequestId = .number(1)

    /// The wire ID of the request that names no session.
    private static let otherRequestId: RequestId = .number(2)

    /// The params of a request that names `sessionId`.
    private static let sessionParams: JSONValue = .object(["sessionId": .string(sessionId.rawValue)])

    /// Records each finished session request that the tracker reports.
    private final class Recorder: Sendable {
        /// The reported requests, in order.
        private let finished = Mutex<[FinishedSessionRequest]>([])

        /// Every reported request so far.
        var requests: [FinishedSessionRequest] { finished.withLock { $0 } }

        /// Makes a tracker that reports to this recorder.
        ///
        /// - Returns: The tracker.
        func makeTracker() -> OutgoingRequestTracker {
            OutgoingRequestTracker { request in self.finished.withLock { $0.append(request) } }
        }
    }

    /// The report for the session-scoped request.
    ///
    /// - Parameter outcome: How the request finished.
    /// - Returns: The expected report.
    private static func sessionReport(_ outcome: OutgoingRequestOutcome) -> FinishedSessionRequest {
        FinishedSessionRequest(id: sessionRequestId, method: promptMethod, sessionId: sessionId, outcome: outcome)
    }

    @Test func finishReportsASessionRequestBeforeItReturns() {
        let recorder = Recorder()
        let tracker = recorder.makeTracker()
        tracker.start(id: Self.sessionRequestId, method: Self.promptMethod, params: Self.sessionParams)

        tracker.finish(id: Self.sessionRequestId, outcome: .succeeded)

        #expect(recorder.requests == [Self.sessionReport(.succeeded)])
    }

    @Test func finishDoesNotReportARequestThatNamesNoSession() {
        let recorder = Recorder()
        let tracker = recorder.makeTracker()
        tracker.start(id: Self.otherRequestId, method: Self.initializeMethod, params: .object([:]))

        tracker.finish(id: Self.otherRequestId, outcome: .succeeded)

        #expect(recorder.requests.isEmpty)
    }

    @Test func finishAllReportsEachSessionRequestAsFailed() {
        let recorder = Recorder()
        let tracker = recorder.makeTracker()
        tracker.start(id: Self.sessionRequestId, method: Self.promptMethod, params: Self.sessionParams)
        tracker.start(id: Self.otherRequestId, method: Self.initializeMethod, params: nil)

        tracker.finishAll()

        #expect(recorder.requests == [Self.sessionReport(.failed)])
    }

    @Test func aSecondFinishOfOneRequestReportsNothing() {
        let recorder = Recorder()
        let tracker = recorder.makeTracker()
        tracker.start(id: Self.sessionRequestId, method: Self.promptMethod, params: Self.sessionParams)

        tracker.finish(id: Self.sessionRequestId, outcome: .failed)
        tracker.finish(id: Self.sessionRequestId, outcome: .succeeded)

        #expect(recorder.requests == [Self.sessionReport(.failed)])
    }
}
