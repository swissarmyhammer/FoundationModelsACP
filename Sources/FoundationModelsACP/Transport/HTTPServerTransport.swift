import Foundation
import Network
import Synchronization

/// An ACP v2 over HTTP server: it listens on a port and gives the host one
/// ``HTTPConnectionTransport`` for each ACP connection that a client opens.
///
/// ACP over HTTP is not a standard yet, so the wire of this transport is
/// its own, and it stays behind ``ACPTransport``. A client speaks it in
/// three requests:
///
/// - `POST` with one JSON-RPC message as the body. A `POST` of `initialize`
///   with no `Acp-Connection-Id` header opens a connection; the `202`
///   response carries the new `Acp-Connection-Id`. Each later request must
///   carry that header and the same `Authorization` header as the
///   `initialize`, and each `POST` gets `202` when its message reached the
///   connection.
/// - `GET` opens the one agent-to-client stream of the connection: a
///   chunked `application/x-ndjson` response with one chunk for each
///   message, in the order that the agent wrote them. The JSON-RPC response
///   to each request comes on this stream, so the order of the wire is
///   kept. Messages that the agent writes before the `GET` wait for it.
/// - `DELETE` ends the connection.
///
/// A request with no `Acp-Connection-Id` that is not a `POST` of
/// `initialize` gets `400`; an id that names no open connection gets `404`;
/// a request with another bearer token than the `initialize` gets `403`. A
/// client sends its `POST` requests one after the other, so that they reach
/// the agent in order.
///
/// The server gives the host the id and the bearer token of each
/// connection in ``HTTPConnectionTransport/connectionInfo``, and
/// `AgentSideConnection` gives them to the agent. The server does not judge
/// the token: the host decides the trust of each connection from it.
///
/// ```swift
/// let server = try HTTPServerTransport(port: 8080)
/// _ = try await server.start()
/// for await transport in server.connections {
///     let connection = await AgentSideConnection(stream: transport) { connection in
///         MyAgent(connection: connection, token: connection.connectionInfo?.bearerToken)
///     }
///     keep(connection)
/// }
/// ```
public final class HTTPServerTransport: Sendable {
    /// The header that names the connection of a request.
    public static let connectionIdHeader = "Acp-Connection-Id"

    /// Each connection that a client opened, in order. The stream finishes
    /// when the server stops.
    public var connections: AsyncStream<HTTPConnectionTransport> { router.connections }

    /// The connection table.
    private let router: HTTPConnectionRouter

    /// The listening socket.
    private let listener: NWListener

    /// The queue of the Network callbacks of the listener and its sockets.
    private let queue = DispatchQueue(label: "FoundationModelsACP.HTTPServerTransport")

    /// The diagnostic sink.
    private let logger: ACPLogger

    /// The task of each open socket, so that ``stop()`` can end it.
    private let sockets = Mutex(OpenSockets())

    /// Creates a server that listens when ``start()`` runs.
    ///
    /// - Parameters:
    ///   - port: The port to listen on; `.any` gives a free port, which
    ///     ``start()`` returns.
    ///   - parameters: The protocol stack. The default is plain TCP; give
    ///     TLS options here to serve HTTPS.
    ///   - logger: Diagnostic sink; it never gets a bearer token.
    /// - Throws: An `NWError` when the parameters cannot listen on `port`.
    public init(port: NWEndpoint.Port = .any, parameters: NWParameters = .tcp, logger: ACPLogger = .disabled) throws {
        listener = try NWListener(using: parameters, on: port)
        router = HTTPConnectionRouter(logger: logger)
        self.logger = logger
    }

    /// Starts to listen, and waits until the port is ready.
    ///
    /// - Returns: The port that the server listens on.
    /// - Throws: An `NWError` when the listener fails, or
    ///   ``StoppedError`` when ``stop()`` ran first.
    public func start() async throws -> NWEndpoint.Port {
        listener.newConnectionHandler = { [weak self] socket in
            self?.accept(socket)
        }
        let ready = OneShot<NWEndpoint.Port>()
        listener.stateUpdateHandler = { [listener, logger] state in
            switch state {
            case .ready:
                ready.resume(with: listener.port.map(Result.success) ?? .failure(StoppedError()))
            case .failed(let error):
                logger.log("HTTPServerTransport: the listener failed: \(error)")
                ready.resume(with: .failure(error))
            case .cancelled:
                ready.resume(with: .failure(StoppedError()))
            case .setup, .waiting:
                break
            @unknown default:
                break
            }
        }
        return try await ready.wait { listener.start(queue: queue) }
    }

    /// Stops to listen, and ends each connection and each socket.
    ///
    /// ``connections`` finishes. Idempotent.
    public func stop() {
        listener.cancel()
        router.closeAll()
        let tasks = sockets.withLock { sockets in
            sockets.isStopped = true
            return Array(sockets.tasks.values)
        }
        for task in tasks {
            task.cancel()
        }
    }

    /// Thrown by ``start()`` when the server stopped before it was ready.
    public struct StoppedError: Error, Equatable {}

    /// Serves one socket of a client until it closes.
    ///
    /// - Parameter socket: The new socket.
    private func accept(_ socket: NWConnection) {
        let session = HTTPSocketSession(socket: socket, router: router, queue: queue, logger: logger)
        sockets.withLock { sockets in
            guard !sockets.isStopped else {
                socket.cancel()
                return
            }
            let key = sockets.nextKey
            sockets.nextKey += 1
            sockets.tasks[key] = Task { [weak self] in
                await session.serve()
                self?.sockets.withLock { _ = $0.tasks.removeValue(forKey: key) }
            }
        }
    }
}

/// The open sockets of a server.
private struct OpenSockets {
    /// The key of the next socket.
    var nextKey: UInt64 = 0

    /// The task that serves each open socket.
    var tasks: [UInt64: Task<Void, Never>] = [:]

    /// Whether the server stopped; then it serves no new socket.
    var isStopped = false
}

/// A continuation that resumes one time, from whichever callback comes
/// first.
private final class OneShot<Value: Sendable>: Sendable {
    /// The waiting continuation, until it resumes.
    private let continuation = Mutex<CheckedContinuation<Value, any Error>?>(nil)

    /// Suspends until ``resume(with:)``.
    ///
    /// - Parameter start: Starts the work whose callback resumes the wait.
    /// - Returns: The value of the first ``resume(with:)``.
    /// - Throws: The error of the first ``resume(with:)``.
    func wait(_ start: () -> Void) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation.withLock { $0 = continuation }
            start()
        }
    }

    /// Resumes the wait; a later call has no effect.
    ///
    /// - Parameter result: The result of the wait.
    func resume(with result: Result<Value, any Error>) {
        continuation.withLock { continuation in
            continuation?.resume(with: result)
            continuation = nil
        }
    }
}

/// One TCP socket of a client: it reads requests, sends each to the router,
/// and writes the responses or the agent-to-client stream.
private final class HTTPSocketSession: Sendable {
    /// The most bytes that one read takes.
    private static let readSize = 64 * 1024

    /// The socket.
    private let socket: NWConnection

    /// The connection table.
    private let router: HTTPConnectionRouter

    /// The queue of the Network callbacks.
    private let queue: DispatchQueue

    /// The diagnostic sink.
    private let logger: ACPLogger

    /// Creates the session of a new socket.
    ///
    /// - Parameters:
    ///   - socket: The socket.
    ///   - router: The connection table.
    ///   - queue: The queue of the Network callbacks.
    ///   - logger: The diagnostic sink.
    init(socket: NWConnection, router: HTTPConnectionRouter, queue: DispatchQueue, logger: ACPLogger) {
        self.socket = socket
        self.router = router
        self.queue = queue
        self.logger = logger
    }

    /// Serves the socket until the client closes it, a request does not
    /// parse, its agent-to-client stream ends, or the task is cancelled.
    func serve() async {
        socket.start(queue: queue)
        await withTaskCancellationHandler {
            do {
                try await serveRequests()
            } catch {
                logger.log("HTTPServerTransport: a socket ended: \(error)")
            }
        } onCancel: {
            socket.cancel()
        }
        socket.cancel()
    }

    /// Reads and answers requests until the socket ends or a stream opens.
    ///
    /// - Throws: A Network error when a read or a write fails.
    private func serveRequests() async throws {
        var parser = HTTPRequestParser()
        while let chunk = try await read() {
            let requests: [HTTPRequest]
            do {
                requests = try parser.append(chunk)
            } catch {
                try await write(error.response.serialized())
                return
            }
            for request in requests {
                switch router.route(request) {
                case .respond(let response):
                    try await write(response.serialized())
                case .stream(let connection):
                    await stream(connection)
                    return
                }
            }
        }
    }

    /// Sends the agent-to-client messages of a connection until the
    /// connection or the socket ends. The end of one ends the other.
    ///
    /// - Parameter connection: The connection whose messages to send.
    private func stream(_ connection: HTTPConnectionTransport) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await self.send(connection)
                self.socket.cancel()
            }
            group.addTask {
                await self.waitForEnd()
                connection.close()
            }
        }
    }

    /// Writes the chunked response of the messages of a connection.
    ///
    /// - Parameter connection: The connection whose messages to send.
    private func send(_ connection: HTTPConnectionTransport) async {
        do {
            try await write(HTTPResponse.streamHead)
            for await message in connection.outgoing {
                try await write(HTTPResponse.chunk(message))
            }
            try await write(HTTPResponse.lastChunk)
        } catch {
            logger.log("HTTPServerTransport: the stream of a connection ended: \(error)")
            connection.close()
        }
    }

    /// Reads, and drops, the bytes of the client until the socket ends.
    private func waitForEnd() async {
        while (try? await read()) != nil {}
    }

    /// Reads the next bytes of the client.
    ///
    /// - Returns: The bytes, or `nil` when the client closed the socket.
    /// - Throws: A Network error when the socket failed or was cancelled.
    private func read() async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            socket.receive(minimumIncompleteLength: 1, maximumLength: Self.readSize) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(returning: isComplete ? nil : Data())
                }
            }
        }
    }

    /// Writes bytes to the client.
    ///
    /// - Parameter data: The bytes.
    /// - Throws: A Network error when the write fails.
    private func write(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            socket.send(
                content: data,
                completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            )
        }
    }
}
