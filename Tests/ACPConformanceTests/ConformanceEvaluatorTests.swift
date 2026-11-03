import Foundation
import Testing

@testable import ACPConformance
@testable import FoundationModelsACP

/// The checks on recorded runs: a run that follows the rules passes, and one
/// changed run for each rule fails with that rule.
@Suite struct ConformanceEvaluatorTests {
    private typealias F = ConformanceFixtures

    private func outcome(_ id: ConformanceCheck, in results: [ConformanceResult]) -> ConformanceResult.Outcome? {
        results.first { $0.check == id }?.outcome
    }

    // MARK: turn

    @Test func aTurnThatFollowsTheRulesPasses() {
        let results = ConformanceEvaluator.turn(F.turn(), session: F.session)
        #expect(results.allSatisfy { $0.outcome == .pass })
    }

    @Test func aTurnWithoutAStateUpdateFailsTheStateCheck() {
        let run = RecordedRun(name: "turn", entries: [F.response(F.promptMethod), F.message()])
        #expect(outcome(.turnStates, in: ConformanceEvaluator.turn(run, session: F.session)) == .fail)
    }

    @Test func aTurnThatRunsAgainAfterIdleFailsTheStateCheck() {
        let run = RecordedRun(
            name: "turn", entries: [F.response(F.promptMethod), F.running(), F.idle(), F.running()])
        #expect(outcome(.turnStates, in: ConformanceEvaluator.turn(run, session: F.session)) == .fail)
    }

    @Test func aTurnThatIdlesTwiceFailsTheStateCheck() {
        let run = RecordedRun(
            name: "turn", entries: [F.response(F.promptMethod), F.running(), F.idle(), F.idle()])
        #expect(outcome(.turnStates, in: ConformanceEvaluator.turn(run, session: F.session)) == .fail)
    }

    @Test func aStateCheckFailureNamesThePositionOfTheBreak() {
        let run = RecordedRun(
            name: "turn", entries: [F.response(F.promptMethod), F.running(), F.idle(), F.running()])
        let failure = ConformanceEvaluator.turn(run, session: F.session).first { $0.outcome == .fail }
        #expect(failure?.position == 3)
    }

    @Test func aFailedPromptResponseFailsTheResponseCheck() {
        let run = RecordedRun(
            name: "turn", entries: [F.response(F.promptMethod, succeeded: false), F.running(), F.idle()])
        #expect(outcome(.turnResponse, in: ConformanceEvaluator.turn(run, session: F.session)) == .fail)
    }

    @Test func aMissingPromptResponseFailsTheResponseCheck() {
        let run = RecordedRun(name: "turn", entries: [F.running(), F.idle()])
        #expect(outcome(.turnResponse, in: ConformanceEvaluator.turn(run, session: F.session)) == .fail)
    }

    // MARK: cancel

    @Test func aCancelThatEndsInIdlePasses() {
        #expect(ConformanceEvaluator.cancel(F.cancel(), session: F.session).outcome == .pass)
    }

    @Test func aCancelWithoutAnIdleStateFails() {
        let run = RecordedRun(name: "cancel", entries: [F.response(F.promptMethod), F.running()])
        #expect(ConformanceEvaluator.cancel(run, session: F.session).outcome == .fail)
    }

    // MARK: resume

    @Test func aResumeThatFollowsTheRulesPasses() {
        let results = ConformanceEvaluator.resume(F.resume(), replaysHistory: false)
        #expect(results.allSatisfy { $0.outcome == .pass })
    }

    @Test func aFailedResumeFailsTheAcceptedCheck() {
        let run = RecordedRun(
            name: "resume", resumeSessionId: F.session,
            entries: [F.response(F.resumeMethod, succeeded: false)])
        #expect(outcome(.resumeAccepted, in: ConformanceEvaluator.resume(run, replaysHistory: false)) == .fail)
    }

    @Test func historyWithoutReplayFromFailsTheHistoryCheck() {
        let run = RecordedRun(
            name: "resume", resumeSessionId: F.session,
            entries: [F.message(), F.idle(), F.info(), F.response(F.resumeMethod)])
        #expect(outcome(.resumeNoHistoryWithoutReplayFrom, in: ConformanceEvaluator.resume(run, replaysHistory: false)) == .fail)
    }

    @Test func historyWithReplayFromIsAllowed() {
        let results = ConformanceEvaluator.resume(F.replayingResume(), replaysHistory: true)
        #expect(results.allSatisfy { $0.outcome == .pass })
    }

    // MARK: the ten rules

    private func failedRules(_ runs: [RecordedRun]) -> [ConformanceCheck] {
        ConformanceEvaluator.rules(runs).filter { $0.outcome == .fail }.map(\.check)
    }

    @Test func runsThatFollowTheRulesPassAllTenRules() {
        let results = ConformanceEvaluator.rules([F.turn(), F.resume(), F.replayingResume()])
        #expect(results.count == 10)
        #expect(results.allSatisfy { $0.outcome == .pass })
    }

    @Test func aSecondCurrentStateUpdateFailsRuleTwoAtItsPosition() {
        let run = RecordedRun(
            name: "resume", resumeSessionId: F.session,
            entries: [F.idle(), F.idle(), F.info(), F.response(F.resumeMethod)])
        let results = ConformanceEvaluator.rules([run])
        let failure = results.first { $0.check == .rule(.noHistoricalStateAsCurrent) }
        #expect(failure?.outcome == .fail)
        #expect(failure?.position == 2)
        #expect(failure?.scenario == "resume")
    }

    @Test func aMissingStateUpdateFailsRuleOne() {
        let run = RecordedRun(
            name: "resume", resumeSessionId: F.session, entries: [F.info(), F.response(F.resumeMethod)])
        #expect(failedRules([run]).contains(.rule(.resumeOrder)))
    }

    @Test func aReplayedRequestFailsRuleSix() {
        let run = RecordedRun(
            name: "resume", resumeSessionId: F.session,
            entries: [
                .agentRequest(id: .number(9), method: "session/request_permission", sessionId: F.session),
                F.idle(), F.info(), F.response(F.resumeMethod),
            ])
        #expect(failedRules([run]).contains(.rule(.noReplayedRequests)))
    }

    @Test func onlyTheBrokenRuleFails() {
        let run = RecordedRun(
            name: "resume", resumeSessionId: F.session,
            entries: [
                .agentRequest(id: .number(9), method: "session/request_permission", sessionId: F.session),
                F.idle(), F.info(), F.response(F.resumeMethod),
            ])
        #expect(failedRules([run]) == [.rule(.noReplayedRequests)])
    }

    @Test func withoutAnyRunTheRulesAreSkipped() {
        #expect(ConformanceEvaluator.rules([]).allSatisfy { $0.outcome == .skipped })
    }
}
