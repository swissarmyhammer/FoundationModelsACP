import FoundationModelsACP

/// What one connection to the agent under test showed, in wire order.
struct RecordedRun: Sendable {
    /// One thing that crossed the wire.
    enum Entry: Sendable {
        /// The agent sent a `session/update`.
        case update(SessionId, SessionUpdate)

        /// The agent answered a request of the runner. `succeeded` is false for an error.
        case response(id: RequestId, method: String, succeeded: Bool)

        /// The agent sent a request that waits on the user.
        case agentRequest(id: RequestId, method: String, sessionId: SessionId)
    }

    /// The name in the report, such as `turn` or `resume-replay`.
    var name: String

    /// The session that the runner resumed, or `nil` when the run has no resume.
    var resumeSessionId: SessionId?

    /// The agent answered the resume with method-not-found.
    var resumeUnsupported = false

    var entries: [Entry]

    /// The error that stopped the scenario (a start failure or a failed
    /// request), when there is one. The checks put it in their messages.
    var failure: String?

    /// `message`, with the failure of the run added when there is one.
    func failureText(_ message: String) -> String {
        failure.map { "\(message) (\($0))" } ?? message
    }

    init(
        name: String, resumeSessionId: SessionId? = nil, resumeUnsupported: Bool = false, failure: String? = nil,
        entries: [Entry]
    ) {
        self.failure = failure
        self.name = name
        self.resumeSessionId = resumeSessionId
        self.resumeUnsupported = resumeUnsupported
        self.entries = entries
    }

    private static let resumeMethod = WireMethod.resume

    /// The trace for ``SubagentWireTraceValidator``. A run with a resume starts
    /// with the resume request. The responses of other requests are not in it.
    var wireTrace: [WireTraceEvent] {
        var trace: [WireTraceEvent] = []
        if let resumeSessionId { trace.append(.resumeRequest(id: .number(0), sessionId: resumeSessionId)) }
        for entry in entries {
            switch entry {
            case .update(let session, let update):
                trace.append(.update(sessionId: session, update: update))
            case .agentRequest(let id, let method, let session):
                trace.append(.agentRequest(id: id, method: method, sessionId: session))
            case .response(let id, let method, _):
                if method == Self.resumeMethod { trace.append(.resumeResponse(id: id)) }
            }
        }
        return trace
    }
}

/// The wire methods that the checks name. The package keeps its routing table
/// private, so the runner states the two it needs.
enum WireMethod {
    static let prompt = "session/prompt"
    static let resume = "session/resume"
}
