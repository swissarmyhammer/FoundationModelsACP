import ACPMarkdown
import Foundation
import FoundationModelsACP
import Testing

/// The golden files of the Markdown renderer.
///
/// Each pair is `Golden/<name>.ndjson` (one `SessionUpdate` for each line, in
/// the wire form) and `Golden/<name>.md` (the expected document). The test
/// compares the text byte for byte. Set `RECORD_GOLDEN` to write the `.md`
/// files again when the format changes on purpose. The diff of the golden
/// files is then the review.
@Suite struct SessionMarkdownGoldenTests {
    /// One golden pair and its options.
    struct Case: CustomTestStringConvertible, Sendable {
        /// The name of the pair.
        let name: String
        /// The options of the render.
        let options: SessionMarkdown.Options

        var testDescription: String { name }
    }

    /// Each golden pair.
    static let cases: [Case] = [
        Case(name: "messages", options: .init()),
        Case(name: "thought-hidden", options: .init()),
        Case(name: "thought-shown", options: .init(includeThoughts: true)),
        Case(name: "tool-call-no-content", options: .init()),
        Case(name: "tool-call-text", options: .init()),
        Case(name: "tool-call-diff-patch", options: .init()),
        Case(name: "tool-call-diff-no-patch", options: .init()),
        Case(name: "tool-call-terminal", options: .init()),
        Case(name: "terminal-standalone", options: .init()),
        Case(name: "plan-three-changes", options: .init()),
        Case(name: "session-message-from-session", options: .init()),
        Case(name: "session-message-from-user", options: .init()),
        Case(name: "session-message-sent", options: .init()),
        Case(name: "user-message-sah-meta", options: .init()),
        Case(name: "compaction", options: .init()),
        Case(name: "unknown-update", options: .init()),
        Case(name: "content-blocks", options: .init()),
        Case(name: "backticks", options: .init()),
        Case(name: "title-and-agent-name", options: .init(agentName: "Testudo")),
        Case(name: "empty", options: .init()),
        Case(name: "empty-with-title", options: .init(title: "Nothing yet")),
    ]

    @Test(arguments: cases)
    func theRenderIsTheGoldenDocument(_ goldenCase: Case) throws {
        let input = goldenCase.name == "empty-with-title" ? "empty" : goldenCase.name
        let updates = try GoldenFiles.updates(named: input)
        try GoldenFiles.assertGolden(
            SessionMarkdown.render(updates: updates, options: goldenCase.options),
            named: goldenCase.name
        )
    }

    @Test func theFullSessionIsTheGoldenDocument() throws {
        let updates = try GoldenFiles.fullSessionUpdates()
        try GoldenFiles.assertGolden(
            SessionMarkdown.render(updates: updates, options: .init(agentName: "golden-agent")),
            named: "full-session-agent"
        )
    }

    /// The first line of each golden input decodes as a known update, except
    /// the line that is unknown on purpose. A known update that does not
    /// decode would make an unknown entry, and the golden file would test the
    /// wrong thing.
    @Test(arguments: cases.map(\.name).filter { $0 != "empty-with-title" })
    func eachInputLineDecodesAsTheIntendedUpdate(_ name: String) throws {
        for update in try GoldenFiles.updates(named: name) {
            if case .unknown(let type, _) = update {
                #expect(type == "future_update", "\(name): a line decoded as unknown \(type)")
            }
        }
    }
}
