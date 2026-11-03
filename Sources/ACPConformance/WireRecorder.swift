import FoundationModelsACP

/// Collects the entries of one run in wire order.
actor WireRecorder {
    private var items: [(sequence: UInt64, entry: RecordedRun.Entry)] = []
    private var revision = 0

    func add(sequence: UInt64, _ entry: RecordedRun.Entry) {
        items.append((sequence, entry))
        revision += 1
    }

    /// The entries so far, ordered by the wire sequence number.
    var entries: [RecordedRun.Entry] {
        items.enumerated().sorted { ($0.element.sequence, $0.offset) < ($1.element.sequence, $1.offset) }.map(\.element.entry)
    }

    /// Counts the entries. It changes when an entry arrives.
    var count: Int { revision }
}

/// The client of the runner. It records the requests of the agent, and
/// answers each one with a cancel, so that the agent goes on.
struct ConformanceClient: Client {
    let recorder: WireRecorder

    func sessionUpdate(_ notification: UpdateSessionNotification) async {}

    func requestPermission(_ params: RequestPermissionRequest) async throws -> RequestPermissionResponse {
        await record(method: "session/request_permission", sessionId: params.sessionId)
        return RequestPermissionResponse(outcome: .cancelled(CancelledPermissionOutcome()))
    }

    func createElicitation(_ params: CreateElicitationRequest) async throws -> CreateElicitationResponse {
        if case .form(let form) = params.mode, case .session(let scope) = form.scope {
            await record(method: "elicitation/create", sessionId: scope.sessionId)
        }
        return .object(["action": .string("cancel")])
    }

    func elicitationComplete(_ notification: CompleteElicitationNotification) async {}

    private func record(method: String, sessionId: SessionId) async {
        let arrival = ClientSideConnection.currentRequestArrival ?? UInt64.max
        await recorder.add(
            sequence: arrival,
            .agentRequest(
                id: .number(Double(arrival)), method: method,
                sessionId: sessionId))
    }
}
