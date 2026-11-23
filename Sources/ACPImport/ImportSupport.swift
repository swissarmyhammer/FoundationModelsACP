import Foundation
import FoundationModelsACP

/// A JSON object of a record.
typealias Record = [String: Any]

/// The shared parts of the readers.
enum ImportSupport {
    /// The maximum length of the title of a tool call, in characters.
    static let maximumTitleLength = 80

    /// The kind of a skipped line that is not JSON.
    static let invalidJSONKind = "invalid-json"

    /// The lines of a file, as byte slices, with no line end. Empty lines
    /// are not given.
    static func lines(of data: Data) -> [Data.SubSequence] {
        data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
            .map { line in
                line.last == UInt8(ascii: "\r") ? line.dropLast() : line
            }
            .filter { !$0.allSatisfy { $0 == UInt8(ascii: " ") || $0 == UInt8(ascii: "\t") } }
    }

    /// The complete lines of a window of a file, with no line end. Empty
    /// lines are not given.
    ///
    /// A line is complete only with its line break, thus the bytes after the
    /// last line break are dropped: the window ends in a line, or the file
    /// ends in a line that the agent writes now. A window that does not
    /// start at the start of a line also drops the bytes before its first
    /// line break. A line break byte is never a part of a UTF-8 character,
    /// thus a window that starts or ends in a character gives no part of it.
    ///
    /// - Parameters:
    ///   - window: The bytes of the window.
    ///   - startsAtLineStart: `true` when the window starts at the start of
    ///     the file.
    static func completeLines(in window: Data, startsAtLineStart: Bool) -> [Data.SubSequence] {
        let lineBreak = UInt8(ascii: "\n")
        guard let lastBreak = window.lastIndex(of: lineBreak) else {
            return []
        }
        var start = window.startIndex
        if !startsAtLineStart, let firstBreak = window.firstIndex(of: lineBreak) {
            start = firstBreak + 1
        }
        guard start < lastBreak else {
            return []
        }
        return lines(of: window[start..<lastBreak])
    }

    /// A prompt on one line, cut at
    /// ``SessionFileMetadata/maximumPromptLength`` characters.
    ///
    /// - Returns: The prompt, or `nil` when it has only white space.
    static func promptPreview(_ text: String) -> String? {
        let line = singleLine(text)
        guard !line.isEmpty else {
            return nil
        }
        return String(line.prefix(SessionFileMetadata.maximumPromptLength))
    }

    /// Parses one line as a JSON object.
    ///
    /// - Returns: The object, or `nil` when the line is not a JSON object.
    static func record(_ line: Data.SubSequence) -> Record? {
        (try? JSONSerialization.jsonObject(with: Data(line), options: [.fragmentsAllowed])) as? Record
    }

    /// `true` when the line has the bytes of `needle`. It is a fast check
    /// before a parse.
    static func contains(_ line: Data.SubSequence, _ needle: [UInt8]) -> Bool {
        guard needle.count <= line.count, let first = needle.first else {
            return false
        }
        var index = line.startIndex
        let end = line.endIndex - needle.count
        while index <= end {
            if line[index] == first, line[index..<(index + needle.count)].elementsEqual(needle) {
                return true
            }
            index += 1
        }
        return false
    }

    /// Reads an ISO 8601 date, with or with no fractional seconds.
    static func date(_ value: Any?) -> Date? {
        guard let text = value as? String else {
            return nil
        }
        if let date = try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) {
            return date
        }
        return try? Date(text, strategy: Date.ISO8601FormatStyle())
    }

    /// The title of a tool call: the name, then a short form of the input,
    /// at most ``maximumTitleLength`` characters.
    static func toolTitle(name: String, detail: String?) -> String {
        let detailLine = detail.map(singleLine) ?? ""
        let title = detailLine.isEmpty ? name : "\(name): \(detailLine)"
        guard title.count > maximumTitleLength else {
            return title
        }
        return String(title.prefix(maximumTitleLength - 1)) + "…"
    }

    /// Changes each run of white space to one space, and trims the ends.
    static func singleLine(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The short form of the input of a tool: the first string member of a
    /// preferred list of keys, else the first string member in key order.
    static func inputDetail(_ input: Record, preferred keys: [String]) -> String? {
        for key in keys {
            if let value = input[key] as? String, !value.isEmpty {
                return value
            }
            if let parts = input[key] as? [String], !parts.isEmpty {
                return parts.joined(separator: " ")
            }
        }
        for key in input.keys.sorted() {
            if let value = input[key] as? String, !value.isEmpty {
                return value
            }
        }
        return nil
    }

    /// The text update of a message.
    static func textChunk(_ text: String, messageId: String) -> ContentChunk {
        ContentChunk(content: .text(TextContent(text: text)), messageId: MessageId(rawValue: messageId))
    }

    /// A tool call that starts, with its title and kind.
    static func toolCallStart(id: String, title: String, kind: ToolKind, content: [ToolCallContent] = []) -> SessionUpdate {
        .toolCallUpdate(
            ToolCallUpdate(
                toolCallId: ToolCallId(rawValue: id),
                content: content.isEmpty ? .unchanged : .value(content),
                kind: .value(kind),
                status: .value(.pending),
                title: .value(title)
            )
        )
    }

    /// The end of a tool call: its status and its output. The output adds to
    /// the content of the tool call.
    static func toolCallEnd(id: String, failed: Bool, output: [ContentBlock]) -> [SessionUpdate] {
        let toolCallId = ToolCallId(rawValue: id)
        var updates = output.map { block in
            SessionUpdate.toolCallContentChunk(ToolCallContentChunk(content: .content(Content(content: block)), toolCallId: toolCallId))
        }
        updates.append(.toolCallUpdate(ToolCallUpdate(toolCallId: toolCallId, status: .value(failed ? .failed : .completed))))
        return updates
    }

    /// A diff of one file, from its old and new text. The patch has the
    /// old lines with `-` and the new lines with `+`.
    static func diff(path: String, edits: [(old: String, new: String)]) -> ToolCallContent? {
        guard path.hasPrefix("/"), !edits.isEmpty else {
            return nil
        }
        var lines = ["--- a\(path)", "+++ b\(path)"]
        for edit in edits {
            lines.append("@@")
            lines += edit.old.split(separator: "\n", omittingEmptySubsequences: false).map { "-" + $0 }
            lines += edit.new.split(separator: "\n", omittingEmptySubsequences: false).map { "+" + $0 }
        }
        return .diff(
            Diff(
                changes: [DiffChange(operation: .modify(DiffPathChange(path: AbsolutePath(rawValue: path))))],
                patch: DiffPatch(format: .gitPatch, text: lines.joined(separator: "\n") + "\n")
            )
        )
    }

    /// A plan from its items.
    static func plan(id: String, items: [(content: String, status: String)]) -> SessionUpdate {
        let entries = items.map { item in
            PlanEntry(content: item.content, priority: .medium, status: planStatus(item.status))
        }
        return .planUpdate(PlanUpdate(plan: .items(PlanItems(entries: entries, planId: PlanId(rawValue: id)))))
    }

    /// The status of a plan item from the word of the source.
    static func planStatus(_ word: String) -> PlanEntryStatus {
        switch word {
        case "completed", "done": .completed
        case "in_progress", "in-progress", "active": .inProgress
        case "cancelled", "canceled": .cancelled
        default: .pending
        }
    }

    /// One compaction line.
    static func compaction(id: String) -> SessionUpdate {
        .compactionUpdate(CompactionUpdate(compactionId: CompactionId(rawValue: id), status: .completed))
    }

    /// An image block from base64 data.
    static func image(data: String, mimeType: String) -> ContentBlock {
        .image(ImageContent(data: data, mimeType: MediaType(rawValue: mimeType)))
    }
}

/// Counts the records that a reader did not read.
struct SkipCounter {
    private(set) var kinds: [String: Int] = [:]

    var total: Int { kinds.values.reduce(0, +) }

    mutating func skip(_ kind: String) {
        kinds[kind, default: 0] += 1
    }
}

/// The dates of a file: the first and the last.
struct DateRange {
    private(set) var first: Date?
    private(set) var last: Date?

    mutating func add(_ date: Date?) {
        guard let date else { return }
        if first == nil { first = date }
        last = date
    }
}
