import Foundation
import FoundationModelsACP

/// Reads a Codex session file (`~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`)
/// into ACP v2 session updates. (D209 (b), (c) of Testudo.)
///
/// Each line is one JSON record `{"timestamp", "type", "payload"}`. The map:
///
/// - `session_meta`: the session id, the `cwd` and the first date.
/// - `response_item` of the type `message`: the role `user` is a
///   `user_message_chunk`, the role `assistant` is an `agent_message_chunk`.
///   A user message that holds only the context that Codex adds
///   (`<environment_context>`, `<user_instructions>`) is skipped.
/// - `response_item` of the type `reasoning`: its summary text is an
///   `agent_thought_chunk`.
/// - `function_call`, `custom_tool_call` and `local_shell_call` are a tool
///   call. A shell call has the kind `execute` and its command in the title.
///   An `apply_patch` call has the kind `edit` and a diff with the patch
///   text. An `update_plan` call is a plan.
/// - The output item with the same `call_id` ends the tool call, with its
///   text as the content.
/// - `compacted` is one compaction line.
/// - The title is the thread name, when the file has one.
///
/// The reader skips `event_msg` and `turn_context` records and the token
/// records with no count, because they repeat the response items or are
/// state. It skips and counts each other record and item that it does not
/// know, and each line that is not JSON.
///
/// The wire id of a message is `codex-<line>`, the place of its line in the
/// file, so two reads of the same file give the same ids.
public struct CodexSessionReader: Sendable {
    /// The identifier of the session. `nil` takes the id of the
    /// `session_meta` record.
    public var sourceID: String?

    /// Makes a reader.
    ///
    /// - Parameter sourceID: The identifier of the session, or `nil`.
    public init(sourceID: String? = nil) {
        self.sourceID = sourceID
    }

    /// Reads a session file.
    ///
    /// - Parameter data: The bytes of the file.
    /// - Returns: The session.
    /// - Throws: ``ImportReadError/notThisFormat`` when no record is a Codex
    ///   record, ``ImportReadError/noReadableRecord`` when no record gives
    ///   an update.
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
    /// - Throws: ``ImportReadError/notThisFormat`` when no record is a Codex
    ///   record, ``ImportReadError/noReadableRecord`` when no record
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
    /// - Throws: ``ImportReadError/notThisFormat`` when no record is a Codex
    ///   record.
    public func metadata(_ data: Data) throws -> ImportedSessionMetadata {
        var scan = MetadataScan()
        for line in ImportSupport.lines(of: data) {
            scan.add(line)
        }
        guard scan.recognized else {
            throw scan.sawJSON ? ImportReadError.notThisFormat : ImportReadError.noReadableRecord
        }
        return ImportedSessionMetadata(
            agent: .codex,
            sourceID: sourceID ?? scan.meta.id ?? "",
            cwd: scan.meta.cwd.map { URL(fileURLWithPath: $0) },
            title: scan.meta.title,
            firstDate: scan.dates.first,
            lastDate: scan.dates.last,
            turnCount: scan.turnCount
        )
    }

    /// Reads the metadata of a session file from some windows of the file
    /// only, as `ClaudeCodeSessionReader.metadata(from:)` does. (D212 of
    /// Testudo, section 4.3.)
    ///
    /// The fields:
    ///
    /// - `sourceID`, `gitBranch` (`git.branch`): the `session_meta` record.
    /// - `cwd`: the last `cwd` of a `turn_context` or `session_meta` record.
    /// - `isAutomated`: `true` when the `originator` of the `session_meta`
    ///   record has the word `exec` (the `codex exec` command). The tail of
    ///   a Codex file does not tell, thus the reader reads the head.
    /// - `firstPrompt`, `lastPrompt`: the first and the last user message
    ///   that is not the context that Codex adds.
    /// - `title`: the last thread name.
    ///
    /// - Parameter source: The bytes of the file.
    /// - Returns: The metadata.
    /// - Throws: ``ImportReadError/notThisFormat`` when no record of the
    ///   windows is a Codex record, ``ImportReadError/noReadableRecord`` when
    ///   the windows have no JSON record, or the error of a read.
    public func metadata(from source: some SessionByteSource) throws -> SessionFileMetadata {
        try MetadataWindows.read(source, scan: Self.scanMetadata).metadata(agent: .codex, sourceID: sourceID)
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

// MARK: - Shared rules

/// The session metadata of a Codex file.
struct CodexMeta {
    var id: String?
    var cwd: String?
    var title: String?

    /// Reads a `session_meta` payload.
    mutating func read(meta payload: Record) {
        if id == nil, let value = payload["id"] as? String { id = value }
        if cwd == nil, let value = payload["cwd"] as? String, !value.isEmpty { cwd = value }
        title = Self.title(of: payload) ?? title
    }

    /// Reads an `event_msg` payload for a new thread name.
    mutating func read(event payload: Record) {
        title = Self.threadName(ofEvent: payload) ?? title
    }

    /// The new thread name of an `event_msg` payload, or `nil` when the
    /// event does not name the thread.
    static func threadName(ofEvent payload: Record) -> String? {
        guard let type = payload["type"] as? String, type.contains("thread_name") || type.contains("title") else {
            return nil
        }
        return title(of: payload)
    }

    /// The last title member of a payload: `thread_name`, `title` or `name`.
    static func title(of payload: Record) -> String? {
        ["thread_name", "title", "name"]
            .compactMap { (payload[$0] as? String).map(ImportSupport.singleLine) }
            .last { !$0.isEmpty }
    }
}

extension CodexSessionReader {
    /// The record types that the reader skips with no count, because they
    /// repeat the response items or are state.
    static let ignoredTypes: Set<String> = ["event_msg", "turn_context"]

    /// The text of a user message that holds only the context of Codex.
    static func isContext(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return ["<environment_context>", "<user_instructions>", "<user_shell_command>", "# AGENTS.md instructions"]
            .contains { trimmed.hasPrefix($0) }
    }

    /// The type and the payload of a record, also for the earlier form of
    /// the file, where a line is the item itself.
    static func split(_ record: Record) -> (type: String, payload: Record)? {
        if let type = record["type"] as? String, let payload = record["payload"] as? Record {
            return (type, payload)
        }
        if let type = record["type"] as? String, responseTypes.contains(type) {
            return ("response_item", record)
        }
        if record["id"] is String, record["instructions"] != nil || record["timestamp"] != nil, record["type"] == nil {
            return ("session_meta", record)
        }
        if record["record_type"] is String {
            return ("state", record)
        }
        return nil
    }

    /// The types of the response items.
    static let responseTypes: Set<String> = [
        "message", "reasoning", "function_call", "function_call_output", "custom_tool_call",
        "custom_tool_call_output", "local_shell_call", "local_shell_call_output", "web_search_call",
    ]

    /// The text of the content items of a message.
    static func text(of content: Any?) -> String {
        if let text = content as? String { return text }
        guard let items = content as? [Record] else { return "" }
        return items.compactMap { item -> String? in
            switch item["type"] as? String {
            case "input_text", "output_text", "text": item["text"] as? String
            default: nil
            }
        }.joined()
    }

    /// The kind and the title detail of a tool from its name and input.
    static func tool(name: String, input: Record) -> (kind: ToolKind, detail: String?) {
        switch name {
        case "shell", "local_shell", "exec_command", "container.exec", "shell_command":
            return (.execute, ImportSupport.inputDetail(input, preferred: ["command", "cmd"]))
        case "apply_patch":
            return (.edit, nil)
        case "read_file", "view_image":
            return (.read, ImportSupport.inputDetail(input, preferred: ["path", "file_path"]))
        case "web_search", "web_fetch":
            return (.fetch, ImportSupport.inputDetail(input, preferred: ["query", "url"]))
        case "grep", "search", "find":
            return (.search, ImportSupport.inputDetail(input, preferred: ["pattern", "query"]))
        default:
            return (.other, ImportSupport.inputDetail(input, preferred: []))
        }
    }

    /// The diff of an `apply_patch` text: the changed paths, and the patch
    /// text as it is.
    static func patchDiff(_ patch: String, cwd: String?) -> ToolCallContent? {
        var changes: [DiffChange] = []
        for line in patch.split(separator: "\n") {
            let prefixes: [(String, (AbsolutePath) -> DiffChange.Payload)] = [
                ("*** Add File: ", { .add(DiffPathChange(path: $0)) }),
                ("*** Update File: ", { .modify(DiffPathChange(path: $0)) }),
                ("*** Delete File: ", { .delete(DiffPathChange(path: $0)) }),
            ]
            for (prefix, make) in prefixes where line.hasPrefix(prefix) {
                var path = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                if !path.hasPrefix("/"), let cwd {
                    path = URL(fileURLWithPath: cwd).appendingPathComponent(path).path
                }
                changes.append(DiffChange(operation: make(AbsolutePath(rawValue: path))))
            }
        }
        guard !changes.isEmpty else { return nil }
        return .diff(Diff(changes: changes, patch: DiffPatch(format: .unknown("apply_patch"), text: patch)))
    }

    /// The text of the output of a tool call, and `true` when the call
    /// failed.
    static func output(_ value: Any?) -> (text: String, failed: Bool) {
        if let object = value as? Record {
            let text = (object["content"] as? String) ?? (object["output"] as? String) ?? ""
            let failed = object["success"] as? Bool == false
            return (text, failed)
        }
        guard let text = value as? String else { return ("", false) }
        if let data = text.data(using: .utf8), let object = (try? JSONSerialization.jsonObject(with: data)) as? Record,
            let inner = object["output"] as? String
        {
            let exitCode = (object["metadata"] as? Record)?["exit_code"] as? Int
            return (inner, exitCode.map { $0 != 0 } ?? false)
        }
        return (text, false)
    }
}

// MARK: - The read

extension CodexSessionReader {
    private struct ReadState: SessionRecordParser {
        var updates: [SessionUpdate] = []
        var emittedCount = 0
        /// The place of the next line among the lines that are not blank.
        /// The wire ids of the messages use it.
        var lineIndex = 0
        var skipped = SkipCounter()
        var dates = DateRange()
        var meta = CodexMeta()
        var turnCount = 0
        var jsonRecords = 0
        var recognized = 0
        var planCalls: Set<String> = []
        var lastWasCompaction = false

        func metadata(sourceID: String?) -> ImportedSessionMetadata {
            ImportedSessionMetadata(
                agent: .codex,
                sourceID: sourceID ?? meta.id ?? "",
                cwd: meta.cwd.map { URL(fileURLWithPath: $0) },
                title: meta.title,
                firstDate: dates.first,
                lastDate: dates.last,
                turnCount: turnCount
            )
        }

        mutating func read(line: Data.SubSequence) {
            defer { lineIndex += 1 }
            guard let record = ImportSupport.record(line) else {
                skipped.skip(ImportSupport.invalidJSONKind)
                return
            }
            read(record, line: lineIndex)
        }

        mutating func emit(_ update: SessionUpdate) {
            updates.append(update)
            emittedCount += 1
            if case .compactionUpdate = update { lastWasCompaction = true } else { lastWasCompaction = false }
        }

        mutating func read(_ record: Record, line: Int) {
            jsonRecords += 1
            guard let (type, payload) = CodexSessionReader.split(record) else {
                skipped.skip((record["type"] as? String) ?? "unknown")
                return
            }
            recognized += 1
            dates.add(ImportSupport.date(record["timestamp"] ?? payload["timestamp"]))
            switch type {
            case "session_meta":
                meta.read(meta: payload)
            case "response_item":
                readItem(payload, line: line)
            case "compacted":
                if !lastWasCompaction {
                    emit(ImportSupport.compaction(id: "codex-\(line)"))
                }
            case "event_msg":
                meta.read(event: payload)
            case "state":
                break
            case let other where CodexSessionReader.ignoredTypes.contains(other):
                break
            default:
                skipped.skip(type)
            }
        }

        mutating func readItem(_ item: Record, line: Int) {
            let id = "codex-\(line)"
            let itemType = (item["type"] as? String) ?? "unknown"
            switch itemType {
            case "message":
                let text = CodexSessionReader.text(of: item["content"])
                switch item["role"] as? String {
                case "user":
                    guard !text.isEmpty, !CodexSessionReader.isContext(text) else {
                        skipped.skip("message:context")
                        return
                    }
                    emit(.userMessageChunk(ImportSupport.textChunk(text, messageId: id)))
                    turnCount += 1
                case "assistant":
                    guard !text.isEmpty else { return }
                    emit(.agentMessageChunk(ImportSupport.textChunk(text, messageId: id)))
                case let role:
                    skipped.skip("message:" + (role ?? "unknown"))
                }
            case "reasoning":
                let summary = ((item["summary"] as? [Record]) ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n\n")
                guard !summary.isEmpty else {
                    skipped.skip("reasoning:no-summary")
                    return
                }
                emit(.agentThoughtChunk(ImportSupport.textChunk(summary, messageId: id)))
            case "function_call":
                let callID = (item["call_id"] as? String) ?? id
                let name = (item["name"] as? String) ?? "tool"
                let arguments = (item["arguments"] as? String).flatMap { $0.data(using: .utf8) }
                let input = (arguments.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? Record) ?? [:]
                if name == "update_plan", let steps = input["plan"] as? [Record] {
                    planCalls.insert(callID)
                    let items = steps.compactMap { step -> (content: String, status: String)? in
                        guard let content = step["step"] as? String else { return nil }
                        return (content, (step["status"] as? String) ?? "pending")
                    }
                    emit(ImportSupport.plan(id: callID, items: items))
                    return
                }
                let tool = CodexSessionReader.tool(name: name, input: input)
                emit(ImportSupport.toolCallStart(id: callID, title: ImportSupport.toolTitle(name: name, detail: tool.detail), kind: tool.kind))
            case "custom_tool_call":
                let callID = (item["call_id"] as? String) ?? id
                let name = (item["name"] as? String) ?? "tool"
                let input = (item["input"] as? String) ?? ""
                let tool = CodexSessionReader.tool(name: name, input: [:])
                var content: [ToolCallContent] = []
                if name == "apply_patch", let diff = CodexSessionReader.patchDiff(input, cwd: meta.cwd) {
                    content.append(diff)
                }
                let detail = name == "apply_patch" ? nil : input
                emit(ImportSupport.toolCallStart(id: callID, title: ImportSupport.toolTitle(name: name, detail: detail), kind: tool.kind, content: content))
            case "local_shell_call":
                let callID = (item["call_id"] as? String) ?? (item["id"] as? String) ?? id
                let action = (item["action"] as? Record) ?? [:]
                let command = (action["command"] as? [String])?.joined(separator: " ") ?? (action["command"] as? String)
                emit(ImportSupport.toolCallStart(id: callID, title: ImportSupport.toolTitle(name: "shell", detail: command), kind: .execute))
            case "function_call_output", "custom_tool_call_output", "local_shell_call_output":
                guard let callID = item["call_id"] as? String else {
                    skipped.skip(itemType)
                    return
                }
                guard !planCalls.contains(callID) else { return }
                let output = CodexSessionReader.output(item["output"])
                let blocks: [ContentBlock] = output.text.isEmpty ? [] : [.text(TextContent(text: output.text))]
                for update in ImportSupport.toolCallEnd(id: callID, failed: output.failed, output: blocks) {
                    emit(update)
                }
            default:
                skipped.skip("response_item:" + itemType)
            }
        }
    }
}

// MARK: - The metadata scan

extension CodexSessionReader {
    private struct MetadataScan {
        var dates = DateRange()
        var meta = CodexMeta()
        var turnCount = 0
        var recognized = false
        var sawJSON = false

        private static let timestampKey = Array(#""timestamp":""#.utf8)
        private static let metaMarker = Array(#""session_meta""#.utf8)
        private static let userRole = Array(#""role":"user""#.utf8)
        private static let threadMarker = Array(#"thread_name"#.utf8)
        private static let payloadKey = Array(#""payload""#.utf8)
        private static let instructionsKey = Array(#""instructions""#.utf8)

        mutating func add(_ line: Data.SubSequence) {
            if line.first == UInt8(ascii: "{") { sawJSON = true }
            if let start = line.firstRange(of: Self.timestampKey)?.upperBound,
                let end = line[start...].firstIndex(of: UInt8(ascii: "\""))
            {
                dates.add(ImportSupport.date(String(decoding: line[start..<end], as: UTF8.self)))
            }
            let isMeta = ImportSupport.contains(line, Self.metaMarker)
                || (!recognized && ImportSupport.contains(line, Self.instructionsKey))
            let isUser = ImportSupport.contains(line, Self.userRole)
            let isTitle = ImportSupport.contains(line, Self.threadMarker)
            if !recognized, ImportSupport.contains(line, Self.payloadKey) {
                recognized = true
            }
            guard isMeta || isUser || isTitle else { return }
            guard let record = ImportSupport.record(line), let (type, payload) = CodexSessionReader.split(record) else {
                return
            }
            recognized = true
            switch type {
            case "session_meta":
                meta.read(meta: payload)
            case "event_msg":
                meta.read(event: payload)
            case "response_item":
                if payload["type"] as? String == "message", payload["role"] as? String == "user" {
                    let text = CodexSessionReader.text(of: payload["content"])
                    if !text.isEmpty, !CodexSessionReader.isContext(text) {
                        turnCount += 1
                    }
                }
            default:
                break
            }
        }
    }
}

// MARK: - The bounded metadata scan

extension CodexSessionReader {
    /// The word of an `originator` value of a session that a program
    /// started: `codex_exec` or `codex-exec`, the `codex exec` command.
    static let automatedOriginatorWord = "exec"

    /// The rank of a thread name. A Codex file has one kind of title, thus
    /// the last thread name is the title.
    static let threadNameRank = 0

    /// Reads one record of a window into the metadata fields.
    static func scanMetadata(_ record: Record, into fields: inout MetadataFields) {
        guard let (type, payload) = split(record) else {
            return
        }
        fields.isRecognized = true
        fields.dates.add(ImportSupport.date(record["timestamp"] ?? payload["timestamp"]))
        switch type {
        case "session_meta":
            fields.noteSourceID(payload["id"])
            fields.noteCwd(payload["cwd"])
            fields.noteGitBranch((payload["git"] as? Record)?["branch"])
            if let originator = payload["originator"] as? String, !originator.isEmpty {
                fields.isAutomated = originator.lowercased().contains(automatedOriginatorWord)
            }
            noteThreadName(CodexMeta.title(of: payload), in: &fields)
        case "turn_context":
            fields.noteCwd(payload["cwd"])
        case "event_msg":
            noteThreadName(CodexMeta.threadName(ofEvent: payload), in: &fields)
        case "response_item":
            if let text = userPrompt(of: payload) {
                fields.notePrompt(text)
            }
        default:
            break
        }
    }

    /// Keeps a thread name as the title.
    private static func noteThreadName(_ name: String?, in fields: inout MetadataFields) {
        guard let name else {
            return
        }
        fields.noteTitle(RankedTitle(text: name, rank: threadNameRank))
    }

    /// The text of a user message that is not the context of Codex, or
    /// `nil` when the item is not one.
    static func userPrompt(of item: Record) -> String? {
        guard item["type"] as? String == "message", item["role"] as? String == "user" else {
            return nil
        }
        let text = text(of: item["content"])
        guard !text.isEmpty, !isContext(text) else {
            return nil
        }
        return text
    }
}
