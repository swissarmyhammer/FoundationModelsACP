import Foundation
import FoundationModelsACP

/// Makes the Markdown document of one transcript.
///
/// The renderer makes a list of blocks. Two blocks have one blank line
/// between them. The document ends with one `\n`.
struct MarkdownRenderer {
    /// The turn that the last heading started.
    private enum Turn {
        /// No heading yet, or a heading of a message from or to another
        /// session.
        case none
        /// A turn of the user.
        case user
        /// A turn of the agent.
        case agent
    }

    /// The entries of the transcript, in order.
    private let entries: [SessionEntry]

    /// The title of the document, or `nil`.
    private let title: String?

    /// The options of the document.
    private let options: SessionMarkdown.Options

    /// The terminal entries, by identifier.
    private let terminals: [TerminalId: AccumulatedTerminal]

    /// The terminals that a tool call names. They render in the tool call,
    /// not at their own position.
    private let namedTerminals: Set<TerminalId>

    /// The blocks of the document.
    private var blocks: [String] = []

    /// The turn of the last heading.
    private var turn = Turn.none

    /// The terminals that the document has already.
    private var renderedTerminals: Set<TerminalId> = []

    /// The fixed words of the document.
    private var labels: SessionMarkdown.Labels { options.labels }

    /// Makes a renderer.
    ///
    /// - Parameters:
    ///   - entries: The entries of the transcript, in order.
    ///   - title: The title of the document, or `nil`.
    ///   - options: The options of the document.
    init(entries: [SessionEntry], title: String?, options: SessionMarkdown.Options) {
        self.entries = entries
        self.title = title
        self.options = options
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
    }

    /// Makes the document.
    ///
    /// - Returns: The Markdown text.
    func render() -> String {
        var renderer = self
        if let title = renderer.title {
            renderer.blocks.append("# " + MarkdownText.singleLine(title))
        }
        for entry in renderer.entries {
            renderer.render(entry)
        }
        guard !renderer.blocks.isEmpty else {
            return ""
        }
        return renderer.blocks.joined(separator: "\n\n") + "\n"
    }

    // MARK: - Entries

    /// Adds the blocks of one entry.
    ///
    /// - Parameter entry: The entry.
    private mutating func render(_ entry: SessionEntry) {
        switch entry.kind {
        case .userMessage(let message):
            renderUserMessage(message)
        case .agentMessage(let message):
            addToAgentTurn(contentBlocks(message.content))
        case .agentThought(let message):
            guard options.includeThoughts else {
                return
            }
            let body = contentBlocks(message.content)
            guard !body.isEmpty else {
                return
            }
            addToAgentTurn([MarkdownText.details(summary: labels.thought, body: body)])
        case .toolCall(let toolCall):
            addToAgentTurn([toolCallBlock(toolCall)])
        case .terminal(let id, let terminal):
            guard !namedTerminals.contains(id), renderedTerminals.insert(id).inserted else {
                return
            }
            addToAgentTurn(terminalBlocks(terminal))
        case .plan(let plan):
            addToAgentTurn([planBlock(plan)])
        case .compaction:
            blocks.append(MarkdownText.italic(labels.compacted))
        case .sessionMessage(let message):
            renderSessionMessage(message)
        case .unknown(let type, _):
            blocks.append(MarkdownText.comment("unknown session update: \(type)"))
        }
    }

    /// Adds a user message: a turn of the user, or a quote when the message
    /// came from another session.
    ///
    /// - Parameter message: The merged message.
    private mutating func renderUserMessage(_ message: SessionEntry.Message) {
        let body = contentBlocks(message.content)
        guard !body.isEmpty else {
            return
        }
        if let sender = SAH.SessionMessage.extract(from: message.meta.value)?.sender {
            addQuote(heading: fromHeading(sender: sender, fallbackSessionId: nil), body: body)
            return
        }
        blocks.append("## " + labels.user)
        blocks.append(contentsOf: body)
        turn = .user
    }

    /// Adds a message between this session and another session, as a quote.
    ///
    /// - Parameter message: The merged message.
    private mutating func renderSessionMessage(_ message: SessionEntry.InterSessionMessage) {
        let body = contentBlocks(message.content)
        guard !body.isEmpty else {
            return
        }
        let sent = message.recipientMessageId.value != nil && message.senderMessageId.value == nil
        let heading: String
        if sent {
            let recipient = message.recipientSessionId.value.map { Self.shortID($0) } ?? labels.unknownSession
            heading = labels.to + " " + recipient
        } else {
            let sender = SAH.SessionMessage.extract(from: message.meta.value)?.sender
                ?? SAH.SessionMessage.Sender(kind: .session, sessionId: message.senderSessionId.value)
            heading = fromHeading(sender: sender, fallbackSessionId: message.senderSessionId.value)
        }
        addQuote(heading: heading, body: body)
    }

    /// Adds a heading and a quote. The heading ends the current turn.
    ///
    /// - Parameters:
    ///   - heading: The text of the heading.
    ///   - body: The blocks of the message.
    private mutating func addQuote(heading: String, body: [String]) {
        blocks.append("## " + MarkdownText.singleLine(heading))
        blocks.append(MarkdownText.quote(body.joined(separator: "\n\n")))
        turn = .none
    }

    /// Adds blocks to the turn of the agent. The heading of the agent comes
    /// first when the agent turn has not started.
    ///
    /// - Parameter body: The blocks.
    private mutating func addToAgentTurn(_ body: [String]) {
        guard !body.isEmpty else {
            return
        }
        if turn != .agent {
            blocks.append("## " + MarkdownText.singleLine(options.agentName ?? labels.agent))
            turn = .agent
        }
        blocks.append(contentsOf: body)
    }

    /// The heading of a message from another session.
    ///
    /// - Parameters:
    ///   - sender: The sender of the message.
    ///   - fallbackSessionId: The session that sent the message, when the
    ///     sender does not name it.
    /// - Returns: The text of the heading.
    private func fromHeading(sender: SAH.SessionMessage.Sender, fallbackSessionId: SessionId?) -> String {
        let name = sender.title
            ?? (sender.sessionId ?? fallbackSessionId).map { Self.shortID($0) }
            ?? labels.unknownSession
        if sender.kind == .user {
            return labels.fromUserIn + " " + name
        }
        return labels.from + " " + name
    }

    /// The short form of a session identifier: its last seven characters,
    /// in lower case.
    ///
    /// - Parameter id: The session identifier.
    /// - Returns: The short form.
    static func shortID(_ id: SessionId) -> String {
        String(id.rawValue.suffix(7)).lowercased()
    }

    // MARK: - Content blocks

    /// The blocks of a list of content blocks. Text blocks next to each other
    /// make one block, because the chunks of a message split its text at any
    /// position.
    ///
    /// - Parameter content: The content blocks.
    /// - Returns: The Markdown blocks. Empty text gives no block.
    private func contentBlocks(_ content: [ContentBlock]) -> [String] {
        var result: [String] = []
        var text = ""
        func flushText() {
            let trimmed = MarkdownText.trimmed(text)
            if !trimmed.isEmpty {
                result.append(trimmed)
            }
            text = ""
        }
        for block in content {
            if case .text(let textContent) = block {
                text += textContent.text
                continue
            }
            flushText()
            result.append(contentBlock(block))
        }
        flushText()
        return result
    }

    /// The Markdown of one content block that is not text.
    ///
    /// - Parameter block: The content block.
    /// - Returns: The Markdown block.
    private func contentBlock(_ block: ContentBlock) -> String {
        switch block {
        case .text(let text):
            return MarkdownText.trimmed(text.text)
        case .image(let image):
            return MarkdownText.italic("\(labels.image) (\(image.mimeType.rawValue))")
        case .audio(let audio):
            return MarkdownText.italic("\(labels.audio) (\(audio.mimeType.rawValue))")
        case .resourceLink(let link):
            return "[\(MarkdownText.linkText(link.name))](\(MarkdownText.linkDestination(link.uri)))"
        case .resource(let embedded):
            return embeddedResource(embedded.resource)
        case .unknown(let type, _):
            return MarkdownText.comment("unknown content block: \(type)")
        }
    }

    /// The Markdown of an embedded resource: the URI and a fenced block for
    /// text, or one line for a binary resource.
    ///
    /// - Parameter resource: The raw resource contents.
    /// - Returns: The Markdown block.
    private func embeddedResource(_ resource: JSONValue) -> String {
        let members: [String: JSONValue]
        if case .object(let object) = resource {
            members = object
        } else {
            members = [:]
        }
        func string(_ key: String) -> String? {
            if case .string(let value)? = members[key] {
                return value
            }
            return nil
        }
        let uri = string("uri")
        if let text = string("text") {
            let fence = MarkdownText.fenced(text, language: nil)
            guard let uri else {
                return fence
            }
            return MarkdownText.codeSpan(uri) + "\n" + fence
        }
        let kind = string("mimeType").map { "\(labels.resource) (\($0))" } ?? labels.resource
        guard let uri else {
            return MarkdownText.italic(kind)
        }
        return MarkdownText.italic(kind) + " " + MarkdownText.codeSpan(uri)
    }

    // MARK: - Tool calls

    /// The Markdown of a tool call: one line with no content, or a
    /// `<details>` block with the content.
    ///
    /// - Parameter toolCall: The folded tool call.
    /// - Returns: The Markdown block.
    private mutating func toolCallBlock(_ toolCall: ToolCallUpdate) -> String {
        let title = MarkdownText.singleLine(toolCall.title.value ?? labels.toolCall)
        let status = toolCall.status.value.map(statusWord)
        let kind = toolCall.kind.value.map(kindWord)
        var body: [String] = []
        for item in toolCall.content.resolved(onto: []) {
            body.append(contentsOf: toolCallContent(item))
        }
        if body.isEmpty {
            var line = "**\(MarkdownText.escapeInline(title))**"
            if let status {
                line += ": " + status
            }
            if let kind {
                line += " (\(kind))"
            }
            return line
        }
        var summary = title
        if let status {
            summary += ": " + status
        }
        if let kind {
            summary += " (\(kind))"
        }
        return MarkdownText.details(summary: summary, body: body)
    }

    /// The blocks of one content item of a tool call.
    ///
    /// - Parameter item: The content item.
    /// - Returns: The Markdown blocks.
    private mutating func toolCallContent(_ item: ToolCallContent) -> [String] {
        switch item {
        case .content(let content):
            return contentBlocks([content.content])
        case .diff(let diff):
            return [diffBlock(diff)]
        case .terminal(let reference):
            guard renderedTerminals.insert(reference.terminalId).inserted else {
                return []
            }
            guard let terminal = terminals[reference.terminalId] else {
                return [MarkdownText.italic(labels.terminal) + " " + MarkdownText.codeSpan(reference.terminalId.rawValue)]
            }
            return terminalBlocks(terminal)
        case .unknown(let type, _):
            return [MarkdownText.comment("unknown tool call content: \(type)")]
        }
    }

    /// The word of a tool-call status.
    ///
    /// - Parameter status: The status.
    /// - Returns: The word.
    private func statusWord(_ status: ToolCallStatus) -> String {
        let words = labels.toolCallStatus
        switch status {
        case .pending: return words.pending
        case .inProgress: return words.inProgress
        case .paused: return words.paused
        case .completed: return words.completed
        case .failed: return words.failed
        case .cancelled: return words.cancelled
        case .unknown(let value): return MarkdownText.singleLine(value)
        }
    }

    /// The word of a tool kind.
    ///
    /// - Parameter kind: The kind.
    /// - Returns: The word.
    private func kindWord(_ kind: ToolKind) -> String {
        let words = labels.toolKind
        switch kind {
        case .read: return words.read
        case .edit: return words.edit
        case .delete: return words.delete
        case .move: return words.move
        case .search: return words.search
        case .execute: return words.execute
        case .think: return words.think
        case .fetch: return words.fetch
        case .switchMode: return words.switchMode
        case .other: return words.other
        case .unknown(let value): return MarkdownText.singleLine(value)
        }
    }

    // MARK: - Diffs

    /// The Markdown of a diff: a fenced `diff` block with the patch, or a
    /// list of the changed paths.
    ///
    /// - Parameter diff: The diff.
    /// - Returns: The Markdown block.
    private func diffBlock(_ diff: Diff) -> String {
        if let patch = diff.patch {
            return MarkdownText.fenced(patch.text, language: "diff")
        }
        let words = labels.diffOperation
        let lines = diff.changes.map { change -> String in
            switch change.operation {
            case .add(let path): "- \(words.add): \(MarkdownText.codeSpan(path.path.rawValue))"
            case .delete(let path): "- \(words.delete): \(MarkdownText.codeSpan(path.path.rawValue))"
            case .modify(let path): "- \(words.modify): \(MarkdownText.codeSpan(path.path.rawValue))"
            case .move(let pair):
                "- \(words.move): \(MarkdownText.codeSpan(pair.oldPath.rawValue)) → \(MarkdownText.codeSpan(pair.path.rawValue))"
            case .copy(let pair):
                "- \(words.copy): \(MarkdownText.codeSpan(pair.oldPath.rawValue)) → \(MarkdownText.codeSpan(pair.path.rawValue))"
            case .unknown(let operation, _): "- " + MarkdownText.comment("unknown diff operation: \(operation)")
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Terminals

    /// The blocks of a terminal: a fenced `console` block, then the exit
    /// status when it is known.
    ///
    /// - Parameter terminal: The terminal.
    /// - Returns: The Markdown blocks.
    private func terminalBlocks(_ terminal: AccumulatedTerminal) -> [String] {
        var lines: [String] = []
        if let command = terminal.command.value {
            lines.append("$ " + command)
        }
        let output = MarkdownText.trimmedTrailing(String(decoding: terminal.output, as: UTF8.self))
        if !output.isEmpty {
            lines.append(output)
        }
        var result = [MarkdownText.fenced(lines.joined(separator: "\n"), language: "console")]
        if let status = terminal.exitStatus.value {
            var parts: [String] = []
            if let code = status.exitCode {
                parts.append(String(code))
            }
            if let signal = status.signal {
                parts.append(MarkdownText.singleLine(signal))
            }
            if !parts.isEmpty {
                result.append("\(labels.exitStatus): \(parts.joined(separator: ", "))")
            }
        }
        return result
    }

    // MARK: - Plans

    /// The Markdown of a plan: a line with the label, then a checklist.
    ///
    /// - Parameter plan: The last update of the plan.
    /// - Returns: The Markdown block.
    private func planBlock(_ plan: PlanUpdate) -> String {
        switch plan.plan {
        case .items(let items):
            var lines = ["**\(labels.plan)**", ""]
            for entry in items.entries {
                let content = MarkdownText.escapeInline(MarkdownText.singleLine(entry.content))
                switch entry.status {
                case .completed:
                    lines.append("- [x] " + content)
                case .inProgress:
                    lines.append("- [ ] \(content) (\(labels.planItemStatus.inProgress))")
                case .cancelled:
                    lines.append("- [ ] \(content) (\(labels.planItemStatus.cancelled))")
                case .pending, .unknown:
                    lines.append("- [ ] " + content)
                }
            }
            if items.entries.isEmpty {
                lines.removeLast()
            }
            return lines.joined(separator: "\n")
        case .unknown(let type, _):
            return MarkdownText.comment("unknown plan content: \(type)")
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
