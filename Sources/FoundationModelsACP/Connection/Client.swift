/// The client role that drives an agent (spec §4).
///
/// Stable v2 gives the client exactly two entry points, and both are
/// required members with no default: v2 removed `fs/*` and `terminal/*`
/// outright — *"stable v2 defines no standard client capability fields"* — and
/// elicitation remains unstable-only, so there is nothing left on the client
/// surface to gate behind a capability.
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
    /// The one long-lived request on the stable surface: it genuinely waits
    /// on a human, and a conforming connection must never let it block the
    /// read loop that keeps other traffic — including a `session/cancel`
    /// notification — flowing.
    ///
    /// - Parameter params: The permission request.
    /// - Returns: The user's permission decision.
    /// - Throws: A `RequestError` when the request cannot be answered.
    func requestPermission(
        _ params: RequestPermissionRequest
    ) async throws -> RequestPermissionResponse
}
