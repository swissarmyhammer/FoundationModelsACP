import Foundation
import Testing

@testable import FoundationModelsACP

// MARK: - Helpers

/// One observable event of a role connection in these tests.
private enum CoreEvent: Equatable {
    /// The read loop started to wait for the role.
    case readLoopWaits
    /// The peer end received this frame.
    case frame(JSONValue)
    /// The peer end has no more frames.
    case endOfFrames
}

/// Encodes one `initialize` request frame with the given id.
///
/// - Parameter id: The JSON-RPC id of the request.
/// - Returns: The NDJSON frame.
/// - Throws: An encoding failure.
private func initializeFrame(id: Int) throws -> Data {
    try NDJSONCodec.encode(
        JSONValue.object([
            "jsonrpc": .string("2.0"),
            "id": .number(Double(id)),
            "method": .string("initialize"),
            "params": JSONValue.encode(result: handshakeInitializeRequest()),
        ])
    )
}

/// Gives each frame that `peer` receives to `events`, then `endOfFrames`.
///
/// One task reads the peer end for the full test. A second reader of the
/// same stream is not permitted.
///
/// - Parameters:
///   - peer: The raw end that the test plays.
///   - events: The continuation of the event stream of the test.
/// - Returns: The reader task.
private func forwardFrames(
    of peer: InMemoryTransport,
    to events: AsyncStream<CoreEvent>.Continuation
) -> Task<Void, Never> {
    Task {
        defer { events.yield(.endOfFrames) }
        do {
            for try await frame in NDJSONCodec.frames(from: peer.bytes, logger: .disabled) {
                if case .message(let value) = frame {
                    events.yield(.frame(value))
                }
            }
        } catch {
            return
        }
    }
}

/// Makes a role core that serves the agent side. Its role is a `String`, and
/// each request answers with the handler name and the role.
///
/// - Parameters:
///   - stream: The transport of the core.
///   - events: Gets `readLoopWaits` when the read loop waits for the role.
/// - Returns: The core, with no role set.
private func makeAgentCore(
    on stream: InMemoryTransport,
    events: AsyncStream<CoreEvent>.Continuation
) async -> RoleConnectionCore<String> {
    await RoleConnectionCore<String>(
        stream: stream,
        logger: .disabled,
        logPrefix: "InboundBeforeRoleTests: ",
        requestTimeout: nil,
        servedSide: .agent,
        peerSide: .client,
        dispatchRequest: { handler, _, role in
            .object(["handler": .string(handler), "role": .string(role)])
        },
        dispatchNotification: { _, _, _ in },
        onInboundWait: { events.yield(.readLoopWaits) }
    )
}

// MARK: - Tests

/// A frame that is in the transport before the role connection exists must
/// find the role. The read loop must not read it before `setRole`.
@Suite struct InboundBeforeRoleTests {
    /// The read loop waits for the role and reads no frame before it.
    ///
    /// The test is deterministic for both orders. When the read loop waits
    /// for the role, the first event is `readLoopWaits`, and no response
    /// can come before `setRole`. When the read loop dispatches before the
    /// role is set, it always writes a method-not-found response, and the
    /// wait hook never runs. Thus the first event is that response, and the
    /// test fails. The test uses no time limit and no timing loop.
    @Test func readLoopWaitsForTheRoleBeforeItReadsAFrame() async throws {
        let (peer, local) = InMemoryTransport.pair()
        defer {
            peer.close()
            local.close()
        }
        try await peer.write(initializeFrame(id: 1))

        let (events, emit) = AsyncStream<CoreEvent>.makeStream()
        let reader = forwardFrames(of: peer, to: emit)
        defer { reader.cancel() }
        let core = await makeAgentCore(on: local, events: emit)

        var iterator = events.makeAsyncIterator()
        // Stop at once on a failure: no later event comes to the waits below.
        try #require(await iterator.next() == .readLoopWaits)

        core.setRole("served-role", extensionHandlers: ExtensionHandlers())
        let response = await iterator.next()
        #expect(
            response
                == .frame(
                    .object([
                        "jsonrpc": .string("2.0"),
                        "id": .number(1),
                        "result": .object(["handler": .string("initialize"), "role": .string("served-role")]),
                    ])
                )
        )
        await core.close()
    }

    /// A close before the role is set ends the connection. The read loop
    /// reads no frame, so no response goes to the peer.
    @Test func closeBeforeTheRoleEndsTheConnectionWithNoResponse() async throws {
        let (peer, local) = InMemoryTransport.pair()
        defer { peer.close() }
        try await peer.write(initializeFrame(id: 1))

        let (events, emit) = AsyncStream<CoreEvent>.makeStream()
        let reader = forwardFrames(of: peer, to: emit)
        defer { reader.cancel() }
        let core = await makeAgentCore(on: local, events: emit)

        var iterator = events.makeAsyncIterator()
        // Stop at once on a failure: no later event comes to the waits below.
        try #require(await iterator.next() == .readLoopWaits)

        await core.close()
        guard case .closedLocally = await core.closed else {
            Issue.record("the close reason is not closedLocally")
            return
        }
        local.close()
        #expect(await iterator.next() == .endOfFrames)
    }

    /// The scenario of the bug report: the client wrote `initialize` before
    /// the agent connection existed. The agent of the factory serves it.
    ///
    /// This test is the end-to-end case only. It is not a regression guard:
    /// with the old order (dispatch before `setRole`) the result depends on
    /// a race, so this test can pass. The deterministic proof is
    /// `readLoopWaitsForTheRoleBeforeItReadsAFrame` and
    /// `closeBeforeTheRoleEndsTheConnectionWithNoResponse`.
    @Test func agentServesAnInitializeThatWasWrittenBeforeTheConnection() async throws {
        let (peer, local) = InMemoryTransport.pair()
        defer {
            peer.close()
            local.close()
        }
        try await peer.write(initializeFrame(id: 7))

        let (events, emit) = AsyncStream<CoreEvent>.makeStream()
        let reader = forwardFrames(of: peer, to: emit)
        defer { reader.cancel() }
        let connection = await AgentSideConnection(stream: local) { _ in StubAgent() }

        var iterator = events.makeAsyncIterator()
        guard case .frame(.object(let fields)) = await iterator.next() else {
            Issue.record("the agent sent no response")
            return
        }
        #expect(fields["id"] == .number(7))
        #expect(fields["error"] == nil)
        #expect(fields["result"] != nil)
        await connection.close()
    }
}
