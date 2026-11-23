import ACPImport
import Foundation
import FoundationModelsACP
import Synchronization
import Testing

/// A byte source that records each read of the source that it wraps.
final class CountingByteSource: SessionByteSource {
    /// The source that gives the bytes.
    let base: any SessionByteSource

    /// The byte range of each read, in the order of the reads.
    private let calls = Mutex<[Range<Int>]>([])

    /// Makes a counting source.
    ///
    /// - Parameter base: The source that gives the bytes.
    init(_ base: any SessionByteSource) {
        self.base = base
    }

    var size: Int { base.size }

    func read(offset: Int, length: Int) throws -> Data {
        calls.withLock { $0.append(offset..<(offset + length)) }
        return try base.read(offset: offset, length: length)
    }

    /// The byte range of each read, in the order of the reads.
    var readRanges: [Range<Int>] { calls.withLock { $0 } }

    /// The number of reads.
    var readCount: Int { readRanges.count }

    /// The number of bytes that the reads asked for.
    var byteCount: Int { readRanges.reduce(0) { $0 + $1.count } }
}

/// A temporary folder for the generated session files. The folder is
/// removed when the body ends.
enum GeneratedFiles {
    /// Runs a body with a new empty folder, and removes the folder after it.
    static func withFolder<Result>(_ body: (URL) async throws -> Result) async throws -> Result {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ACPImportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        return try await body(folder)
    }

    /// Writes lines to a file. Each line gets a line break, except the last
    /// line when `endsWithLineBreak` is `false`.
    static func write(_ lines: [String], to file: URL, endsWithLineBreak: Bool = true) throws {
        #expect(FileManager.default.createFile(atPath: file.path, contents: nil))
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        for (index, line) in lines.enumerated() {
            let isLast = index == lines.count - 1
            let end = isLast && !endsWithLineBreak ? "" : "\n"
            try handle.write(contentsOf: Data((line + end).utf8))
        }
    }

    /// Writes lines to a new file in a folder.
    ///
    /// - Returns: The URL of the file.
    static func file(_ lines: [String], in folder: URL, endsWithLineBreak: Bool = true) throws -> URL {
        let file = folder.appendingPathComponent("\(UUID().uuidString).jsonl")
        try write(lines, to: file, endsWithLineBreak: endsWithLineBreak)
        return file
    }

    /// Writes lines to a new file in a folder and opens the file through a
    /// counting byte source.
    static func source(
        _ lines: [String], in folder: URL, endsWithLineBreak: Bool = true
    ) throws -> CountingByteSource {
        CountingByteSource(try FileByteSource(forReadingFrom: file(lines, in: folder, endsWithLineBreak: endsWithLineBreak)))
    }
}

/// The two formats, with the line builders of a generated session file.
enum SessionFormat: String, CaseIterable, Sendable {
    case claudeCode
    case codex

    static let sessionID = "0199bbbb-0000-7000-8000-00000000b16f"
    static let cwd = "/work/big"
    static let gitBranch = "main"
    static let firstDateText = "2026-11-03T08:00:00.000Z"
    static let middleDateText = "2026-11-03T08:30:00.000Z"
    static let lastDateText = "2026-11-03T09:00:00.000Z"
    static let firstPrompt = "First prompt of the big session"
    static let lastPrompt = "Last prompt of the big session"
    static let title = "The big session"

    /// The length of the text of a large agent record: 50 KB.
    static let fillerLength = 50_000

    /// The text of a large agent record.
    static let fillerText = String(repeating: "x", count: fillerLength)

    /// The number of large agent records of a 50 MB file.
    static let fillerCount = 1_000

    /// The size that a generated large file has at least.
    static let largeFileSize = 50_000_000

    /// Reads the metadata through the bounded reader.
    func metadata(from source: some SessionByteSource) throws -> SessionFileMetadata {
        switch self {
        case .claudeCode: try ClaudeCodeSessionReader().metadata(from: source)
        case .codex: try CodexSessionReader().metadata(from: source)
        }
    }

    /// The metadata of a full read with the old API.
    func fullMetadata(_ data: Data) throws -> ImportedSessionMetadata {
        switch self {
        case .claudeCode: try ClaudeCodeSessionReader().metadata(data)
        case .codex: try CodexSessionReader().metadata(data)
        }
    }

    /// The updates of a full read with the old API.
    func fullUpdates(_ data: Data) throws -> [SessionUpdate] {
        switch self {
        case .claudeCode: try ClaudeCodeSessionReader().read(data).updates
        case .codex: try CodexSessionReader().read(data).updates
        }
    }

    /// The session of a full read with the old API.
    func fullRead(_ data: Data) throws -> ImportedSession {
        switch self {
        case .claudeCode: try ClaudeCodeSessionReader().read(data)
        case .codex: try CodexSessionReader().read(data)
        }
    }

    /// The session of the block read of the copy.
    func read(from source: some SessionByteSource, blockSize: Int) throws -> ImportedSession {
        switch self {
        case .claudeCode: try ClaudeCodeSessionReader().read(from: source, blockSize: blockSize)
        case .codex: try CodexSessionReader().read(from: source, blockSize: blockSize)
        }
    }

    /// The batches of the streaming reader.
    func updates(from source: some SessionByteSource, blockSize: Int = SessionUpdateBatches.defaultBlockSize) -> SessionUpdateBatches {
        switch self {
        case .claudeCode: ClaudeCodeSessionReader().updates(from: source, blockSize: blockSize)
        case .codex: CodexSessionReader().updates(from: source, blockSize: blockSize)
        }
    }

    /// The URL of the fixture of the format.
    var fixtureURL: URL {
        switch self {
        case .claudeCode: ImportFixtures.directory.appendingPathComponent("claude-code-basic.jsonl")
        case .codex: ImportFixtures.directory.appendingPathComponent("codex-basic.jsonl")
        }
    }

    /// The other format.
    var other: SessionFormat {
        switch self {
        case .claudeCode: .codex
        case .codex: .claudeCode
        }
    }

    /// The first lines of a session: the state records, or the session
    /// record.
    func headLines(automated: Bool) -> [String] {
        switch self {
        case .claudeCode:
            [#"{"type":"permission-mode","permissionMode":"default","sessionId":"\#(Self.sessionID)"}"#]
        case .codex:
            [
                #"{"timestamp":"\#(Self.firstDateText)","type":"session_meta","payload":{"id":"\#(Self.sessionID)","timestamp":"\#(Self.firstDateText)","cwd":"\#(Self.cwd)","originator":"\#(automated ? "codex_exec" : "codex_cli_rs")","cli_version":"0.50.0","git":{"branch":"\#(Self.gitBranch)"}}}"#
            ]
        }
    }

    /// A prompt of the user.
    func prompt(_ text: String, automated: Bool, date: String = Self.firstDateText) -> String {
        switch self {
        case .claudeCode:
            #"{"type":"user","uuid":"u-\#(text.count)","sessionId":"\#(Self.sessionID)","timestamp":"\#(date)","cwd":"\#(Self.cwd)","gitBranch":"\#(Self.gitBranch)","entrypoint":"\#(Self.entrypoint(automated))","isSidechain":false,"version":"2.0.0","message":{"role":"user","content":"\#(text)"}}"#
        case .codex:
            #"{"timestamp":"\#(date)","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"\#(text)"}]}}"#
        }
    }

    /// A large agent record.
    func filler(_ index: Int, automated: Bool) -> String {
        switch self {
        case .claudeCode:
            #"{"type":"assistant","uuid":"a-\#(index)","sessionId":"\#(Self.sessionID)","timestamp":"\#(Self.middleDateText)","cwd":"\#(Self.cwd)","gitBranch":"\#(Self.gitBranch)","entrypoint":"\#(Self.entrypoint(automated))","isSidechain":false,"version":"2.0.0","message":{"id":"m-\#(index)","role":"assistant","content":[{"type":"text","text":"\#(Self.fillerText)"}]}}"#
        case .codex:
            #"{"timestamp":"\#(Self.middleDateText)","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"\#(Self.fillerText)"}]}}"#
        }
    }

    /// A small record with the working folder and the last date.
    func context(automated: Bool) -> String {
        switch self {
        case .claudeCode:
            #"{"type":"assistant","uuid":"a-last","sessionId":"\#(Self.sessionID)","timestamp":"\#(Self.lastDateText)","cwd":"\#(Self.cwd)","gitBranch":"\#(Self.gitBranch)","entrypoint":"\#(Self.entrypoint(automated))","isSidechain":false,"version":"2.0.0","message":{"id":"m-last","role":"assistant","content":[{"type":"text","text":"Done."}]}}"#
        case .codex:
            #"{"timestamp":"\#(Self.lastDateText)","type":"turn_context","payload":{"cwd":"\#(Self.cwd)","model":"gpt"}}"#
        }
    }

    /// The record of the last prompt.
    func lastPrompt(_ text: String) -> String {
        switch self {
        case .claudeCode:
            #"{"type":"last-prompt","lastPrompt":"\#(text)","sessionId":"\#(Self.sessionID)"}"#
        case .codex:
            prompt(text, automated: false, date: Self.middleDateText)
        }
    }

    /// The record of the title.
    var titleLine: String {
        switch self {
        case .claudeCode:
            #"{"type":"ai-title","aiTitle":"\#(Self.title)","sessionId":"\#(Self.sessionID)"}"#
        case .codex:
            #"{"timestamp":"\#(Self.middleDateText)","type":"event_msg","payload":{"type":"thread_name_updated","thread_name":"\#(Self.title)"}}"#
        }
    }

    /// The lines of a 50 MB session.
    func largeSession(automated: Bool) -> [String] {
        headLines(automated: automated)
            + [prompt(Self.firstPrompt, automated: automated)]
            + (0..<Self.fillerCount).map { filler($0, automated: automated) }
            + [titleLine, lastPrompt(Self.lastPrompt), context(automated: automated)]
    }

    /// The number of updates of ``largeSession(automated:)``: the first
    /// prompt, each large record, the last prompt of Codex (a user message)
    /// and the last agent text of Claude Code.
    var largeSessionUpdateCount: Int {
        1 + Self.fillerCount + 1
    }

    /// The metadata that a full read of ``largeSession(automated:)`` gives.
    /// The head of an automated Claude Code session is not read, thus it has
    /// no first date. The head of a Codex session tells if it is automated,
    /// thus it is always read.
    func largeSessionMetadata(automated: Bool) -> SessionFileMetadata {
        let firstDate = self == .claudeCode && automated ? nil : Self.date(Self.firstDateText)
        return SessionFileMetadata(
            agent: self == .claudeCode ? .claudeCode : .codex,
            sourceID: Self.sessionID,
            cwd: URL(fileURLWithPath: Self.cwd),
            gitBranch: Self.gitBranch,
            isAutomated: automated,
            title: Self.title,
            firstPrompt: automated ? nil : Self.firstPrompt,
            lastPrompt: Self.lastPrompt,
            firstDate: firstDate,
            lastDate: Self.date(Self.lastDateText)
        )
    }

    static func entrypoint(_ automated: Bool) -> String {
        automated ? "sdk-cli" : "cli"
    }

    static func date(_ text: String) -> Date {
        ImportFixtures.date(text)
    }
}
