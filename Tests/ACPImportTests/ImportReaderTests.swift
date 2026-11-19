import ACPImport
import ACPMarkdown
import Foundation
import FoundationModelsACP
import Testing

/// The fixtures and golden files of the readers.
enum ImportFixtures {
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures")

    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: directory.appendingPathComponent(name))
    }

    /// The updates as pretty JSON with sorted keys, one stable text.
    static func json(_ updates: [SessionUpdate]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(updates), as: UTF8.self) + "\n"
    }

    /// Compares a text with its golden file, or writes the file when
    /// `RECORD_GOLDEN` is set.
    static func assertGolden(_ text: String, named name: String, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let url = directory.appendingPathComponent(name)
        if ProcessInfo.processInfo.environment["RECORD_GOLDEN"] != nil {
            try Data(text.utf8).write(to: url)
            return
        }
        let expected = try String(contentsOf: url, encoding: .utf8)
        #expect(text == expected, "\(name) differs; run with RECORD_GOLDEN=1 and review the diff", sourceLocation: sourceLocation)
    }

    static let claudeSource = "5a1e0000-0000-4000-8000-000000000001"
    static let codexSource = "0199aaaa-0000-7000-8000-00000000c0de"

    static func date(_ text: String) -> Date {
        try! Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }
}

/// `ClaudeCodeSessionReader`.
@Suite struct ClaudeCodeSessionReaderTests {
    private static func read() throws -> ImportedSession {
        try ClaudeCodeSessionReader(sourceID: ImportFixtures.claudeSource).read(ImportFixtures.data("claude-code-basic.jsonl"))
    }

    @Test func theUpdatesAreTheGoldenUpdates() throws {
        try ImportFixtures.assertGolden(ImportFixtures.json(try Self.read().updates), named: "claude-code-basic.updates.json")
    }

    @Test func theMarkdownIsTheGoldenMarkdown() throws {
        let session = try Self.read()
        let markdown = SessionMarkdown.render(updates: session.updates, options: .init(includeThoughts: true, title: session.metadata.title))
        try ImportFixtures.assertGolden(markdown, named: "claude-code-basic.md")
    }

    @Test func theMetadataIsRead() throws {
        let metadata = try Self.read().metadata
        #expect(metadata.agent == .claudeCode)
        #expect(metadata.sourceID == ImportFixtures.claudeSource)
        #expect(metadata.cwd == URL(fileURLWithPath: "/work/app"))
        #expect(metadata.title == "Test fix")
        #expect(metadata.firstDate == ImportFixtures.date("2026-11-01T10:00:00.000Z"))
        #expect(metadata.lastDate == ImportFixtures.date("2026-11-01T10:00:17.000Z"))
        #expect(metadata.turnCount == 2)
    }

    @Test func theScanGivesTheSameMetadataAsTheRead() throws {
        let data = try ImportFixtures.data("claude-code-basic.jsonl")
        let reader = ClaudeCodeSessionReader(sourceID: ImportFixtures.claudeSource)
        #expect(try reader.metadata(data) == reader.read(data).metadata)
        #expect(try ClaudeCodeSessionReader().metadata(data).sourceID == ImportFixtures.claudeSource)
    }

    @Test func theSkippedRecordsAreCounted() throws {
        let session = try Self.read()
        #expect(session.skippedKinds == [
            "invalid-json": 1,
            "queue-operation": 1,
            "block:redacted_thinking": 1,
            "block:future_block": 1,
            "assistant:sidechain": 1,
            "user:meta": 1,
            "attachment": 1,
        ])
        #expect(session.skippedRecordCount == 7)
    }

    @Test func anAiTitleIsTheTitleWhenThereIsNoCustomTitle() throws {
        let data = Data((#"{"type":"ai-title","aiTitle":"From the model","sessionId":"s"}"# + "\n"
            + #"{"type":"user","uuid":"u","sessionId":"s","message":{"role":"user","content":"Hi"}}"#).utf8)
        #expect(try ClaudeCodeSessionReader().read(data).metadata.title == "From the model")
        #expect(try ClaudeCodeSessionReader().metadata(data).title == "From the model")
    }
}

/// `CodexSessionReader`.
@Suite struct CodexSessionReaderTests {
    private static func read() throws -> ImportedSession {
        try CodexSessionReader().read(ImportFixtures.data("codex-basic.jsonl"))
    }

    @Test func theUpdatesAreTheGoldenUpdates() throws {
        try ImportFixtures.assertGolden(ImportFixtures.json(try Self.read().updates), named: "codex-basic.updates.json")
    }

    @Test func theMarkdownIsTheGoldenMarkdown() throws {
        let session = try Self.read()
        let markdown = SessionMarkdown.render(updates: session.updates, options: .init(includeThoughts: true, title: session.metadata.title))
        try ImportFixtures.assertGolden(markdown, named: "codex-basic.md")
    }

    @Test func theMetadataIsRead() throws {
        let metadata = try Self.read().metadata
        #expect(metadata.agent == .codex)
        #expect(metadata.sourceID == ImportFixtures.codexSource)
        #expect(metadata.cwd == URL(fileURLWithPath: "/work/cli"))
        #expect(metadata.title == "Add a README")
        #expect(metadata.firstDate == ImportFixtures.date("2026-11-02T09:00:00.000Z"))
        #expect(metadata.lastDate == ImportFixtures.date("2026-11-02T09:00:15.000Z"))
        #expect(metadata.turnCount == 2)
    }

    @Test func theScanGivesTheSameMetadataAsTheRead() throws {
        let data = try ImportFixtures.data("codex-basic.jsonl")
        #expect(try CodexSessionReader().metadata(data) == CodexSessionReader().read(data).metadata)
    }

    @Test func theSkippedRecordsAreCounted() throws {
        let session = try Self.read()
        #expect(session.skippedKinds == [
            "invalid-json": 1,
            "message:developer": 1,
            "message:context": 1,
            "response_item:future_item": 1,
            "future_record": 1,
        ])
    }

    @Test func aFailedShellCallIsFailed() throws {
        let failed = try Self.read().updates.contains {
            if case .toolCallUpdate(let call) = $0, call.toolCallId == ToolCallId(rawValue: "call_fail") {
                return call.status == .value(.failed)
            }
            return false
        }
        #expect(failed)
    }
}

/// The rules that hold for both readers.
@Suite struct ImportReaderRuleTests {
    enum Format: String, CaseIterable, Sendable {
        case claudeCode = "claude-code-basic.jsonl"
        case codex = "codex-basic.jsonl"

        func read(_ data: Data) throws -> ImportedSession {
            switch self {
            case .claudeCode: try ClaudeCodeSessionReader().read(data)
            case .codex: try CodexSessionReader().read(data)
            }
        }

        func metadata(_ data: Data) throws -> ImportedSessionMetadata {
            switch self {
            case .claudeCode: try ClaudeCodeSessionReader().metadata(data)
            case .codex: try CodexSessionReader().metadata(data)
            }
        }

        var other: Format { self == .claudeCode ? .codex : .claudeCode }
    }

    @Test(arguments: Format.allCases)
    func aSecondReadGivesTheSameUpdatesAndIds(_ format: Format) throws {
        let data = try ImportFixtures.data(format.rawValue)
        #expect(try format.read(data) == format.read(data))
    }

    @Test(arguments: Format.allCases)
    func theMergeEngineAndTheRendererTakeTheUpdates(_ format: Format) throws {
        let session = try format.read(ImportFixtures.data(format.rawValue))
        let engine = SessionMergeEngine(replaying: session.updates)
        for entry in engine.entries {
            if case .unknown(let type, _) = entry.kind {
                Issue.record("an unknown entry: \(type)")
            }
        }
        for update in session.updates {
            if case .unknown(let type, _) = update {
                Issue.record("an unknown update: \(type)")
            }
        }
        // The updates encode and decode with no change.
        let data = try JSONEncoder().encode(session.updates)
        #expect(try JSONDecoder().decode([SessionUpdate].self, from: data) == session.updates)
        #expect(!SessionMarkdown.render(updates: session.updates).contains("unknown session update"))
    }

    @Test(arguments: Format.allCases)
    func aFileOfTheOtherFormatIsNotThisFormat(_ format: Format) throws {
        let data = try ImportFixtures.data(format.other.rawValue)
        #expect(throws: ImportReadError.notThisFormat) { try format.read(data) }
        #expect(throws: ImportReadError.notThisFormat) { try format.metadata(data) }
    }

    @Test(arguments: Format.allCases)
    func anEmptyFileHasNoReadableRecord(_ format: Format) throws {
        #expect(throws: ImportReadError.noReadableRecord) { try format.read(Data()) }
        #expect(throws: ImportReadError.noReadableRecord) { try format.read(Data("not json\n\n".utf8)) }
    }

    @Test func aFileWithOnlyATitleHasNoReadableRecord() throws {
        let data = Data(#"{"type":"custom-title","customTitle":"Only a title","sessionId":"s"}"#.utf8)
        #expect(throws: ImportReadError.noReadableRecord) { try ClaudeCodeSessionReader().read(data) }
        let codex = Data(#"{"timestamp":"2026-11-02T09:00:00Z","type":"session_meta","payload":{"id":"x","cwd":"/w"}}"#.utf8)
        #expect(throws: ImportReadError.noReadableRecord) { try CodexSessionReader().read(codex) }
    }

    @Test func aLongToolTitleIsCut() throws {
        let command = String(repeating: "echo word ", count: 30)
        let line = #"{"type":"assistant","uuid":"a","sessionId":"s","message":{"id":"m","role":"assistant","content":[{"type":"tool_use","id":"t","name":"Bash","input":{"command":"\#(command)"}}]}}"#
        let updates = try ClaudeCodeSessionReader().read(Data(line.utf8)).updates
        guard case .toolCallUpdate(let call)? = updates.first, case .value(let title) = call.title else {
            Issue.record("no tool call")
            return
        }
        #expect(title.count == 80)
        #expect(title.hasPrefix("Bash: echo word"))
        #expect(title.hasSuffix("…"))
    }
}

/// The metadata scan is fast on a large file.
@Suite struct ImportMetadataScanSpeedTests {
    /// About 50 MB of records: many large agent and tool records, few
    /// prompts.
    private static func claudeFile() -> Data {
        let text = String(repeating: "x", count: 50_000)
        var lines: [String] = []
        for index in 0..<1_000 {
            if index % 100 == 0 {
                lines.append(#"{"type":"user","uuid":"u\#(index)","sessionId":"s","timestamp":"2026-11-01T10:00:00.000Z","cwd":"/w","message":{"role":"user","content":"Prompt \#(index)"}}"#)
            }
            lines.append(#"{"type":"assistant","uuid":"a\#(index)","sessionId":"s","timestamp":"2026-11-01T10:00:01.000Z","cwd":"/w","message":{"id":"m\#(index)","role":"assistant","content":[{"type":"text","text":"\#(text)"}]}}"#)
        }
        return Data(lines.joined(separator: "\n").utf8)
    }

    private static func codexFile() -> Data {
        let text = String(repeating: "y", count: 50_000)
        var lines = [#"{"timestamp":"2026-11-02T09:00:00.000Z","type":"session_meta","payload":{"id":"c","cwd":"/w"}}"#]
        for index in 0..<1_000 {
            if index % 100 == 0 {
                lines.append(#"{"timestamp":"2026-11-02T09:00:01.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Prompt \#(index)"}]}}"#)
            }
            lines.append(#"{"timestamp":"2026-11-02T09:00:02.000Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"\#(text)"}]}}"#)
        }
        return Data(lines.joined(separator: "\n").utf8)
    }

    /// The bound of one scan of 50 MB. A debug build scans in well under
    /// it; a full parse of each line takes longer.
    private static let bound = Duration.seconds(4)

    @Test func theClaudeCodeScanIsFast() throws {
        let data = Self.claudeFile()
        #expect(data.count > 50_000_000)
        let clock = ContinuousClock()
        var metadata: ImportedSessionMetadata?
        let elapsed = try clock.measure { metadata = try ClaudeCodeSessionReader().metadata(data) }
        #expect(metadata?.turnCount == 10)
        #expect(elapsed < Self.bound, "the scan took \(elapsed)")
    }

    @Test func theCodexScanIsFast() throws {
        let data = Self.codexFile()
        #expect(data.count > 50_000_000)
        let clock = ContinuousClock()
        var metadata: ImportedSessionMetadata?
        let elapsed = try clock.measure { metadata = try CodexSessionReader().metadata(data) }
        #expect(metadata?.turnCount == 10)
        #expect(elapsed < Self.bound, "the scan took \(elapsed)")
    }
}
