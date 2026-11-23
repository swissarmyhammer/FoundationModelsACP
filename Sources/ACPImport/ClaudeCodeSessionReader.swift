import Foundation
import FoundationModelsACP

/// Reads a Claude Code session file (`~/.claude/projects/<project>/<id>.jsonl`)
/// into ACP v2 session updates. (D209 (b), (c) of Testudo.)
///
/// Each line is one JSON record. The map:
///
/// - The text of a `user` record is a `user_message_chunk`, and an image
///   block stays an image block. The wire id is the `uuid` of the record.
/// - The text of an `assistant` record is an `agent_message_chunk`, and a
///   `thinking` block is an `agent_thought_chunk`. The wire id is the
///   `message.id`, so the records of one message join.
/// - A `tool_use` block is a tool call with its name and a short form of its
///   input as the title, and the kind from the name. An `Edit` or a
///   `MultiEdit` also has a diff. A `TodoWrite` call is a plan.
/// - The `tool_result` block with the same id adds its text to the tool
///   call, with the status `completed`, or `failed` when `is_error` is true.
/// - A `system` record of the subtype `compact_boundary`, or a `user` record
///   with `isCompactSummary`, is one compaction line.
/// - The title is the last `custom-title` record, else the last `ai-title`
///   record, else the last `summary` record.
///
/// The reader skips and counts: the `isSidechain` records (sub-agents), the
/// `isMeta` records, `redacted_thinking` blocks, each record type and block
/// type that it does not know, and each line that is not JSON.
public struct ClaudeCodeSessionReader: Sendable {
    /// The identifier of the session: the name of the file with no
    /// extension. `nil` takes the `sessionId` of the records.
    public var sourceID: String?

    /// Makes a reader.
    ///
    /// - Parameter sourceID: The name of the file with no extension, or
    ///   `nil`.
    public init(sourceID: String? = nil) {
        self.sourceID = sourceID
    }

    /// Reads a session file.
    ///
    /// - Parameter data: The bytes of the file.
    /// - Returns: The session.
    /// - Throws: ``ImportReadError/notThisFormat`` when no record is a Claude
    ///   Code record, ``ImportReadError/noReadableRecord`` when no record
    ///   gives an update.
    public func read(_ data: Data) throws -> ImportedSession {
        var state = ReadState()
        for line in ImportSupport.lines(of: data) {
            state.read(line: line)
        }
        if let error = state.endOfFileError {
            throw error
        }
        return ImportedSession(
            metadata: state.metadata(sourceID: sourceID),
            updates: state.updates,
            skippedRecordCount: state.skipped.total,
            skippedKinds: state.skipped.kinds
        )
    }

    /// Reads a session file one block at a time: its metadata, each
    /// update, and the count of the records that the reader did not read.
    /// The copy of a session uses it. The memory holds the updates, one
    /// block and one line, never the bytes of the whole file.
    ///
    /// - Parameters:
    ///   - source: The bytes of the file.
    ///   - blockSize: The number of bytes of each read.
    /// - Returns: The session.
    /// - Throws: ``ImportReadError/notThisFormat`` when no record is a Claude
    ///   Code record, ``ImportReadError/noReadableRecord`` when no record
    ///   gives an update, a `CancellationError` when the task is cancelled,
    ///   or the error of a read.
    public func read(
        from source: some SessionByteSource,
        blockSize: Int = SessionUpdateBatches.defaultBlockSize
    ) throws -> ImportedSession {
        var state = ReadState()
        try state.readAll(from: source, blockSize: blockSize)
        if let error = state.endOfFileError {
            throw error
        }
        return ImportedSession(
            metadata: state.metadata(sourceID: sourceID),
            updates: state.updates,
            skippedRecordCount: state.skipped.total,
            skippedKinds: state.skipped.kinds
        )
    }

    /// Scans a session file for its metadata only. The scan parses only the
    /// records that the metadata needs, so it is fast on a large file.
    ///
    /// - Parameter data: The bytes of the file.
    /// - Returns: The metadata.
    /// - Throws: ``ImportReadError/notThisFormat`` when no record is a Claude
    ///   Code record.
    public func metadata(_ data: Data) throws -> ImportedSessionMetadata {
        var scan = MetadataScan()
        for line in ImportSupport.lines(of: data) {
            scan.add(line)
        }
        guard scan.recognized else {
            throw scan.sawJSON ? ImportReadError.notThisFormat : ImportReadError.noReadableRecord
        }
        return ImportedSessionMetadata(
            agent: .claudeCode,
            sourceID: sourceID ?? scan.sessionID ?? "",
            cwd: scan.cwd.map { URL(fileURLWithPath: $0) },
            title: scan.titles.best,
            firstDate: scan.dates.first,
            lastDate: scan.dates.last,
            turnCount: scan.turnCount
        )
    }

    /// Reads the metadata of a session file from some windows of the file
    /// only. (D212 of Testudo, section 4.3.)
    ///
    /// The reader reads the last 64 KB; the last 256 KB one time when the
    /// tail gives no working folder; and the first 64 KB when the session
    /// is not automated. Thus it reads at most 384 KB of a file. A file of
    /// 64 KB or less is read in full, one time, and a file of 256 KB or less
    /// can be read in full by the long tail. A larger file is never read in
    /// full. A partial line at the edge of a window is not read, and a last
    /// line with no line break is not read.
    ///
    /// The fields:
    ///
    /// - `cwd`, `gitBranch`: the last values of the records.
    /// - `isAutomated`: `true` when the last `entrypoint` value starts with
    ///   `sdk`. A file with no `entrypoint` value is typed.
    /// - `firstPrompt`: the first prompt of the head, from a
    ///   `queue-operation` record or a `user` record.
    /// - `lastPrompt`: the last prompt, from a `last-prompt` record or a
    ///   `user` record.
    /// - `title`: the last `custom-title`, else the last `ai-title`, else
    ///   the last `summary` of the windows.
    ///
    /// - Parameter source: The bytes of the file.
    /// - Returns: The metadata.
    /// - Throws: ``ImportReadError/notThisFormat`` when no record of the
    ///   windows is a Claude Code record, ``ImportReadError/noReadableRecord``
    ///   when the windows have no JSON record, or the error of a read.
    public func metadata(from source: some SessionByteSource) throws -> SessionFileMetadata {
        try MetadataWindows.read(source, scan: Self.scanMetadata).metadata(agent: .claudeCode, sourceID: sourceID)
    }

    /// Reads the session updates of a full session file in batches, one
    /// block at a time. The updates are the updates of ``read(_:)``.
    ///
    /// - Parameters:
    ///   - source: The bytes of the file.
    ///   - blockSize: The number of bytes of each read.
    /// - Returns: The batches.
    public func updates(
        from source: some SessionByteSource,
        blockSize: Int = SessionUpdateBatches.defaultBlockSize
    ) -> SessionUpdateBatches {
        SessionUpdateBatches(source: source, blockSize: blockSize, parser: ReadState())
    }
}

// MARK: - Titles

/// The title records of a file. The best is the last `custom-title`, else
/// the last `ai-title`, else the last `summary`.
struct ClaudeTitles {
    var custom: String?
    var ai: String?
    var summary: String?

    var best: String? { custom ?? ai ?? summary }

    /// The rank of a `custom-title`, an `ai-title` and a `summary` record.
    private static let customRank = 2
    private static let aiRank = 1
    private static let summaryRank = 0

    /// The members that hold the text of each type of title record, and
    /// the rank of the type.
    private static let kinds: [String: (keys: [String], rank: Int)] = [
        "custom-title": (["customTitle", "title"], customRank),
        "ai-title": (["aiTitle", "title"], aiRank),
        "summary": (["summary", "title"], summaryRank),
    ]

    /// The types of the title records.
    static let types = Set(kinds.keys)

    /// Reads a title record. Returns `false` when the record is not one.
    mutating func read(_ record: Record) -> Bool {
        switch record["type"] as? String {
        case "custom-title":
            custom = Self.rankedTitle(of: record)?.text ?? custom
        case "ai-title":
            ai = Self.rankedTitle(of: record)?.text ?? ai
        case "summary":
            summary = Self.rankedTitle(of: record)?.text ?? summary
        default:
            return false
        }
        return true
    }

    /// The title of a title record with its rank, or `nil` when the record
    /// is not a title record or has no text.
    static func rankedTitle(of record: Record) -> RankedTitle? {
        guard let type = record["type"] as? String, let kind = kinds[type], let text = text(record, keys: kind.keys) else {
            return nil
        }
        return RankedTitle(text: text, rank: kind.rank)
    }

    private static func text(_ record: Record, keys: [String]) -> String? {
        for key in keys {
            if let value = record[key] as? String {
                let line = ImportSupport.singleLine(value)
                if !line.isEmpty { return line }
            }
        }
        return nil
    }
}

// MARK: - The read

extension ClaudeCodeSessionReader {
    /// The state of one read.
    private struct ReadState: SessionRecordParser {
        var updates: [SessionUpdate] = []
        var emittedCount = 0
        var skipped = SkipCounter()
        var dates = DateRange()
        var titles = ClaudeTitles()
        var cwd: String?
        var sessionID: String?
        var turnCount = 0
        var jsonRecords = 0
        var recognized = 0
        /// The tool calls that are plans: their results give no update.
        var planCalls: Set<String> = []
        /// `true` when the last update is a compaction.
        var lastWasCompaction = false

        func metadata(sourceID: String?) -> ImportedSessionMetadata {
            ImportedSessionMetadata(
                agent: .claudeCode,
                sourceID: sourceID ?? sessionID ?? "",
                cwd: cwd.map { URL(fileURLWithPath: $0) },
                title: titles.best,
                firstDate: dates.first,
                lastDate: dates.last,
                turnCount: turnCount
            )
        }

        mutating func read(line: Data.SubSequence) {
            guard let record = ImportSupport.record(line) else {
                skipped.skip(ImportSupport.invalidJSONKind)
                return
            }
            read(record)
        }

        mutating func emit(_ update: SessionUpdate) {
            updates.append(update)
            emittedCount += 1
            if case .compactionUpdate = update {
                lastWasCompaction = true
            } else {
                lastWasCompaction = false
            }
        }

        mutating func read(_ record: Record) {
            jsonRecords += 1
            guard let type = record["type"] as? String, record["sessionId"] != nil || record["uuid"] != nil || ClaudeTitles.types.contains(type) else {
                skipped.skip((record["type"] as? String) ?? "unknown")
                return
            }
            recognized += 1
            dates.add(ImportSupport.date(record["timestamp"]))
            if cwd == nil, let value = record["cwd"] as? String, !value.isEmpty { cwd = value }
            if sessionID == nil, let value = record["sessionId"] as? String { sessionID = value }
            if titles.read(record) {
                return
            }
            if record["isSidechain"] as? Bool == true {
                skipped.skip("\(type):sidechain")
                return
            }
            switch type {
            case "user":
                readUser(record)
            case "assistant":
                readAssistant(record)
            case "system" where record["subtype"] as? String == "compact_boundary":
                addCompaction(id: "compact-" + ((record["uuid"] as? String) ?? String(emittedCount)))
            case "system":
                skipped.skip("system:" + ((record["subtype"] as? String) ?? "unknown"))
            default:
                skipped.skip(type)
            }
        }

        mutating func addCompaction(id: String) {
            guard !lastWasCompaction else { return }
            emit(ImportSupport.compaction(id: id))
        }

        mutating func readUser(_ record: Record) {
            let uuid = (record["uuid"] as? String) ?? "user-\(emittedCount)"
            if record["isCompactSummary"] as? Bool == true {
                addCompaction(id: "compact-" + uuid)
                return
            }
            if record["isMeta"] as? Bool == true {
                skipped.skip("user:meta")
                return
            }
            guard let message = record["message"] as? Record else {
                skipped.skip("user:no-message")
                return
            }
            if let text = message["content"] as? String {
                guard !text.isEmpty else {
                    skipped.skip("user:empty")
                    return
                }
                emit(.userMessageChunk(ImportSupport.textChunk(text, messageId: uuid)))
                turnCount += 1
                return
            }
            guard let blocks = message["content"] as? [Record] else {
                skipped.skip("user:no-content")
                return
            }
            var prompt = false
            for block in blocks {
                switch block["type"] as? String {
                case "text":
                    if let text = block["text"] as? String, !text.isEmpty {
                        emit(.userMessageChunk(ImportSupport.textChunk(text, messageId: uuid)))
                        prompt = true
                    }
                case "image":
                    if let image = Self.image(block) {
                        emit(.userMessageChunk(ContentChunk(content: image, messageId: MessageId(rawValue: uuid))))
                        prompt = true
                    } else {
                        skipped.skip("block:image")
                    }
                case "tool_result":
                    readToolResult(block)
                case let other:
                    skipped.skip("block:" + (other ?? "unknown"))
                }
            }
            if prompt { turnCount += 1 }
        }

        mutating func readToolResult(_ block: Record) {
            guard let id = block["tool_use_id"] as? String else {
                skipped.skip("block:tool_result")
                return
            }
            guard !planCalls.contains(id) else { return }
            var output: [ContentBlock] = []
            if let text = block["content"] as? String {
                if !text.isEmpty { output.append(.text(TextContent(text: text))) }
            } else if let parts = block["content"] as? [Record] {
                for part in parts {
                    switch part["type"] as? String {
                    case "text":
                        if let text = part["text"] as? String, !text.isEmpty { output.append(.text(TextContent(text: text))) }
                    case "image":
                        if let image = Self.image(part) { output.append(image) } else { skipped.skip("block:image") }
                    case let other:
                        skipped.skip("block:" + (other ?? "unknown"))
                    }
                }
            }
            for update in ImportSupport.toolCallEnd(id: id, failed: block["is_error"] as? Bool == true, output: output) {
                emit(update)
            }
        }

        mutating func readAssistant(_ record: Record) {
            guard let message = record["message"] as? Record, let blocks = message["content"] as? [Record] else {
                skipped.skip("assistant:no-content")
                return
            }
            let messageId = (message["id"] as? String) ?? (record["uuid"] as? String) ?? "assistant-\(emittedCount)"
            for block in blocks {
                switch block["type"] as? String {
                case "text":
                    if let text = block["text"] as? String, !text.isEmpty {
                        emit(.agentMessageChunk(ImportSupport.textChunk(text, messageId: messageId)))
                    }
                case "thinking":
                    if let text = block["thinking"] as? String, !text.isEmpty {
                        emit(.agentThoughtChunk(ImportSupport.textChunk(text, messageId: messageId + "/thinking")))
                    }
                case "tool_use":
                    readToolUse(block)
                case let other:
                    skipped.skip("block:" + (other ?? "unknown"))
                }
            }
        }

        mutating func readToolUse(_ block: Record) {
            guard let id = block["id"] as? String, let name = block["name"] as? String else {
                skipped.skip("block:tool_use")
                return
            }
            let input = (block["input"] as? Record) ?? [:]
            if name == "TodoWrite", let todos = input["todos"] as? [Record] {
                planCalls.insert(id)
                let items = todos.compactMap { todo -> (content: String, status: String)? in
                    guard let content = todo["content"] as? String else { return nil }
                    return (content, (todo["status"] as? String) ?? "pending")
                }
                emit(ImportSupport.plan(id: id, items: items))
                return
            }
            let title = ImportSupport.toolTitle(name: name, detail: ImportSupport.inputDetail(input, preferred: Self.detailKeys(name)))
            var content: [ToolCallContent] = []
            if let path = input["file_path"] as? String {
                var edits: [(old: String, new: String)] = []
                if let old = input["old_string"] as? String, let new = input["new_string"] as? String {
                    edits.append((old, new))
                }
                for edit in (input["edits"] as? [Record]) ?? [] {
                    if let old = edit["old_string"] as? String, let new = edit["new_string"] as? String {
                        edits.append((old, new))
                    }
                }
                if let diff = ImportSupport.diff(path: path, edits: edits) {
                    content.append(diff)
                }
            }
            emit(ImportSupport.toolCallStart(id: id, title: title, kind: Self.kind(name), content: content))
        }

        static func kind(_ name: String) -> ToolKind {
            switch name {
            case "Read": .read
            case "Edit", "MultiEdit", "Write", "NotebookEdit": .edit
            case "Bash": .execute
            case "Grep", "Glob": .search
            case "WebFetch", "WebSearch": .fetch
            default: .other
            }
        }

        static func detailKeys(_ name: String) -> [String] {
            switch name {
            case "Bash": ["command"]
            case "Read", "Edit", "MultiEdit", "Write": ["file_path"]
            case "NotebookEdit": ["notebook_path"]
            case "Grep", "Glob": ["pattern"]
            case "WebFetch": ["url"]
            case "WebSearch": ["query"]
            case "Task", "Agent": ["description", "prompt"]
            default: []
            }
        }

        static func image(_ block: Record) -> ContentBlock? {
            guard let source = block["source"] as? Record, let data = source["data"] as? String,
                let mimeType = source["media_type"] as? String
            else {
                return nil
            }
            return ImportSupport.image(data: data, mimeType: mimeType)
        }
    }
}

// MARK: - The metadata scan

extension ClaudeCodeSessionReader {
    /// The scan of the metadata. It parses only the lines that can change
    /// the metadata, and reads the dates with a byte search.
    private struct MetadataScan {
        var dates = DateRange()
        var titles = ClaudeTitles()
        var cwd: String?
        var sessionID: String?
        var turnCount = 0
        var recognized = false
        var sawJSON = false

        private static let timestampKey = Array(#""timestamp":""#.utf8)
        private static let userType = Array(#""type":"user""#.utf8)
        private static let toolUseID = Array(#""tool_use_id""#.utf8)
        private static let titleMarkers = [Array(#""type":"custom-title""#.utf8), Array(#""type":"ai-title""#.utf8), Array(#""type":"summary""#.utf8)]
        private static let sessionKey = Array(#""sessionId""#.utf8)

        mutating func add(_ line: Data.SubSequence) {
            if line.first == UInt8(ascii: "{") { sawJSON = true }
            if let date = Self.timestamp(in: line) {
                dates.add(date)
            }
            let isUser = ImportSupport.contains(line, Self.userType)
            let isTitle = Self.titleMarkers.contains { ImportSupport.contains(line, $0) }
            let needsIdentity = cwd == nil || sessionID == nil || !recognized
            guard isTitle || (isUser && !ImportSupport.contains(line, Self.toolUseID)) || (needsIdentity && ImportSupport.contains(line, Self.sessionKey)) else {
                return
            }
            guard let record = ImportSupport.record(line) else { return }
            if titles.read(record) {
                recognized = true
                return
            }
            guard record["sessionId"] != nil || record["uuid"] != nil else { return }
            recognized = true
            if cwd == nil, let value = record["cwd"] as? String, !value.isEmpty { cwd = value }
            if sessionID == nil, let value = record["sessionId"] as? String { sessionID = value }
            guard record["type"] as? String == "user", record["isSidechain"] as? Bool != true,
                record["isMeta"] as? Bool != true, record["isCompactSummary"] as? Bool != true,
                let message = record["message"] as? Record
            else {
                return
            }
            if let text = message["content"] as? String, !text.isEmpty {
                turnCount += 1
            } else if let blocks = message["content"] as? [Record],
                blocks.contains(where: { ["text", "image"].contains($0["type"] as? String) })
            {
                turnCount += 1
            }
        }

        /// Reads the value of `"timestamp":"…"` with no parse of the line.
        static func timestamp(in line: Data.SubSequence) -> Date? {
            guard let start = line.firstRange(of: timestampKey)?.upperBound,
                let end = line[start...].firstIndex(of: UInt8(ascii: "\""))
            else {
                return nil
            }
            return ImportSupport.date(String(decoding: line[start..<end], as: UTF8.self))
        }
    }
}

// MARK: - The bounded metadata scan

extension ClaudeCodeSessionReader {
    /// The start of an `entrypoint` value of a session that a program
    /// started, such as `sdk-cli` or `sdk-ts`.
    static let automatedEntrypointPrefix = "sdk"

    /// Reads one record of a window into the metadata fields.
    static func scanMetadata(_ record: Record, into fields: inout MetadataFields) {
        guard let type = record["type"] as? String,
            record["sessionId"] != nil || record["uuid"] != nil || ClaudeTitles.types.contains(type)
        else {
            return
        }
        fields.isRecognized = true
        fields.dates.add(ImportSupport.date(record["timestamp"]))
        if let title = ClaudeTitles.rankedTitle(of: record) {
            fields.noteTitle(title)
            return
        }
        fields.noteSourceID(record["sessionId"])
        fields.noteCwd(record["cwd"])
        fields.noteGitBranch(record["gitBranch"])
        if let entrypoint = record["entrypoint"] as? String, !entrypoint.isEmpty {
            fields.isAutomated = entrypoint.hasPrefix(automatedEntrypointPrefix)
        }
        switch type {
        case "queue-operation":
            if let content = record["content"] as? String {
                fields.notePrompt(content)
            }
        case "last-prompt":
            if let text = record["lastPrompt"] as? String {
                fields.noteLastPrompt(text)
            }
        case "user":
            if let text = promptText(of: record) {
                fields.notePrompt(text)
            }
        default:
            break
        }
    }

    /// The text of a prompt of the user: a string content, else the first
    /// text block. A record of a sub-agent, a meta record, a summary of a
    /// compaction and a record with only tool results give no prompt.
    static func promptText(of record: Record) -> String? {
        guard record["isSidechain"] as? Bool != true, record["isMeta"] as? Bool != true,
            record["isCompactSummary"] as? Bool != true, let message = record["message"] as? Record
        else {
            return nil
        }
        if let text = message["content"] as? String {
            return text
        }
        let blocks = (message["content"] as? [Record]) ?? []
        return blocks.first { $0["type"] as? String == "text" }?["text"] as? String
    }
}
