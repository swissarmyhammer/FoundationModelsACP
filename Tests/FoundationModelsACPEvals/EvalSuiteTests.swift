import Foundation
import FoundationModels
import Testing

@testable import FoundationModelsACP

/// Gates whether the live-model scoring runs, keeping model variance out of the
/// deterministic wire suite (spec §8).
///
/// Live scoring runs only when a run opts in with `RUN_EVALS` *and* the
/// on-device model is available; otherwise the scoring test is skipped with a
/// clear reason, so a plain `swift test` never drives the model. The
/// fixture-loading tests are deterministic and always run.
enum EvalGate {
    /// Whether the run opted into live evals via the `RUN_EVALS` environment
    /// variable.
    static var isOptedIn: Bool {
        ProcessInfo.processInfo.environment["RUN_EVALS"] != nil
    }

    /// Whether the on-device model reports itself available.
    static var isModelAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability {
            return true
        }
        return false
    }

    /// Whether live scoring should run this session.
    static var shouldRunLiveEvals: Bool {
        isOptedIn && isModelAvailable
    }
}

/// The FoundationModelsACP behavioral eval suite (spec §8).
///
/// The deterministic tests assert that every seeded transcript loads into a
/// well-formed eval case; the live-scoring test drives each case through the
/// real bridge over the on-device model and asserts the aggregate tool-selection
/// and well-formed-call rates clear the documented threshold. The live test is
/// gated by ``EvalGate`` so it never runs — and never flakes — during the
/// deterministic wire suite. Cases run serially: one ``LanguageModelSession``
/// runs one turn at a time.
@Suite("FoundationModelsACPEvals")
struct EvalSuiteTests {
    /// Loads a case from a seeded transcript.
    ///
    /// - Parameter transcript: The seeded transcript pair to load.
    /// - Returns: The loaded eval case.
    /// - Throws: Any loading error.
    private func load(_ transcript: SeededTranscript) throws -> EvalCase {
        try EvalCase.load(
            named: transcript.name,
            scriptURL: transcript.scriptURL,
            agentURL: transcript.agentURL
        )
    }

    @Test("Eval-case loading parses every seeded transcript fixture")
    func loadingParsesEverySeededFixture() throws {
        let transcripts = try EvalFixtures.allSeededTranscripts()
        #expect(transcripts.count >= 2, "expected the eval fixtures plus the wire golden")
        for transcript in transcripts {
            let evalCase = try load(transcript)
            #expect(
                !evalCase.prompt.isEmpty,
                "seeded fixture \(transcript.name) parsed to an empty prompt"
            )
        }
    }

    @Test("Every live-scored fixture declares a known, directive tool expectation")
    func liveScoredFixturesDeclareKnownTools() throws {
        let transcripts = try EvalFixtures.liveScoredTranscripts()
        #expect(!transcripts.isEmpty, "expected at least one live-scored eval fixture")
        for transcript in transcripts {
            let evalCase = try load(transcript)
            let expectation = try #require(
                evalCase.expectation,
                "live-scored fixture \(transcript.name) must record a tool call"
            )
            #expect(
                EvalToolRegistry.knownToolNames.contains(expectation.toolName),
                "fixture \(transcript.name) names unknown tool \(expectation.toolName)"
            )
            #expect(
                !expectation.argumentKeys.isEmpty,
                "fixture \(transcript.name) records no argument keys to check"
            )
        }
    }

    @Test(
        "Live eval scoring meets the threshold",
        .enabled(
            if: EvalGate.shouldRunLiveEvals,
            "requires RUN_EVALS=1 and an available on-device SystemLanguageModel"
        )
    )
    func liveEvalScoringMeetsThreshold() async throws {
        let transcripts = try EvalFixtures.liveScoredTranscripts()
        try #require(!transcripts.isEmpty, "no live-scored eval fixtures found")

        var caseScores: [CaseScore] = []
        for transcript in transcripts {
            let evalCase = try load(transcript)
            let expectation = try #require(
                evalCase.expectation,
                "live-scored fixture \(transcript.name) must record a tool call"
            )
            var samples: [SampleOutcome] = []
            for _ in 0..<EvalPolicy.samplesPerCase {
                let observation = try await EvalHarness.run(evalCase)
                samples.append(SampleOutcome.score(observation: observation, against: expectation))
            }
            caseScores.append(
                CaseScore(name: transcript.name, expectation: expectation, samples: samples)
            )
        }

        let report = EvalReport(caseScores: caseScores)
        print(report.summary)
        #expect(report.meetsThreshold, "eval run scored below threshold:\n\(report.summary)")
    }
}
