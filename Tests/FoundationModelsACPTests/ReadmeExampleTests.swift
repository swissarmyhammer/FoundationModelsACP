import Foundation
import FoundationModels
import Synchronization
import Testing

@testable import FoundationModelsACP

/// Compile-checked companions to the usage examples in `README.md`.
///
/// The README's flagship agent runs over `.stdio`; these tests wire the exact
/// same public API over an in-memory transport pair and drive the turn through
/// a scripted generator, so the documented code is proven to compile and round
/// trip deterministically without a live model (spec §8). Keep this file honest
/// against the README: if an example there changes, change its companion here.
struct ReadmeExampleTests {
    /// The README's flagship "Apple-native model as an ACP agent" example: build
    /// a ``FoundationModelsAgent`` from a ``LanguageModelSession`` behind an
    /// ``AgentSideConnection``, then drive a full initialize/new-session/prompt
    /// turn through a real ``ClientSideConnection``.
    ///
    /// Building the session never runs inference, and the scripted turn stands in
    /// for the model's generation, so the round trip is deterministic.
    @Test("the README flagship agent example compiles and serves a full turn")
    func flagshipAgentExampleServesATurn() async throws {
        let (clientEnd, agentEnd) = InMemoryTransport.pair()

        // --- README example (agent author) -----------------------------------
        // The README runs this over `.stdio`; here `agentEnd` stands in.
        let myTools: [any Tool] = []
        let capturedAgent = Mutex<FoundationModelsAgent?>(nil)
        let agentConnection = await AgentSideConnection(stream: agentEnd, logger: .standardError) { connection in
            let agent = FoundationModelsAgent(
                connection: connection,
                session: LanguageModelSession(model: SystemLanguageModel.default, tools: myTools)
            )
            capturedAgent.withLock { $0 = agent }
            return agent
        }
        // ---------------------------------------------------------------------

        let client = await ClientSideConnection(stream: clientEnd) { _ in MinimalClient() }

        _ = try await client.initialize(endToEndInitializeRequest())
        let created = try await client.newSession(bridgeNewSessionRequest())
        let sessionId = created.sessionId

        // The one-liner mints its session id internally; script the turn against
        // it before prompting so no live model is driven.
        let reply = "Hello from FoundationModels."
        capturedAgent.withLock { $0 }?.enqueueScriptedTurn(for: sessionId) { deliver in
            await deliver([responseEntry(reply)])
            return Transcript(entries: [responseEntry(reply)])
        }

        var updates = client.updates(for: sessionId).makeAsyncIterator()
        let response = try await client.prompt(endToEndPromptRequest(text: "Say hello.", sessionId: sessionId))

        #expect(response.stopReason == .endTurn)
        #expect(await updates.next() == messageChunkUpdate(reply))

        await client.close()
        await agentConnection.close()
    }

    /// The README's client-side example: subscribe to a session's update stream
    /// with ``ClientSideConnection/updates(for:)`` and fold the turn's updates
    /// back into a FoundationModels ``Transcript`` with ``TranscriptBuilder``.
    ///
    /// The subscription is opened before the turn runs, the connection is closed
    /// to finish the stream, and the finished stream is then folded to a
    /// transcript.
    @Test("the README client + TranscriptBuilder example folds a turn's updates")
    func clientTranscriptExampleFoldsUpdates() async throws {
        let sessionId = SessionId(rawValue: "readme-transcript")
        let (clientEnd, agentEnd) = InMemoryTransport.pair()

        let capturedAgent = Mutex<FoundationModelsAgent?>(nil)
        let agentConnection = await AgentSideConnection(stream: agentEnd) { connection in
            let agent = FoundationModelsAgent(
                connection: connection,
                provider: SessionProvider(makeSession: { _, _ in (sessionId, makeModelSession()) })
            )
            capturedAgent.withLock { $0 = agent }
            return agent
        }
        let client = await ClientSideConnection(stream: clientEnd) { _ in MinimalClient() }

        _ = try await client.initialize(endToEndInitializeRequest())
        _ = try await client.newSession(bridgeNewSessionRequest())

        let reply = "Folded reply."
        capturedAgent.withLock { $0 }?.enqueueScriptedTurn(for: sessionId) { deliver in
            await deliver([responseEntry(reply)])
            return Transcript(entries: [responseEntry(reply)])
        }

        // --- README example (client author) ----------------------------------
        let updates = client.updates(for: sessionId)
        _ = try await client.prompt(endToEndPromptRequest(text: "Say hello.", sessionId: sessionId))
        await client.close()
        await agentConnection.close()
        let transcript = await TranscriptBuilder.transcript(folding: updates)
        // ---------------------------------------------------------------------

        #expect(Array(transcript).count == 1)
    }
}
