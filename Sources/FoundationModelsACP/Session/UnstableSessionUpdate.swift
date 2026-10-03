extension Unstable {
    /// **UNSTABLE**
    ///
    /// A typed view of the session updates that upstream ACP has not made
    /// stable yet. Upstream can change or remove these updates at any time.
    ///
    /// The stable ``FoundationModelsACP/SessionUpdate`` enum has no case for
    /// these updates. A received `compaction_update`,
    /// `compaction_summary_chunk` or `notice` thus decodes as
    /// ``FoundationModelsACP/SessionUpdate/unknown(_:_:)``, and
    /// ``init(_:)`` reads it from that case. To send one of these updates,
    /// an agent makes the stable value with
    /// ``FoundationModelsACP/SessionUpdate/init(_:)`` and sends that value.
    public enum SessionUpdate: Hashable, Sendable {
        /// A context compaction was created or updated.
        ///
        /// The first update for a compaction ID fixes its position in the
        /// session timeline. A later update with the same ID patches that
        /// compaction: see ``CompactionUpdate/folded(onto:)``.
        case compactionUpdate(CompactionUpdate)

        /// A content block to append to the retained summary of a compaction
        /// that is in progress.
        case compactionSummaryChunk(CompactionSummaryChunk)

        /// Advisory information for the user. A notice is a live event and
        /// not part of the session history.
        case notice(Notice)

        /// The `sessionUpdate` wire value of each case.
        private enum Tag: String {
            /// The wire value of ``SessionUpdate/compactionUpdate(_:)``.
            case compactionUpdate = "compaction_update"

            /// The wire value of ``SessionUpdate/compactionSummaryChunk(_:)``.
            case compactionSummaryChunk = "compaction_summary_chunk"

            /// The wire value of ``SessionUpdate/notice(_:)``.
            case notice = "notice"
        }

        /// Reads an unstable session update from the stable value that
        /// carries it.
        ///
        /// - Parameter update: A received stable session update.
        /// - Returns: `nil` when `update` is not
        ///   ``FoundationModelsACP/SessionUpdate/unknown(_:_:)``, or when its
        ///   type is not an unstable update that this view knows.
        /// - Throws: `DecodingError` when the type is known but the payload
        ///   does not decode as that update.
        public init?(_ update: FoundationModelsACP.SessionUpdate) throws {
            guard case .unknown(let wireType, let payload) = update, let tag = Tag(rawValue: wireType) else {
                return nil
            }
            switch tag {
            case .compactionUpdate:
                self = .compactionUpdate(try payload.decoded(as: CompactionUpdate.self))
            case .compactionSummaryChunk:
                self = .compactionSummaryChunk(try payload.decoded(as: CompactionSummaryChunk.self))
            case .notice:
                self = .notice(try payload.decoded(as: Notice.self))
            }
        }

        /// The `sessionUpdate` wire value of this update.
        fileprivate var wireType: String {
            switch self {
            case .compactionUpdate: Tag.compactionUpdate.rawValue
            case .compactionSummaryChunk: Tag.compactionSummaryChunk.rawValue
            case .notice: Tag.notice.rawValue
            }
        }

        /// This update's payload as structural JSON, without the
        /// `sessionUpdate` member.
        ///
        /// - Returns: The encoded payload.
        /// - Throws: `EncodingError` when the payload cannot be encoded.
        fileprivate func encodedPayload() throws -> JSONValue {
            switch self {
            case .compactionUpdate(let payload): try JSONValue.encode(result: payload)
            case .compactionSummaryChunk(let payload): try JSONValue.encode(result: payload)
            case .notice(let payload): try JSONValue.encode(result: payload)
            }
        }
    }
}

extension SessionUpdate {
    /// **UNSTABLE**
    ///
    /// Makes the stable session update that carries an unstable update, so
    /// that an agent can send it.
    ///
    /// The result is ``unknown(_:_:)`` with the update's wire type and
    /// payload. It encodes to the same wire object as the unstable update.
    ///
    /// - Parameter update: The unstable update to carry.
    /// - Throws: `EncodingError` when the payload cannot be encoded.
    public init(_ update: Unstable.SessionUpdate) throws {
        self = .unknown(update.wireType, try update.encodedPayload())
    }
}
