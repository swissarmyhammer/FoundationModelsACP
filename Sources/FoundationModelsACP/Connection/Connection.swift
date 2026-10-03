import Foundation
import Synchronization

/// Work an inbound request handler defers until after this connection has
/// written that request's response — never before, so a handler that sends
/// an outbound notification this way cannot have it race the response it
/// logically follows. `AgentSideConnection.afterRespondingToCurrentRequest(_:)`
/// is the public entry point; `Connection` only owns the collector and the
/// task-local that locates the right one (see `Connection.currentResponseHooks`).
///
/// A plain class guarded by a lock rather than an actor: registration must be
/// synchronous, with no `await` between "the handler decides to defer work"
/// and "the work is recorded" — an actor hop there would reopen a scheduling
/// gap of exactly the kind this type exists to close.
///
/// A task that the handler starts inherits the task-local, and thus keeps
/// this object for its full life. Thus, this object keeps a closure only
/// until the closures run or are discarded. After that, it keeps no closure:
/// `append` drops the closure and logs a warning, because no response
/// follows and the closure can never run.
final class ResponseHooks: Sendable {
    /// One deferred closure.
    typealias Work = @Sendable () async -> Void

    /// Why the collector keeps no more closures.
    private enum ClosingReason {
        /// `runAll()` took the closures, after the response was written.
        case ran

        /// `discardAll()` released the closures, because the connection
        /// wrote no response.
        case discarded
    }

    /// The life cycle of the collector.
    private enum Phase {
        /// The handler can still defer work. The closures wait for the
        /// response, in registration order.
        case collecting([Work])

        /// The closures were taken. The collector keeps no closure.
        case closed(ClosingReason)
    }

    /// The guarded phase. A closure is in it only while the phase is
    /// `collecting`.
    private let phase = Mutex(Phase.collecting([]))

    /// Gets the warning for a closure that comes too late.
    private let logger: ACPLogger

    /// The wire id of the request that the hooks follow. The warning names
    /// it.
    private let requestId: RequestId

    /// Makes an empty collector for one inbound request.
    ///
    /// - Parameters:
    ///   - logger: The connection logger. It gets the warning for a closure
    ///     that comes after the closures ran or were discarded.
    ///   - requestId: The wire id of the request that the hooks follow.
    init(logger: ACPLogger, requestId: RequestId) {
        self.logger = logger
        self.requestId = requestId
    }

    /// Registers one closure to run after the current response is written.
    ///
    /// After `runAll()` or `discardAll()`, the method does not keep the
    /// closure. It drops the closure and logs a warning.
    ///
    /// - Parameter work: The deferred work, run once this request's response
    ///   has been handed to the transport.
    func append(_ work: @escaping Work) {
        let closingReason: ClosingReason? = phase.withLock { phase in
            switch phase {
            case .collecting(var pending):
                pending.append(work)
                phase = .collecting(pending)
                return nil
            case .closed(let reason):
                return reason
            }
        }
        guard let closingReason else { return }
        logger.log(Connection.logPrefix + dropWarning(for: closingReason))
    }

    /// Takes every registered closure and clears them in the same lock, then
    /// runs them in registration order, awaiting each before starting the
    /// next. After this call starts, the collector keeps no closure.
    func runAll() async {
        for item in take(closingAs: .ran) {
            await item()
        }
    }

    /// Releases every registered closure and does not run them. The
    /// connection calls this when it wrote no response, so the closures can
    /// never run.
    func discardAll() {
        _ = take(closingAs: .discarded)
    }

    /// Takes the registered closures and closes the collector in one lock.
    ///
    /// - Parameter reason: Why the collector closes.
    /// - Returns: The closures that were waiting, in registration order. The
    ///   result is empty when the collector closed before.
    private func take(closingAs reason: ClosingReason) -> [Work] {
        phase.withLock { phase in
            guard case .collecting(let pending) = phase else { return [] }
            phase = .closed(reason)
            return pending
        }
    }

    /// The warning for a closure that came after the collector closed.
    ///
    /// - Parameter closingReason: Why the collector closed.
    /// - Returns: The warning text, without the log prefix.
    private func dropWarning(for closingReason: ClosingReason) -> String {
        let cause =
            switch closingReason {
            case .ran:
                "the response was written and the deferred work already ran"
            case .discarded:
                "the connection wrote no response"
            }
        return "dropped work deferred for request \(requestId): \(cause); "
            + "defer work from the request handler before it returns"
    }
}

extension Connection {
    /// The response-hooks collector for the request currently being handled
    /// on this task, if any.
    ///
    /// Set by `dispatchRequest` around the handler invocation, so any code the
    /// handler calls — however many `await`s deep, as long as it stays on this
    /// same task rather than an unrelated one — can register deferred work
    /// without this connection threading a request id through every layer of
    /// dispatch just to let one handler find its own request back again.
    @TaskLocal static var currentResponseHooks: ResponseHooks?
}

/// Failures raised locally by `Connection`, never received from the peer.
public enum ConnectionError: Error, Hashable, Sendable {
    /// The transport reached EOF or failed, or the connection was closed;
    /// every pending request is rejected with this error (spec §5:
    /// fail loud on disconnect, never hang callers).
    case closed

    /// The per-request timeout elapsed before the peer answered.
    case timedOut
}

/// Full-duplex JSON-RPC 2.0 engine over an `ACPTransport` (spec §5).
///
/// The actor holds a monotonic numeric request id and a
/// `[RequestId: continuation]` pending map. Every outgoing frame is produced
/// and written from actor-isolated methods, so no separate write queue is
/// needed — but actor reentrancy means two `transport.write` calls may
/// overlap across their suspensions, which is safe because `ACPTransport`
/// requires each `write` call to be atomic and concurrency-tolerant.
///
/// One read loop dispatches each inbound message by kind:
/// - **request** → handler → response keyed by `id`. Each inbound request runs
///   in its own `Task`, so a slow `session/prompt` never head-of-line-blocks
///   an incoming `session/cancel`, `$/cancel_request`, or a reverse call;
///   long-lived requests (`session/request_permission`) are just suspended
///   continuations.
/// - **notification** → handler, awaited inline so notifications are observed
///   in arrival order (the `session/update` stream depends on this). Once
///   dispatched, this connection makes no further ordering claim — a handler
///   that itself reorders or buffers updates must correlate by `messageId` /
///   `toolCallId` / `terminalId`, never by delivery order.
/// - **response** → resolves the pending continuation for that `id`.
/// - **`$/cancel_request`** → protocol-level, handled here rather than routed
///   to either role: cancels the named request's in-flight inbound `Task`, if
///   still running.
/// - **batch** (a JSON array of the above) → every item dispatches exactly as
///   it would at the top level, except responses owed to items in the batch
///   are collected and written back as a single batch-response array, once
///   every owed response has resolved.
/// - **malformed line** (valid framing, invalid JSON) → answered with a
///   `-32700` parse-error response, `id: null`; the read loop keeps going.
///
/// Fail loud on disconnect: on EOF or stream error every pending continuation
/// is rejected with `ConnectionError.closed` — callers are never left hung.
/// After that, and after each inbound handler ended, `closed` gives the
/// close reason to each task that waits for it.
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

    /// The JSON-RPC envelope's `jsonrpc` member key, shared by every read
    /// site that checks the version and every write site that stamps it, so
    /// this file states the field name once rather than repeating the
    /// literal.
    private static let jsonrpcKey = "jsonrpc"

    /// The JSON-RPC envelope's `id` member key, shared by every read site
    /// that extracts it and every write site that stamps it, so this file
    /// states the field name once rather than repeating the literal.
    private static let idKey = "id"

    /// The JSON-RPC envelope's `method` member key, shared by every read
    /// site that extracts it and every write site that stamps it, so this
    /// file states the field name once rather than repeating the literal.
    private static let methodKey = "method"

    /// The JSON-RPC envelope's `params` member key, shared by every read
    /// site that extracts it and every write site that stamps it, so this
    /// file states the field name once rather than repeating the literal.
    private static let paramsKey = "params"

    /// Prefix applied to every diagnostic this connection logs. `ResponseHooks`
    /// in this file uses it too, because it logs for the connection.
    fileprivate static let logPrefix = "Connection: "

    /// The wire method name for `$/cancel_request`, read from the generated
    /// routing table rather than hardcoded, so this file never restates a
    /// wire string the schema already owns.
    private static let cancelRequestMethod: String = {
        guard let entry = ACPMethodTable.methods.first(where: { $0.side == .protocolLevel }) else {
            preconditionFailure("ACPMethodTable has no protocol-level entry for $/cancel_request")
        }
        return entry.wireMethod
    }()

    /// The JSON-RPC envelope's `error` member key, shared by every read site
    /// that checks for it and every write site that sets it, so this file
    /// states the field name once rather than repeating the literal.
    private static let errorKey = "error"

    /// The JSON-RPC envelope's `result` member key, shared by every read
    /// site that checks for it and every write site that sets it, so this
    /// file states the field name once rather than repeating the literal.
    private static let resultKey = "result"

    /// The `$/cancel_request` notification's `requestId` field key, shared by
    /// the read side (`handleCancelRequest`) and the write side
    /// (`cancelOutbound`) so both agree on the same field name.
    private static let requestIdKey = "requestId"

    /// One outbound request awaiting its response.
    private struct PendingRequest {
        /// Resumed with the response's `result`, or throwing on error.
        let continuation: CheckedContinuation<JSONValue, any Error>
        /// Rejects the request with `ConnectionError.timedOut` when it fires;
        /// cancelled as soon as the request resolves.
        let timeout: Task<Void, Never>?
    }

    /// One in-flight batch call's response collector: how many owed responses
    /// remain, and the responses collected so far, in completion order (batch
    /// responses need not preserve request order — see spec §5, upsert
    /// correlation is always by id, never by arrival or send order).
    private struct BatchState {
        var remaining: Int
        var results: [JSONValue] = []
    }

    /// Invoked once when the connection shuts down, after every pending
    /// request is rejected. Upper layers use this disconnect signal to finish
    /// streams they derive from the connection (e.g. per-session update
    /// streams).
    public typealias CloseHandler = @Sendable () -> Void

    private let transport: any ACPTransport
    private let logger: ACPLogger
    private let requestTimeout: Duration?
    private let requestHandler: RequestHandler?
    private let notificationHandler: NotificationHandler?
    private let onClose: CloseHandler?

    /// Monotonic id for outbound requests.
    private var nextRequestID = 1
    /// Outbound requests awaiting a response, keyed by their wire id.
    /// Each change to this map is also recorded in `outgoingRequests`.
    private var pending: [RequestId: PendingRequest] = [:]
    /// The outbound requests that wait for a response, and the events that
    /// tell when each one starts and finishes. The connection records a start
    /// before it writes the request, and a finish before it resumes the
    /// caller, so the role connections can give a synchronous lookup.
    nonisolated let outgoingRequests = OutgoingRequestTracker()
    /// In-flight inbound request handlers, keyed by the request's own wire
    /// id — the same id a `$/cancel_request` names — and cancelled on
    /// disconnect.
    private var inboundTasks: [RequestId: Task<Void, Never>] = [:]
    /// Each inbound request task that did not end, keyed by a monotonic
    /// token local to this connection. A task stays here until its last
    /// step, also after `inboundTasks` dropped it to write its response and
    /// to run its deferred work. The read loop waits for these tasks before
    /// `closed` gives its reason.
    private var liveInboundTasks: [Int: Task<Void, Never>] = [:]
    /// Monotonic key for `liveInboundTasks` entries.
    private var nextInboundToken = 0
    /// In-flight batch calls awaiting their owed responses, keyed by a
    /// monotonic token local to this connection.
    private var batches: [Int: BatchState] = [:]
    /// Monotonic key for `batches` entries.
    private var nextBatchToken = 0
    /// Why the connection closed, or `nil` while it is open. Set exactly
    /// once, by `shutDown(reason:)`, before pending requests are rejected.
    private var closeReason: ConnectionCloseReason?
    /// `true` after `shutDown(reason:)` ran.
    private var isClosed: Bool { closeReason != nil }
    /// Gives the close reason to each task that waits on `closed`.
    private nonisolated let closeSignal = ConnectionCloseSignal()
    /// The read loop; cancelled by `close()`.
    private var readTask: Task<Void, Never>?

    /// Creates a connection and starts its read loop.
    ///
    /// - Parameters:
    ///   - transport: The bidirectional byte transport to run over.
    ///   - logger: Receives diagnostics for malformed frames and write
    ///     failures — never stdout.
    ///   - requestTimeout: Default timeout applied to every outbound request;
    ///     `nil` means requests wait indefinitely (long-lived calls like
    ///     `session/request_permission` rely on this default).
    ///   - requestHandler: Handles inbound requests; when `nil`, every request
    ///     is answered with `-32601` method-not-found.
    ///   - notificationHandler: Handles inbound notifications; when `nil`,
    ///     notifications are dropped.
    ///   - onClose: Invoked once when the connection shuts down, after pending
    ///     requests are rejected; when `nil`, shutdown notifies no one.
    public init(
        transport: any ACPTransport,
        logger: ACPLogger = .disabled,
        requestTimeout: Duration? = nil,
        requestHandler: RequestHandler? = nil,
        notificationHandler: NotificationHandler? = nil,
        onClose: CloseHandler? = nil
    ) async {
        self.transport = transport
        self.logger = logger
        self.requestTimeout = requestTimeout
        self.requestHandler = requestHandler
        self.notificationHandler = notificationHandler
        self.onClose = onClose
        readTask = Task { await self.readLoop() }
    }

    // MARK: - Outbound

    /// Builds an outbound request or notification envelope: the `jsonrpc`
    /// version, `method`, `params` when non-`nil`, and `id` when provided.
    ///
    /// `request` and `notify` share this rather than each assembling their
    /// own dictionary literal, so a future change to method or params
    /// encoding has exactly one call site to update instead of two that
    /// would otherwise need to be kept in lockstep by hand.
    ///
    /// - Parameters:
    ///   - id: The request's wire id, or `nil` for a notification, which
    ///     carries none.
    ///   - method: The JSON-RPC method name.
    ///   - params: The parameters, passed through verbatim; the member is
    ///     omitted entirely when `nil`.
    /// - Returns: The encodable envelope.
    private static func outboundEnvelope(id: RequestId?, method: String, params: JSONValue?) -> JSONValue {
        var envelope: [String: JSONValue] = [
            Self.jsonrpcKey: Self.jsonrpcVersion,
            Self.methodKey: .string(method),
        ]
        if let id {
            envelope[Self.idKey] = id
        }
        envelope[Self.paramsKey] = params
        return .object(envelope)
    }

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
    ///   `CancellationError` when the awaiting `Task` is cancelled — in which
    ///   case a best-effort `$/cancel_request` notifies the peer too, so it
    ///   can stop working on a result nobody is waiting for.
    public func request(
        method: String,
        params: JSONValue? = nil,
        timeout: Duration? = nil
    ) async throws -> JSONValue {
        guard !isClosed else { throw ConnectionError.closed }
        let id: RequestId = .number(Double(nextRequestID))
        nextRequestID += 1
        let frame = try NDJSONCodec.encode(Self.outboundEnvelope(id: id, method: method, params: params))
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
                outgoingRequests.start(id: id, method: method)
                // Write only after registering, so a response arriving
                // immediately always finds its continuation, and a peer
                // message that names this id always comes after its start
                // event.
                Task { await self.write(frame, failing: id) }
            }
        } onCancel: {
            Task { await self.cancelOutbound(id: id) }
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
        try await transport.write(NDJSONCodec.encode(Self.outboundEnvelope(id: nil, method: method, params: params)))
    }

    /// Shuts the connection down: rejects every pending request with
    /// `ConnectionError.closed`, cancels in-flight inbound handlers, and
    /// stops the read loop. Idempotent.
    ///
    /// When the connection is open, the close reason becomes
    /// `ConnectionCloseReason.closedLocally`. When it already closed, the
    /// call has no effect, and `closed` keeps the first reason.
    public func close() {
        shutDown(reason: .closedLocally)
    }

    /// Waits until the connection closed, and gives the reason.
    ///
    /// The value comes one time for each connection, and each waiter gets
    /// the same reason. A waiter that starts after the close gets the reason
    /// at once. The first event that closes the connection sets the reason:
    /// the end of input, a failure of the input stream, or `close()`.
    ///
    /// The value comes only after each inbound handler ended, finished or
    /// cancelled. This includes the work that a request handler deferred
    /// until after its response. Thus the owner can release the state that
    /// the handlers use, with no race against a handler that still runs.
    ///
    /// Do not wait for this value in an inbound handler: the value waits for
    /// that handler to end. The wait does not stop when the waiting task is
    /// cancelled.
    public nonisolated var closed: ConnectionCloseReason {
        get async { await closeSignal.wait() }
    }

    // MARK: - Read loop

    /// Consumes the transport's framed lines until EOF or stream failure,
    /// then fails loud: `shutDown(reason:)` rejects everything still pending.
    ///
    /// The loop also ends when `close()` cancels it. In each case, the loop
    /// then waits for each inbound request task to end, and only then gives
    /// the close reason to `closed`. A notification handler runs on this
    /// loop, so it ended too.
    private func readLoop() async {
        let reason = shutDown(reason: await readFrames())
        await waitForLiveInboundTasks()
        closeSignal.fire(reason)
    }

    /// Waits until each inbound request task ended, finished or cancelled.
    ///
    /// Call only after `shutDown(reason:)`: after the close, no new inbound
    /// request task starts, so this wait sees each task that can still run.
    private func waitForLiveInboundTasks() async {
        let running = liveInboundTasks.values
        liveInboundTasks = [:]
        for task in running {
            await task.value
        }
    }

    /// Forgets one inbound request task at its last step.
    ///
    /// - Parameter token: The `liveInboundTasks` key of the task.
    private func retireInboundTask(token: Int) {
        liveInboundTasks.removeValue(forKey: token)
    }

    /// Dispatches each framed line of the transport until the input stream
    /// ends.
    ///
    /// - Returns: Why the input stream ended: `endOfInput` when it finished,
    ///   or `transportFailed` with the error of the stream.
    private func readFrames() async -> ConnectionCloseReason {
        do {
            for try await frame in NDJSONCodec.frames(from: transport.bytes, logger: logger) {
                switch frame {
                case .message(let value):
                    await dispatch(value)
                case .malformed:
                    // Framing survived; JSON parsing did not. Answer the
                    // peer's malformed frame with a clean protocol error
                    // instead of dropping it silently or letting a decode
                    // failure escape and tear down the loop.
                    await respondParseError()
                }
            }
            return .endOfInput
        } catch {
            log("transport stream failed: \(error)")
            return .transportFailed(error)
        }
    }

    /// Routes one decoded line: a single envelope, or a batch array of them.
    ///
    /// - Parameter message: The decoded top-level JSON value.
    private func dispatch(_ message: JSONValue) async {
        switch message {
        case .array(let items):
            await dispatchBatch(items)
        case .object:
            await dispatchSingle(message, batchToken: nil)
        default:
            log("dropping message that is neither an object nor a batch array")
        }
    }

    /// Dispatches every item of a batch call, collecting the responses owed
    /// to id-bearing items into one aggregate reply.
    ///
    /// Per JSON-RPC 2.0, an item owes a response iff it carries an `id` and is
    /// not itself a response (a request, or a malformed stand-in for one); a
    /// batch containing none — all notifications — gets no reply at all.
    ///
    /// - Parameter items: The batch's elements, in wire order.
    private func dispatchBatch(_ items: [JSONValue]) async {
        guard !items.isEmpty else {
            log("dropping empty batch")
            return
        }
        let owedCount = items.count { owesResponse($0) }
        guard owedCount > 0 else {
            for item in items { await dispatchSingle(item, batchToken: nil) }
            return
        }
        let token = nextBatchToken
        nextBatchToken += 1
        batches[token] = BatchState(remaining: owedCount)
        for item in items {
            await dispatchSingle(item, batchToken: token)
        }
    }

    /// Whether a batch item owes a response: it carries a non-response `id`.
    ///
    /// - Parameter item: One batch element.
    /// - Returns: `true` when the item has an `id` and is not itself a
    ///   response (no `result` or `error` member).
    private func owesResponse(_ item: JSONValue) -> Bool {
        guard case .object(let fields) = item else { return false }
        return fields[Self.idKey] != nil && fields[Self.resultKey] == nil && fields[Self.errorKey] == nil
    }

    /// One already-version-checked envelope's wire shape, so `dispatchSingle`
    /// reduces to a single flat switch instead of interleaving shape
    /// classification with per-shape handling.
    private enum MessageKind {
        /// A request: carries an `id` and a string `method`.
        case request(id: RequestId, method: String, params: JSONValue?)
        /// A notification: carries a string `method`, no `id`.
        case notification(method: String, params: JSONValue?)
        /// The protocol-level `$/cancel_request` notification — a
        /// notification whose method names it specifically.
        case cancelRequest(params: JSONValue?)
        /// A response: carries an `id` and a `result` or `error` member.
        case response(id: RequestId, fields: [String: JSONValue])
        /// Carries an `id` but matches none of the shapes above — still owed
        /// a reply, answered with `invalidRequest` rather than dropped.
        case unclassifiable(id: RequestId)
        /// No `id` and no recognized shape — logged and dropped, since
        /// nothing is owed a reply.
        case malformed
    }

    /// Classifies one already-version-checked envelope by wire shape: a
    /// string `method` member makes it a request, notification, or
    /// `$/cancel_request`; failing that, a `result`/`error` member makes it a
    /// response; failing that, it is unclassifiable (if it still carries an
    /// `id`) or outright malformed.
    ///
    /// A pure function of `fields` — it reads no actor state — so
    /// `dispatchSingle` can call it before deciding which (if any) actor
    /// method to await.
    ///
    /// - Parameter fields: The envelope's decoded members.
    /// - Returns: The envelope's classification.
    private static func classify(fields: [String: JSONValue]) -> MessageKind {
        let id = fields[Self.idKey]
        if case .string(let method) = fields[Self.methodKey, default: .null] {
            if id == nil, method == Self.cancelRequestMethod {
                return .cancelRequest(params: fields[Self.paramsKey])
            }
            if let id {
                return .request(id: id, method: method, params: fields[Self.paramsKey])
            }
            return .notification(method: method, params: fields[Self.paramsKey])
        }
        if let id, fields[Self.resultKey] != nil || fields[Self.errorKey] != nil {
            return .response(id: id, fields: fields)
        }
        if let id {
            return .unclassifiable(id: id)
        }
        return .malformed
    }

    /// Routes one envelope by kind: request, notification, response,
    /// `$/cancel_request`, or — failing all of those — an invalid-request
    /// error / logged drop. Classification (`Self.classify(fields:)`) is
    /// kept separate from handling so each stays simple on its own: the
    /// classifier is a pure function of the envelope's shape, and this
    /// method is a flat dispatch over its result.
    ///
    /// - Parameters:
    ///   - message: The decoded envelope.
    ///   - batchToken: The enclosing batch's collector, or `nil` when this
    ///     envelope arrived on its own.
    private func dispatchSingle(_ message: JSONValue, batchToken: Int?) async {
        guard case .object(let fields) = message else {
            log("dropping non-object message")
            return
        }
        // The version check mirrors the write side, which stamps every
        // outgoing envelope with the version constant.
        guard fields[Self.jsonrpcKey, default: .null] == Self.jsonrpcVersion else {
            await rejectWrongVersion(fields: fields, batchToken: batchToken)
            return
        }
        switch Self.classify(fields: fields) {
        case .request(let id, let method, let params):
            await dispatchRequest(id: id, method: method, params: params, batchToken: batchToken)
        case .notification(let method, let params):
            await notificationHandler?(method, params)
        case .cancelRequest(let params):
            handleCancelRequest(params: params)
        case .response(let id, let responseFields):
            resolve(id: id, fields: responseFields)
        case .unclassifiable(let id):
            await respond(id: id, outcome: .failure(.invalidRequest), batchToken: batchToken)
        case .malformed:
            log("dropping unclassifiable message")
        }
    }

    /// Answers a message that failed the jsonrpc-version check: an
    /// `invalidRequest` response when it owed one (request-shaped, or a
    /// detectable stand-in), or a loud rejection of the matching pending
    /// caller when it looked like a response instead — never a reply, since
    /// the `id` could collide with one of the peer's own calls. A no-op when
    /// the envelope carries no `id` at all — nothing is owed and nothing is
    /// pending to fail.
    ///
    /// - Parameters:
    ///   - fields: The envelope's decoded members.
    ///   - batchToken: The enclosing batch's collector, or `nil` when this
    ///     envelope arrived on its own.
    private func rejectWrongVersion(fields: [String: JSONValue], batchToken: Int?) async {
        log("rejecting message without jsonrpc 2.0 version")
        guard let id = fields[Self.idKey] else { return }
        if fields[Self.resultKey] == nil, fields[Self.errorKey] == nil {
            // Owed a response (request-shaped, or a detectable stand-in).
            await respond(id: id, outcome: .failure(.invalidRequest), batchToken: batchToken)
        } else {
            // Response-shaped: never answer a response — the id could
            // collide with one of the peer's own calls. Fail the awaiting
            // caller loud instead of leaving it hung (no-op if unknown).
            fail(id: id, with: RequestError.invalidRequest)
        }
    }

    /// Cancels the in-flight inbound handler named by a `$/cancel_request`
    /// notification, if it is still running. A no-op for an unknown or
    /// already-completed id — cancellation racing completion is expected,
    /// not an error.
    ///
    /// - Parameter params: The notification's raw parameters.
    private func handleCancelRequest(params: JSONValue?) {
        guard case .object(let fields) = params ?? .null, let requestId = fields[Self.requestIdKey] else {
            log("dropping $/cancel_request with no requestId")
            return
        }
        inboundTasks[requestId]?.cancel()
    }

    /// Runs one inbound request in its own `Task` so it never blocks the read
    /// loop, then sends the response keyed by the request's `id`. A `Task`
    /// cancelled by `$/cancel_request` answers `requestCancelled` rather than
    /// leaving the peer unanswered.
    ///
    /// A request whose `id` collides with one already in flight is rejected
    /// with `invalidRequest` rather than dispatched: `inboundTasks` has one
    /// slot per id, so silently registering the second would either drop the
    /// first task's handle (making it uncancellable and unreachable by a
    /// later `$/cancel_request`) or let the second overwrite the first's
    /// eventual response. A peer — buggy or hostile — reusing an id gets a
    /// loud, diagnosable error instead of that silent misdirection.
    ///
    /// - Parameters:
    ///   - id: The request's wire id, echoed back verbatim on the response,
    ///     and the same key a `$/cancel_request` names to cancel this task.
    ///   - method: The JSON-RPC method name.
    ///   - params: The request parameters, passed through verbatim.
    ///   - batchToken: The enclosing batch's collector, or `nil` when this
    ///     request arrived on its own.
    private func dispatchRequest(id: RequestId, method: String, params: JSONValue?, batchToken: Int?) async {
        // A batch can still dispatch items after `close()`. A handler that
        // starts now cannot write a response, and `closed` could give its
        // reason while that handler runs; thus it does not start.
        guard !isClosed else {
            log("dropping request with id \(id): the connection is closed")
            return
        }
        if inboundTasks[id] != nil {
            log("rejecting request with id \(id): a request with this id is already in flight")
            await respond(id: id, outcome: .failure(.invalidRequest), batchToken: batchToken)
            return
        }
        let handler = requestHandler
        let token = nextInboundToken
        nextInboundToken += 1
        let task = Task {
            // Bound around the handler call so `afterRespondingToCurrentRequest`
            // finds the right collector no matter how deep the handler's own
            // `await`s go, as long as they stay on this task. `hooks.runAll()`
            // below — outside this scope, after the response is written —
            // is what makes deferred work provably follow the response
            // rather than merely being likely to.
            let hooks = ResponseHooks(logger: logger, requestId: id)
            let outcome = await Self.$currentResponseHooks.withValue(hooks) {
                await Self.outcome(of: handler, method: method, params: params)
            }
            // Only run deferred hooks when a response was actually written:
            // `completeInbound` skips writing if the connection closed while
            // the handler ran, and running hooks anyway would break the
            // documented contract that they follow a response that exists.
            // With no response, discard the hooks: a task that the handler
            // started keeps `hooks` through the task-local, and must not keep
            // the closures and their captured values too.
            if await self.completeInbound(id: id, outcome: outcome, batchToken: batchToken) {
                await hooks.runAll()
            } else {
                hooks.discardAll()
            }
            self.retireInboundTask(token: token)
        }
        inboundTasks[id] = task
        liveInboundTasks[token] = task
    }

    /// Computes the outcome of invoking `handler` with `method`/`params`,
    /// translating any thrown error into a typed `RequestError` outcome:
    /// `.methodNotFound` when there is no handler at all, the thrown
    /// `RequestError` verbatim when the handler raises one, `.requestCancelled`
    /// for a `CancellationError`, and `.internalError` for anything else.
    ///
    /// A `static` helper rather than an actor method: it touches no actor
    /// state, so keeping it outside actor isolation avoids an unnecessary hop
    /// on this concurrency-critical dispatch path, and it keeps
    /// `dispatchRequest`'s `Task` body from nesting a `do`/`catch` inside the
    /// task-local `withValue` closure.
    ///
    /// - Parameters:
    ///   - handler: The request handler to invoke, or `nil` when none is
    ///     configured.
    ///   - method: The JSON-RPC method name.
    ///   - params: The request parameters, passed through verbatim.
    /// - Returns: `.success` with the handler's result, or `.failure` with the
    ///   translated error.
    private static func outcome(
        of handler: RequestHandler?,
        method: String,
        params: JSONValue?
    ) async -> Result<JSONValue, RequestError> {
        do {
            guard let handler else { throw RequestError.methodNotFound(method) }
            return .success(try await handler(method, params))
        } catch is CancellationError {
            return .failure(.requestCancelled)
        } catch let error as RequestError {
            return .failure(error)
        } catch {
            return .failure(.internalError(detail: String(describing: error)))
        }
    }

    /// Retires one inbound handler task and sends its response, unless the
    /// connection shut down while the handler ran.
    ///
    /// - Parameters:
    ///   - id: The request's wire id.
    ///   - outcome: The handler's result or typed error.
    ///   - batchToken: The enclosing batch's collector, or `nil` when this
    ///     request arrived on its own.
    /// - Returns: Whether the response was actually written — `false` when
    ///   the connection had already closed, so the caller knows not to run
    ///   any work deferred until "after the response."
    @discardableResult
    private func completeInbound(
        id: RequestId,
        outcome: Result<JSONValue, RequestError>,
        batchToken: Int?
    ) async -> Bool {
        inboundTasks.removeValue(forKey: id)
        guard !isClosed else { return false }
        await respond(id: id, outcome: outcome, batchToken: batchToken)
        return true
    }

    /// Writes one response envelope — immediately if it arrived on its own,
    /// or into its batch's collector, flushing the aggregate array once every
    /// owed response in that batch has resolved.
    ///
    /// - Parameters:
    ///   - id: The request's wire id, echoed back verbatim.
    ///   - outcome: The `result` value or the `error` to report.
    ///   - batchToken: The enclosing batch's collector, or `nil` to write a
    ///     standalone frame.
    private func respond(id: JSONValue, outcome: Result<JSONValue, RequestError>, batchToken: Int?) async {
        var envelope: [String: JSONValue] = [Self.jsonrpcKey: Self.jsonrpcVersion, Self.idKey: id]
        switch outcome {
        case .success(let result):
            envelope[Self.resultKey] = result
        case .failure(let error):
            envelope[Self.errorKey] = error.wireValue
        }
        await deliver(.object(envelope), batchToken: batchToken)
    }

    /// Writes a response frame, or — inside a batch — appends it to that
    /// batch's collector and flushes the aggregate array once nothing more is
    /// owed.
    ///
    /// - Parameters:
    ///   - responseObject: The single response envelope.
    ///   - batchToken: The enclosing batch's collector, or `nil` to write a
    ///     standalone frame.
    private func deliver(_ responseObject: JSONValue, batchToken: Int?) async {
        guard let batchToken else {
            await writeEncoded(responseObject, logMessage: "failed to write response")
            return
        }
        guard var state = batches[batchToken] else {
            // Every batch item calls `deliver` exactly once, so a missing
            // token here means the owed-response accounting has drifted —
            // fail loud with a diagnostic rather than silently emitting a
            // stray standalone frame a peer expecting a batch array would
            // not know how to correlate.
            log("dropping a batch response for unknown or already-flushed batch token \(batchToken)")
            return
        }
        state.results.append(responseObject)
        state.remaining -= 1
        if state.remaining <= 0 {
            batches.removeValue(forKey: batchToken)
            await writeEncoded(.array(state.results), logMessage: "failed to write batch response")
        } else {
            batches[batchToken] = state
        }
    }

    /// Answers a malformed line with a `-32700` parse-error response, `id:
    /// null` — there is no request id to echo, since the line never parsed.
    private func respondParseError() async {
        let envelope: [String: JSONValue] = [
            Self.jsonrpcKey: Self.jsonrpcVersion,
            Self.idKey: .null,
            Self.errorKey: RequestError.parseError.wireValue,
        ]
        await writeEncoded(.object(envelope), logMessage: "failed to write parse-error response")
    }

    /// Resolves the pending continuation for a response's `id`; responses for
    /// unknown ids (late after timeout, or spurious) are logged and dropped.
    ///
    /// - Parameters:
    ///   - id: The response's wire id.
    ///   - fields: The response envelope's members.
    private func resolve(id: JSONValue, fields: [String: JSONValue]) {
        guard let entry = removePending(id: id) else {
            log("dropping response for unknown id \(id)")
            return
        }
        entry.timeout?.cancel()
        // Tolerate peers that emit `"error": null` alongside a result.
        if let error = fields[Self.errorKey], error != .null {
            entry.continuation.resume(throwing: RequestError(wire: error))
        } else {
            entry.continuation.resume(returning: fields[Self.resultKey, default: .null])
        }
    }

    // MARK: - Failure paths

    /// Emits one diagnostic with the connection's log prefix.
    ///
    /// - Parameter message: The diagnostic text, without prefix.
    private func log(_ message: String) {
        logger.log(Self.logPrefix + message)
    }

    /// Encodes and writes one JSON value to the transport, logging rather
    /// than throwing on failure. Every call site here treats an outbound
    /// write as best effort with no caller awaiting its result — unlike
    /// `write(_:failing:)`, which rejects a specific pending request instead
    /// of merely logging, because a caller is waiting on that one.
    ///
    /// - Parameters:
    ///   - value: The JSON value to encode and write.
    ///   - logMessage: The diagnostic logged, with the underlying error
    ///     appended, if the write fails.
    private func writeEncoded(_ value: JSONValue, logMessage: String) async {
        do {
            try await transport.write(NDJSONCodec.encode(value))
        } catch {
            log("\(logMessage): \(error)")
        }
    }

    /// Schedules the task that rejects request `id` with
    /// `ConnectionError.timedOut` after `limit` elapses.
    ///
    /// - Parameters:
    ///   - id: The pending entry to reject when the timeout fires.
    ///   - limit: The timeout, or `nil` for no timeout (returns `nil`).
    /// - Returns: The scheduled timeout task, or `nil` when unlimited.
    private func makeTimeoutTask(
        for id: RequestId,
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
    private func write(_ frame: Data, failing id: RequestId) async {
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
    /// - Returns: Whether a pending entry was found and rejected.
    @discardableResult
    private func fail(id: RequestId, with error: any Error) -> Bool {
        guard let entry = removePending(id: id) else { return false }
        entry.timeout?.cancel()
        entry.continuation.resume(throwing: error)
        return true
    }

    /// Removes one pending request and records its finish in
    /// `outgoingRequests`, before the caller resumes the continuation.
    ///
    /// - Parameter id: The pending entry's wire id.
    /// - Returns: The removed entry, or `nil` when no request with this id
    ///   is pending.
    private func removePending(id: RequestId) -> PendingRequest? {
        guard let entry = pending.removeValue(forKey: id) else { return nil }
        outgoingRequests.finish(id: id)
        return entry
    }

    /// Rejects one outbound request whose awaiting `Task` was cancelled, and
    /// — only when there was still something to reject — tells the peer with
    /// a best-effort `$/cancel_request` so it can stop working on a result
    /// nobody is waiting for. The local rejection never waits on this
    /// notification landing.
    ///
    /// - Parameter id: The cancelled request's wire id.
    private func cancelOutbound(id: RequestId) async {
        guard fail(id: id, with: CancellationError()) else { return }
        guard !isClosed else { return }
        let notification = Self.outboundEnvelope(
            id: nil, method: Self.cancelRequestMethod, params: .object([Self.requestIdKey: id]))
        await writeEncoded(notification, logMessage: "failed to send $/cancel_request")
    }

    /// Fails loud: marks the connection closed, records the finish of every
    /// pending request in `outgoingRequests` and finishes its event streams,
    /// rejects every pending request with `ConnectionError.closed`, cancels
    /// in-flight inbound
    /// handlers, stops the read loop, and fires the close handler last so
    /// upper layers finish derived streams only after callers are unblocked.
    /// Idempotent: the first call sets the close reason, and a later call
    /// changes nothing.
    ///
    /// The read loop gives the reason to `closed` later, after each inbound
    /// task ended (see `readLoop()`).
    ///
    /// - Parameter reason: Why the connection closes.
    /// - Returns: The close reason of the connection: `reason` on the first
    ///   call, and the reason of the first call after that.
    @discardableResult
    private func shutDown(reason: ConnectionCloseReason) -> ConnectionCloseReason {
        if let closeReason {
            return closeReason
        }
        closeReason = reason
        readTask?.cancel()
        readTask = nil
        let rejected = pending
        pending = [:]
        outgoingRequests.finishAll()
        for entry in rejected.values {
            entry.timeout?.cancel()
            entry.continuation.resume(throwing: ConnectionError.closed)
        }
        let cancelled = inboundTasks
        inboundTasks = [:]
        for task in cancelled.values {
            task.cancel()
        }
        // Incomplete batches can never flush now that inbound handlers are
        // cancelled and the transport is going away; drop them rather than
        // leave dead state behind.
        batches = [:]
        onClose?()
        return reason
    }
}
