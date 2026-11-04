import Foundation
import Testing

@testable import ACPConformance
@testable import FoundationModelsACP

/// The runner against the real `acp-test-agent`: the agent must pass.
@Suite struct ConformanceRunnerTests {
    private func configuration(_ arguments: [String], script: ConformanceScript? = nil) -> ConformanceConfiguration {
        ConformanceConfiguration(
            executable: ConformanceTestSupport.helperAgentURL, arguments: arguments, script: script,
            timeout: .seconds(20), quiet: .milliseconds(600))
    }

    @Test func theConformantTestAgentPassesEveryCheck() async {
        let report = await ConformanceRunner.run(configuration(["--scenario", "conformant"]))
        #expect(report.results.filter { $0.outcome == .fail }.isEmpty, "\(report.text)")
        #expect(report.exitCode == 0)
    }

    @Test func theConformantTestAgentRunsEveryCheck() async {
        let report = await ConformanceRunner.run(configuration(["--scenario", "conformant"]))
        #expect(report.results.filter { $0.outcome == .pass }.count == ConformanceCheck.allCases.count)
    }

    @Test func theNestedScenarioPassesAllTenRulesThroughAScript() async {
        let script = ConformanceScript(resumes: [
            .init(sessionId: "root", replayFrom: true, untilToolCall: "call-child-1")
        ])
        let report = await ConformanceRunner.run(
            configuration(["--scenario", "conformant", "--scenario", "nested-subagents"], script: script))
        #expect(report.results.filter { $0.outcome == .fail }.isEmpty, "\(report.text)")
        let rules = report.results.filter { if case .rule = $0.check { true } else { false } }
        #expect(rules.count == 10)
        #expect(rules.allSatisfy { $0.outcome == .pass })
    }

    @Test func aMissingExecutableFailsTheHandshakeAndRunsNothingElse() async {
        let report = await ConformanceRunner.run(
            ConformanceConfiguration(executable: URL(fileURLWithPath: "/nonexistent/agent"), arguments: []))
        #expect(report.exitCode == 1)
        #expect(report.results.first { $0.check == .initialize }?.outcome == .fail)
    }

    @Test func thePlainTestAgentFailsTheTurnStateCheck() async {
        // The plain test agent sends no state update.
        let report = await ConformanceRunner.run(configuration([]))
        #expect(report.results.first { $0.check == .turnStates }?.outcome == .fail)
    }

    @Test func anInterruptedTurnRunsFirstAndTheResumesTargetItsSession() async throws {
        let script = ConformanceScript(resumes: [.init(replayFrom: true)], interruptedTurn: true)
        let report = await ConformanceRunner.run(configuration(["--scenario", "conformant"], script: script))
        let interrupted = try #require(report.runs.first { $0.name == "interrupted" })
        let resume = try #require(report.runs.first { $0.name == "resume-1-replay" })
        let session = interrupted.entries.compactMap { entry -> SessionId? in
            if case .update(let id, _) = entry { id } else { nil }
        }.first
        #expect(resume.resumeSessionId == session)
    }

    @Test func aScriptWithoutAnInterruptedTurnRecordsNoInterruptedRun() async {
        let report = await ConformanceRunner.run(configuration(["--scenario", "conformant"]))
        #expect(!report.runs.contains { $0.name == "interrupted" })
    }
}
