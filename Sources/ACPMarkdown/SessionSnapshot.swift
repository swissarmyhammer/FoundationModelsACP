import Foundation
import FoundationModelsACP

/// The snapshot of a shared session: the session updates after the content
/// rules of the share, and their Markdown. (D208 of Testudo.)
///
/// ``build(updates:options:)`` is a pure function. The UI and the agent use
/// it, so the same updates and the same options always give the same
/// snapshot.
///
/// The content rules:
///
/// - The builder folds the updates with a `SessionMergeEngine`. The
///   snapshot has one update for each transcript entry, in the order of the
///   transcript (`SessionMergeEngine/transcriptUpdates`).
/// - The state updates (commands, configuration options, usage, session
///   information, state, sub-agents) and the notices are not in the
///   snapshot, as in the export.
/// - With ``Options/includeThoughts`` `false`, the thoughts are not in the
///   snapshot.
/// - With ``Options/includeToolOutput`` `false`, a tool call keeps its title,
///   its kind, its status and its diffs. It loses its other content, its raw
///   input and output, and its terminals. A terminal entry is not in the
///   snapshot.
/// - The builder does not check for secrets and does not change the text of
///   an update. The owner of the share is responsible for its content.
public struct SessionSnapshot: Hashable, Sendable {
    /// The version of the coded form that this library writes.
    public static let formatVersion = 1

    /// The session updates after the content rules, one for each transcript
    /// entry.
    public let updates: [SessionUpdate]

    /// The Markdown of the updates: ``SessionMarkdown/render(updates:options:)``
    /// with the title and the thoughts of the options.
    public let markdown: String

    /// The number of turns: the user messages and the messages that this
    /// session received from another session.
    public let turnCount: Int

    /// The options that made the snapshot.
    public let options: Options

    /// Makes the snapshot of a session.
    ///
    /// When ``Options/title`` is `nil`, the title comes from the folded
    /// session information of the updates.
    ///
    /// - Parameters:
    ///   - updates: The session updates of the session, in the order of the
    ///     wire.
    ///   - options: The options of the share.
    /// - Returns: The snapshot.
    public static func build(updates: some Sequence<SessionUpdate>, options: Options = .init()) -> SessionSnapshot {
        let engine = SessionMergeEngine(replaying: updates)
        var resolved = options
        if resolved.title == nil, case .value(let title) = engine.sessionInfo.title {
            resolved.title = title
        }
        let filtered = engine.transcriptUpdates.compactMap { apply(resolved, to: $0) }
        return SessionSnapshot(filtered: filtered, options: resolved)
    }

    /// Makes a snapshot from updates that the content rules already
    /// filtered.
    private init(filtered: [SessionUpdate], options: Options) {
        self.updates = filtered
        self.options = options
        self.markdown = SessionMarkdown.render(
            updates: filtered,
            options: SessionMarkdown.Options(
                includeThoughts: options.includeThoughts,
                title: options.title,
                agentName: options.agentName
            )
        )
        self.turnCount = SessionMergeEngine(replaying: filtered).entries.reduce(0) { count, entry in
            switch entry.kind {
            case .userMessage:
                count + 1
            case .sessionMessage(let message):
                Self.isSent(message) ? count : count + 1
            default:
                count
            }
        }
    }

    /// Applies the content rules to one transcript update.
    ///
    /// - Parameters:
    ///   - options: The options of the share.
    ///   - update: One update of `SessionMergeEngine/transcriptUpdates`.
    /// - Returns: The update to keep, or `nil` to drop it.
    private static func apply(_ options: Options, to update: SessionUpdate) -> SessionUpdate? {
        switch update {
        case .agentThought, .agentThoughtChunk:
            return options.includeThoughts ? update : nil
        case .toolCallUpdate(let toolCall):
            guard !options.includeToolOutput else {
                return update
            }
            let diffs = toolCall.content.resolved(onto: []).filter {
                if case .diff = $0 { return true }
                return false
            }
            return .toolCallUpdate(
                ToolCallUpdate(
                    toolCallId: toolCall.toolCallId,
                    content: diffs.isEmpty ? .unchanged : .value(diffs),
                    kind: toolCall.kind,
                    status: toolCall.status,
                    title: toolCall.title
                )
            )
        case .terminalUpdate, .terminalOutputChunk, .toolCallContentChunk:
            return options.includeToolOutput ? update : nil
        case .stateUpdate, .availableCommandsUpdate, .configOptionUpdate, .sessionInfoUpdate, .usageUpdate,
            .subagentUpdate, .notice:
            return nil
        case .userMessageChunk, .userMessage, .agentMessageChunk, .agentMessage, .planUpdate, .compactionUpdate,
            .compactionSummaryChunk, .sessionMessage, .sessionMessageChunk, .unknown:
            return update
        }
    }

    /// `true` when this session sent the message to another session.
    private static func isSent(_ message: SessionEntry.InterSessionMessage) -> Bool {
        if case .value = message.recipientMessageId, case .value = message.senderMessageId {
            return false
        }
        if case .value = message.recipientMessageId {
            return true
        }
        return false
    }
}

// MARK: - Options

extension SessionSnapshot {
    /// The options of a share.
    ///
    /// The defaults give all that the chat shows: the thoughts and the full
    /// tool output.
    public struct Options: Hashable, Sendable, Codable {
        /// The default of ``includeThoughts``: `true`.
        public static let defaultIncludeThoughts = true

        /// The default of ``includeToolOutput``: `true`.
        public static let defaultIncludeToolOutput = true

        /// `true` keeps the thoughts of the agent in the share.
        public var includeThoughts: Bool

        /// `true` keeps the content and the terminal output of each tool call
        /// in the share, with no cut. `false` keeps the title, the kind, the
        /// status and the diffs of each tool call.
        public var includeToolOutput: Bool

        /// The title of the session. `nil` takes the title of the session
        /// information of the updates.
        public var title: String?

        /// The heading of the turns of the agent in the Markdown, or `nil`
        /// for "Agent".
        public var agentName: String?

        /// Makes the options.
        ///
        /// - Parameters:
        ///   - includeThoughts: `true` keeps the thoughts.
        ///   - includeToolOutput: `true` keeps the tool output.
        ///   - title: The title, or `nil` for the title of the session.
        ///   - agentName: The heading of the turns of the agent, or `nil`.
        public init(
            includeThoughts: Bool = Options.defaultIncludeThoughts,
            includeToolOutput: Bool = Options.defaultIncludeToolOutput,
            title: String? = nil,
            agentName: String? = nil
        ) {
            self.includeThoughts = includeThoughts
            self.includeToolOutput = includeToolOutput
            self.title = title
            self.agentName = agentName
        }
    }
}

// MARK: - Coded form

extension SessionSnapshot {
    /// An error of ``init(decoding:)``.
    public enum DecodingError: Error, Equatable, CustomStringConvertible {
        /// The share has a format version that this library does not know.
        case newerFormat(version: Int)

        public var description: String {
            switch self {
            case .newerFormat:
                "This share needs a newer Testudo."
            }
        }
    }

    /// The JSON form of a snapshot (`updates.json`).
    private struct Coded: Codable {
        var formatVersion: Int
        var options: Options
        var updates: [SessionUpdate]
    }

    /// Only the version of the coded form, so that a newer form is found
    /// before its other fields are read.
    private struct Version: Decodable {
        var formatVersion: Int
    }

    /// The coded form: JSON with `formatVersion`, the options, and the
    /// updates in their wire form. The keys are sorted, so the same snapshot
    /// always gives the same bytes.
    ///
    /// - Returns: The JSON bytes.
    /// - Throws: `EncodingError` when an update cannot be encoded.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(Coded(formatVersion: Self.formatVersion, options: options, updates: updates))
    }

    /// Reads the coded form that ``encoded()`` writes. The Markdown and the
    /// turn count come again from the updates.
    ///
    /// - Parameter data: The JSON bytes.
    /// - Throws: ``DecodingError/newerFormat(version:)`` when the format
    ///   version is higher than ``formatVersion``, or a `Swift.DecodingError`
    ///   when the JSON is not valid.
    public init(decoding data: Data) throws {
        let version = try JSONDecoder().decode(Version.self, from: data).formatVersion
        guard version <= Self.formatVersion else {
            throw DecodingError.newerFormat(version: version)
        }
        let coded = try JSONDecoder().decode(Coded.self, from: data)
        self.init(filtered: coded.updates, options: coded.options)
    }
}
