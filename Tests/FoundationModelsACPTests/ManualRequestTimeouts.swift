import Synchronization

@testable import FoundationModelsACP

/// A request timeout scheduler that the test drives by hand, with no clock.
///
/// The connection gives each request that has a time limit to `scheduler`.
/// The scheduler keeps the limit and the `expire` closure, and does nothing
/// more. The test calls ``expireAll()`` to make each kept timeout fire.
/// `expireAll()` returns after the connection failed each request, and
/// tells which timeouts failed a request. The test requires that list
/// before it waits for the caller. Thus a broken timeout fails the test at
/// once, and the test does not wait for a caller that nothing resumes.
final class ManualRequestTimeouts: Sendable {
    /// One timeout that the connection started.
    private struct Timeout: Sendable {
        /// The time limit that the connection gave.
        let limit: Duration
        /// Fails the request with `ConnectionError.timedOut`, and returns
        /// `true` when the request waited.
        let expire: @Sendable () async -> Bool
    }

    /// The started timeouts that did not fire, in start order.
    private let started = Mutex<[Timeout]>([])

    /// The scheduler to give to the connection.
    var scheduler: Connection.RequestTimeoutScheduler {
        { [self] limit, expire in
            self.started.withLock { $0.append(Timeout(limit: limit, expire: expire)) }
            return Task {}
        }
    }

    /// Opens a connection that starts its request timeouts with `scheduler`.
    ///
    /// - Parameters:
    ///   - transport: The transport to run over.
    ///   - requestTimeout: The default timeout of each outbound request;
    ///     `nil` waits forever.
    /// - Returns: The connection.
    func connection(over transport: any ACPTransport, requestTimeout: Duration? = nil) async -> Connection {
        await Connection(
            transport: transport,
            logger: .disabled,
            requestTimeout: requestTimeout,
            requestHandler: nil,
            notificationHandler: nil,
            onClose: nil,
            outgoingRequests: OutgoingRequestTracker(),
            scheduleRequestTimeout: scheduler
        )
    }

    /// Opens a client connection that starts its request timeouts with
    /// `scheduler`.
    ///
    /// - Parameters:
    ///   - stream: The transport to run over.
    ///   - requestTimeout: The default timeout of each outbound request;
    ///     `nil` waits forever.
    ///   - factory: Builds the client from the connection.
    /// - Returns: The client connection.
    func clientConnection(
        over stream: any ACPTransport,
        requestTimeout: Duration?,
        _ factory: @Sendable (ClientSideConnection) -> any Client
    ) async -> ClientSideConnection {
        await ClientSideConnection(
            stream: stream,
            logger: .disabled,
            requestTimeout: requestTimeout,
            bufferLimits: .default,
            scheduleRequestTimeout: scheduler,
            factory
        )
    }

    /// Makes each started timeout fire, in start order, and forgets it.
    ///
    /// - Returns: The time limit of each timeout that failed a request that
    ///   waited, in start order. A timeout of a request that ended before is
    ///   not in the list.
    @discardableResult
    func expireAll() async -> [Duration] {
        let timeouts = started.withLock { timeouts in
            defer { timeouts = [] }
            return timeouts
        }
        var failed: [Duration] = []
        for timeout in timeouts {
            if await timeout.expire() {
                failed.append(timeout.limit)
            }
        }
        return failed
    }
}
