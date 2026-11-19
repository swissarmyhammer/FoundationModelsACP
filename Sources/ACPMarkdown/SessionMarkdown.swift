import FoundationModelsACP

/// Makes a Markdown document from the session updates of one session.
///
/// The renderer is a pure function. The same updates and the same options
/// always give the same text. The document has no date, no time, no random
/// identifier and no text that depends on the locale, unless the caller gives
/// it in the ``Options``.
///
/// The document:
///
/// - A level 1 heading with the title. With no title, there is no level 1
///   heading.
/// - A level 2 heading at the start of each turn. A user message starts a
///   turn of the user. An agent message, a thought, a tool call, a terminal
///   and a plan are in the turn of the agent.
/// - A message from another session has the heading "From <title>" or
///   "From the user, in <title>", and its text is a quote. A message that this
///   session sent has the heading "To <recipient>".
/// - The text of a message stays as it is, because it is Markdown already.
/// - A tool call with no content is one line. A tool call with content is a
///   `<details>` block.
/// - A diff is a fenced `diff` block, or a list of the changed paths when the
///   diff has no patch.
/// - A terminal is a fenced `console` block, then a line with the exit
///   status.
/// - A plan is a checklist, at the position of its first update, with its
///   last state.
/// - A thought is not in the document, unless ``Options/includeThoughts`` is
///   `true`.
/// - The state updates and the notices are not in the document. An unknown
///   update is an HTML comment.
public enum SessionMarkdown {
    /// Folds the updates with a new `SessionMergeEngine`, then renders the
    /// transcript.
    ///
    /// When ``Options/title`` is `nil`, the title comes from the folded
    /// session information.
    ///
    /// - Parameters:
    ///   - updates: The session updates of one session, in the order of the
    ///     wire.
    ///   - options: The options of the document.
    /// - Returns: The Markdown document.
    public static func render(updates: some Sequence<SessionUpdate>, options: Options = .init()) -> String {
        let engine = SessionMergeEngine(replaying: updates)
        return render(entries: engine.entries, sessionInfo: engine.sessionInfo, options: options)
    }

    /// Renders the entries of a transcript.
    ///
    /// - Parameters:
    ///   - entries: The entries, in the order of the transcript.
    ///   - sessionInfo: The session information. Its title is the title of
    ///     the document when ``Options/title`` is `nil`.
    ///   - options: The options of the document.
    /// - Returns: The Markdown document.
    public static func render(
        entries: [SessionEntry],
        sessionInfo: SessionInfoUpdate? = nil,
        options: Options = .init()
    ) -> String {
        var title = options.title
        if title == nil, case .value(let infoTitle)? = sessionInfo?.title {
            title = infoTitle
        }
        return MarkdownRenderer(entries: entries, title: title, options: options).render()
    }
}

extension SessionMarkdown {
    /// The options of a document.
    public struct Options: Hashable, Sendable {
        /// `true` puts each thought of the agent in the document, as a
        /// `<details>` block. The default is `false`.
        public var includeThoughts: Bool

        /// The title of the document. `nil` takes the title of the session
        /// information. With no title, the document has no level 1 heading.
        public var title: String?

        /// The heading of the turns of the agent. `nil` gives
        /// ``Labels/agent``.
        public var agentName: String?

        /// The fixed words of the document.
        public var labels: Labels

        /// Makes the options.
        ///
        /// - Parameters:
        ///   - includeThoughts: `true` puts the thoughts in the document.
        ///   - title: The title, or `nil` for the title of the session.
        ///   - agentName: The heading of the turns of the agent, or `nil`.
        ///   - labels: The fixed words of the document.
        public init(
            includeThoughts: Bool = false,
            title: String? = nil,
            agentName: String? = nil,
            labels: Labels = .english
        ) {
            self.includeThoughts = includeThoughts
            self.title = title
            self.agentName = agentName
            self.labels = labels
        }
    }

    /// The fixed words of a document.
    ///
    /// A UI gives localized words. The agent uses ``english``.
    public struct Labels: Hashable, Sendable {
        /// The heading of a turn of the user.
        public var user = "User"

        /// The heading of a turn of the agent, when the options give no
        /// agent name.
        public var agent = "Agent"

        /// The summary of a thought.
        public var thought = "Thought"

        /// The start of the heading of a message from another session:
        /// "From <title>".
        public var from = "From"

        /// The start of the heading of a message that the user sent from
        /// another session: "From the user, in <title>".
        public var fromUserIn = "From the user, in"

        /// The start of the heading of a message that this session sent:
        /// "To <recipient>".
        public var to = "To"

        /// The name of a session that the document cannot name.
        public var unknownSession = "an unknown session"

        /// The line before the checklist of a plan.
        public var plan = "Plan"

        /// The start of the line after a terminal: "Exit status: 0".
        public var exitStatus = "Exit status"

        /// The line of a compaction.
        public var compacted = "The context was compacted."

        /// The title of a tool call that has no title.
        public var toolCall = "Tool call"

        /// The line of a terminal that the transcript does not have.
        public var terminal = "Terminal"

        /// The kind of an image content block.
        public var image = "Image"

        /// The kind of an audio content block.
        public var audio = "Audio"

        /// The kind of a binary resource.
        public var resource = "Resource"

        /// The status words of a tool call.
        public var toolCallStatus = ToolCallStatusLabels()

        /// The kind words of a tool call.
        public var toolKind = ToolKindLabels()

        /// The status words of a plan item.
        public var planItemStatus = PlanItemStatusLabels()

        /// The operation words of a changed path of a diff.
        public var diffOperation = DiffOperationLabels()

        /// Makes the English labels. Change a field to change one word.
        public init() {}

        /// The English labels.
        public static let english = Labels()
    }

    /// The status words of a tool call. A status that this package does not
    /// know shows its wire value.
    public struct ToolCallStatusLabels: Hashable, Sendable {
        /// `pending`.
        public var pending = "pending"
        /// `in_progress`.
        public var inProgress = "in progress"
        /// `paused`.
        public var paused = "paused"
        /// `completed`.
        public var completed = "completed"
        /// `failed`.
        public var failed = "failed"
        /// `cancelled`.
        public var cancelled = "cancelled"

        /// Makes the English words.
        public init() {}
    }

    /// The kind words of a tool call. A kind that this package does not know
    /// shows its wire value.
    public struct ToolKindLabels: Hashable, Sendable {
        /// `read`.
        public var read = "read"
        /// `edit`.
        public var edit = "edit"
        /// `delete`.
        public var delete = "delete"
        /// `move`.
        public var move = "move"
        /// `search`.
        public var search = "search"
        /// `execute`.
        public var execute = "execute"
        /// `think`.
        public var think = "think"
        /// `fetch`.
        public var fetch = "fetch"
        /// `switch_mode`.
        public var switchMode = "switch mode"
        /// `other`.
        public var other = "other"

        /// Makes the English words.
        public init() {}
    }

    /// The words after a plan item that is not pending or completed.
    public struct PlanItemStatusLabels: Hashable, Sendable {
        /// `in_progress`.
        public var inProgress = "in progress"
        /// `cancelled`.
        public var cancelled = "cancelled"

        /// Makes the English words.
        public init() {}
    }

    /// The operation words of a changed path of a diff. An operation that
    /// this package does not know shows its wire value.
    public struct DiffOperationLabels: Hashable, Sendable {
        /// `add`.
        public var add = "Added"
        /// `delete`.
        public var delete = "Deleted"
        /// `modify`.
        public var modify = "Modified"
        /// `move`.
        public var move = "Moved"
        /// `copy`.
        public var copy = "Copied"

        /// Makes the English words.
        public init() {}
    }
}
