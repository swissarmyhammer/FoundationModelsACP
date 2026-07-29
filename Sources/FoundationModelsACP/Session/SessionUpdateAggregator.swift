import Foundation

/// Materializes the effect of a `session/update` stream into accumulated
/// per-session state.
///
/// ACP v2 states its update rules only in prose, on each variant's own doc
/// comment: whole-message upserts (`user_message` / `agent_message` /
/// `agent_thought`) replace `content` wholesale while their `*_chunk`
/// siblings append; `tool_call_update` and `terminal_update` are
/// patch-semantics upserts keyed by `toolCallId` / `terminalId`, where the
/// first sighting of an id creates and later sightings patch; `plan_update`
/// replaces a plan's entries outright, keyed by `planId`. None of that is
/// enforced by the generated wire types alone — a decoded `ToolCallUpdate` is
/// only ever one update in isolation — so this type is where "first sighting
/// creates, later sightings patch" actually happens.
///
/// Update kinds with no per-item identity to accumulate — `state_update`,
/// `available_commands_update`, `config_option_update`, `session_info_update`,
/// `usage_update`, and an unrecognized variant — pass through as no-ops.
/// Each of those is already a complete, self-contained value with nothing to
/// fold onto; a consumer that cares about them reads the `SessionUpdate`
/// directly off the stream (e.g. from `SessionUpdateRouter`).
public struct SessionUpdateAggregator: Sendable {
    /// One message's current content, after every upsert and chunk applied
    /// so far, keyed by `messageId`. Covers `user_message`, `agent_message`,
    /// and `agent_thought` alike — the three share the same upsert shape.
    public private(set) var messages: [MessageId: [ContentBlock]] = [:]

    /// One tool call's current accumulated state, keyed by `toolCallId`.
    ///
    /// Stored as a `ToolCallUpdate` itself: its patch-semantics fields are
    /// exactly the accumulated state's shape, so folding a newer update onto
    /// an older one is one `PatchField.folded(onto:)` per field.
    public private(set) var toolCalls: [ToolCallId: ToolCallUpdate] = [:]

    /// One agent-owned terminal's current accumulated state, keyed by
    /// `terminalId`.
    public private(set) var terminals: [TerminalId: AccumulatedTerminal] = [:]

    /// One plan's current entries, replaced outright by every `plan_update`
    /// naming it, keyed by `planId`.
    public private(set) var plans: [PlanId: [PlanEntry]] = [:]

    /// Creates an aggregator with no accumulated state.
    public init() {}

    /// Folds one `session/update` notification's payload into the
    /// accumulated state.
    ///
    /// - Parameter update: The update to apply.
    public mutating func apply(_ update: SessionUpdate) {
        switch update {
        case .userMessageChunk(let chunk):
            appendMessageChunk(chunk)
        case .userMessage(let message):
            upsertMessage(id: message.messageId, content: message.content)
        case .agentMessageChunk(let chunk):
            appendMessageChunk(chunk)
        case .agentMessage(let message):
            upsertMessage(id: message.messageId, content: message.content)
        case .agentThoughtChunk(let chunk):
            appendMessageChunk(chunk)
        case .agentThought(let thought):
            upsertMessage(id: thought.messageId, content: thought.content)
        case .stateUpdate:
            break
        case .toolCallContentChunk(let chunk):
            appendToolCallContentChunk(chunk)
        case .toolCallUpdate(let toolCall):
            upsertToolCall(toolCall)
        case .terminalUpdate(let terminal):
            upsertTerminal(terminal)
        case .terminalOutputChunk(let chunk):
            appendTerminalOutputChunk(chunk)
        case .planUpdate(let plan):
            applyPlanUpdate(plan)
        case .availableCommandsUpdate, .configOptionUpdate, .sessionInfoUpdate, .usageUpdate, .unknown:
            break
        }
    }

    // MARK: - Messages

    /// Upserts a whole-message `content` field: omitted leaves any
    /// accumulated content unchanged (or starts empty for a new
    /// `messageId`), `null`/`[]` clears it, and a concrete array replaces it.
    ///
    /// - Parameters:
    ///   - id: The message's identifier.
    ///   - content: The upsert's patch-semantics `content` field.
    private mutating func upsertMessage(id: MessageId, content: PatchField<[ContentBlock]>) {
        switch content {
        case .unchanged:
            messages[id] = messages[id] ?? []
        case .cleared:
            messages[id] = []
        case .value(let blocks):
            messages[id] = blocks
        }
    }

    /// Appends one streamed content item to its message, creating the
    /// message on the chunk's first sighting.
    ///
    /// - Parameter chunk: The streamed content chunk.
    private mutating func appendMessageChunk(_ chunk: ContentChunk) {
        messages[chunk.messageId, default: []].append(chunk.content)
    }

    // MARK: - Tool calls

    /// Upserts a tool call: the first sighting of a `toolCallId` creates it
    /// verbatim (its own omitted fields already mean "unknown, use client
    /// defaults"); a later sighting folds each field onto what is stored.
    ///
    /// - Parameter incoming: The received tool-call update.
    private mutating func upsertToolCall(_ incoming: ToolCallUpdate) {
        guard let existing = toolCalls[incoming.toolCallId] else {
            toolCalls[incoming.toolCallId] = incoming
            return
        }
        toolCalls[incoming.toolCallId] = ToolCallUpdate(
            toolCallId: incoming.toolCallId,
            content: incoming.content.folded(onto: existing.content),
            kind: incoming.kind.folded(onto: existing.kind),
            locations: incoming.locations.folded(onto: existing.locations),
            rawInput: incoming.rawInput.folded(onto: existing.rawInput),
            rawOutput: incoming.rawOutput.folded(onto: existing.rawOutput),
            status: incoming.status.folded(onto: existing.status),
            title: incoming.title.folded(onto: existing.title),
            meta: incoming.meta.folded(onto: existing.meta)
        )
    }

    /// Appends one streamed content item to a tool call's accumulated
    /// content, creating the tool call on the chunk's first sighting.
    ///
    /// An intervening `tool_call_update` carrying `content` replaces the
    /// accumulated array outright (ordinary upsert semantics, handled by
    /// `upsertToolCall`); later chunks then append to that replacement,
    /// exactly as they would to content the tool call started with.
    ///
    /// - Parameter chunk: The streamed tool-call content chunk.
    private mutating func appendToolCallContentChunk(_ chunk: ToolCallContentChunk) {
        var toolCall = toolCalls[chunk.toolCallId] ?? ToolCallUpdate(toolCallId: chunk.toolCallId)
        let accumulated: [ToolCallContent]
        switch toolCall.content {
        case .unchanged, .cleared: accumulated = []
        case .value(let content): accumulated = content
        }
        toolCall.content = .value(accumulated + [chunk.content])
        toolCalls[chunk.toolCallId] = toolCall
    }

    // MARK: - Terminals

    /// Upserts a terminal's patch-semantics fields, and — when `output`
    /// carries a concrete snapshot — replaces the accumulated output bytes
    /// wholesale rather than folding, since a `TerminalOutput` is documented
    /// as "an authoritative replacement snapshot", not a patch.
    ///
    /// - Parameter incoming: The received terminal update.
    private mutating func upsertTerminal(_ incoming: TerminalUpdate) {
        var terminal = terminals[incoming.terminalId] ?? AccumulatedTerminal()
        terminal.command = incoming.command.folded(onto: terminal.command)
        terminal.cwd = incoming.cwd.folded(onto: terminal.cwd)
        terminal.exitStatus = incoming.exitStatus.folded(onto: terminal.exitStatus)
        terminal.meta = incoming.meta.folded(onto: terminal.meta)
        switch incoming.output {
        case .unchanged:
            break
        case .cleared:
            terminal.output = Data()
        case .value(let snapshot):
            // A snapshot that fails to decode as base64 is dropped rather
            // than corrupting the accumulated buffer, matching the
            // forgiving-decode posture the generated types use elsewhere for
            // malformed peer data.
            if let bytes = Data(base64Encoded: snapshot.data) {
                terminal.output = bytes
            }
        }
        terminals[incoming.terminalId] = terminal
    }

    /// Appends one chunk's base64-decoded bytes to a terminal's accumulated
    /// output, creating the terminal on the chunk's first sighting. A chunk
    /// that fails to decode as base64 is dropped rather than corrupting the
    /// accumulated buffer.
    ///
    /// - Parameter chunk: The streamed terminal output chunk.
    private mutating func appendTerminalOutputChunk(_ chunk: TerminalOutputChunk) {
        guard let bytes = Data(base64Encoded: chunk.data) else { return }
        terminals[chunk.terminalId, default: AccumulatedTerminal()].output.append(bytes)
    }

    // MARK: - Plans

    /// Replaces a plan's entries outright, keyed by `planId`.
    ///
    /// An unrecognized `PlanUpdateContent` variant has no known `entries`
    /// shape to materialize, so it is skipped here — the wire payload itself
    /// is already preserved intact by the generated `.unknown` fallback.
    ///
    /// - Parameter update: The received plan update.
    private mutating func applyPlanUpdate(_ update: PlanUpdate) {
        guard case .items(let items) = update.plan else { return }
        plans[items.planId] = items.entries
    }
}

/// One agent-owned terminal's accumulated state, folded from `terminal_update`
/// and `terminal_output_chunk` notifications.
///
/// `output` is tracked separately from the other fields: `terminal_update`'s
/// own `output` field carries a `TerminalOutput` snapshot that *replaces* the
/// accumulated bytes outright (an authoritative resync), while
/// `terminal_output_chunk` appends to them — two different operations on the
/// same buffer, not a patch-semantics field to fold like the rest.
public struct AccumulatedTerminal: Hashable, Sendable {
    /// The command being run.
    public var command: PatchField<String> = .unchanged

    /// The absolute working directory of the command.
    public var cwd: PatchField<AbsolutePath> = .unchanged

    /// Exit information. A concrete value marks the terminal as exited.
    public var exitStatus: PatchField<TerminalExitStatus> = .unchanged

    /// The `_meta` extension field.
    public var meta: PatchField<JSONValue> = .unchanged

    /// The terminal's accumulated output bytes, decoded from base64 as they
    /// arrive.
    public var output = Data()

    /// Creates a terminal with every field unknown — the state a
    /// never-before-seen `terminalId` starts in.
    public init() {}
}
