import Foundation
import FoundationModelsACP

/// The agent that wrote a session file. (D209 of Testudo.)
public enum ImportSourceAgent: String, Sendable, Hashable, Codable, CaseIterable {
    /// Claude Code: `~/.claude/projects/<project>/<session id>.jsonl`.
    case claudeCode = "claude-code"

    /// Codex: `~/.codex/sessions/YYYY/MM/DD/rollout-<timestamp>-<id>.jsonl`.
    case codex = "codex"
}

/// What the scan of a session file gives, with no updates.
public struct ImportedSessionMetadata: Sendable, Hashable {
    /// The agent that wrote the file.
    public var agent: ImportSourceAgent

    /// The identifier of the session in the source agent.
    public var sourceID: String

    /// The working folder of the session, or `nil` when the file does not
    /// give it.
    public var cwd: URL?

    /// The title of the session, or `nil` when the file has no title.
    public var title: String?

    /// The date of the first record that has a date.
    public var firstDate: Date?

    /// The date of the last record that has a date.
    public var lastDate: Date?

    /// The number of prompts of the user.
    public var turnCount: Int

    /// Makes the metadata.
    public init(
        agent: ImportSourceAgent,
        sourceID: String,
        cwd: URL? = nil,
        title: String? = nil,
        firstDate: Date? = nil,
        lastDate: Date? = nil,
        turnCount: Int = 0
    ) {
        self.agent = agent
        self.sourceID = sourceID
        self.cwd = cwd
        self.title = title
        self.firstDate = firstDate
        self.lastDate = lastDate
        self.turnCount = turnCount
    }
}

/// A session that a reader read from a file.
public struct ImportedSession: Sendable, Hashable {
    /// The metadata of the session.
    public var metadata: ImportedSessionMetadata

    /// The ACP v2 session updates of the session, in the order of the file.
    /// `SessionMergeEngine` and the `ACPMarkdown` renderer take them with no
    /// unknown update.
    public var updates: [SessionUpdate]

    /// The number of records (and lines that are not JSON) that the reader
    /// did not read.
    public var skippedRecordCount: Int

    /// The kind of each skipped record, with its count. A line that is not
    /// JSON has the kind `invalid-json`.
    public var skippedKinds: [String: Int]

    /// Makes an imported session.
    public init(
        metadata: ImportedSessionMetadata,
        updates: [SessionUpdate],
        skippedRecordCount: Int,
        skippedKinds: [String: Int]
    ) {
        self.metadata = metadata
        self.updates = updates
        self.skippedRecordCount = skippedRecordCount
        self.skippedKinds = skippedKinds
    }
}

/// An error of a reader.
public enum ImportReadError: Error, Sendable, Hashable {
    /// The file has records of this format, but no record that gives a
    /// message, a tool call or a plan. An empty file also gives this error.
    case noReadableRecord

    /// The file has JSON records, but none of them is a record of this
    /// format.
    case notThisFormat
}
