import Foundation

extension Connection {
    /// The arrival number of the inbound request that the current task
    /// handles, or `nil` outside a handler task. `dispatchRequest` binds it
    /// around the handler call.
    @TaskLocal static var currentRequestArrivalNumber: UInt64?

    /// The arrival number of the inbound request that the current task
    /// handles.
    ///
    /// Each inbound request runs in its own task, so two handlers can start
    /// in an order that is not the wire order. This number gives the wire
    /// order: the connection gives each inbound request that it dispatches
    /// the next number, in the order that it reads the frames. A later
    /// request always has a larger number. The numbers are local to one
    /// connection and can have gaps (for example, a request with a
    /// duplicate id gets no number).
    ///
    /// It is `nil` when the current task handles no inbound request.
    ///
    /// Read it as the first statement of a handler, before any `await`.
    public static var currentRequestArrival: UInt64? {
        currentRequestArrivalNumber
    }
}

extension ClientSideConnection {
    /// The arrival number of the inbound request that the current task
    /// handles, in wire order. See ``Connection/currentRequestArrival``.
    ///
    /// Read it as the first statement of a handler, before any `await`.
    public static var currentRequestArrival: UInt64? {
        Connection.currentRequestArrival
    }

    /// The `_meta` of the `$/cancel_request` that cancelled the inbound
    /// request that the current task handles. See
    /// ``Connection/cancelRequestMeta``.
    ///
    /// Read it in the task of the handler, after the handler sees the
    /// cancel. Do not read it in an `onCancel` closure.
    public static var cancelRequestMeta: JSONValue? {
        Connection.cancelRequestMeta
    }

    /// Whether a `$/cancel_request` from the agent cancelled the inbound
    /// request that the current task handles. `false` for a close, no
    /// cancel, or no handler. See ``Connection/cancelledByPeer``.
    ///
    /// Read it in the task of the handler, after the handler sees the
    /// cancel. Do not read it in an `onCancel` closure.
    public static var cancelledByPeer: Bool {
        Connection.cancelledByPeer
    }
}

extension AgentSideConnection {
    /// The arrival number of the inbound request that the current task
    /// handles, in wire order. See ``Connection/currentRequestArrival``.
    ///
    /// Read it as the first statement of a handler, before any `await`.
    public static var currentRequestArrival: UInt64? {
        Connection.currentRequestArrival
    }

    /// The `_meta` of the `$/cancel_request` that cancelled the inbound
    /// request that the current task handles. See
    /// ``Connection/cancelRequestMeta``.
    ///
    /// Read it in the task of the handler, after the handler sees the
    /// cancel. Do not read it in an `onCancel` closure.
    public static var cancelRequestMeta: JSONValue? {
        Connection.cancelRequestMeta
    }

    /// Whether a `$/cancel_request` from the client cancelled the inbound
    /// request that the current task handles. `false` for a close, no
    /// cancel, or no handler. See ``Connection/cancelledByPeer``.
    ///
    /// Read it in the task of the handler, after the handler sees the
    /// cancel. Do not read it in an `onCancel` closure.
    public static var cancelledByPeer: Bool {
        Connection.cancelledByPeer
    }
}
