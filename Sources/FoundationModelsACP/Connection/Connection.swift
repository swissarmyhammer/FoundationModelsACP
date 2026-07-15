import Foundation

/// Full-duplex JSON-RPC 2.0 engine over an `ACPTransport` (spec §5), porting
/// the classic Rust-SDK oneshot + pending-map design.
///
/// The actor holds a monotonic numeric request id and a
/// `[RequestID: continuation]` pending map. Every outgoing frame is produced
/// and written from actor-isolated methods, so no separate write queue is
/// needed — but actor reentrancy means two `transport.write` calls may
/// overlap across their suspensions, which is safe because `ACPTransport`
/// requires each `write` call to be atomic and concurrency-tolerant.
///
/// One read loop dispatches each inbound message by kind:
/// - **request** → handler → response keyed by `id`. Each inbound request runs
///   in its own `Task`, so a slow `session/prompt` never head-of-line-blocks
///   an incoming `session/cancel`, `request_permission`, or `fs/*` callback;
///   long-lived requests are just suspended continuations.
/// - **notification** → handler, awaited inline so notifications are observed
///   in arrival order (the `session/update` stream depends on this).
/// - **response** → resolves the pending continuation for that `id`.
///
/// Fail loud on disconnect: on EOF or stream error every pending continuation
/// is rejected with `ConnectionError.closed` — callers are never left hung.
public actor Connection {
    /// Handles one inbound request; the returned value becomes the response's
    /// `result`. Throw a `RequestError` to answer with a specific JSON-RPC
    /// error; any other thrown error answers `-32603` internal error.
    public typealias RequestHandler =
        @Sendable (_ method: String, _ params: JSONValue?) async throws -> JSONValue

    /// Handles one inbound notification. Awaited inline by the read loop, so
    /// implementations should return promptly (e.g. yield to an AsyncStream)
    /// to keep messages flowing.
    public typealias NotificationHandler =
        @Sendable (_ method: String, _ params: JSONValue?) async -> Void

    /// The JSON-RPC version stamped on every outbound envelope and required
    /// on every inbound one.
    private static let jsonrpcVersion: JSONValue = .string("2.0")

    /// Prefix applied to every diagnostic this connection logs.
    private static let logPrefix = "Connection: "

    /// One outbound request awaiting its response.
    private struct PendingRequest {
        /// Resumed with the response's `result`, or throwing on error.
        let continuation: CheckedContinuation<JSONValue, any Error>
        /// Rejects the request with `ConnectionError.timedOut` when it fires;
        /// cancelled as soon as the request resolves.
        let timeout: Task<Void, Never>?
    }

    private let transport: any ACPTransport
    private let logger: ACPLogger
    private let requestTimeout: Duration?
    private let requestHandler: RequestHandler?
    private let notificationHandler: NotificationHandler?

    /// Monotonic id for outbound requests.
    private var nextRequestID = 1
    /// Outbound requests awaiting a response, keyed by their wire id.
    private var pending: [RequestID: PendingRequest] = [:]
    /// In-flight inbound request handlers, cancelled on disconnect.
    private var inboundTasks: [Int: Task<Void, Never>] = [:]
    /// Monotonic key for `inboundTasks` entries.
    private var nextInboundKey = 0
    /// Set exactly once, by `shutDown()`, before pending requests are rejected.
    private var isClosed = false
    /// The read loop; cancelled by `close()`.
    private var readTask: Task<Void, Never>?

    /// Creates a connection and starts its read loop.
    ///
    /// - Parameters:
    ///   - transport: The bidirectional byte transport to run over.
    ///   - logger: Receives diagnostics for skipped messages and write
    ///     failures — never stdout.
    ///   - requestTimeout: Default timeout applied to every outbound request;
    ///     `nil` means requests wait indefinitely (long-lived calls like
    ///     `session/prompt` rely on this default).
    ///   - requestHandler: Handles inbound requests; when `nil`, every request
    ///     is answered with `-32601` method-not-found.
    ///   - notificationHandler: Handles inbound notifications; when `nil`,
    ///     notifications are dropped.
    public init(
        transport: any ACPTransport,
        logger: ACPLogger = .disabled,
        requestTimeout: Duration? = nil,
        requestHandler: RequestHandler? = nil,
        notificationHandler: NotificationHandler? = nil
    ) async {
        self.transport = transport
        self.logger = logger
        self.requestTimeout = requestTimeout
        self.requestHandler = requestHandler
        self.notificationHandler = notificationHandler
        readTask = Task { await self.readLoop() }
    }

    // MARK: - Outbound

    /// Sends one request and suspends until the peer responds.
    ///
    /// - Parameters:
    ///   - method: The JSON-RPC method name.
    ///   - params: The request parameters, passed through verbatim
    ///     (`_meta` and all).
    ///   - timeout: Overrides the connection's default request timeout when
    ///     non-`nil`.
    /// - Returns: The response's `result` value.
    /// - Throws: `RequestError` when the peer answers with an error;
    ///   `ConnectionError.closed` when the connection is (or becomes)
    ///   disconnected; `ConnectionError.timedOut` when the timeout fires;
    ///   `CancellationError` when the awaiting `Task` is cancelled.
    public func request(
        method: String,
        params: JSONValue? = nil,
        timeout: Duration? = nil
    ) async throws -> JSONValue {
        guard !isClosed else { throw ConnectionError.closed }
        let id: RequestID = .number(Double(nextRequestID))
        nextRequestID += 1
        var envelope: [String: JSONValue] = [
            "jsonrpc": Self.jsonrpcVersion,
            "id": id,
            "method": .string(method),
        ]
        envelope["params"] = params
        let frame = try NDJSONCodec.encode(JSONValue.object(envelope))
        let limit = timeout ?? requestTimeout

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // Pre-cancelled caller: onCancel already ran (finding nothing
                // to fail), so resume here or the caller hangs.
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                // The connection may have shut down during the suspension
                // points above; registering now would never be rejected.
                guard !isClosed else {
                    continuation.resume(throwing: ConnectionError.closed)
                    return
                }
                let timeoutTask = makeTimeoutTask(for: id, after: limit)
                pending[id] = PendingRequest(continuation: continuation, timeout: timeoutTask)
                // Write only after registering, so a response arriving
                // immediately always finds its continuation.
                Task { await self.write(frame, failing: id) }
            }
        } onCancel: {
            Task { await self.fail(id: id, with: CancellationError()) }
        }
    }

    /// Sends one notification; no response is expected.
    ///
    /// - Parameters:
    ///   - method: The JSON-RPC method name.
    ///   - params: The notification parameters, passed through verbatim.
    /// - Throws: `ConnectionError.closed` after disconnect; otherwise
    ///   rethrows transport write failures.
    public func notify(method: String, params: JSONValue? = nil) async throws {
        guard !isClosed else { throw ConnectionError.closed }
        var envelope: [String: JSONValue] = [
            "jsonrpc": Self.jsonrpcVersion,
            "method": .string(method),
        ]
        envelope["params"] = params
        try await transport.write(NDJSONCodec.encode(JSONValue.object(envelope)))
    }

    /// Shuts the connection down: rejects every pending request with
    /// `ConnectionError.closed`, cancels in-flight inbound handlers, and
    /// stops the read loop. Idempotent.
    public func close() {
        shutDown()
    }

    // MARK: - Read loop

    /// Consumes the transport's framed messages until EOF or stream failure,
    /// then fails loud: `shutDown()` rejects everything still pending.
    private func readLoop() async {
        do {
            for try await message in NDJSONCodec.messages(from: transport.bytes, logger: logger) {
                await dispatch(message)
            }
        } catch {
            log("transport stream failed: \(error)")
        }
        shutDown()
    }

    /// Routes one inbound message by kind: request, notification, response,
    /// or — failing all three — an invalid-request error / logged drop.
    ///
    /// - Parameter message: The decoded envelope.
    private func dispatch(_ message: JSONValue) async {
        guard case .object(let fields) = message else {
            log("dropping non-object message")
            return
        }
        let id = fields["id"]
        // The version check mirrors the write side, which stamps every
        // outgoing envelope with the version constant.
        guard fields["jsonrpc", default: .null] == Self.jsonrpcVersion else {
            log("rejecting message without jsonrpc 2.0 version")
            if fields["method"] != nil {
                // Request-shaped: JSON-RPC answers malformed requests -32600.
                await respondInvalidRequest(id: id)
            } else if let id, fields["result"] != nil || fields["error"] != nil {
                // Response-shaped: never answer a response — the id could
                // collide with one of the peer's own calls. Fail the awaiting
                // caller loud instead of leaving it hung (no-op if unknown).
                fail(id: id, with: RequestError.invalidRequest)
            }
            return
        }
        if case .string(let method) = fields["method", default: .null] {
            if let id {
                dispatchRequest(id: id, method: method, params: fields["params"])
            } else {
                await notificationHandler?(method, fields["params"])
            }
            return
        }
        if let id, fields["result"] != nil || fields["error"] != nil {
            resolve(id: id, fields: fields)
            return
        }
        if id != nil {
            await respondInvalidRequest(id: id)
        } else {
            log("dropping unclassifiable message")
        }
    }

    /// Answers `-32600` invalid request when the envelope carried an id;
    /// id-less envelopes get no reply, per JSON-RPC.
    ///
    /// - Parameter id: The offending envelope's wire id, if any.
    private func respondInvalidRequest(id: JSONValue?) async {
        guard let id else { return }
        await respond(id: id, outcome: .failure(.invalidRequest))
    }

    /// Runs one inbound request in its own `Task` so it never blocks the read
    /// loop, then sends the response keyed by the request's `id`.
    ///
    /// - Parameters:
    ///   - id: The request's wire id, echoed back verbatim on the response.
    ///   - method: The JSON-RPC method name.
    ///   - params: The request parameters, passed through verbatim.
    private func dispatchRequest(id: JSONValue, method: String, params: JSONValue?) {
        let key = nextInboundKey
        nextInboundKey += 1
        let handler = requestHandler
        inboundTasks[key] = Task {
            let outcome: Result<JSONValue, RequestError>
            do {
                guard let handler else { throw RequestError.methodNotFound(method) }
                outcome = .success(try await handler(method, params))
            } catch let error as RequestError {
                outcome = .failure(error)
            } catch {
                outcome = .failure(.internalError(detail: String(describing: error)))
            }
            await self.completeInbound(key: key, id: id, outcome: outcome)
        }
    }

    /// Retires one inbound handler task and sends its response, unless the
    /// connection shut down while the handler ran.
    ///
    /// - Parameters:
    ///   - key: The `inboundTasks` entry to retire.
    ///   - id: The request's wire id.
    ///   - outcome: The handler's result or typed error.
    private func completeInbound(
        key: Int,
        id: JSONValue,
        outcome: Result<JSONValue, RequestError>
    ) async {
        inboundTasks[key] = nil
        guard !isClosed else { return }
        await respond(id: id, outcome: outcome)
    }

    /// Writes one response envelope. Write failures are logged, not thrown —
    /// there is no caller left to reject, and disconnect handling belongs to
    /// the read loop.
    ///
    /// - Parameters:
    ///   - id: The request's wire id, echoed back verbatim.
    ///   - outcome: The `result` value or the `error` to report.
    private func respond(id: JSONValue, outcome: Result<JSONValue, RequestError>) async {
        var envelope: [String: JSONValue] = ["jsonrpc": Self.jsonrpcVersion, "id": id]
        switch outcome {
        case .success(let result):
            envelope["result"] = result
        case .failure(let error):
            envelope["error"] = error.wireValue
        }
        do {
            try await transport.write(NDJSONCodec.encode(JSONValue.object(envelope)))
        } catch {
            log("failed to write response: \(error)")
        }
    }

    /// Resolves the pending continuation for a response's `id`; responses for
    /// unknown ids (late after timeout, or spurious) are logged and dropped.
    ///
    /// - Parameters:
    ///   - id: The response's wire id.
    ///   - fields: The response envelope's members.
    private func resolve(id: JSONValue, fields: [String: JSONValue]) {
        guard let entry = pending.removeValue(forKey: id) else {
            log("dropping response for unknown id \(id)")
            return
        }
        entry.timeout?.cancel()
        // Tolerate peers that emit `"error": null` alongside a result.
        if let error = fields["error"], error != .null {
            entry.continuation.resume(throwing: RequestError(wire: error))
        } else {
            entry.continuation.resume(returning: fields["result", default: .null])
        }
    }

    // MARK: - Failure paths

    /// Emits one diagnostic with the connection's log prefix.
    ///
    /// - Parameter message: The diagnostic text, without prefix.
    private func log(_ message: String) {
        logger.log(Self.logPrefix + message)
    }

    /// Schedules the task that rejects request `id` with
    /// `ConnectionError.timedOut` after `limit` elapses.
    ///
    /// - Parameters:
    ///   - id: The pending entry to reject when the timeout fires.
    ///   - limit: The timeout, or `nil` for no timeout (returns `nil`).
    /// - Returns: The scheduled timeout task, or `nil` when unlimited.
    private func makeTimeoutTask(
        for id: RequestID,
        after limit: Duration?
    ) -> Task<Void, Never>? {
        guard let limit else { return nil }
        // Created in actor-isolated context, so the task inherits the actor
        // and `fail` is a synchronous same-actor call.
        return Task {
            try? await Task.sleep(for: limit)
            guard !Task.isCancelled else { return }
            self.fail(id: id, with: ConnectionError.timedOut)
        }
    }

    /// Writes one outbound request frame; a write failure rejects that
    /// request's pending continuation immediately.
    ///
    /// - Parameters:
    ///   - frame: The encoded request line.
    ///   - id: The pending entry to reject if the write fails.
    private func write(_ frame: Data, failing id: RequestID) async {
        do {
            try await transport.write(frame)
        } catch {
            fail(id: id, with: error)
        }
    }

    /// Rejects one pending request, if still pending; no-op otherwise, so
    /// timeout, cancellation, response, and disconnect can race safely.
    ///
    /// - Parameters:
    ///   - id: The pending entry's wire id.
    ///   - error: The error to throw to the awaiting caller.
    private func fail(id: RequestID, with error: any Error) {
        guard let entry = pending.removeValue(forKey: id) else { return }
        entry.timeout?.cancel()
        entry.continuation.resume(throwing: error)
    }

    /// Fails loud: marks the connection closed, rejects every pending
    /// request with `ConnectionError.closed`, cancels in-flight inbound
    /// handlers, and stops the read loop. Idempotent.
    private func shutDown() {
        guard !isClosed else { return }
        isClosed = true
        readTask?.cancel()
        readTask = nil
        let rejected = pending
        pending = [:]
        for entry in rejected.values {
            entry.timeout?.cancel()
            entry.continuation.resume(throwing: ConnectionError.closed)
        }
        let cancelled = inboundTasks
        inboundTasks = [:]
        for task in cancelled.values {
            task.cancel()
        }
    }
}
