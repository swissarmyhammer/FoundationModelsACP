import Foundation

/// Links the local pending prompts of a client to the user messages that the
/// agent inserts.
///
/// When a client sends `session/prompt`, it can show the prompt at once as a
/// local pending entry. The agent then inserts the user message, gives it a
/// `messageId`, and sends two items that have that identifier:
///
/// - The `session/prompt` response, ``PromptResponse/messageId``.
/// - A `user_message` (or `user_message_chunk`) session update: the echo.
///
/// The echo can arrive before or after the response. This type accepts the
/// two items in either order. When it has both items for a pending prompt, it
/// returns a ``Link``. The client then replaces its local pending entry with
/// the transcript entry of the message, ``Link/entryID``.
///
/// Use it in this sequence:
///
/// 1. Call ``addPendingPrompt(_:)`` before you send `session/prompt`.
/// 2. Give the response to ``resolve(_:with:)``.
/// 3. Give each session update of the session to ``observe(_:)``.
/// 4. If the request fails, call ``removePendingPrompt(_:)``.
///
/// The correlator keeps an echo that arrives before its response only while a
/// prompt waits for its response. An echo that arrives when no prompt waits
/// is from a different source (for example, a replay or a different client),
/// so the correlator does not keep it.
///
/// The correlator is a value type. It does not use Observation or a global
/// actor, so it can live in any isolation domain.
public struct PendingPromptCorrelator<LocalID: Hashable & Sendable>: Hashable, Sendable {
    /// The link between a local pending prompt and the user message that the
    /// agent inserted for it.
    public struct Link: Hashable, Sendable {
        /// The local identifier of the pending prompt.
        public let localID: LocalID

        /// The identifier that the agent gave to the user message.
        public let messageId: MessageId

        /// The identifier of the user message entry in a
        /// ``SessionMergeEngine`` transcript.
        public var entryID: SessionEntry.ID {
            .userMessage(messageId)
        }
    }

    /// The local prompts that wait for their `session/prompt` response.
    private var awaitingResponse: Set<LocalID> = []

    /// The local prompt of each response that waits for its echo, by the
    /// message identifier that the response gave.
    private var awaitingEcho: [MessageId: LocalID] = [:]

    /// The message identifiers of echoes that arrived before a response named
    /// them.
    private var earlyEchoes: Set<MessageId> = []

    /// Creates a correlator with no pending prompts.
    public init() {}

    /// Tells if a pending prompt waits for its `session/prompt` response.
    ///
    /// While this is `true`, ``observe(_:)`` keeps each echo that no response
    /// named yet.
    var isAwaitingResponse: Bool {
        !awaitingResponse.isEmpty
    }

    /// Records a local prompt that the client is about to send.
    ///
    /// Call this before you send `session/prompt`. Then the correlator keeps
    /// an echo that arrives before the response.
    ///
    /// - Parameter localID: The local identifier of the pending prompt.
    public mutating func addPendingPrompt(_ localID: LocalID) {
        awaitingResponse.insert(localID)
    }

    /// Gives the `session/prompt` response of a pending prompt.
    ///
    /// - Parameters:
    ///   - localID: The local identifier of the pending prompt.
    ///   - response: The response, which names the inserted user message.
    /// - Returns: The link when the echo arrived before this response, or
    ///   `nil` when the echo did not arrive yet.
    @discardableResult
    public mutating func resolve(_ localID: LocalID, with response: PromptResponse) -> Link? {
        awaitingResponse.remove(localID)
        defer { forgetEarlyEchoesWhenNoPromptWaits() }
        guard earlyEchoes.remove(response.messageId) != nil else {
            awaitingEcho[response.messageId] = localID
            return nil
        }
        return Link(localID: localID, messageId: response.messageId)
    }

    /// Gives one session update of the session.
    ///
    /// Only a `user_message` or a `user_message_chunk` update can make a
    /// link. The correlator ignores all other updates.
    ///
    /// - Parameter update: The session update.
    /// - Returns: The link when this update is the first echo of a message
    ///   that a response named, or `nil` in all other cases.
    @discardableResult
    public mutating func observe(_ update: SessionUpdate) -> Link? {
        guard let messageId = update.userMessageId else {
            return nil
        }
        if let localID = awaitingEcho.removeValue(forKey: messageId) {
            return Link(localID: localID, messageId: messageId)
        }
        if !awaitingResponse.isEmpty {
            earlyEchoes.insert(messageId)
        }
        return nil
    }

    /// Removes a pending prompt that will not get a link, for example
    /// because its request failed.
    ///
    /// - Parameter localID: The local identifier of the pending prompt.
    public mutating func removePendingPrompt(_ localID: LocalID) {
        awaitingResponse.remove(localID)
        awaitingEcho = awaitingEcho.filter { $0.value != localID }
        forgetEarlyEchoesWhenNoPromptWaits()
    }

    /// Removes the early echoes when no prompt waits for its response. No
    /// later response can name them.
    private mutating func forgetEarlyEchoesWhenNoPromptWaits() {
        guard awaitingResponse.isEmpty else {
            return
        }
        earlyEchoes.removeAll()
    }
}

extension SessionUpdate {
    /// The message identifier, when this update is a `user_message` or a
    /// `user_message_chunk`.
    var userMessageId: MessageId? {
        switch self {
        case .userMessage(let message):
            message.messageId
        case .userMessageChunk(let chunk):
            chunk.messageId
        case .agentMessageChunk, .agentMessage, .agentThoughtChunk, .agentThought, .toolCallUpdate,
            .toolCallContentChunk, .terminalUpdate, .terminalOutputChunk, .planUpdate, .stateUpdate,
            .availableCommandsUpdate, .configOptionUpdate, .usageUpdate, .sessionInfoUpdate, .notice,
            .compactionUpdate, .compactionSummaryChunk, .unknown:
            nil
        }
    }
}
