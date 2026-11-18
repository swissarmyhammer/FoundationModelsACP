import Foundation

// MARK: - Fork cut

extension SAH {
    /// The cut point of a fork, in `_meta.sah.forkCut` of a
    /// `ForkSessionRequest`. (Unstable: ACP v2 `session/fork`.)
    ///
    /// ACP `session/fork` has no cut point: the agent forks the whole
    /// session. Testudo uses this object for "Fork from Here". The fork gets
    /// the history of the source up to the cut:
    ///
    /// - ``Side/after``: the history up to and including the message.
    ///   Testudo uses it on an agent message.
    /// - ``Side/before``: the history up to the message, without the
    ///   message. Testudo uses it on a user message.
    ///
    /// A request with no cut forks at the last completed turn. A running
    /// turn is not copied.
    ///
    /// A client sends a cut only when the agent advertises it: the agent
    /// sets `_meta.sah.forkCut` to `true` on its `SessionForkCapabilities`
    /// (``advertise(into:)``, ``isAdvertised(by:)``).
    public struct ForkCut: Codable, Hashable, Sendable {
        /// The `_meta.sah` member name of the object, and of the capability
        /// flag.
        public static let metaKey = "forkCut"

        /// The message at the cut, by its ACP `messageId` in the transcript
        /// of the source session.
        public var messageId: MessageId

        /// The side of the message where the cut is.
        public var side: Side

        /// Makes a cut.
        ///
        /// - Parameters:
        ///   - messageId: The message at the cut.
        ///   - side: The side of the message where the cut is.
        public init(messageId: MessageId, side: Side) {
            self.messageId = messageId
            self.side = side
        }

        /// The side of the message where the cut is.
        ///
        /// The value is open. A peer can send a side that this library does
        /// not know, and the value decodes with its raw text. An agent that
        /// does not know the side must refuse the request.
        public struct Side: WireRawValueCodable, Hashable, Sendable {
            /// The side name as it crosses the wire.
            public let rawValue: String

            /// Makes a side from its wire name.
            ///
            /// - Parameter rawValue: The side name.
            public init(rawValue: String) {
                self.rawValue = rawValue
            }

            /// The cut is before the message. The fork does not have the
            /// message.
            public static let before = Side(rawValue: "before")

            /// The cut is after the message. The fork has the message.
            public static let after = Side(rawValue: "after")
        }

        /// Reads the cut from `_meta.sah.forkCut` of a `ForkSessionRequest`.
        ///
        /// - Parameter meta: The `_meta` value of the request, or `nil`.
        /// - Returns: The cut, or `nil` when it is absent or is not valid.
        public static func extract(from meta: JSONValue?) -> ForkCut? {
            SAH.payload(ForkCut.self, inSAHObjectOf: meta, member: metaKey)
        }

        /// Writes this cut into `_meta.sah.forkCut` of a `_meta` value.
        ///
        /// The function keeps every other member of `_meta` and of
        /// `_meta.sah`. When `meta` or `_meta.sah` is a value that is not an
        /// object, the function returns `meta` unchanged.
        ///
        /// - Parameter meta: The `_meta` value to write into, or `nil`.
        /// - Returns: The `_meta` value to send.
        /// - Throws: `EncodingError` when the cut cannot be encoded.
        public func inject(into meta: JSONValue?) throws -> JSONValue {
            try SAH.inject(self, intoSAHObjectOf: meta, member: Self.metaKey)
        }

        /// Writes the flag `_meta.sah.forkCut = true` into the `_meta` of a
        /// `SessionForkCapabilities`. An agent sets it when it takes a cut.
        ///
        /// - Parameter meta: The `_meta` value to write into, or `nil`.
        /// - Returns: The `_meta` value to send.
        /// - Throws: `EncodingError` when the flag cannot be encoded.
        public static func advertise(into meta: JSONValue?) throws -> JSONValue {
            try SAH.inject(true, intoSAHObjectOf: meta, member: metaKey)
        }

        /// Tells whether a `_meta` value has the flag `_meta.sah.forkCut =
        /// true`.
        ///
        /// - Parameter meta: The `_meta` value of a `SessionForkCapabilities`,
        ///   or `nil`.
        /// - Returns: `true` only when the flag is the JSON value `true`.
        public static func isAdvertised(in meta: JSONValue?) -> Bool {
            SAH.payload(Bool.self, inSAHObjectOf: meta, member: metaKey) == true
        }

        /// Tells whether the fork capability of an agent advertises the cut.
        ///
        /// - Parameter capabilities: The `fork` member of the session
        ///   capabilities of the agent, or `nil`.
        /// - Returns: `true` when the agent can fork and takes a cut.
        public static func isAdvertised(by capabilities: SessionForkCapabilities?) -> Bool {
            guard let capabilities else {
                return false
            }
            return isAdvertised(in: capabilities.meta)
        }
    }
}
