import Foundation

/// Merges the full `session/update` stream of one session into the complete
/// state of the session.
///
/// ACP v2 gives the merge rules only in text, on the documentation of each
/// update. The generated wire types decode one update at a time. This engine
/// applies the rules over the stream:
///
/// - The transcript is an ordered list of ``SessionEntry`` values. The first
///   update for an item adds an entry at the end. Each later update for the
///   same item changes that entry, and the entry keeps its position.
/// - A whole message update replaces the content, and a chunk appends to it.
/// - A tool-call update folds each field onto the tool call with
///   `ToolCallUpdate.folded(onto:)`, which the generator makes for each field.
/// - A terminal chunk appends decoded bytes, and an `output` snapshot replaces
///   them.
/// - A plan update replaces the plan with the same `planId`.
/// - An unknown update becomes an unknown entry. The engine never drops an
///   update.
/// - The last-value fields (``availableCommands``, ``configOptions``,
///   ``usage``, ``agentState``) take the value of the last update.
///   ``sessionInfo`` folds as a patch: an omitted field does not change, and
///   `null` clears the field.
///
/// Each call to ``apply(_:)`` returns a ``SessionMergeEngine/Change`` that
/// tells what changed and holds the new value. A client model can then change
/// only the affected object. An agent can keep the engine as the history of a
/// session, and send ``transcriptUpdates`` and ``stateUpdates`` again on
/// `session/resume`. The replay keeps the identifier of each entry.
///
/// The engine is a value type. It does not use Observation or a global actor,
/// so it can live in any isolation domain.
public struct SessionMergeEngine: Hashable, Sendable {
    /// What one update changed, with the new value.
    public enum Change: Hashable, Sendable {
        /// The update added an entry at the end of the transcript.
        case entryAdded(index: Int, entry: SessionEntry)

        /// The update changed the entry at this index. The entry holds its
        /// identifier and its new state.
        case entryChanged(index: Int, entry: SessionEntry)

        /// The available commands changed to this list. An empty list means
        /// that the agent has no commands.
        case availableCommandsChanged([AvailableCommand])

        /// The configuration options changed to this full set.
        case configOptionsChanged([SessionConfigOption])

        /// The usage changed to this value.
        case usageChanged(UsageUpdate)

        /// The agent state changed to this value.
        case agentStateChanged(StateUpdate)

        /// The session information changed to this folded value.
        case sessionInfoChanged(SessionInfoUpdate)
    }

    /// The transcript, in the order of first appearance.
    public private(set) var entries: [SessionEntry] = []

    /// The commands that the agent advertises. `nil` means that the agent
    /// did not report commands. An empty list means that the agent has no
    /// commands.
    public private(set) var availableCommands: [AvailableCommand]?

    /// The configuration options of the session. `nil` means that the agent
    /// did not report options.
    public private(set) var configOptions: [SessionConfigOption]?

    /// The last usage report. `nil` means that the agent did not report
    /// usage.
    public private(set) var usage: UsageUpdate?

    /// The last state of the foreground work of the agent. `nil` means that
    /// the agent did not report a state.
    public private(set) var agentState: StateUpdate?

    /// The session information, folded as a patch. A field that no update
    /// gave stays `.unchanged`.
    public private(set) var sessionInfo = SessionInfoUpdate()

    /// The index in ``entries`` of each entry identifier.
    private var indexByID: [SessionEntry.ID: Int] = [:]

    /// Creates an engine with an empty transcript and no session state.
    public init() {}

    // MARK: - Applying updates

    /// Merges one `session/update` payload into the session state.
    ///
    /// - Parameter update: The update to merge.
    /// - Returns: What changed, with the new value.
    @discardableResult
    public mutating func apply(_ update: SessionUpdate) -> Change {
        switch update {
        case .userMessageChunk(let chunk):
            updateMessage(chunk.messageId, role: .user) { $0.append(chunk) }
        case .userMessage(let message):
            updateMessage(message.messageId, role: .user) { $0.apply(content: message.content, meta: message.meta) }
        case .agentMessageChunk(let chunk):
            updateMessage(chunk.messageId, role: .agent) { $0.append(chunk) }
        case .agentMessage(let message):
            updateMessage(message.messageId, role: .agent) { $0.apply(content: message.content, meta: message.meta) }
        case .agentThoughtChunk(let chunk):
            updateMessage(chunk.messageId, role: .thought) { $0.append(chunk) }
        case .agentThought(let thought):
            updateMessage(thought.messageId, role: .thought) { $0.apply(content: thought.content, meta: thought.meta) }
        case .toolCallUpdate(let toolCall):
            updateToolCall(toolCall.toolCallId) { $0 = toolCall.folded(onto: $0) }
        case .toolCallContentChunk(let chunk):
            updateToolCall(chunk.toolCallId) { toolCall in
                toolCall.appendContent(chunk.content)
                toolCall.meta = PatchField(optional: chunk.meta).folded(onto: toolCall.meta)
            }
        case .terminalUpdate(let terminal):
            updateTerminal(terminal.terminalId) { $0.apply(terminal) }
        case .terminalOutputChunk(let chunk):
            updateTerminal(chunk.terminalId) { terminal in
                terminal.appendOutput(base64: chunk.data)
                terminal.meta = PatchField(optional: chunk.meta).folded(onto: terminal.meta)
            }
        case .planUpdate(let plan):
            updatePlan(plan)
        case .unknown(let type, let payload):
            appendEntry(SessionEntry(id: nextUnidentifiedID, kind: .unknown(type: type, payload: payload)))
        case .stateUpdate(let state):
            setAgentState(state)
        case .availableCommandsUpdate(let commands):
            setAvailableCommands(commands.availableCommands)
        case .configOptionUpdate(let options):
            setConfigOptions(options.configOptions)
        case .usageUpdate(let usage):
            setUsage(usage)
        case .sessionInfoUpdate(let info):
            foldSessionInfo(info)
        }
    }

    /// Sets the commands and the configuration options that a
    /// `session/new` response gives.
    ///
    /// An omitted or empty command list leaves ``availableCommands`` as it
    /// is: the wire states that both mean "no initial commands are
    /// advertised", and a later `available_commands_update` gives the list.
    ///
    /// - Parameter response: The `session/new` response.
    /// - Returns: The state changes, in the order the engine applied them.
    @discardableResult
    public mutating func seed(from response: NewSessionResponse) -> [Change] {
        seed(availableCommands: response.availableCommands, configOptions: response.configOptions)
    }

    /// Sets the commands and the configuration options that a
    /// `session/resume` response gives.
    ///
    /// An omitted or empty command list leaves ``availableCommands`` as it
    /// is, as for a `session/new` response.
    ///
    /// - Parameter response: The `session/resume` response.
    /// - Returns: The state changes, in the order the engine applied them.
    @discardableResult
    public mutating func seed(from response: ResumeSessionResponse) -> [Change] {
        seed(availableCommands: response.availableCommands, configOptions: response.configOptions)
    }

    /// Clears the transcript and the session state.
    ///
    /// A client that resumes a session that is already open calls this
    /// before the replay starts. If it does not, replayed chunks append to
    /// the messages that the engine has already.
    public mutating func reset() {
        self = SessionMergeEngine()
    }

    // MARK: - Reading the state

    /// Finds the entry with an identifier.
    ///
    /// - Parameter id: The entry identifier.
    /// - Returns: The entry, or `nil` when the transcript has no entry with
    ///   this identifier.
    public func entry(withID id: SessionEntry.ID) -> SessionEntry? {
        indexByID[id].map { entries[$0] }
    }

    /// The transcript as session updates, one update for each entry, in the
    /// order of the transcript.
    ///
    /// When an engine with no entries applies these updates, it gets the
    /// same entries with the same identifiers. An agent sends them on
    /// `session/resume`.
    public var transcriptUpdates: [SessionUpdate] {
        entries.map(\.replayUpdate)
    }

    /// The session state as session updates: one update for each state field
    /// that has a value.
    ///
    /// When an engine with no state applies these updates, it gets the same
    /// state.
    public var stateUpdates: [SessionUpdate] {
        let commands = availableCommands.map {
            SessionUpdate.availableCommandsUpdate(AvailableCommandsUpdate(availableCommands: $0))
        }
        let options = configOptions.map { SessionUpdate.configOptionUpdate(ConfigOptionUpdate(configOptions: $0)) }
        let info = sessionInfo == SessionInfoUpdate() ? nil : SessionUpdate.sessionInfoUpdate(sessionInfo)
        let replay = [commands, options, usage.map(SessionUpdate.usageUpdate), info, agentState.map(SessionUpdate.stateUpdate)]
        return replay.compactMap { $0 }
    }

    // MARK: - Transcript entries

    /// The identifier for the next entry that has no wire identifier.
    private var nextUnidentifiedID: SessionEntry.ID {
        .unidentified(position: entries.count)
    }

    /// Changes a message entry, and adds the entry when it is new.
    ///
    /// - Parameters:
    ///   - messageId: The identifier of the message.
    ///   - role: The kind of message.
    ///   - change: Changes the message.
    /// - Returns: What changed.
    private mutating func updateMessage(
        _ messageId: MessageId,
        role: MessageRole,
        change: (inout SessionEntry.Message) -> Void
    ) -> Change {
        upsert(
            role.entryID(messageId),
            initial: SessionEntry.Message(messageId: messageId),
            extract: \.message,
            embed: role.kind,
            change: change
        )
    }

    /// Changes a tool-call entry, and adds the entry when it is new.
    ///
    /// - Parameters:
    ///   - toolCallId: The identifier of the tool call.
    ///   - change: Changes the tool call.
    /// - Returns: What changed.
    private mutating func updateToolCall(_ toolCallId: ToolCallId, change: (inout ToolCallUpdate) -> Void) -> Change {
        upsert(
            .toolCall(toolCallId),
            initial: ToolCallUpdate(toolCallId: toolCallId),
            extract: \.toolCall,
            embed: SessionEntry.Kind.toolCall,
            change: change
        )
    }

    /// Changes a terminal entry, and adds the entry when it is new.
    ///
    /// - Parameters:
    ///   - terminalId: The identifier of the terminal.
    ///   - change: Changes the terminal.
    /// - Returns: What changed.
    private mutating func updateTerminal(_ terminalId: TerminalId, change: (inout AccumulatedTerminal) -> Void) -> Change {
        upsert(
            .terminal(terminalId),
            initial: AccumulatedTerminal(),
            extract: \.terminal,
            embed: { .terminal(terminalId, $0) },
            change: change
        )
    }

    /// Replaces a plan entry, and adds the entry when it is new.
    ///
    /// A plan update with no `planId` cannot match an entry, so it always
    /// adds an entry. A plan update without `_meta` keeps the `_meta` of the
    /// plan.
    ///
    /// - Parameter incoming: The plan update.
    /// - Returns: What changed.
    private mutating func updatePlan(_ incoming: PlanUpdate) -> Change {
        upsert(
            incoming.planId.map(SessionEntry.ID.plan) ?? nextUnidentifiedID,
            initial: incoming,
            extract: \.plan,
            embed: SessionEntry.Kind.plan
        ) { plan in
            plan = PlanUpdate(plan: incoming.plan, meta: incoming.meta ?? plan.meta)
        }
    }

    /// Changes the payload of an entry, and adds the entry when it is new.
    ///
    /// - Parameters:
    ///   - id: The identifier of the entry.
    ///   - initial: The payload of a new entry, before the change.
    ///   - extract: Gets the payload from the kind of the entry.
    ///   - embed: Makes the kind of the entry from the payload.
    ///   - change: Changes the payload.
    /// - Returns: What changed.
    private mutating func upsert<Payload>(
        _ id: SessionEntry.ID,
        initial: Payload,
        extract: (SessionEntry.Kind) -> Payload?,
        embed: (Payload) -> SessionEntry.Kind,
        change: (inout Payload) -> Void
    ) -> Change {
        guard let index = indexByID[id] else {
            var payload = initial
            change(&payload)
            return appendEntry(SessionEntry(id: id, kind: embed(payload)))
        }
        // Each identifier case belongs to one entry kind, so the payload is
        // always there. A missing payload is a defect in this type.
        guard var payload = extract(entries[index].kind) else {
            preconditionFailure("The entry \(id) does not have the kind that its identifier gives")
        }
        // Put a placeholder in the entry before the change. Then the payload
        // holds the only reference to its storage, and a chunk appends in
        // place. Without this, each chunk copies all of the earlier content.
        entries[index].kind = .unknown(type: "", payload: .null)
        change(&payload)
        entries[index].kind = embed(payload)
        return .entryChanged(index: index, entry: entries[index])
    }

    /// Adds an entry at the end of the transcript.
    ///
    /// - Parameter entry: The new entry.
    /// - Returns: The change that tells about the new entry.
    private mutating func appendEntry(_ entry: SessionEntry) -> Change {
        indexByID[entry.id] = entries.count
        entries.append(entry)
        return .entryAdded(index: entries.count - 1, entry: entry)
    }

    // MARK: - Last-value state

    /// Replaces the agent state.
    ///
    /// - Parameter state: The state from a `state_update`.
    /// - Returns: What changed.
    private mutating func setAgentState(_ state: StateUpdate) -> Change {
        agentState = state
        return .agentStateChanged(state)
    }

    /// Replaces the available commands.
    ///
    /// - Parameter commands: The list from an `available_commands_update`.
    /// - Returns: What changed.
    private mutating func setAvailableCommands(_ commands: [AvailableCommand]) -> Change {
        availableCommands = commands
        return .availableCommandsChanged(commands)
    }

    /// Replaces the configuration options.
    ///
    /// - Parameter options: The full set from a `config_option_update`.
    /// - Returns: What changed.
    private mutating func setConfigOptions(_ options: [SessionConfigOption]) -> Change {
        configOptions = options
        return .configOptionsChanged(options)
    }

    /// Replaces the usage.
    ///
    /// - Parameter usage: The value from a `usage_update`.
    /// - Returns: What changed.
    private mutating func setUsage(_ usage: UsageUpdate) -> Change {
        self.usage = usage
        return .usageChanged(usage)
    }

    /// Folds a `session_info_update` onto the session information. An
    /// omitted field does not change, and `null` clears the field.
    ///
    /// - Parameter info: The session information update.
    /// - Returns: What changed.
    private mutating func foldSessionInfo(_ info: SessionInfoUpdate) -> Change {
        sessionInfo = info.folded(onto: sessionInfo)
        return .sessionInfoChanged(sessionInfo)
    }

    /// Applies the commands and the configuration options of a session
    /// response as the equivalent session updates.
    ///
    /// - Parameters:
    ///   - commands: The `availableCommands` field of the response.
    ///   - options: The `configOptions` field of the response.
    /// - Returns: The state changes, in the order the engine applied them.
    private mutating func seed(
        availableCommands commands: [AvailableCommand]?,
        configOptions options: [SessionConfigOption]?
    ) -> [Change] {
        let advertised = commands.flatMap { $0.isEmpty ? nil : $0 }
        let seedUpdates = [
            advertised.map { SessionUpdate.availableCommandsUpdate(AvailableCommandsUpdate(availableCommands: $0)) },
            options.map { SessionUpdate.configOptionUpdate(ConfigOptionUpdate(configOptions: $0)) },
        ]
        return seedUpdates.compactMap { $0 }.map { apply($0) }
    }
}

/// The three kinds of message entry. Each kind has its own identifier case
/// and its own entry kind.
private enum MessageRole {
    case user
    case agent
    case thought

    /// Makes the entry identifier of a message of this kind.
    ///
    /// - Parameter messageId: The identifier of the message.
    /// - Returns: The entry identifier.
    func entryID(_ messageId: MessageId) -> SessionEntry.ID {
        switch self {
        case .user: .userMessage(messageId)
        case .agent: .agentMessage(messageId)
        case .thought: .agentThought(messageId)
        }
    }

    /// Makes the entry kind of a message of this kind.
    ///
    /// - Parameter message: The merged message.
    /// - Returns: The entry kind.
    func kind(_ message: SessionEntry.Message) -> SessionEntry.Kind {
        switch self {
        case .user: .userMessage(message)
        case .agent: .agentMessage(message)
        case .thought: .agentThought(message)
        }
    }
}
