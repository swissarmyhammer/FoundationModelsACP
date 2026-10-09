import Foundation

/// One entry of a session transcript that ``SessionMergeEngine`` keeps.
///
/// An entry has a stable identifier and a kind. The identifier comes from the
/// wire identifier of the item (for example, the `messageId` of a message).
/// Thus, an entry that an agent replays keeps the same identifier. Each later
/// update for the same item changes the entry, and the entry keeps the
/// position where it first appeared.
public struct SessionEntry: Hashable, Sendable, Identifiable {
    /// The stable identifier of a transcript entry.
    ///
    /// The three message kinds have different cases. Thus, a thought and an
    /// agent message that use the same `messageId` are two entries.
    public enum ID: Hashable, Sendable {
        /// A user message, by its `messageId`.
        case userMessage(MessageId)

        /// An agent message, by its `messageId`.
        case agentMessage(MessageId)

        /// An agent thought, by its `messageId`.
        case agentThought(MessageId)

        /// A tool call, by its `toolCallId`.
        case toolCall(ToolCallId)

        /// An agent-owned terminal, by its `terminalId`.
        case terminal(TerminalId)

        /// A plan, by its `planId`.
        case plan(PlanId)

        /// A context compaction, by its `compactionId`.
        case compaction(CompactionId)

        /// An entry that has no wire identifier: an unknown session update,
        /// or a plan update with unknown content and no `planId`. The value is
        /// the position of the entry in the transcript. A replay in the same
        /// order gives the same position.
        case unidentified(position: Int)
    }

    /// The kind of a transcript entry, with its merged state.
    public enum Kind: Hashable, Sendable {
        /// A message from the user.
        case userMessage(Message)

        /// A message from the agent.
        case agentMessage(Message)

        /// A thought (reasoning) from the agent.
        case agentThought(Message)

        /// A tool call. The value holds each field after all updates. A field
        /// that no update gave stays `.unchanged`.
        case toolCall(ToolCallUpdate)

        /// An agent-owned terminal, with its identifier and its merged state.
        case terminal(TerminalId, AccumulatedTerminal)

        /// A plan. The value is the last plan update for this plan.
        case plan(PlanUpdate)

        /// A context compaction: a mark in the transcript, with its status
        /// and its summary.
        ///
        /// A compaction changes only the model context of the agent. The
        /// transcript keeps the full history, so this entry does not remove
        /// or change an earlier entry.
        case compaction(Compaction)

        /// A session update that this revision of the schema does not know.
        /// The entry keeps the update type and the raw payload, so that a
        /// replay sends the update again without change.
        case unknown(type: String, payload: JSONValue)
    }

    /// The merged state of one message or thought.
    public struct Message: Hashable, Sendable {
        /// The identifier of the message.
        public var messageId: MessageId

        /// The content of the message. A whole-message update replaces it,
        /// and a chunk appends to it. An unknown content block stays in the
        /// content as the generated `.unknown` value.
        public var content: [ContentBlock] = []

        /// The `_meta` field of the message, folded with the patch rules.
        public var meta: PatchField<JSONValue> = .unchanged
    }

    /// The merged state of one context compaction.
    ///
    /// A `compaction_update` folds onto this state with the patch rules. A
    /// `compaction_summary_chunk` appends one content block to ``summary``.
    public struct Compaction: Hashable, Sendable {
        /// The status of a compaction that has a summary chunk but no
        /// `compaction_update` yet.
        ///
        /// The wire gives no status for this state, so the engine uses the
        /// `.unknown` case with the wire value `_unreported`.
        ///
        /// The value begins with `_` because the schema keeps each
        /// `CompactionStatus` value that begins with `_` for
        /// implementation-specific extensions. A value that does not begin
        /// with `_` is kept for a future ACP status, so this library must not
        /// send one. The value encodes and decodes without change, so a
        /// replay keeps it.
        public static let unreportedStatus = CompactionStatus.unknown("_unreported")

        /// The identifier of the compaction.
        public var compactionId: CompactionId

        /// The status from the last `compaction_update`, or
        /// ``unreportedStatus`` before the first one.
        public var status: CompactionStatus

        /// The summary that the compaction keeps. An update with a summary
        /// replaces it, `null` or an empty list clears it, and a chunk
        /// appends to it.
        public var summary: [ContentBlock] = []

        /// The reason that the compaction failed, folded with the patch
        /// rules.
        public var error: PatchField<String> = .unchanged

        /// The `_meta` field of the compaction, folded with the patch rules.
        public var meta: PatchField<JSONValue> = .unchanged
    }

    /// The stable identifier of the entry.
    public let id: ID

    /// The kind of the entry, with its merged state.
    public internal(set) var kind: Kind
}

extension SessionEntry.Kind {
    /// The message, when this entry is a user message, an agent message, or
    /// a thought.
    internal var message: SessionEntry.Message? {
        switch self {
        case .userMessage(let message), .agentMessage(let message), .agentThought(let message): message
        case .toolCall, .terminal, .plan, .compaction, .unknown: nil
        }
    }

    /// The tool call, when this entry is a tool call.
    internal var toolCall: ToolCallUpdate? {
        switch self {
        case .toolCall(let toolCall): toolCall
        case .userMessage, .agentMessage, .agentThought, .terminal, .plan, .compaction, .unknown: nil
        }
    }

    /// The terminal state, when this entry is a terminal.
    internal var terminal: AccumulatedTerminal? {
        switch self {
        case .terminal(_, let terminal): terminal
        case .userMessage, .agentMessage, .agentThought, .toolCall, .plan, .compaction, .unknown: nil
        }
    }

    /// The plan update, when this entry is a plan.
    internal var plan: PlanUpdate? {
        switch self {
        case .plan(let plan): plan
        case .userMessage, .agentMessage, .agentThought, .toolCall, .terminal, .compaction, .unknown: nil
        }
    }

    /// The compaction, when this entry is a compaction.
    internal var compaction: SessionEntry.Compaction? {
        switch self {
        case .compaction(let compaction): compaction
        case .userMessage, .agentMessage, .agentThought, .toolCall, .terminal, .plan, .unknown: nil
        }
    }
}

extension SessionEntry {
    /// The one session update that makes this entry in an empty engine, with
    /// the same identifier and the same state.
    internal var replayUpdate: SessionUpdate {
        switch kind {
        case .userMessage(let message):
            .userMessage(UserMessage(messageId: message.messageId, content: .value(message.content), meta: message.meta))
        case .agentMessage(let message):
            .agentMessage(AgentMessage(messageId: message.messageId, content: .value(message.content), meta: message.meta))
        case .agentThought(let message):
            .agentThought(AgentThought(messageId: message.messageId, content: .value(message.content), meta: message.meta))
        case .toolCall(let toolCall):
            .toolCallUpdate(toolCall)
        case .terminal(let terminalId, let terminal):
            .terminalUpdate(terminal.replayUpdate(terminalId: terminalId))
        case .plan(let plan):
            .planUpdate(plan)
        case .compaction(let compaction):
            compaction.replayUpdate
        case .unknown(let type, let payload):
            .unknown(type, payload)
        }
    }
}

extension SessionEntry.Compaction {
    /// Makes the state of a compaction that no update has changed yet.
    ///
    /// - Parameter compactionId: The identifier of the compaction.
    internal init(compactionId: CompactionId) {
        self.init(compactionId: compactionId, status: Self.unreportedStatus)
    }

    /// This state as one `compaction_update`, with the patch semantics of
    /// the wire.
    ///
    /// An empty summary is omitted, because an empty compaction also has an
    /// empty summary.
    private var asUpdate: CompactionUpdate {
        CompactionUpdate(
            compactionId: compactionId,
            status: status,
            error: error,
            summary: summary.isEmpty ? .unchanged : .value(summary),
            meta: meta
        )
    }

    /// Folds a `compaction_update` onto this compaction with the generated
    /// `CompactionUpdate.folded(onto:)`.
    ///
    /// An omitted field does not change. `null` clears the field. A
    /// `summary` of `[]` also clears the summary.
    ///
    /// - Parameter update: The compaction update.
    internal mutating func apply(_ update: CompactionUpdate) {
        let merged = update.folded(onto: asUpdate)
        status = merged.status
        summary = merged.summary.resolved(onto: [])
        error = merged.error
        meta = merged.meta
    }

    /// Appends the content block of a summary chunk to the summary. A chunk
    /// that has `_meta` replaces the `_meta` of the compaction.
    ///
    /// - Parameter chunk: The summary chunk.
    internal mutating func append(_ chunk: CompactionSummaryChunk) {
        summary.append(chunk.content)
        meta = PatchField(optional: chunk.meta).folded(onto: meta)
    }

    /// The one session update that carries this compaction as a
    /// `compaction_update`.
    fileprivate var replayUpdate: SessionUpdate {
        .compactionUpdate(asUpdate)
    }
}

extension SessionEntry.Message {
    /// Appends the content of a chunk. A chunk that has `_meta` replaces the
    /// `_meta` of the message.
    ///
    /// - Parameter chunk: The streamed content chunk.
    internal mutating func append(_ chunk: ContentChunk) {
        content.append(chunk.content)
        meta = PatchField(optional: chunk.meta).folded(onto: meta)
    }

    /// Applies a whole-message update. Each field follows the patch rules.
    ///
    /// - Parameters:
    ///   - newContent: The `content` field of the update.
    ///   - newMeta: The `_meta` field of the update.
    internal mutating func apply(content newContent: PatchField<[ContentBlock]>, meta newMeta: PatchField<JSONValue>) {
        content = newContent.resolved(onto: content)
        meta = newMeta.folded(onto: meta)
    }
}

extension ToolCallUpdate {
    /// Appends one streamed content item to the content of this tool call.
    ///
    /// When the content is `.unchanged` or `.cleared`, the tool call has no
    /// content yet, so the item starts a new list. A later update that
    /// carries `content` replaces the list, and later chunks append to that
    /// replacement.
    ///
    /// - Parameter item: The streamed content item.
    internal mutating func appendContent(_ item: ToolCallContent) {
        content = .value(content.resolved(onto: []) + [item])
    }
}

extension PlanUpdate {
    /// The identifier of the plan.
    ///
    /// Known content holds the `planId`. For unknown content, the identifier
    /// comes from a `planId` string in the raw payload, when there is one.
    internal var planId: PlanId? {
        switch plan {
        case .items(let items):
            return items.planId
        case .unknown(_, let payload):
            return payload.string(member: "planId").map(PlanId.init(rawValue:))
        }
    }
}
