/// The client role that drives an agent (spec §4).
///
/// Stable v2 gives the client four entry points, and all four are required
/// members with no default: v2 removed `fs/*` and `terminal/*` outright, and
/// the pinned schema revision promotes elicitation to the stable surface —
/// `elicitation/create` and `elicitation/complete` route beside
/// `session/request_permission` and `session/update`. `ClientCapabilities`
/// gates elicitation behind its `elicitation` field, where omitted and `null`
/// both mean no support.
///
/// Method names are exactly the generated routing table's handler names
/// (`ACPMethodTable.methods`) — never a second, hand-wired mapping from wire
/// method to Swift name.
public protocol Client: Sendable {
    /// Receives a streamed session update from the agent.
    ///
    /// Carries everything that happens during a turn: message chunks and
    /// upserts, tool-call upserts, terminal output, plan updates, and the
    /// `state_update` notifications that report a turn's progress and
    /// completion.
    ///
    /// - Parameter notification: The session-update notification.
    func sessionUpdate(_ notification: UpdateSessionNotification) async

    /// Answers the agent's request for permission mid-turn.
    ///
    /// A long-lived request on the stable surface: it genuinely waits on a
    /// human, and a conforming connection must never let it block the read
    /// loop that keeps other traffic — including a `session/cancel`
    /// notification — flowing.
    ///
    /// - Parameter params: The permission request.
    /// - Returns: The user's permission decision.
    /// - Throws: A `RequestError` when the request cannot be answered.
    func requestPermission(
        _ params: RequestPermissionRequest
    ) async throws -> RequestPermissionResponse

    /// Answers the agent's request for structured user input.
    ///
    /// The other long-lived request on the stable surface: a form mode asks
    /// the client to render a form from the provided schema, and a url mode
    /// asks it to direct the user to a URL. Both wait on a human, so a
    /// conforming connection must never let this call block the read loop.
    ///
    /// - Parameter params: The elicitation request.
    /// - Returns: The user's response — accept with content, decline, or
    ///   cancel — as raw JSON (`CreateElicitationResponse`).
    /// - Throws: A `RequestError` when the request cannot be answered.
    func createElicitation(
        _ params: CreateElicitationRequest
    ) async throws -> CreateElicitationResponse

    /// Receives the agent's notice that a URL-based elicitation finished.
    ///
    /// A notification: nothing goes back on the wire. The client uses it to
    /// dismiss whatever UI the matching `elicitation/create` opened.
    ///
    /// - Parameter notification: The completion notification.
    func elicitationComplete(_ notification: CompleteElicitationNotification) async
}
