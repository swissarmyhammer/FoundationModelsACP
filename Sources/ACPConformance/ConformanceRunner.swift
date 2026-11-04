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

        var target = session
        if configuration.script?.interruptedTurn == true {
            let interrupted = await playInterruptedTurn(configuration, session: session)
            runs.append(interrupted.run)
            target = interrupted.session
        }

        let steps = configuration.script?.resumes ?? [.init(replayFrom: true), .init(replayFrom: false)]
        for (index, step) in steps.enumerated() {
            let replays = step.replayFrom ?? true
            let run = await playResume(
                configuration, step: step, name: "resume-\(index + 1)-\(replays ? "replay" : "no-replay")",
                createdSession: target)
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
        let session: SessionId
        do {
            let opened = try await openScenario(configuration, name: name)
            agent = opened.agent
            session = opened.session
        } catch {
            let passed = error.step == .newSession
            return TurnOutcome(
                results: (passed ? [ConformanceResult(check: .initialize, outcome: .pass, scenario: name)] : [])
                    + [ConformanceResult(check: error.step, outcome: .fail, scenario: name, message: error.message)],
                session: nil, run: empty)
        }
        var results = [
            ConformanceResult(check: .initialize, outcome: .pass, scenario: name),
            ConformanceResult(check: .newSession, outcome: .pass, scenario: name),
        ]
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

    /// A prompt that the runner does not wait for. The runner closes the agent
    /// as soon as a second session reports `running`, or when the wire is quiet.
    private static func playInterruptedTurn(
        _ configuration: ConformanceConfiguration, session: SessionId
    ) async -> (run: RecordedRun, session: SessionId) {
        let name = "interrupted"
        return await playOpened(configuration, name: name, fallback: session) { agent, created in
            let client = agent.client
            let prompt = Task<String?, Never> {
                do {
                    _ = try await client.prompt(
                        PromptRequest(prompt: [.text(TextContent(text: "Say hello."))], sessionId: created))
                    return nil
                } catch let error as RequestError {
                    return "\(error)"
                } catch {
                    return nil
                }
            }
            await agent.wait { childRunning($0, root: created) }
            var run = await finish(agent, name: name, failure: nil)
            prompt.cancel()
            run.failure = await prompt.value
            return run
        }
    }

    /// A prompt that holds, then session/cancel.
    private static func playCancel(
        _ configuration: ConformanceConfiguration, session: SessionId
    ) async -> (run: RecordedRun, session: SessionId) {
        let name = "cancel"
        return await playOpened(configuration, name: name, fallback: session) { agent, created in
            var failure: String?
            do {
                _ = try await agent.client.prompt(
                    PromptRequest(prompt: [.text(TextContent(text: holdText))], sessionId: created))
                await agent.wait { stateSeen($0, created, idle: false) }
                try await agent.client.sessionCancel(CancelSessionNotification(sessionId: created))
                await agent.wait { stateSeen($0, created, idle: true) }
            } catch {
                failure = "\(error)"
            }
            return await finish(agent, name: name, failure: failure)
        }
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

    /// An agent that is started, initialized, and has a new session.
    private struct OpenedScenario {
        var agent: AgentProcess
        var session: SessionId
    }

    /// A scenario that could not open.
    private struct OpenFailure: Error {
        /// The check that failed.
        var step: ConformanceCheck
        var message: String
        /// The run that records the failure.
        var run: RecordedRun
    }

    /// Starts the agent, initializes it, and creates a session.
    ///
    /// - Throws: ``OpenFailure`` for the step that failed.
    private static func openScenario(
        _ configuration: ConformanceConfiguration, name: String
    ) async throws(OpenFailure) -> OpenedScenario {
        let agent: AgentProcess
        do {
            agent = try await AgentProcess(configuration)
        } catch {
            let message = "cannot start the agent: \(error)"
            throw OpenFailure(
                step: .initialize, message: message, run: RecordedRun(name: name, failure: message, entries: []))
        }
        var step = ConformanceCheck.initialize
        do {
            try await initialize(agent)
            step = .newSession
            let session = try await agent.client.newSession(
                NewSessionRequest(cwd: AbsolutePath(rawValue: configuration.cwd))
            ).sessionId
            return OpenedScenario(agent: agent, session: session)
        } catch {
            throw OpenFailure(
                step: step, message: "\(error)", run: await finish(agent, name: name, failure: "\(error)"))
        }
    }

    /// Opens a scenario and plays `body` on it. When the scenario does not open,
    /// the result is the run of the failure and `fallback`.
    private static func playOpened(
        _ configuration: ConformanceConfiguration, name: String, fallback: SessionId,
        _ body: (AgentProcess, SessionId) async -> RecordedRun
    ) async -> (run: RecordedRun, session: SessionId) {
        do {
            let opened = try await openScenario(configuration, name: name)
            return (await body(opened.agent, opened.session), opened.session)
        } catch {
            return (error.run, fallback)
        }
    }

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

    /// Whether a session other than `root` reported `running`.
    private static func childRunning(_ entries: [RecordedRun.Entry], root: SessionId) -> Bool {
        ConformanceEvaluator.states(in: entries) { $0 != root }.contains { $0.kind == .running }
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
