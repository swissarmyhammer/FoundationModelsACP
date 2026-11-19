import ACPMarkdown
import Foundation
import FoundationModelsACP
import Testing

/// `SessionSnapshot`: the snapshot of a shared session (D208).
@Suite struct SessionSnapshotTests {
    /// One combination of the two switches, with the name of its golden
    /// files: `snapshot-<name>.md` and `snapshot-<name>.json`.
    struct Combination: CustomTestStringConvertible, Sendable {
        let name: String
        let includeThoughts: Bool
        let includeToolOutput: Bool
        var testDescription: String { name }
    }

    static let combinations = [
        Combination(name: "all", includeThoughts: true, includeToolOutput: true),
        Combination(name: "no-thoughts", includeThoughts: false, includeToolOutput: true),
        Combination(name: "no-tool-output", includeThoughts: true, includeToolOutput: false),
        Combination(name: "none", includeThoughts: false, includeToolOutput: false),
    ]

    private static func session() throws -> [SessionUpdate] {
        try GoldenFiles.updates(named: "snapshot-session")
    }

    @Test(arguments: combinations)
    func theSnapshotIsTheGoldenSnapshot(_ combination: Combination) throws {
        let snapshot = SessionSnapshot.build(
            updates: try Self.session(),
            options: .init(includeThoughts: combination.includeThoughts, includeToolOutput: combination.includeToolOutput)
        )
        try GoldenFiles.assertGolden(snapshot.markdown, named: "snapshot-\(combination.name)")
        try GoldenFiles.assertGolden(
            String(decoding: try snapshot.encoded(), as: UTF8.self) + "\n",
            named: "snapshot-\(combination.name)",
            extension: "json"
        )
    }

    @Test func theDefaultsKeepTheThoughtsAndTheToolOutput() throws {
        let defaults = SessionSnapshot.Options()
        #expect(defaults.includeThoughts)
        #expect(defaults.includeToolOutput)
        let snapshot = SessionSnapshot.build(updates: try Self.session())
        #expect(snapshot == SessionSnapshot.build(updates: try Self.session(), options: .init(includeThoughts: true, includeToolOutput: true)))
        #expect(snapshot.markdown.contains("The build fails in a.swift."))
        #expect(snapshot.markdown.contains("error: a.swift:3"))
    }

    @Test func theTitleComesFromTheSessionOrTheOptions() throws {
        #expect(SessionSnapshot.build(updates: try Self.session()).options.title == "Share me")
        let titled = SessionSnapshot.build(updates: try Self.session(), options: .init(title: "Mine"))
        #expect(titled.markdown.hasPrefix("# Mine\n"))
    }

    @Test func theStateUpdatesAreNotInTheSnapshot() throws {
        let snapshot = SessionSnapshot.build(updates: try Self.session())
        for update in snapshot.updates {
            switch update {
            case .stateUpdate, .availableCommandsUpdate, .configOptionUpdate, .sessionInfoUpdate, .usageUpdate,
                .subagentUpdate, .notice:
                Issue.record("a state update is in the snapshot: \(update)")
            default:
                break
            }
        }
    }

    @Test func theTurnCountCountsThePromptsAndTheReceivedMessages() throws {
        #expect(SessionSnapshot.build(updates: try Self.session()).turnCount == 3)
        #expect(SessionSnapshot.build(updates: [SessionUpdate]()).turnCount == 0)
    }

    @Test func withNoToolOutputAToolCallKeepsItsTitleKindStatusAndDiffs() throws {
        let snapshot = SessionSnapshot.build(updates: try Self.session(), options: .init(includeToolOutput: false))
        let toolCalls = snapshot.updates.compactMap { update -> ToolCallUpdate? in
            if case .toolCallUpdate(let toolCall) = update { return toolCall }
            return nil
        }
        #expect(toolCalls.map(\.title) == [.value("Run swift build"), .value("Read a.swift"), .value("Edit a.swift")])
        #expect(toolCalls.map(\.status) == [.value(.failed), .value(.completed), .value(.completed)])
        #expect(toolCalls[0].content == .unchanged)
        #expect(toolCalls[0].rawInput == .unchanged)
        #expect(toolCalls[0].rawOutput == .unchanged)
        guard case .value(let editContent) = toolCalls[2].content, case .diff? = editContent.first else {
            Issue.record("the edit lost its diff")
            return
        }
        #expect(editContent.count == 1)
        #expect(!snapshot.updates.contains { if case .terminalUpdate = $0 { true } else { false } })
    }

    @Test func aLongToolOutputIsNotCut() throws {
        let output = String(repeating: "line of output\n", count: 20_000)  // 300,000 bytes
        let updates: [SessionUpdate] = [
            .terminalUpdate(TerminalUpdate(terminalId: TerminalId(rawValue: "t"), command: .value("cat big"))),
            .terminalOutputChunk(TerminalOutputChunk(data: Data(output.utf8).base64EncodedString(), terminalId: TerminalId(rawValue: "t"))),
        ]
        let snapshot = SessionSnapshot.build(updates: updates)
        #expect(snapshot.markdown.contains(String(output.dropLast())))
        let decoded = try SessionSnapshot(decoding: try snapshot.encoded())
        #expect(decoded == snapshot)
    }

    @Test(arguments: combinations)
    func theCodedFormRoundTrips(_ combination: Combination) throws {
        let snapshot = SessionSnapshot.build(
            updates: try Self.session(),
            options: .init(includeThoughts: combination.includeThoughts, includeToolOutput: combination.includeToolOutput, agentName: "Testudo")
        )
        let decoded = try SessionSnapshot(decoding: try snapshot.encoded())
        #expect(decoded == snapshot)
        #expect(try decoded.encoded() == snapshot.encoded())
    }

    @Test func aNewerFormatGivesAClearError() throws {
        let data = Data(#"{"formatVersion":2,"somethingNew":true}"#.utf8)
        #expect(throws: SessionSnapshot.DecodingError.newerFormat(version: 2)) {
            _ = try SessionSnapshot(decoding: data)
        }
        #expect(SessionSnapshot.DecodingError.newerFormat(version: 2).description == "This share needs a newer Testudo.")
    }

    @Test func theSameUpdatesAndOptionsGiveTheSameSnapshot() throws {
        #expect(SessionSnapshot.build(updates: try Self.session()) == SessionSnapshot.build(updates: try Self.session()))
        #expect(try SessionSnapshot.build(updates: try Self.session()).encoded() == SessionSnapshot.build(updates: try Self.session()).encoded())
    }

    @Test func theSnapshotOfASnapshotIsTheSame() throws {
        for combination in Self.combinations {
            let options = SessionSnapshot.Options(includeThoughts: combination.includeThoughts, includeToolOutput: combination.includeToolOutput)
            let snapshot = SessionSnapshot.build(updates: try Self.session(), options: options)
            #expect(SessionSnapshot.build(updates: snapshot.updates, options: snapshot.options) == snapshot)
        }
    }
}
