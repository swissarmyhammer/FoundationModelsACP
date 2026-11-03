import Foundation
import FoundationModelsACP

/// Plays the scripted client scenarios against an agent and checks the wire.
enum ConformanceRunner {
    private static let holdText = "Keep working until cancelled."

    static func run(_ configuration: ConformanceConfiguration) async -> ConformanceReport {
        var results: [ConformanceResult] = []
        var runs: [RecordedRun] = []

        let handshake = await playTurn(configuration)
        results += handshake.results
        guard let session = handshake.session else {
            results += skipped(
                ConformanceCheck.allCases.filter { check in !results.contains { $0.check == check } },
                "the handshake failed")
            return ConformanceReport(results: ordered(results))
        }
        runs.append(handshake.run)

        let cancelled = await playCancel(configuration, session: session)
        results.append(ConformanceEvaluator.cancel(cancelled.run, session: cancelled.session))
        runs.append(cancelled.run)

        let steps = configuration.script?.resumes ?? [.init(replayFrom: true), .init(replayFrom: false)]
        for (index, step) in steps.enumerated() {
            let replays = step.replayFrom ?? true
            let run = await playResume(
                configuration, step: step, name: "resume-\(index + 1)-\(replays ? "replay" : "no-replay")",
                createdSession: session)
            results += ConformanceEvaluator.resume(run, replaysHistory: replays)
            runs.append(run)
        }
        results += ConformanceEvaluator.rules(runs)
        return ConformanceReport(results: ordered(merge(results)), runs: runs)
    }

    // MARK: scenarios

    private struct TurnOutcome {
        var results: [ConformanceResult]
        var session: SessionId?
        var run: RecordedRun
    }

    /// initialize, session/new, and one prompt turn.
    private static func playTurn(_ configuration: ConformanceConfiguration) async -> TurnOutcome {
        let name = "turn"
        let empty = RecordedRun(name: name, entries: [])
        let agent: AgentProcess
        do {
            agent = try await AgentProcess(configuration)
        } catch {
            return TurnOutcome(
                results: [ConformanceResult(check: .initialize, outcome: .fail, scenario: name, message: "cannot start the agent: \(error)")],
                session: nil, run: empty)
        }
        var results: [ConformanceResult] = []
        do {
            try await initialize(agent)
            results.append(ConformanceResult(check: .initialize, outcome: .pass, scenario: name))
        } catch {
            await agent.close()
            return TurnOutcome(
                results: [ConformanceResult(check: .initialize, outcome: .fail, scenario: name, message: "\(error)")],
                session: nil, run: empty)
        }
        let session: SessionId
        do {
            session = try await agent.client.newSession(NewSessionRequest(cwd: AbsolutePath(rawValue: configuration.cwd))).sessionId
            results.append(ConformanceResult(check: .newSession, outcome: .pass, scenario: name))
        } catch {
            await agent.close()
            results.append(ConformanceResult(check: .newSession, outcome: .fail, scenario: name, message: "\(error)"))
            return TurnOutcome(results: results, session: nil, run: empty)
        }
        var failure: String?
        do {
            _ = try await agent.client.prompt(
                PromptRequest(prompt: [.text(TextContent(text: "Say hello."))], sessionId: session))
        } catch {
            failure = "\(error)"
        }
        await agent.wait { stateSeen($0, session, idle: true) }
        let run = await finish(agent, name: name, failure: failure)
        results += ConformanceEvaluator.turn(run, session: session)
        return TurnOutcome(results: results, session: session, run: run)
    }

    /// A prompt that holds, then session/cancel.
    private static func playCancel(
        _ configuration: ConformanceConfiguration, session: SessionId
    ) async -> (run: RecordedRun, session: SessionId) {
        let name = "cancel"
        let agent: AgentProcess
        do {
            agent = try await AgentProcess(configuration)
        } catch {
            return (RecordedRun(name: name, failure: "cannot start the agent: \(error)", entries: []), session)
        }
        var created = session
        var failure: String?
        do {
            try await initialize(agent)
            created = try await agent.client.newSession(NewSessionRequest(cwd: AbsolutePath(rawValue: configuration.cwd))).sessionId
            _ = try await agent.client.prompt(
                PromptRequest(prompt: [.text(TextContent(text: holdText))], sessionId: created))
            await agent.wait { stateSeen($0, created, idle: false) }
            try await agent.client.sessionCancel(CancelSessionNotification(sessionId: created))
            await agent.wait { stateSeen($0, created, idle: true) }
        } catch {
            failure = "\(error)"
        }
        return (await finish(agent, name: name, failure: failure), created)
    }

    /// One session/resume.
    private static func playResume(
        _ configuration: ConformanceConfiguration, step: ConformanceScript.Resume, name: String, createdSession: SessionId
    ) async -> RecordedRun {
        let session = step.sessionId.map { SessionId(rawValue: $0) } ?? createdSession
        let agent: AgentProcess
        do {
            agent = try await AgentProcess(configuration)
        } catch {
            return RecordedRun(
                name: name, resumeSessionId: session, failure: "cannot start the agent: \(error)", entries: [])
        }
        var unsupported = false
        var failure: String?
        do {
            try await initialize(agent)
            let request = ResumeSessionRequest(
                cwd: AbsolutePath(rawValue: configuration.cwd), sessionId: session,
                replayFrom: (step.replayFrom ?? true) ? .start(ReplayFromStart()) : nil)
            _ = try await agent.client.resumeSession(request)
            if let call = step.untilToolCall {
                await agent.wait(needsCondition: true) { finalToolCall($0, call) }
            } else {
                await agent.settle()
            }
        } catch let error as RequestError where error.code == .methodNotFound {
            unsupported = true
        } catch {
            failure = "\(error)"
        }
        return await finish(agent, name: name, resumeSessionId: session, resumeUnsupported: unsupported, failure: failure)
    }

    // MARK: helpers

    private static func initialize(_ agent: AgentProcess) async throws {
        _ = try await agent.client.initialize(
            InitializeRequest(info: Implementation(name: "acp-conformance", version: "0.0.0"), protocolVersion: .latest))
    }

    /// Records the entries, closes the agent, and returns the run.
    private static func finish(
        _ agent: AgentProcess, name: String, resumeSessionId: SessionId? = nil, resumeUnsupported: Bool = false,
        failure: String? = nil
    ) async -> RecordedRun {
        let entries = await agent.recorder.entries
        await agent.close()
        return RecordedRun(
            name: name, resumeSessionId: resumeSessionId, resumeUnsupported: resumeUnsupported, failure: failure,
            entries: entries)
    }

    /// Whether the session reported `idle` (or, when `idle` is false, `running`).
    private static func stateSeen(_ entries: [RecordedRun.Entry], _ session: SessionId, idle: Bool) -> Bool {
        ConformanceEvaluator.states(in: entries, session: session).contains { $0.kind == (idle ? .idle : .running) }
    }

    private static func finalToolCall(_ entries: [RecordedRun.Entry], _ id: String) -> Bool {
        entries.contains { entry in
            guard case .update(_, .toolCallUpdate(let call)) = entry, call.toolCallId.rawValue == id,
                case .value(let status) = call.status
            else { return false }
            return status == .completed || status == .failed || status == .cancelled
        }
    }

    private static func skipped(_ checks: [ConformanceCheck], _ reason: String) -> [ConformanceResult] {
        checks.map { ConformanceResult(check: $0, outcome: .skipped, message: reason) }
    }

    /// One result for each check: the first failure, else a pass, else a skip.
    private static func merge(_ results: [ConformanceResult]) -> [ConformanceResult] {
        ConformanceCheck.allCases.compactMap { check in
            let matching = results.filter { $0.check == check }
            return matching.first { $0.outcome == .fail } ?? matching.first { $0.outcome == .pass } ?? matching.first
        }
    }

    private static func ordered(_ results: [ConformanceResult]) -> [ConformanceResult] {
        ConformanceCheck.allCases.compactMap { check in results.first { $0.check == check } }
    }
}
