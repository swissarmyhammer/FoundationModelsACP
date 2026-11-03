import FoundationModelsACP

/// One check of the conformance runner.
///
/// Each check has a stable `id`. A CI job can pin on the ids. The ten rules of
/// ``SubagentWireTraceValidator`` have the ids `rule.1` to `rule.10`.
enum ConformanceCheck: Hashable, Sendable, CaseIterable {
    /// `initialize` succeeds.
    case initialize

    /// `session/new` succeeds and names a session.
    case newSession

    /// `session/prompt` gets a successful response.
    case turnResponse

    /// A prompt turn reports `running` and then one final `idle`.
    case turnStates

    /// After `session/cancel`, the turn ends in `idle`.
    case cancelEndsTurn

    /// `session/resume` succeeds, with and without `replayFrom`.
    case resumeAccepted

    /// A resume without `replayFrom` replays no conversation history.
    case resumeNoHistoryWithoutReplayFrom

    /// One rule of ``SubagentWireTraceValidator``, checked on every recorded
    /// trace.
    case rule(SubagentWireTraceValidator.Rule)

    static var allCases: [ConformanceCheck] {
        [
            .initialize, .newSession, .turnResponse, .turnStates, .cancelEndsTurn, .resumeAccepted,
            .resumeNoHistoryWithoutReplayFrom,
        ] + SubagentWireTraceValidator.Rule.allCases.map { .rule($0) }
    }

    /// The stable id of the check.
    var id: String {
        switch self {
        case .initialize: "handshake.initialize"
        case .newSession: "handshake.new-session"
        case .turnResponse: "turn.response"
        case .turnStates: "turn.states"
        case .cancelEndsTurn: "cancel.ends-turn"
        case .resumeAccepted: "resume.accepted"
        case .resumeNoHistoryWithoutReplayFrom: "resume.no-history-without-replay-from"
        case .rule(let rule): "rule.\(rule.rawValue)"
        }
    }

    /// A short title for the output.
    var title: String {
        switch self {
        case .initialize: "initialize succeeds"
        case .newSession: "session/new succeeds"
        case .turnResponse: "session/prompt is answered"
        case .turnStates: "a turn reports running, then one final idle"
        case .cancelEndsTurn: "session/cancel ends the turn in idle"
        case .resumeAccepted: "session/resume is accepted"
        case .resumeNoHistoryWithoutReplayFrom: "a resume without replayFrom replays no history"
        case .rule(let rule): "sub-agent rule \(rule.rawValue): \(Self.title(of: rule))"
        }
    }

    private static func title(of rule: SubagentWireTraceValidator.Rule) -> String {
        switch rule {
        case .resumeOrder: "resume order"
        case .noHistoricalStateAsCurrent: "no historical state as current"
        case .announceBeforeUse: "announce a child before use"
        case .currentSnapshotAfterResponse: "current snapshots after the response"
        case .childHistoryBeforeResponse: "child history before the response"
        case .noReplayedRequests: "no replayed requests"
        case .wholeSahObject: "whole _meta.sah object"
        case .finalToolCallLast: "final tool call last"
        case .backgroundList: "background list"
        case .failedChild: "failed child"
        }
    }
}
