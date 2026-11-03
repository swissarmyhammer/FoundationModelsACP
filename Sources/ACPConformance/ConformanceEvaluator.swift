import FoundationModelsACP

/// The checks on recorded runs. All of them are pure: a run goes in and
/// results come out.
enum ConformanceEvaluator {
    private static let promptMethod = WireMethod.prompt
    private static let resumeMethod = WireMethod.resume

    /// Whether the first response to `method` succeeded, or `nil` without a response.
    private static func firstResponse(in run: RecordedRun, method: String) -> Bool? {
        run.entries.lazy.compactMap { entry -> Bool? in
            if case .response(_, let responded, let succeeded) = entry, responded == method { succeeded } else { nil }
        }.first
    }

    enum StateKind { case running, idle, requiresAction, unknown }

    /// The `state_update` kinds of one session in the entries, with their positions.
    static func states(in entries: [RecordedRun.Entry], session: SessionId) -> [(position: Int, kind: StateKind)] {
        entries.enumerated().compactMap { position, entry in
            guard case .update(let id, .stateUpdate(let state)) = entry, id == session else { return nil }
            switch state {
            case .running: return (position, .running)
            case .idle: return (position, .idle)
            case .requiresAction: return (position, .requiresAction)
            case .unknown: return (position, .unknown)
            }
        }
    }

    // MARK: turn

    /// `turn.response` and `turn.states` for a prompt turn of `session`.
    static func turn(_ run: RecordedRun, session: SessionId) -> [ConformanceResult] {
        [turnResponse(run), turnStates(run, session: session)]
    }

    private static func turnResponse(_ run: RecordedRun) -> ConformanceResult {
        switch firstResponse(in: run, method: promptMethod) {
        case true: return ConformanceResult(check: .turnResponse, outcome: .pass, scenario: run.name)
        case false:
            return ConformanceResult(
                check: .turnResponse, outcome: .fail, scenario: run.name, message: "the agent answered session/prompt with an error")
        default:
            return ConformanceResult(
                check: .turnResponse, outcome: .fail, scenario: run.name, message: run.failureText("no session/prompt response"))
        }
    }

    private static func turnStates(_ run: RecordedRun, session: SessionId) -> ConformanceResult {
        func fail(_ position: Int?, _ message: String) -> ConformanceResult {
            ConformanceResult(check: .turnStates, outcome: .fail, scenario: run.name, position: position, message: message)
        }
        let states = states(in: run.entries, session: session)
        guard let first = states.first else { return fail(nil, "no state_update in the turn") }
        guard first.kind == .running else { return fail(first.position, "the first state_update is not running") }
        guard let firstIdle = states.firstIndex(where: { $0.kind == .idle }) else {
            return fail(states.last?.position, "the turn never reports idle")
        }
        if firstIdle != states.count - 1 {
            return fail(states[firstIdle + 1].position, "a state_update follows the final idle")
        }
        return ConformanceResult(check: .turnStates, outcome: .pass, scenario: run.name)
    }

    // MARK: cancel

    /// `cancel.ends-turn` for a run in which the runner cancelled a turn of `session`.
    static func cancel(_ run: RecordedRun, session: SessionId) -> ConformanceResult {
        let states = states(in: run.entries, session: session)
        guard let last = states.last else {
            return ConformanceResult(
                check: .cancelEndsTurn, outcome: .fail, scenario: run.name, message: run.failureText("no state_update after the prompt"))
        }
        guard last.kind == .idle else {
            return ConformanceResult(
                check: .cancelEndsTurn, outcome: .fail, scenario: run.name, position: last.position,
                message: "the last state_update after session/cancel is not idle")
        }
        return ConformanceResult(check: .cancelEndsTurn, outcome: .pass, scenario: run.name)
    }

    // MARK: resume

    /// `resume.accepted` and `resume.no-history-without-replay-from`.
    ///
    /// - Parameters:
    ///   - run: A run with one resume.
    ///   - replaysHistory: Whether the request had `replayFrom`.
    static func resume(_ run: RecordedRun, replaysHistory: Bool) -> [ConformanceResult] {
        if run.resumeUnsupported {
            let message = "session/resume is not supported"
            return [ConformanceCheck.resumeAccepted, .resumeNoHistoryWithoutReplayFrom].map {
                ConformanceResult(check: $0, outcome: .skipped, scenario: run.name, message: message)
            }
        }
        let response = firstResponse(in: run, method: resumeMethod)
        let accepted = ConformanceResult(
            check: .resumeAccepted, outcome: response == true ? .pass : .fail, scenario: run.name,
            message: response == true ? nil : run.failureText("session/resume got no successful response"))
        return [accepted, history(run, replaysHistory: replaysHistory)]
    }

    private static func history(_ run: RecordedRun, replaysHistory: Bool) -> ConformanceResult {
        if replaysHistory {
            return ConformanceResult(check: .resumeNoHistoryWithoutReplayFrom, outcome: .pass, scenario: run.name)
        }
        let trace = run.wireTrace
        for (position, event) in trace.enumerated() {
            if case .resumeResponse = event { break }
            guard case .update(_, let update) = event else { continue }
            switch update {
            case .userMessage, .userMessageChunk, .agentMessage, .agentMessageChunk, .agentThought, .agentThoughtChunk:
                return ConformanceResult(
                    check: .resumeNoHistoryWithoutReplayFrom, outcome: .fail, scenario: run.name, position: position,
                    message: "conversation history before the response, but the request had no replayFrom")
            default:
                continue
            }
        }
        return ConformanceResult(check: .resumeNoHistoryWithoutReplayFrom, outcome: .pass, scenario: run.name)
    }

    // MARK: the ten rules

    /// One result for each rule of ``SubagentWireTraceValidator``, over every run. A rule
    /// fails with the first violation in the first run that breaks it. Without a run, every
    /// rule is skipped.
    static func rules(_ runs: [RecordedRun]) -> [ConformanceResult] {
        let validator = SubagentWireTraceValidator()
        let violations = runs.flatMap { run in validator.validate(run.wireTrace).map { (run.name, $0) } }
        return SubagentWireTraceValidator.Rule.allCases.map { rule in
            if runs.isEmpty {
                return ConformanceResult(check: .rule(rule), outcome: .skipped, message: "no trace was recorded")
            }
            guard let (scenario, violation) = violations.first(where: { $0.1.rule == rule }) else {
                return ConformanceResult(check: .rule(rule), outcome: .pass)
            }
            return ConformanceResult(
                check: .rule(rule), outcome: .fail, scenario: scenario, position: violation.position,
                message: violation.message)
        }
    }
}
