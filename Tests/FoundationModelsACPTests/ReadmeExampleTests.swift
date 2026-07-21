import Foundation
import Testing

import FoundationModelsACP

// MARK: - README example agent

/// The README's flagship agent: streams each prompt block back as an agent
/// message chunk, then ends the turn.
///
/// This type is the README's agent example verbatim — keep the two in
/// lockstep. It implements only the four required `Agent` methods; every
/// optional method answers method-not-found through the protocol's defaults.
struct EchoAgent: Agent {
    /// The serving connection, captured so `prompt` can stream updates.
    let connection: AgentSideConnection

    func initialize(_ params: InitializeRequest) async throws -> InitializeResponse {
        InitializeResponse(protocolVersion: .latest)
    }

    func newSession(_ params: NewSessionRequest) async throws -> NewSessionResponse {
        NewSessionResponse(sessionId: SessionId(rawValue: UUID().uuidString))
    }

    func prompt(_ params: PromptRequest) async throws -> PromptResponse {
        for block in params.prompt {
            try await connection.sessionUpdate(
                SessionNotification(
                    sessionId: params.sessionId,
                    update: .agentMessageChunk(ContentChunk(content: block))
                )
            )
        }
        return PromptResponse(stopReason: .endTurn)
    }

    func cancel(_ params: CancelNotification) async {}
}

// MARK: - README example tests

/// Compile-checked companions to the usage examples in `README.md`.
///
/// The README's agent example serves over `.stdio`; these tests wire the exact
/// same public API over an in-memory transport pair, so the documented code is
/// proven to compile and round trip deterministically (spec §8). Keep this
/// file honest against the README: if an example there changes, change its
/// companion here.
struct ReadmeExampleTests {
    /// The README agent example: ``EchoAgent`` served by an
    /// ``AgentSideConnection``, driven through a real ``ClientSideConnection``
    /// for a full initialize/new-session/prompt turn.
    @Test("the README agent example compiles and serves a full turn")
    func agentExampleServesATurn() async throws {
        let (clientEnd, agentEnd) = InMemoryTransport.pair()

        // --- README example (agent author) -----------------------------------
        // The README serves this over `.stdio`; here `agentEnd` stands in.
        let agentConnection = await AgentSideConnection(stream: agentEnd, logger: .standardError) { conn in
            EchoAgent(connection: conn)
        }
        // ---------------------------------------------------------------------

        let client = await ClientSideConnection(stream: clientEnd) { _ in MinimalClient() }

        _ = try await client.initialize(InitializeRequest(protocolVersion: .latest))
        let session = try await client.newSession(newSessionRequest())

        var updates = client.updates(for: session.sessionId).makeAsyncIterator()
        let response = try await client.prompt(
            PromptRequest(prompt: [.text(TextContent(text: "Hello"))], sessionId: session.sessionId)
        )

        #expect(response.stopReason == .endTurn)
        #expect(await updates.next() == messageChunkUpdate("Hello"))

        await client.close()
        await agentConnection.close()
    }

    /// The README client example: initialize, open a session, subscribe to its
    /// update stream, and drive one prompt turn — against a scripted wire
    /// agent, so the turn's updates are deterministic.
    @Test("the README client example drives a turn and receives its updates")
    func clientExampleDrivesATurn() async throws {
        let sessionId = SessionId(rawValue: "readme-client")
        let reply = "Hello from the agent."
        let pair = await makeEndToEndPair(sessionId: sessionId) { _ in MinimalClient() }
        pair.agent.enqueueTurn { context in
            try await context.update(messageChunkUpdate(reply))
            return .endTurn
        }

        // --- README example (client author) ----------------------------------
        let client = pair.client
        _ = try await client.initialize(InitializeRequest(protocolVersion: .latest))
        let session = try await client.newSession(NewSessionRequest(cwd: testCwd, mcpServers: []))

        // Subscribe before driving the turn — updates for a session with no
        // active subscriber are dropped.
        var updates = client.updates(for: session.sessionId).makeAsyncIterator()
        let outcome = try await client.prompt(
            PromptRequest(prompt: [.text(TextContent(text: "Say hello."))], sessionId: session.sessionId)
        )
        // ---------------------------------------------------------------------

        #expect(outcome.stopReason == .endTurn)
        #expect(await updates.next() == messageChunkUpdate(reply))

        await client.close()
        await pair.agentConnection.close()
    }
}
