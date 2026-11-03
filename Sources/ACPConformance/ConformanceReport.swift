import Foundation

/// The result of one check.
struct ConformanceResult: Sendable, Encodable {
    enum Outcome: String, Sendable, Encodable {
        case pass
        case fail
        case skipped
    }

    let check: ConformanceCheck
    let outcome: Outcome

    /// The recorded run that the result comes from, such as `resume-replay`.
    var scenario: String?

    /// The position of the first event that breaks the check, in the trace of
    /// the scenario. For a resume scenario, position 0 is the resume request.
    var position: Int?

    /// What is wrong, or why the check was skipped.
    var message: String?

    init(
        check: ConformanceCheck, outcome: Outcome, scenario: String? = nil, position: Int? = nil,
        message: String? = nil
    ) {
        self.check = check
        self.outcome = outcome
        self.scenario = scenario
        self.position = position
        self.message = message
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, outcome, scenario, position, message
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(check.id, forKey: .id)
        try container.encode(check.title, forKey: .title)
        try container.encode(outcome, forKey: .outcome)
        try container.encodeIfPresent(scenario, forKey: .scenario)
        try container.encodeIfPresent(position, forKey: .position)
        try container.encodeIfPresent(message, forKey: .message)
    }
}

/// The result of a conformance run: one result for each check.
struct ConformanceReport: Sendable {
    let results: [ConformanceResult]

    /// Whether no check failed. A skipped check does not fail the run.
    var passed: Bool { !results.contains { $0.outcome == .fail } }

    /// 0 when no check failed, 1 when a check failed.
    var exitCode: Int32 { passed ? 0 : 1 }

    /// One line for each check.
    var text: String {
        results.map { result in
            var line = "\(result.outcome.rawValue.uppercased().padding(toLength: 7, withPad: " ", startingAt: 0))"
            line += "\(result.check.id)  \(result.check.title)"
            if let scenario = result.scenario { line += " [\(scenario)]" }
            if let position = result.position { line += " position \(position)" }
            if let message = result.message { line += ": \(message)" }
            return line
        }.joined(separator: "\n")
    }

    /// The report as a JSON object with `passed` and `results`.
    func json() throws -> String {
        struct Wire: Encodable {
            let passed: Bool
            let results: [ConformanceResult]
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(Wire(passed: passed, results: results)), as: UTF8.self)
    }
}
