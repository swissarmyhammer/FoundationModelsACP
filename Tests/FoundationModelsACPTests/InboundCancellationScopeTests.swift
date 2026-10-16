import Foundation
import Testing

@testable import FoundationModelsACP

/// What a task that a handler started read after the handler ended.
private struct LateRead: Sendable {
    let meta: JSONValue?
    let byPeer: Bool
}

/// The scope of `Connection.cancelRequestMeta` and
/// `Connection.cancelledByPeer`: a task that a handler starts inherits the
/// cancel box of the request, but after the handler ends, the box gives
/// `nil` and `false`.
///
/// Each step waits for a stream element or a wire frame that the step before
/// it causes. Each wait also ends when its stream ends. No test uses a clock,
/// a sleep, a poll, a retry or a time limit.
@Suite struct InboundCancellationScopeTests {
    /// The `_meta` of the `$/cancel_request` that the peer sends.
    private static let cancelMeta: JSONValue = .object([
        CancelRequestNotification.reasonMetaKey: .string("run cancelled")
    ])

    /// A handler starts a task, and the peer cancels the request with a
    /// `_meta`. The handler reads the cancel. The task reads only after the
    /// response of the request is on the wire, and it reads `nil` and
    /// `false`.
    @Test func aTaskThatTheHandlerStartsReadsNoCancelAfterTheHandlerEnds() async throws {
        let (agentEnd, peerEnd) = InMemoryTransport.pair()
        let entered = AsyncStream<LateRead>.makeStream()
        let readNow = AsyncStream<Void>.makeStream()
        let lateRead = AsyncStream<LateRead>.makeStream()
        let never = AsyncStream<Void>.makeStream()

        let connection = await Connection(
            transport: agentEnd,
            requestHandler: { _, _ in
                let started = Task {
                    defer { lateRead.continuation.finish() }
                    var gate = readNow.stream.makeAsyncIterator()
                    _ = await gate.next()
                    lateRead.continuation.yield(
                        LateRead(meta: Connection.cancelRequestMeta, byPeer: Connection.cancelledByPeer))
                }
                _ = started
                entered.continuation.yield(LateRead(meta: nil, byPeer: false))
                // Ends when the task is cancelled: by the peer, or by a close.
                for await _ in never.stream {}
                entered.continuation.yield(
                    LateRead(meta: Connection.cancelRequestMeta, byPeer: Connection.cancelledByPeer))
                entered.continuation.finish()
                throw CancellationError()
            },
            // A close before the handler starts also ends the wait of the
            // test for the first event.
            onClose: { entered.continuation.finish() }
        )
        let reader = WireReader(peerEnd)

        do {
            var events = entered.stream.makeAsyncIterator()
            try await send(RawPeerEnvelope.request(id: .number(1), method: "test/wait", params: .null), over: peerEnd)
            try #require(await events.next() != nil)
            try await send(
                notificationEnvelope(
                    method: "$/cancel_request",
                    params: .object(["requestId": .number(1), "_meta": Self.cancelMeta])),
                over: peerEnd)
            let inHandler = try #require(await events.next())
            #expect(inHandler.meta == Self.cancelMeta)
            #expect(inHandler.byPeer)

            let response = try #require(try await reader.next())
            #expect(requestID(of: response) == .number(1))

            readNow.continuation.yield()
            var late = lateRead.stream.makeAsyncIterator()
            let afterHandler = try #require(await late.next())
            #expect(afterHandler.meta == nil)
            #expect(!afterHandler.byPeer)
        } catch {
            await connection.close()
            readNow.continuation.finish()
            peerEnd.close()
            throw error
        }
        await connection.close()
        readNow.continuation.finish()
        peerEnd.close()
    }
}
