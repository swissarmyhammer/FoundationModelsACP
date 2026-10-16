import Foundation
import Synchronization
import Testing

@testable import FoundationModelsACP

/// Holds the outbound request work of a connection, so that a test runs each
/// unit in a fixed order.
private final class HeldRequestWork: Sendable {
    /// One element for each unit of work that the connection gives.
    let arrivals: AsyncStream<Void>
    private let arrival: AsyncStream<Void>.Continuation
    private let held = Mutex<[@Sendable () async -> Void]>([])

    init() {
        (arrivals, arrival) = AsyncStream.makeStream()
    }

    /// The scheduler to give to the connection. It holds each unit of work.
    var scheduler: Connection.RequestWorkScheduler {
        { work in
            self.held.withLock { $0.append(work) }
            self.arrival.yield()
        }
    }

    /// Removes the oldest unit of work that is held.
    ///
    /// - Returns: The unit, or `nil` when no unit is held.
    func take() -> (@Sendable () async -> Void)? {
        held.withLock { $0.isEmpty ? nil : $0.removeFirst() }
    }

    /// Ends `arrivals`, so that a wait for a unit of work ends.
    func finish() {
        arrival.finish()
    }
}

/// A transport that keeps each frame that it writes, in the order in which
/// each write ends. It holds the write of a request with ``heldMethod`` until
/// the test calls ``release()``.
private final class HeldWriteTransport: ACPTransport {
    /// The method of the request whose write waits for ``release()``.
    static let heldMethod = "test/held"

    let bytes: AsyncThrowingStream<Data, any Error>
    private let input: AsyncThrowingStream<Data, any Error>.Continuation
    /// One element when the held write starts.
    let entries: AsyncStream<Void>
    private let entry: AsyncStream<Void>.Continuation
    private let state = Mutex(State())

    private struct State {
        var frames: [JSONValue] = []
        var released = false
        var waiter: CheckedContinuation<Void, Never>?
    }

    init() {
        (bytes, input) = AsyncThrowingStream.makeStream()
        (entries, entry) = AsyncStream.makeStream()
    }

    /// The frames whose write ended, in the order in which each write ended.
    var frames: [JSONValue] {
        state.withLock { $0.frames }
    }

    func write(_ data: Data) async throws {
        let frame = try JSONDecoder().decode(JSONValue.self, from: data)
        if case .object(let fields) = frame, fields["method"] == .string(Self.heldMethod), fields["id"] != nil {
            entry.yield()
            await withCheckedContinuation { continuation in
                let resumeNow = state.withLock { state in
                    if state.released { return true }
                    state.waiter = continuation
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        }
        state.withLock { $0.frames.append(frame) }
    }

    /// Lets the held write end.
    func release() {
        let waiter = state.withLock { state in
            state.released = true
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume()
    }

    /// Ends `entries`, so that a wait for the held write ends.
    func finishEntries() {
        entry.finish()
    }

    /// Ends the incoming bytes, so that the read loop of the connection ends.
    func finishInput() {
        input.finish()
    }
}

/// Rule R2 of the elicitation plan: a connection writes no request after its
/// own cancel.
///
/// The connection gets a scheduler that holds its request work. Each test
/// runs the frame write and the cancel work in a fixed order, and awaits each
/// unit to its end. No test uses a clock, a sleep, a poll, a retry or a time
/// limit.
@Suite struct RequestCancelOrderTests {
    /// A connection over `transport` whose request work `work` holds.
    ///
    /// - Parameters:
    ///   - transport: The transport of the connection.
    ///   - work: Holds the request work.
    /// - Returns: The connection.
    private static func connection(
        over transport: HeldWriteTransport, work: HeldRequestWork
    ) async -> Connection {
        await Connection(
            transport: transport,
            logger: .disabled,
            requestTimeout: nil,
            requestHandler: nil,
            notificationHandler: nil,
            onClose: nil,
            outgoingRequests: OutgoingRequestTracker(),
            scheduleRequestWork: work.scheduler
        )
    }

    /// Starts a request with `method`. The task ends `work.arrivals` when the
    /// request ends, so that a wait for request work also ends then.
    ///
    /// - Parameters:
    ///   - connection: The connection that sends the request.
    ///   - method: The method of the request.
    ///   - work: Holds the request work.
    /// - Returns: The task of the caller.
    private static func startRequest(
        on connection: Connection, method: String, work: HeldRequestWork
    ) -> Task<JSONValue, any Error> {
        Task {
            defer { work.finish() }
            return try await connection.request(method: method, params: nil, timeout: nil, onResult: nil)
        }
    }

    /// Closes the connection and ends the transport input.
    ///
    /// - Parameters:
    ///   - connection: The connection to close.
    ///   - transport: Its transport.
    private static func tearDown(_ connection: Connection, _ transport: HeldWriteTransport) async {
        await connection.close()
        transport.release()
        transport.finishEntries()
        transport.finishInput()
    }

    /// The method of each frame, with `$/cancel_request` for a cancel.
    ///
    /// - Parameter frames: The written frames.
    /// - Returns: The method of each frame, in write order.
    private static func methods(_ frames: [JSONValue]) -> [String] {
        frames.map { frame in
            guard case .object(let fields) = frame, case .string(let method)? = fields["method"] else { return "?" }
            return method
        }
    }

    /// A cancel before the frame write starts: the connection writes neither
    /// the request nor its `$/cancel_request`, and the caller gets
    /// `CancellationError`.
    @Test func cancelBeforeTheFrameWriteWritesNoFrame() async throws {
        let transport = HeldWriteTransport()
        let work = HeldRequestWork()
        let connection = await Self.connection(over: transport, work: work)
        var arrivals = work.arrivals.makeAsyncIterator()
        let caller = Self.startRequest(on: connection, method: "test/ask", work: work)

        do {
            try #require(await arrivals.next() != nil)
            let frameWrite = try #require(work.take())
            caller.cancel()
            try #require(await arrivals.next() != nil)
            let cancelWork = try #require(work.take())

            await cancelWork()
            await #expect(throws: CancellationError.self) { try await caller.value }
            await frameWrite()

            #expect(Self.methods(transport.frames) == [])
        } catch {
            caller.cancel()
            await Self.tearDown(connection, transport)
            throw error
        }
        await Self.tearDown(connection, transport)
    }

    /// A cancel while the frame write is in progress: the connection writes
    /// the `$/cancel_request` only after the request frame.
    @Test func cancelDuringTheFrameWriteIsWrittenAfterTheRequest() async throws {
        let transport = HeldWriteTransport()
        let work = HeldRequestWork()
        let connection = await Self.connection(over: transport, work: work)
        var arrivals = work.arrivals.makeAsyncIterator()
        var entries = transport.entries.makeAsyncIterator()
        let caller = Self.startRequest(on: connection, method: HeldWriteTransport.heldMethod, work: work)

        do {
            try #require(await arrivals.next() != nil)
            let frameWrite = try #require(work.take())
            let writing = Task {
                await frameWrite()
                transport.finishEntries()
            }
            try #require(await entries.next() != nil)
            caller.cancel()
            try #require(await arrivals.next() != nil)
            let cancelWork = try #require(work.take())

            await cancelWork()
            await #expect(throws: CancellationError.self) { try await caller.value }
            transport.release()
            await writing.value

            #expect(Self.methods(transport.frames) == [HeldWriteTransport.heldMethod, "$/cancel_request"])
        } catch {
            caller.cancel()
            await Self.tearDown(connection, transport)
            throw error
        }
        await Self.tearDown(connection, transport)
    }

    /// A cancel after the frame write: the connection writes the
    /// `$/cancel_request` at once.
    @Test func cancelAfterTheFrameWriteIsWrittenAtOnce() async throws {
        let transport = HeldWriteTransport()
        let work = HeldRequestWork()
        let connection = await Self.connection(over: transport, work: work)
        var arrivals = work.arrivals.makeAsyncIterator()
        let caller = Self.startRequest(on: connection, method: "test/ask", work: work)

        do {
            try #require(await arrivals.next() != nil)
            let frameWrite = try #require(work.take())
            await frameWrite()
            caller.cancel()
            try #require(await arrivals.next() != nil)
            let cancelWork = try #require(work.take())

            await cancelWork()
            await #expect(throws: CancellationError.self) { try await caller.value }

            #expect(Self.methods(transport.frames) == ["test/ask", "$/cancel_request"])
        } catch {
            caller.cancel()
            await Self.tearDown(connection, transport)
            throw error
        }
        await Self.tearDown(connection, transport)
    }
}
