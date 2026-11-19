import Foundation

extension SessionEntry.ID {
    /// The one text form of an entry identifier: `<kind>:<wire id>`.
    ///
    /// The search uses this form. ``SessionSearchChunker`` writes it, the
    /// server puts it in the `entryId` of a search hit, and a client reads
    /// it with ``init(searchHitID:)``. The kinds are:
    ///
    /// | Case | Text |
    /// |---|---|
    /// | ``userMessage(_:)`` | `user:<messageId>` |
    /// | ``agentMessage(_:)`` | `agent:<messageId>` |
    /// | ``agentThought(_:)`` | `thought:<messageId>` |
    /// | ``toolCall(_:)`` | `tool:<toolCallId>` |
    /// | ``terminal(_:)`` | `terminal:<terminalId>` |
    /// | ``plan(_:)`` | `plan:<planId>` |
    /// | ``compaction(_:)`` | `compaction:<compactionId>` |
    /// | ``sessionMessage(_:)`` | `message:<messageId>` |
    /// | ``unidentified(position:)`` | `position:<position>` |
    ///
    /// The wire id follows the first `:` without change, so a wire id that
    /// has a `:` in it reads back the same.
    public var searchHitID: String {
        switch self {
        case .userMessage(let id): "\(Self.userTag):\(id.rawValue)"
        case .agentMessage(let id): "\(Self.agentTag):\(id.rawValue)"
        case .agentThought(let id): "\(Self.thoughtTag):\(id.rawValue)"
        case .toolCall(let id): "\(Self.toolTag):\(id.rawValue)"
        case .terminal(let id): "\(Self.terminalTag):\(id.rawValue)"
        case .plan(let id): "\(Self.planTag):\(id.rawValue)"
        case .compaction(let id): "\(Self.compactionTag):\(id.rawValue)"
        case .sessionMessage(let id): "\(Self.messageTag):\(id.rawValue)"
        case .unidentified(let position): "\(Self.positionTag):\(position)"
        }
    }

    /// Reads the text form that ``searchHitID`` writes.
    ///
    /// - Parameter text: The text form, `<kind>:<wire id>`.
    /// - Returns: `nil` when the kind is not known, or when a `position`
    ///   is not a whole number that is not negative.
    public init?(searchHitID text: String) {
        guard let colon = text.firstIndex(of: ":") else {
            return nil
        }
        let tag = String(text[..<colon])
        let value = String(text[text.index(after: colon)...])
        switch tag {
        case Self.userTag: self = .userMessage(MessageId(rawValue: value))
        case Self.agentTag: self = .agentMessage(MessageId(rawValue: value))
        case Self.thoughtTag: self = .agentThought(MessageId(rawValue: value))
        case Self.toolTag: self = .toolCall(ToolCallId(rawValue: value))
        case Self.terminalTag: self = .terminal(TerminalId(rawValue: value))
        case Self.planTag: self = .plan(PlanId(rawValue: value))
        case Self.compactionTag: self = .compaction(CompactionId(rawValue: value))
        case Self.messageTag: self = .sessionMessage(MessageId(rawValue: value))
        case Self.positionTag:
            guard let position = Int(value), position >= 0, String(position) == value else {
                return nil
            }
            self = .unidentified(position: position)
        default: return nil
        }
    }

    private static let userTag = "user"
    private static let agentTag = "agent"
    private static let thoughtTag = "thought"
    private static let toolTag = "tool"
    private static let terminalTag = "terminal"
    private static let planTag = "plan"
    private static let compactionTag = "compaction"
    private static let messageTag = "message"
    private static let positionTag = "position"
}

extension SessionEntry.ID: LosslessStringConvertible {
    /// The text form ``searchHitID``: `<kind>:<wire id>`.
    public var description: String {
        searchHitID
    }

    /// Reads the text form ``searchHitID``.
    ///
    /// - Parameter description: The text form, `<kind>:<wire id>`.
    public init?(_ description: String) {
        self.init(searchHitID: description)
    }
}
