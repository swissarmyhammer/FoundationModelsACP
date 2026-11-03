import Foundation
import Testing

@testable import FoundationModelsACP

/// A request that the agent sent to the client, as the client saw it on the
/// wire.
struct ObservedAgentRequest: Sendable {
    /// The wire sequence number of the request frame.
    let arrival: UInt64

    /// The wire method.
    let method: String

    /// The session that the request names.
    let sessionId: SessionId
}

/// A client for the tests that run the nested scenario of `acp-test-agent`.
/// It answers each elicitation with a cancel, and reports the request that it
/// saw.
struct ElicitedClient: Client {
    /// Receives each elicitation request that arrives.
    let requests: AsyncStream<ObservedAgentRequest>.Continuation

    func sessionUpdate(_ notification: UpdateSessionNotification) async {}

    func requestPermission(_ params: RequestPermissionRequest) async throws -> RequestPermissionResponse {
        throw RequestError.methodNotFound("requestPermission")
    }

    func createElicitation(_ params: CreateElicitationRequest) async throws -> CreateElicitationResponse {
        guard let arrival = ClientSideConnection.currentRequestArrival,
            case .form(let form) = params.mode, case .session(let scope) = form.scope
        else {
            throw RequestError.invalidParams
        }
        requests.yield(
            ObservedAgentRequest(
                arrival: arrival, method: RoleRouting.wireMethod(for: "createElicitation", on: .client),
                sessionId: scope.sessionId))
        return .object(["action": .string("cancel")])
    }

    func elicitationComplete(_ notification: CompleteElicitationNotification) async {}
}

/// What a run of the nested scenario of `acp-test-agent` showed to a client.
struct NestedScenarioRecording: Sendable {
    /// The id of the `session/resume` request.
    let resumeId: RequestId

    /// Every event of the all-sessions stream, up to the final update of the
    /// tool call that started `child-1`.
    let events: [SequencedSessionEvent]

    /// The elicitation request that the agent sent.
    let request: ObservedAgentRequest
}

enum NestedScenarioRun {
    /// Starts `acp-test-agent --scenario nested-subagents`, resumes the root
    /// session, and records what the client sees.
    static func play() async throws -> NestedScenarioRecording {
        let root = SessionId(rawValue: "root")
        let childCall = ToolCallId(rawValue: "call-child-1")
        let transport = try SubprocessTransport(
            executableURL: TransportTestSupport.helperAgentURL, arguments: ["--scenario", "nested-subagents"])
        let (requests, continuation) = AsyncStream.makeStream(of: ObservedAgentRequest.self)
        let client = await ClientSideConnection(stream: transport) { _ in ElicitedClient(requests: continuation) }
        var events = client.subscribeToAllSessions().events.makeAsyncIterator()
        do {
            _ = try await client.initialize(handshakeInitializeRequest())
            _ = try await client.resumeSession(ResumeSessionRequest(cwd: AbsolutePath(rawValue: "/work"), sessionId: root))
        } catch {
            await client.close()
            transport.close()
            throw error
        }
        var received: [SequencedSessionEvent] = []
        while let event = await events.next() {
            received.append(event)
            if case .update(.toolCallUpdate(let call)) = event.event, event.sessionId == root,
                call.toolCallId == childCall, call.status == .value(.completed)
            {
                break
            }
        }
        var observed = requests.makeAsyncIterator()
        let request = await observed.next()
        await client.close()
        transport.close()
        let recordedRequest = try #require(request)
        let resumeId = try #require(
            received.compactMap { event -> RequestId? in
                if case .requestFinished(let id, _, _) = event.event { return id } else { return nil }
            }.first)
        return NestedScenarioRecording(resumeId: resumeId, events: received, request: recordedRequest)
    }
}
