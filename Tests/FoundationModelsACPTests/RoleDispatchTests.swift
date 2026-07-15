import Foundation
import Testing

import FoundationModelsACP

// MARK: - Helpers

/// Asserts an operation fails with a JSON-RPC method-not-found error (-32601).
///
/// - Parameters:
///   - operation: The throwing operation expected to fail.
///   - sourceLocation: The caller location, for failure reporting.
private func expectMethodNotFound(
    _ operation: () async throws -> Void,
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    do {
        try await operation()
        Issue.record("expected method-not-found (-32601)", sourceLocation: sourceLocation)
    } catch let error as RequestError {
        #expect(error.code == -32601, sourceLocation: sourceLocation)
    } catch {
        Issue.record("expected RequestError, got \(error)", sourceLocation: sourceLocation)
    }
}

// MARK: - Agent-side request matrix (Client → Agent)

@Test(.timeLimit(.minutes(1)))
func agentSideRequestsDispatchToTheRightHandlerWithDecodedParams() async throws {
    let (clientEnd, agentEnd) = InMemoryTransport.pair()
    let recorder = RoleRecorder()
    let agentConn = await AgentSideConnection(stream: agentEnd) { _ in SpyAgent(recorder: recorder) }
    let client = await ClientSideConnection(stream: clientEnd) { _ in MinimalClient() }

    let initialize = InitializeRequest(protocolVersion: .v1)
    let initializeResponse = try await client.initialize(initialize)
    #expect(initializeResponse.protocolVersion == .v1)
    #expect(recorder.recorded("initialize") == (try encodedValue(initialize)))

    let newSession = NewSessionRequest(cwd: testCwd, mcpServers: [])
    let newSessionResponse = try await client.newSession(newSession)
    #expect(newSessionResponse.sessionId == SessionId(rawValue: "session-1"))
    #expect(recorder.recorded("newSession") == (try encodedValue(newSession)))

    let loadSession = LoadSessionRequest(cwd: testCwd, mcpServers: [], sessionId: testSessionId)
    _ = try await client.loadSession(loadSession)
    #expect(recorder.recorded("loadSession") == (try encodedValue(loadSession)))

    let prompt = PromptRequest(prompt: [.text(TextContent(text: "hello"))], sessionId: testSessionId)
    let promptResponse = try await client.prompt(prompt)
    #expect(promptResponse.stopReason == .endTurn)
    #expect(recorder.recorded("prompt") == (try encodedValue(prompt)))

    let authenticate = AuthenticateRequest(methodId: AuthMethodId(rawValue: "method-1"))
    _ = try await client.authenticate(authenticate)
    #expect(recorder.recorded("authenticate") == (try encodedValue(authenticate)))

    let configOption: SetSessionConfigOptionRequest = .object([
        "sessionId": .string("session-1"),
        "optionId": .string("theme"),
        "value": .string("dark"),
    ])
    _ = try await client.setSessionConfigOption(configOption)
    #expect(recorder.recorded("setSessionConfigOption") == (try encodedValue(configOption)))

    let listSessions = ListSessionsRequest()
    _ = try await client.listSessions(listSessions)
    #expect(recorder.recorded("listSessions") == (try encodedValue(listSessions)))

    let resumeSession = ResumeSessionRequest(cwd: testCwd, sessionId: testSessionId)
    _ = try await client.resumeSession(resumeSession)
    #expect(recorder.recorded("resumeSession") == (try encodedValue(resumeSession)))

    let deleteSession = DeleteSessionRequest(sessionId: testSessionId)
    try await client.deleteSession(deleteSession)
    #expect(recorder.recorded("deleteSession") == (try encodedValue(deleteSession)))

    let closeSession = CloseSessionRequest(sessionId: testSessionId)
    try await client.closeSession(closeSession)
    #expect(recorder.recorded("closeSession") == (try encodedValue(closeSession)))

    let logout = LogoutRequest()
    try await client.logout(logout)
    #expect(recorder.recorded("logout") == (try encodedValue(logout)))

    await agentConn.close()
    await client.close()
}

@Test(.timeLimit(.minutes(1)))
func agentSideCancelNotificationDispatchesToTheHandler() async throws {
    let (clientEnd, agentEnd) = InMemoryTransport.pair()
    let recorder = RoleRecorder()
    let agentConn = await AgentSideConnection(stream: agentEnd) { _ in SpyAgent(recorder: recorder) }
    let client = await ClientSideConnection(stream: clientEnd) { _ in MinimalClient() }

    let cancel = CancelNotification(sessionId: testSessionId)
    try await client.cancel(cancel)
    await recorder.waitForCall("cancel")
    #expect(recorder.recorded("cancel") == (try encodedValue(cancel)))

    await agentConn.close()
    await client.close()
}

@Test(.timeLimit(.minutes(1)))
func agentSideSetSessionModeDispatchesViaTheRoutingTable() async throws {
    // Sent over a raw connection using the routing table's wire name so the
    // test never names the deprecated `setSessionMode` symbol.
    let (clientEnd, agentEnd) = InMemoryTransport.pair()
    let recorder = RoleRecorder()
    let agentConn = await AgentSideConnection(stream: agentEnd) { _ in SpyAgent(recorder: recorder) }
    let client = await Connection(transport: clientEnd)

    let request = SetSessionModeRequest(modeId: SessionModeId(rawValue: "mode-1"), sessionId: testSessionId)
    let wire = wireMethod(for: "setSessionMode", on: .agent)
    _ = try await client.request(method: wire, params: encodedValue(request))
    #expect(recorder.recorded("setSessionMode") == (try encodedValue(request)))

    await agentConn.close()
    await client.close()
}

// MARK: - Client-side request matrix (Agent → Client)

@Test(.timeLimit(.minutes(1)))
func clientSideRequestsDispatchToTheRightHandlerWithDecodedParams() async throws {
    let (clientEnd, agentEnd) = InMemoryTransport.pair()
    let recorder = RoleRecorder()
    let clientConn = await ClientSideConnection(stream: clientEnd) { _ in SpyClient(recorder: recorder) }
    let agent = await AgentSideConnection(stream: agentEnd) { _ in MinimalAgent() }

    let requestPermission = RequestPermissionRequest(
        options: [],
        sessionId: testSessionId,
        toolCall: ToolCallUpdate(toolCallId: ToolCallId(rawValue: "call-1"))
    )
    let permissionResponse = try await agent.requestPermission(requestPermission)
    #expect(permissionResponse.outcome == .cancelled)
    #expect(recorder.recorded("requestPermission") == (try encodedValue(requestPermission)))

    let readTextFile = ReadTextFileRequest(path: testCwd, sessionId: testSessionId)
    let readResponse = try await agent.readTextFile(readTextFile)
    #expect(readResponse.content == "file-contents")
    #expect(recorder.recorded("readTextFile") == (try encodedValue(readTextFile)))

    let writeTextFile = WriteTextFileRequest(content: "data", path: testCwd, sessionId: testSessionId)
    try await agent.writeTextFile(writeTextFile)
    #expect(recorder.recorded("writeTextFile") == (try encodedValue(writeTextFile)))

    let createTerminal = CreateTerminalRequest(command: "ls", sessionId: testSessionId)
    let createResponse = try await agent.createTerminal(createTerminal)
    #expect(createResponse.terminalId == testTerminalId)
    #expect(recorder.recorded("createTerminal") == (try encodedValue(createTerminal)))

    let terminalOutput = TerminalOutputRequest(sessionId: testSessionId, terminalId: testTerminalId)
    let outputResponse = try await agent.terminalOutput(terminalOutput)
    #expect(outputResponse.output == "terminal-output")
    #expect(recorder.recorded("terminalOutput") == (try encodedValue(terminalOutput)))

    let waitForExit = WaitForTerminalExitRequest(sessionId: testSessionId, terminalId: testTerminalId)
    let exitResponse = try await agent.waitForTerminalExit(waitForExit)
    #expect(exitResponse.exitCode == 0)
    #expect(recorder.recorded("waitForTerminalExit") == (try encodedValue(waitForExit)))

    let killTerminal = KillTerminalRequest(sessionId: testSessionId, terminalId: testTerminalId)
    try await agent.killTerminal(killTerminal)
    #expect(recorder.recorded("killTerminal") == (try encodedValue(killTerminal)))

    let releaseTerminal = ReleaseTerminalRequest(sessionId: testSessionId, terminalId: testTerminalId)
    try await agent.releaseTerminal(releaseTerminal)
    #expect(recorder.recorded("releaseTerminal") == (try encodedValue(releaseTerminal)))

    await clientConn.close()
    await agent.close()
}

@Test(.timeLimit(.minutes(1)))
func clientSideSessionUpdateNotificationDispatchesToTheHandler() async throws {
    let (clientEnd, agentEnd) = InMemoryTransport.pair()
    let recorder = RoleRecorder()
    let clientConn = await ClientSideConnection(stream: clientEnd) { _ in SpyClient(recorder: recorder) }
    let agent = await AgentSideConnection(stream: agentEnd) { _ in MinimalAgent() }

    let update = SessionNotification(
        sessionId: testSessionId,
        update: .agentMessageChunk(ContentChunk(content: .text(TextContent(text: "chunk"))))
    )
    try await agent.sessionUpdate(update)
    await recorder.waitForCall("sessionUpdate")
    #expect(recorder.recorded("sessionUpdate") == (try encodedValue(update)))

    await clientConn.close()
    await agent.close()
}

// MARK: - Method-not-found paths

@Test(.timeLimit(.minutes(1)))
func unknownMethodAnswersMethodNotFound() async throws {
    let (clientEnd, agentEnd) = InMemoryTransport.pair()
    let agentConn = await AgentSideConnection(stream: agentEnd) { _ in MinimalAgent() }
    let client = await Connection(transport: clientEnd)

    await expectMethodNotFound {
        _ = try await client.request(method: "bogus/method", params: nil)
    }

    await agentConn.close()
    await client.close()
}

@Test(.timeLimit(.minutes(1)))
func ungatedAgentMethodAnswersMethodNotFound() async throws {
    // A minimal agent implements no optional method, so its default throws.
    let (clientEnd, agentEnd) = InMemoryTransport.pair()
    let agentConn = await AgentSideConnection(stream: agentEnd) { _ in MinimalAgent() }
    let client = await ClientSideConnection(stream: clientEnd) { _ in MinimalClient() }

    let loadSession = LoadSessionRequest(cwd: testCwd, mcpServers: [], sessionId: testSessionId)
    await expectMethodNotFound {
        _ = try await client.loadSession(loadSession)
    }

    await agentConn.close()
    await client.close()
}

@Test(.timeLimit(.minutes(1)))
func ungatedClientMethodAnswersMethodNotFound() async throws {
    // A minimal client implements no gated method, so its default throws.
    let (clientEnd, agentEnd) = InMemoryTransport.pair()
    let clientConn = await ClientSideConnection(stream: clientEnd) { _ in MinimalClient() }
    let agent = await AgentSideConnection(stream: agentEnd) { _ in MinimalAgent() }

    let readTextFile = ReadTextFileRequest(path: testCwd, sessionId: testSessionId)
    await expectMethodNotFound {
        _ = try await agent.readTextFile(readTextFile)
    }

    await clientConn.close()
    await agent.close()
}
