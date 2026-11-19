import Foundation

/// One search chunk of a session transcript: a part of one turn, with one
/// kind. (D207 (a) of Testudo.)
///
/// ``SessionSearchChunker`` makes the chunks from the entries of a
/// ``SessionMergeEngine``. The server and the app use the same chunker, so
/// the same entries always give the same chunks.
public struct SessionSearchChunk: Sendable, Hashable {
    /// The kind of a chunk. The raw value is the word of the `from:` filter
    /// of the search.
    public enum Kind: String, Sendable, Hashable, CaseIterable {
        /// A prompt of the user.
        case user
        /// The agent messages of a turn that follow one another.
        case agent
        /// A message from another session, or to another session.
        case message
        /// A tool call, with its content, its terminal output and its diffs,
        /// or a terminal that no tool call names.
        case tool
        /// A plan: the text of its items.
        case plan
        /// The thoughts of a turn that follow one another.
        case thought
    }

    /// One entry of a chunk, with the part of ``SessionSearchChunk/text``
    /// that comes from it.
    public struct EntryRange: Sendable, Hashable {
        /// The identifier of the entry. ``SessionEntry/ID/searchHitID`` is
        /// its text form.
        public var id: SessionEntry.ID

        /// The range of the entry in ``SessionSearchChunk/text``, in
        /// characters (`Character` values) from the start of the text.
        public var range: Range<Int>

        /// Makes an entry range.
        ///
        /// - Parameters:
        ///   - id: The identifier of the entry.
        ///   - range: The range of the entry in the text, in characters.
        public init(id: SessionEntry.ID, range: Range<Int>) {
            self.id = id
            self.range = range
        }
    }

    /// The turn of the chunk. It is 0 for the entries before the first
    /// prompt. A user message, and a message that this session received from
    /// another session, start a new turn.
    public var turn: Int

    /// The place of the chunk in the session, from 0.
    public var ordinal: Int

    /// The kind of the chunk.
    public var kind: Kind

    /// The sender of a message from another session: the title of the
    /// sender session, or its identifier when it has no title. `nil` for the
    /// other kinds.
    public var author: String?

    /// The date of the first entry of the chunk that has a date, or `nil`.
    public var date: Date?

    /// The title of a tool call. Empty for the other kinds, and for a
    /// terminal that no tool call names.
    public var title: String

    /// The text of the chunk. It has at most
    /// ``SessionSearchChunker/maximumChunkLength`` characters.
    public var text: String

    /// The entries of the chunk, in the order of the text, with their
    /// ranges.
    public var entries: [EntryRange]

    /// Makes a chunk.
    public init(
        turn: Int,
        ordinal: Int,
        kind: Kind,
        author: String?,
        date: Date?,
        title: String,
        text: String,
        entries: [EntryRange]
    ) {
        self.turn = turn
        self.ordinal = ordinal
        self.kind = kind
        self.author = author
        self.date = date
        self.title = title
        self.text = text
        self.entries = entries
    }
}

/// Makes the search chunks of a session transcript. (D207 (a) of Testudo.)
///
/// The rules:
///
/// - Each user message is one chunk of the kind `user`. A user message with
///   `_meta.sah.message` (``SAH/SessionMessage``) came from another session:
///   it is a chunk of the kind `message`, with its sender as the author.
/// - The agent messages of a turn that follow one another are one chunk of
///   the kind `agent`.
/// - Each `session_message` entry is one chunk of the kind `message`, with
///   its sender as the author.
/// - Each tool call is one chunk or more of the kind `tool`: the title, the
///   text content, the output of its terminals and the patch text of its
///   diffs (the changed paths when a diff has no patch), cut at
///   ``maximumToolTextLength`` for each tool call. A terminal that a tool
///   call names is in the chunk of that tool call. A terminal that no tool
///   call names is a `tool` chunk of its own.
/// - Each plan is one chunk of the kind `plan`: the text of its items, one
///   for each line.
/// - The thoughts of a turn that follow one another are one chunk of the
///   kind `thought`.
/// - A compaction and an unknown entry make no chunk.
///
/// Any other chunk between two agent messages (or two thoughts) cuts them.
/// The entries of one chunk are separated by a blank line. A text longer
/// than ``maximumChunkLength`` becomes more chunks of the same kind, cut at
/// the end of a line, or at a space when a line is longer, or at the limit
/// when the text has no space.
public enum SessionSearchChunker {
    /// The maximum length of the text of a chunk, in characters.
    public static let maximumChunkLength = 2_000

    /// The maximum length of the text of one tool call, in UTF-8 bytes
    /// (64 KB). The text after it is not searched.
    public static let maximumToolTextLength = 64 * 1_024

    /// Makes the chunks of the entries of a transcript.
    ///
    /// The function is pure: the same entries and dates always give the
    /// same chunks.
    ///
    /// - Parameters:
    ///   - entries: The entries, in the order of the transcript
    ///     (``SessionMergeEngine/entries``).
    ///   - dates: The date of each entry that the caller knows. The wire
    ///     gives no date, so the server gives the dates that it recorded. A
    ///     chunk takes the date of its first entry that has one.
    /// - Returns: The chunks, in the order of the transcript.
    public static func chunks(
        of entries: [SessionEntry],
        dates: [SessionEntry.ID: Date] = [:]
    ) -> [SessionSearchChunk] {
        var builder = Builder(entries: entries, dates: dates)
        for entry in entries {
            builder.add(entry)
        }
        return builder.finish()
    }
}

// MARK: - The builder

extension SessionSearchChunker {
    /// The part of one entry in a group, before the text is joined.
    fileprivate struct Segment {
        /// The identifier of the entry.
        var id: SessionEntry.ID
        /// The text of the entry.
        var text: String
    }

    /// The entries of one chunk before the cut at the maximum length.
    fileprivate struct Group {
        var turn: Int
        var kind: SessionSearchChunk.Kind
        var author: String?
        var title: String
        var segments: [Segment]
        /// The text between two segments.
        var separator: String
    }

    /// Goes through the entries one time and makes the chunks.
    fileprivate struct Builder {
        /// The terminal entries, by identifier.
        let terminals: [TerminalId: AccumulatedTerminal]
        /// The terminals that a tool call names. They are in the chunk of
        /// the tool call, not at their own position.
        let namedTerminals: Set<TerminalId>
        /// The dates that the caller gave.
        let dates: [SessionEntry.ID: Date]

        var turn = 0
        var open: Group?
        var groups: [Group] = []
        var usedTerminals: Set<TerminalId> = []

        init(entries: [SessionEntry], dates: [SessionEntry.ID: Date]) {
            var terminals: [TerminalId: AccumulatedTerminal] = [:]
            var named: Set<TerminalId> = []
            for entry in entries {
                switch entry.kind {
                case .terminal(let id, let terminal):
                    terminals[id] = terminal
                case .toolCall(let toolCall):
                    for case .terminal(let reference) in toolCall.content.resolved(onto: []) {
                        named.insert(reference.terminalId)
                    }
                default:
                    break
                }
            }
            self.terminals = terminals
            self.namedTerminals = named
            self.dates = dates
        }

        mutating func add(_ entry: SessionEntry) {
            switch entry.kind {
            case .userMessage(let message):
                turn += 1
                let text = Self.text(of: message.content)
                if let sender = SAH.SessionMessage.extract(from: message.meta.value)?.sender {
                    close(Group(turn: turn, kind: .message, author: Self.author(of: sender, sessionId: nil), title: "", segments: [Segment(id: entry.id, text: text)], separator: ""))
                } else {
                    close(Group(turn: turn, kind: .user, author: nil, title: "", segments: [Segment(id: entry.id, text: text)], separator: ""))
                }
            case .agentMessage(let message):
                join(kind: .agent, segment: Segment(id: entry.id, text: Self.text(of: message.content)))
            case .agentThought(let message):
                join(kind: .thought, segment: Segment(id: entry.id, text: Self.text(of: message.content)))
            case .sessionMessage(let message):
                let sent = message.recipientMessageId.value != nil && message.senderMessageId.value == nil
                if !sent {
                    turn += 1
                }
                let sender = SAH.SessionMessage.extract(from: message.meta.value)?.sender
                let author = sender.map { Self.author(of: $0, sessionId: message.senderSessionId.value) }
                    ?? message.senderSessionId.value?.rawValue
                close(Group(turn: turn, kind: .message, author: author, title: "", segments: [Segment(id: entry.id, text: Self.text(of: message.content))], separator: ""))
            case .toolCall(let toolCall):
                close(toolGroup(entry.id, toolCall))
            case .terminal(let id, let terminal):
                guard !namedTerminals.contains(id), usedTerminals.insert(id).inserted else {
                    return
                }
                close(Group(turn: turn, kind: .tool, author: nil, title: "", segments: [Segment(id: entry.id, text: Self.text(of: terminal))], separator: ""))
            case .plan(let plan):
                guard case .items(let items) = plan.plan else {
                    return
                }
                let text = items.entries.map { Self.singleLine($0.content) }.joined(separator: "\n")
                close(Group(turn: turn, kind: .plan, author: nil, title: "", segments: [Segment(id: entry.id, text: text)], separator: ""))
            case .compaction, .unknown:
                return
            }
        }

        /// Adds a segment to the open group of the same kind, or opens a new
        /// group.
        private mutating func join(kind: SessionSearchChunk.Kind, segment: Segment) {
            if var group = open, group.kind == kind, group.turn == turn {
                group.segments.append(segment)
                open = group
                return
            }
            flush()
            open = Group(turn: turn, kind: kind, author: nil, title: "", segments: [segment], separator: "\n\n")
        }

        /// Ends the open group, then adds a group that nothing joins.
        private mutating func close(_ group: Group) {
            flush()
            groups.append(group)
        }

        private mutating func flush() {
            if let group = open {
                groups.append(group)
                open = nil
            }
        }

        /// The group of one tool call: its title, its content in order, and
        /// the terminals that it names.
        private mutating func toolGroup(_ id: SessionEntry.ID, _ toolCall: ToolCallUpdate) -> Group {
            let title = Self.singleLine(toolCall.title.value ?? "")
            var segments: [Segment] = [Segment(id: id, text: title)]
            for item in toolCall.content.resolved(onto: []) {
                switch item {
                case .content(let content):
                    segments.append(Segment(id: id, text: Self.text(of: [content.content])))
                case .diff(let diff):
                    segments.append(Segment(id: id, text: Self.text(of: diff)))
                case .terminal(let reference):
                    guard let terminal = terminals[reference.terminalId],
                        usedTerminals.insert(reference.terminalId).inserted
                    else {
                        continue
                    }
                    segments.append(Segment(id: .terminal(reference.terminalId), text: Self.text(of: terminal)))
                case .unknown:
                    continue
                }
            }
            return Group(turn: turn, kind: .tool, author: nil, title: title, segments: segments, separator: "\n")
        }

        /// Makes the chunks of the groups.
        mutating func finish() -> [SessionSearchChunk] {
            flush()
            var chunks: [SessionSearchChunk] = []
            for group in groups {
                let (text, ranges) = Self.join(group)
                guard !text.isEmpty else {
                    continue
                }
                var capped = (text: text, ranges: ranges)
                if group.kind == .tool {
                    capped = Self.capToolText(text: text, ranges: ranges)
                }
                let dates = dates
                let date = ranges.lazy.compactMap { dates[$0.id] }.first
                for piece in Self.split(Array(capped.text), ranges: capped.ranges) {
                    chunks.append(
                        SessionSearchChunk(
                            turn: group.turn,
                            ordinal: chunks.count,
                            kind: group.kind,
                            author: group.author,
                            date: date,
                            title: group.title,
                            text: piece.text,
                            entries: piece.ranges
                        )
                    )
                }
            }
            return chunks
        }
    }
}

// MARK: - Text of the entries

extension SessionSearchChunker.Builder {
    /// The searchable text of a list of content blocks. Text blocks next to
    /// each other join with no separator, because chunks split a text at any
    /// position.
    fileprivate static func text(of content: [ContentBlock]) -> String {
        var parts: [String] = []
        var text = ""
        func flushText() {
            if !text.isEmpty {
                parts.append(text)
                text = ""
            }
        }
        for block in content {
            switch block {
            case .text(let textContent):
                text += textContent.text
            case .resourceLink(let link):
                flushText()
                parts.append([link.title ?? link.name, link.uri].joined(separator: " "))
            case .resource(let embedded):
                flushText()
                if case .object(let members) = embedded.resource, case .string(let resourceText)? = members["text"] {
                    parts.append(resourceText)
                }
            case .image, .audio, .unknown:
                flushText()
            }
        }
        flushText()
        return trimmed(parts.joined(separator: "\n"))
    }

    /// The text of a terminal: `$ <command>`, then the output.
    fileprivate static func text(of terminal: AccumulatedTerminal) -> String {
        var lines: [String] = []
        if let command = terminal.command.value {
            lines.append("$ " + command)
        }
        lines.append(String(decoding: terminal.output, as: UTF8.self))
        return trimmed(lines.joined(separator: "\n"))
    }

    /// The text of a diff: the patch text, or the changed paths when the
    /// diff has no patch.
    fileprivate static func text(of diff: Diff) -> String {
        if let patch = diff.patch {
            return trimmed(patch.text)
        }
        let paths = diff.changes.compactMap { change -> String? in
            switch change.operation {
            case .add(let path), .delete(let path), .modify(let path): path.path.rawValue
            case .move(let pair), .copy(let pair): pair.oldPath.rawValue + " " + pair.path.rawValue
            case .unknown: nil
            }
        }
        return paths.joined(separator: "\n")
    }

    /// The author of a message from another session.
    fileprivate static func author(of sender: SAH.SessionMessage.Sender, sessionId: SessionId?) -> String? {
        sender.title ?? (sender.sessionId ?? sessionId)?.rawValue
    }

    /// Changes the line ends of a text to spaces.
    fileprivate static func singleLine(_ text: String) -> String {
        trimmed(text.split(whereSeparator: \.isNewline).joined(separator: " "))
    }

    /// Removes the white space at the two ends of a text, and changes
    /// `\r\n` and `\r` to `\n`.
    fileprivate static func trimmed(_ text: String) -> String {
        text.replacing("\r\n", with: "\n").replacing("\r", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Join, cap and split

extension SessionSearchChunker.Builder {
    /// Joins the segments of a group, and gives the range of each entry.
    /// Empty segments are dropped. Two segments of the same entry next to
    /// each other make one range.
    fileprivate static func join(
        _ group: SessionSearchChunker.Group
    ) -> (text: String, ranges: [SessionSearchChunk.EntryRange]) {
        var text = ""
        var length = 0
        var ranges: [SessionSearchChunk.EntryRange] = []
        let separatorLength = group.separator.count
        for segment in group.segments where !segment.text.isEmpty {
            if !text.isEmpty {
                text += group.separator
                length += separatorLength
            }
            let start = length
            text += segment.text
            length += segment.text.count
            if let last = ranges.last, last.id == segment.id, last.range.upperBound + separatorLength == start {
                ranges[ranges.count - 1].range = last.range.lowerBound..<length
            } else {
                ranges.append(SessionSearchChunk.EntryRange(id: segment.id, range: start..<length))
            }
        }
        return (text, ranges)
    }

    /// Cuts the text of a tool call at ``SessionSearchChunker/maximumToolTextLength``
    /// UTF-8 bytes, at a character boundary, and cuts the ranges with it.
    fileprivate static func capToolText(
        text: String,
        ranges: [SessionSearchChunk.EntryRange]
    ) -> (text: String, ranges: [SessionSearchChunk.EntryRange]) {
        guard text.utf8.count > SessionSearchChunker.maximumToolTextLength else {
            return (text, ranges)
        }
        var bytes = 0
        var kept = 0
        for character in text {
            let size = character.utf8.count
            guard bytes + size <= SessionSearchChunker.maximumToolTextLength else {
                break
            }
            bytes += size
            kept += 1
        }
        let cut = String(text.prefix(kept))
        let cutRanges = ranges.compactMap { entry -> SessionSearchChunk.EntryRange? in
            let upper = min(entry.range.upperBound, kept)
            guard entry.range.lowerBound < upper else {
                return nil
            }
            return SessionSearchChunk.EntryRange(id: entry.id, range: entry.range.lowerBound..<upper)
        }
        return (cut, cutRanges)
    }

    /// Splits a text into pieces of at most
    /// ``SessionSearchChunker/maximumChunkLength`` characters. A cut is at
    /// the last line end in the limit, else at the last space, else at the
    /// limit. The line end or the space at a cut is in no piece.
    fileprivate static func split(
        _ characters: [Character],
        ranges: [SessionSearchChunk.EntryRange]
    ) -> [(text: String, ranges: [SessionSearchChunk.EntryRange])] {
        let limit = SessionSearchChunker.maximumChunkLength
        var pieces: [Range<Int>] = []
        var start = 0
        while characters.count - start > limit {
            let window = (start + 1)...(start + limit)
            if let cut = window.reversed().first(where: { characters[$0].isNewline })
                ?? window.reversed().first(where: { characters[$0] == " " })
            {
                pieces.append(start..<cut)
                start = cut + 1
            } else {
                pieces.append(start..<(start + limit))
                start += limit
            }
        }
        pieces.append(start..<characters.count)
        return pieces.map { piece in
            let pieceRanges = ranges.compactMap { entry -> SessionSearchChunk.EntryRange? in
                let lower = max(entry.range.lowerBound, piece.lowerBound)
                let upper = min(entry.range.upperBound, piece.upperBound)
                guard lower < upper else {
                    return nil
                }
                return SessionSearchChunk.EntryRange(id: entry.id, range: (lower - piece.lowerBound)..<(upper - piece.lowerBound))
            }
            return (String(characters[piece]), pieceRanges)
        }
    }
}

extension PatchField {
    /// The value, or `nil` when the field is omitted or cleared.
    fileprivate var value: Wrapped? {
        if case .value(let wrapped) = self {
            return wrapped
        }
        return nil
    }
}
