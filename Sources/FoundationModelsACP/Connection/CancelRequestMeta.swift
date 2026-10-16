import Foundation
import Synchronization

/// Holds the `_meta` that an outbound request sends in its
/// `$/cancel_request`, when the task of the call is cancelled.
///
/// A cancel comes from `Task.cancel()`, which cannot carry data. Thus the
/// caller makes one box for each call, gives it to the call (for example
/// ``AgentSideConnection/createElicitation(_:cancellation:)``), and puts the
/// `_meta` in the box before it cancels the task:
///
/// ```swift
/// let cancellation = OutboundCancellation()
/// let call = Task { try await connection.createElicitation(request, cancellation: cancellation) }
/// // Later, to end the call with a reason:
/// cancellation.setMeta(.object([CancelRequestNotification.reasonMetaKey: .string("run cancelled")]))
/// call.cancel()
/// ```
///
/// Contract:
/// - Call ``setMeta(_:)`` before `Task.cancel()`. The connection reads the
///   box one time, when it writes the `$/cancel_request`. A meta that is set
///   after the cancel is not sent.
/// - When the response, a timeout or a close comes before the cancel, the
///   connection sends no `$/cancel_request`, and the meta is not used.
/// - A `nil` meta (the initial value) sends no `_meta` member, so the
///   notification is the same as a cancel with no box.
public final class OutboundCancellation: Sendable {
    /// The `_meta` to send, or `nil` for no `_meta` member.
    private let storage = Mutex<JSONValue?>(nil)

    /// Creates a box with no meta.
    public init() {}

    /// The `_meta` that the `$/cancel_request` of the call sends, or `nil`
    /// for no `_meta` member.
    public var meta: JSONValue? {
        storage.withLock { $0 }
    }

    /// Sets the `_meta` that the `$/cancel_request` of the call sends. Call
    /// it before `Task.cancel()`.
    ///
    /// - Parameter meta: The `_meta` value, or `nil` for no `_meta` member.
    public func setMeta(_ meta: JSONValue?) {
        storage.withLock { $0 = meta }
    }
}

/// Holds what the `$/cancel_request` that cancelled one inbound request
/// told. The connection binds one box for each inbound request in the task
/// of its handler (`Connection.currentInboundCancellation`).
///
/// A task that the handler starts inherits the task-local, and it can live
/// after the handler. Thus the connection ends the box when the handler
/// returns, and an ended box gives no cancel.
final class InboundCancellation: Sendable {
    /// What a `$/cancel_request` for the request told.
    private struct Received {
        /// Whether a `$/cancel_request` named the request.
        var byPeer = false
        /// The `_meta` of that `$/cancel_request`, or `nil`.
        var meta: JSONValue?
        /// Whether the handler of the request returned.
        var ended = false
    }

    /// The received cancel, shared by the connection and the handler task.
    private let storage = Mutex(Received())

    /// The received `_meta`, or `nil`. `nil` after the handler returned.
    var meta: JSONValue? {
        storage.withLock { $0.ended ? nil : $0.meta }
    }

    /// Whether a `$/cancel_request` named the request. A close, a timeout
    /// or no cancel leaves it `false`. `false` after the handler returned.
    var cancelledByPeer: Bool {
        storage.withLock { !$0.ended && $0.byPeer }
    }

    /// Records a `$/cancel_request` for the request, with its `_meta`. The
    /// connection calls it before it cancels the task of the handler.
    ///
    /// - Parameter meta: The `_meta` of the `$/cancel_request`, or `nil`.
    func recordPeerCancel(meta: JSONValue?) {
        storage.withLock { state in
            state.byPeer = true
            state.meta = meta
        }
    }

    /// Ends the box. The connection calls it when the handler returns, so a
    /// task that the handler started reads no cancel after that.
    func endHandler() {
        storage.withLock { $0.ended = true }
    }
}

extension CancelRequestNotification {
    /// The key of a human-readable cancel reason in the `_meta` of a
    /// `$/cancel_request`: `"_meta": {"reason": "<text>"}`.
    ///
    /// The connection does not read or write this key. It is the agreement
    /// between the side that cancels and the side that reads
    /// `cancelRequestMeta`, and it is the same key that the elicitation
    /// responses use for their reason.
    public static let reasonMetaKey = "reason"
}

extension Connection {
    /// The cancel box of the inbound request that the current task handles,
    /// or `nil` outside a handler task. `dispatchRequest` binds it around
    /// the handler call. A task that the handler starts inherits it, and
    /// `dispatchRequest` ends the box when the handler returns.
    @TaskLocal static var currentInboundCancellation: InboundCancellation?

    /// The `_meta` of the `$/cancel_request` that cancelled the inbound
    /// request that the current task handles.
    ///
    /// It is `nil` when the request is not cancelled, when the cancel had no
    /// `_meta`, or when the current task handles no inbound request. The
    /// value is the raw `_meta`, with no check: a `_meta` that is not an
    /// object is given as it is.
    ///
    /// A task that a handler starts (for example with `Task { }`) inherits
    /// the value of that handler while the handler runs. After the handler
    /// returns, the value in that task is `nil`.
    ///
    /// Contract: read it in the task of the handler, after the handler sees
    /// the cancel (for example after an `await` throws `CancellationError`,
    /// or after a continuation that an `onCancel` closure resumed). The
    /// connection stores the `_meta` before it cancels the task, so the
    /// handler always sees the `_meta` when it sees the cancel. Do not read
    /// it in an `onCancel` closure: that closure runs in the task that
    /// cancels, where the value of the handler task is not available.
    public static var cancelRequestMeta: JSONValue? {
        currentInboundCancellation?.meta
    }

    /// Whether a `$/cancel_request` from the peer cancelled the inbound
    /// request that the current task handles.
    ///
    /// It is `true` only when the peer sent a `$/cancel_request` for the
    /// request, also when that notification had no `_meta`. It is `false`
    /// when a close of the connection cancelled the handler, when there was
    /// no cancel, and when the current task handles no inbound request.
    /// Thus a handler can tell a cancel of the peer from a close, also when
    /// ``cancelRequestMeta`` is `nil`.
    ///
    /// A task that a handler starts inherits the value of that handler while
    /// the handler runs. After the handler returns, the value in that task
    /// is `false`.
    ///
    /// Contract: the same as ``cancelRequestMeta``. Read it in the task of
    /// the handler, after the handler sees the cancel. The connection sets
    /// it before it cancels the task. Do not read it in an `onCancel`
    /// closure.
    public static var cancelledByPeer: Bool {
        currentInboundCancellation?.cancelledByPeer ?? false
    }
}
