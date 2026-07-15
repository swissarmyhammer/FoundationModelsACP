import Foundation

/// A seeded transcript pair on disk: the golden ndJSON files an eval case loads
/// from.
struct SeededTranscript: Sendable {
    /// The case's name, from the fixture file stem.
    let name: String

    /// The client→agent script fixture.
    let scriptURL: URL

    /// The agent→client stream fixture.
    let agentURL: URL
}

/// Locates the transcript fixtures that seed the eval set (spec §8).
///
/// Eval fixtures live beside this file in `Fixtures/`, each a
/// `<name>.script.ndjson` + `<name>.agent.ndjson` pair. The wire golden the
/// end-to-end suite records is also seeded here, so a single captured
/// transcript is both a deterministic wire fixture and an eval case. Fixtures
/// are loaded by path (`#filePath`), never as bundle resources.
enum EvalFixtures {
    /// This file's directory (`Tests/FoundationModelsACPEvals`).
    private static let sourceDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()

    /// The `Tests/` directory holding every test target.
    private static let testsDirectory = sourceDirectory.deletingLastPathComponent()

    /// The eval target's own `Fixtures/` directory.
    static let directory = sourceDirectory.appendingPathComponent("Fixtures")

    /// The end-to-end suite's golden transcript, seeded as an eval case too.
    static let wireGolden = SeededTranscript(
        name: "wire-golden-session",
        scriptURL: wireGoldenFixture("golden-session-script.ndjson"),
        agentURL: wireGoldenFixture("golden-session-agent.ndjson")
    )

    /// Resolves a wire-golden fixture beside the end-to-end test target.
    ///
    /// - Parameter name: The fixture file name.
    /// - Returns: The fixture's URL under `FoundationModelsACPTests/Fixtures`.
    private static func wireGoldenFixture(_ name: String) -> URL {
        testsDirectory.appendingPathComponent("FoundationModelsACPTests/Fixtures/\(name)")
    }

    /// The eval-directory transcript pairs, discovered by their `.script.ndjson`
    /// files and paired with the matching `.agent.ndjson`.
    ///
    /// These are the cases scored against the live model: each carries a
    /// directive prompt and the tool a correct turn should select.
    ///
    /// - Returns: The discovered pairs, sorted by name.
    /// - Throws: Any error enumerating the fixtures directory.
    static func liveScoredTranscripts() throws -> [SeededTranscript] {
        let contents = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        return contents
            .filter { $0.lastPathComponent.hasSuffix(".script.ndjson") }
            .map { scriptURL in
                let name = scriptURL.lastPathComponent.replacingOccurrences(
                    of: ".script.ndjson",
                    with: ""
                )
                return SeededTranscript(
                    name: name,
                    scriptURL: scriptURL,
                    agentURL: directory.appendingPathComponent("\(name).agent.ndjson")
                )
            }
            .sorted { $0.name < $1.name }
    }

    /// Every seeded transcript the loader test must parse: the live-scored eval
    /// fixtures plus the wire golden.
    ///
    /// - Returns: All seeded transcripts, wire golden last.
    /// - Throws: Any error enumerating the fixtures directory.
    static func allSeededTranscripts() throws -> [SeededTranscript] {
        try liveScoredTranscripts() + [wireGolden]
    }
}
