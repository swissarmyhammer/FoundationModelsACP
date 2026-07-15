import Foundation

@testable import FoundationModelsACP

/// How one live turn scored against a case's expectation across the eval
/// metrics (spec §8).
struct SampleOutcome: Sendable, Hashable {
    /// The right tool was selected: a `tool_call` named the expected tool.
    let toolSelected: Bool

    /// The selected call was well formed: it carried a non-empty id and a
    /// `rawInput` object holding every expected argument key.
    let wellFormed: Bool

    /// A structured result flowed back: the turn emitted a completed
    /// `tool_call_update`.
    let structuredResult: Bool

    /// Scores one turn observation against a tool expectation.
    ///
    /// - Parameters:
    ///   - observation: What the turn emitted on the wire.
    ///   - expectation: The tool selection a correct turn should produce.
    /// - Returns: The sample's per-metric outcome.
    static func score(
        observation: TurnObservation,
        against expectation: ToolExpectation
    ) -> SampleOutcome {
        let match = observation.toolCalls.first { $0.name == expectation.toolName }
        return SampleOutcome(
            toolSelected: match != nil,
            wellFormed: match.map { isWellFormed($0, against: expectation) } ?? false,
            structuredResult: observation.producedResult
        )
    }

    /// Whether a matched call carries a non-empty id and every expected
    /// argument key in its `rawInput` object.
    ///
    /// - Parameters:
    ///   - call: The observed call whose name matched the expectation.
    ///   - expectation: The expected tool selection.
    /// - Returns: `true` when the call is well formed.
    private static func isWellFormed(
        _ call: ObservedToolCall,
        against expectation: ToolExpectation
    ) -> Bool {
        guard !call.toolCallId.isEmpty, let fields = call.rawInput?.evalObject else {
            return false
        }
        return expectation.argumentKeys.allSatisfy { fields[$0] != nil }
    }
}

/// One case's scores aggregated over its samples.
struct CaseScore: Sendable {
    /// The case's name.
    let name: String

    /// The expected tool selection scored against.
    let expectation: ToolExpectation

    /// The per-sample outcomes, in run order.
    let samples: [SampleOutcome]

    /// The fraction of samples that selected the right tool.
    var selectionRate: Double { rate(\.toolSelected) }

    /// The fraction of samples that produced a well-formed call.
    var wellFormedRate: Double { rate(\.wellFormed) }

    /// The fraction of samples that produced a structured result.
    var structuredResultRate: Double { passingRate(of: \.structuredResult, in: samples) }

    /// The fraction of samples satisfying a metric.
    ///
    /// - Parameter metric: The boolean metric to average.
    /// - Returns: The passing fraction, or `0` when there are no samples.
    private func rate(_ metric: KeyPath<SampleOutcome, Bool>) -> Double {
        passingRate(of: metric, in: samples)
    }
}

/// The fraction of sample outcomes satisfying a boolean metric.
///
/// - Parameters:
///   - metric: The boolean metric to average.
///   - samples: The outcomes to average over.
/// - Returns: The passing fraction, or `0` when there are no samples.
private func passingRate(
    of metric: KeyPath<SampleOutcome, Bool>,
    in samples: [SampleOutcome]
) -> Double {
    guard !samples.isEmpty else { return 0 }
    return Double(samples.filter { $0[keyPath: metric] }.count) / Double(samples.count)
}

/// The scoring policy: how many samples each case runs and the pass threshold
/// its rates must clear (spec §8).
///
/// The threshold is deliberately conservative. A probe of the on-device model
/// selected the correct tool for directive prompts on every trial, so 0.8
/// leaves generous headroom for beta-toolchain variance while still failing a
/// genuine regression in prompt quality or tool selection.
enum EvalPolicy {
    /// The number of live turns each case runs, for a statistical rate.
    static let samplesPerCase = 5

    /// The minimum tool-selection and well-formed rates a passing run clears.
    static let passThreshold = 0.8
}

/// The aggregate result of scoring every case, with a threshold verdict and a
/// human-readable summary.
struct EvalReport: Sendable {
    /// The per-case scores, in evaluation order.
    let caseScores: [CaseScore]

    /// The overall tool-selection rate across every sample of every case.
    var overallSelectionRate: Double { overall(\.toolSelected) }

    /// The overall well-formed rate across every sample of every case.
    var overallWellFormedRate: Double { overall(\.wellFormed) }

    /// The overall structured-result rate across every sample of every case.
    var overallStructuredResultRate: Double { overall(\.structuredResult) }

    /// Whether the run passes: both the gated metrics — tool selection and
    /// well-formed call — clear the threshold overall.
    ///
    /// Structured result is reported but not gated: it depends on a tool's
    /// completion, a step downstream of the selection the eval targets.
    var meetsThreshold: Bool {
        overallSelectionRate >= EvalPolicy.passThreshold
            && overallWellFormedRate >= EvalPolicy.passThreshold
    }

    /// The overall passing fraction of a metric across every sample.
    ///
    /// - Parameter metric: The boolean metric to average.
    /// - Returns: The passing fraction, or `0` when there are no samples.
    private func overall(_ metric: KeyPath<SampleOutcome, Bool>) -> Double {
        passingRate(of: metric, in: caseScores.flatMap(\.samples))
    }

    /// A multi-line summary of the run: one row per case plus the overall
    /// rates and the threshold.
    var summary: String {
        var lines = ["FoundationModelsACP evals (threshold \(percent(EvalPolicy.passThreshold))):"]
        for score in caseScores {
            lines.append(
                "  \(score.name) [\(score.expectation.toolName)]: "
                    + "select \(percent(score.selectionRate)), "
                    + "well-formed \(percent(score.wellFormedRate)), "
                    + "result \(percent(score.structuredResultRate))"
            )
        }
        lines.append(
            "  OVERALL: select \(percent(overallSelectionRate)), "
                + "well-formed \(percent(overallWellFormedRate)), "
                + "result \(percent(overallStructuredResultRate)) "
                + "-> \(meetsThreshold ? "PASS" : "FAIL")"
        )
        return lines.joined(separator: "\n")
    }

    /// Formats a rate as a whole-number percentage.
    ///
    /// - Parameter rate: The fraction to format.
    /// - Returns: The rate as a percentage string.
    private func percent(_ rate: Double) -> String {
        "\(Int((rate * 100).rounded()))%"
    }
}
