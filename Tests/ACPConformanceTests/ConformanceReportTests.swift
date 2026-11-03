import Foundation
import Testing

@testable import ACPConformance

@Suite struct ConformanceReportTests {
    private func result(_ outcome: ConformanceResult.Outcome, position: Int? = nil) -> ConformanceResult {
        ConformanceResult(check: .turnStates, outcome: outcome, scenario: "turn", position: position, message: "m")
    }

    @Test func aReportWithOnlyPassesAndSkipsExitsWithZero() {
        #expect(ConformanceReport(results: [result(.pass), result(.skipped)]).exitCode == 0)
    }

    @Test func aReportWithAFailureExitsWithOne() {
        #expect(ConformanceReport(results: [result(.pass), result(.fail, position: 3)]).exitCode == 1)
    }

    @Test func theTextListNamesTheOutcomeTheCheckAndThePosition() {
        let text = ConformanceReport(results: [result(.fail, position: 3)]).text
        #expect(text.contains("FAIL"))
        #expect(text.contains("turn.states"))
        #expect(text.contains("position 3"))
    }

    @Test func theJSONCarriesTheOutcomeThePositionAndTheVerdict() throws {
        let json = try ConformanceReport(results: [result(.fail, position: 3)]).json()
        let object = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let results = try #require(object["results"] as? [[String: Any]])
        #expect(object["passed"] as? Bool == false)
        #expect(results.first?["outcome"] as? String == "fail")
        #expect(results.first?["position"] as? Int == 3)
        #expect(results.first?["id"] as? String == "turn.states")
    }
}
