// MARK: - initialize

extension SAH {
    /// The SAH object in `_meta.sah` of the `initialize` response.
    ///
    /// The agent tells the client with it that it has the SAH extensions, and
    /// which GraphQL endpoints it has:
    ///
    /// ```json
    /// "_meta": {"sah": {"version": 1, "graphql": [
    ///   {"name": "kanban", "version": "1", "scope": "sessionFolder", "schema": "type Query { board: Board }"}
    /// ]}}
    /// ```
    ///
    /// A client that finds no valid object knows that the agent has no SAH
    /// extensions.
    public struct InitializeMeta: Codable, Hashable, Sendable {
        /// The version of the SAH extensions of the agent. See ``SAH/version``.
        public var version: Int

        /// The GraphQL endpoints of the agent: `_meta.sah.graphql`. It is the
        /// same list as the result of `_sah/graphql/endpoints`.
        public var graphql: [GraphQL.Endpoint]

        /// Makes the SAH object.
        ///
        /// - Parameters:
        ///   - version: The version of the SAH extensions.
        ///   - graphql: The GraphQL endpoints.
        public init(version: Int = SAH.version, graphql: [GraphQL.Endpoint]) {
            self.version = version
            self.graphql = graphql
        }

        /// Reads the SAH object from the `_meta` value of an `initialize`
        /// response.
        ///
        /// - Parameter meta: The `_meta` value, or `nil`.
        /// - Returns: The SAH object, or `nil` when `_meta.sah` is absent or
        ///   is not a valid object.
        public static func extract(from meta: JSONValue?) -> InitializeMeta? {
            SAH.payload(InitializeMeta.self, in: meta, member: SAH.metaKey)
        }

        /// Writes this SAH object into `_meta.sah` of a `_meta` value.
        ///
        /// The function replaces an earlier `_meta.sah` object. It keeps every
        /// other member of `_meta`. When `meta` is a value that is not an
        /// object, the function returns `meta` unchanged.
        ///
        /// - Parameter meta: The `_meta` value to write into, or `nil`.
        /// - Returns: The `_meta` value to send.
        /// - Throws: `EncodingError` when the object cannot be encoded.
        public func inject(into meta: JSONValue?) throws -> JSONValue {
            try SAH.inject(self, into: meta, member: SAH.metaKey)
        }
    }
}

// MARK: - Messages between sessions

extension SAH {
    /// The sender of a message from another session, in
    /// `_meta.sah.message` of a session update.
    ///
    /// ACP has no message from another session. Thus the agent sends the
    /// text of the message as a normal session update, and this object in its
    /// `_meta` names the sender. A client shows the entry as
    /// "From: <title> (<agent>, <folder>)".
    public struct SessionMessage: Codable, Hashable, Sendable {
        /// The `_meta.sah` member name of the object.
        public static let metaKey = "message"

        /// The id of the message, or `nil`.
        public var messageId: String?

        /// The id of the message that this message replies to, or `nil`.
        public var inReplyTo: String?

        /// The sender of the message.
        public var sender: Sender

        /// Makes the object.
        ///
        /// - Parameters:
        ///   - messageId: The id of the message, or `nil`.
        ///   - inReplyTo: The id of the message that this one replies to, or
        ///     `nil`.
        ///   - sender: The sender of the message.
        public init(messageId: String? = nil, inReplyTo: String? = nil, sender: Sender) {
            self.messageId = messageId
            self.inReplyTo = inReplyTo
            self.sender = sender
        }

        /// The sender of a message.
        public struct Sender: Codable, Hashable, Sendable {
            /// What sent the message.
            public var kind: Kind

            /// The session that sent the message, or `nil` when the sender is
            /// not a session.
            public var sessionId: SessionId?

            /// The title of the session that sent the message, or `nil`.
            public var title: String?

            /// The name of the agent of the session that sent the message, or
            /// `nil`.
            public var agent: String?

            /// The working folder of the session that sent the message, as an
            /// absolute path, or `nil`.
            public var cwd: String?

            /// Makes a sender.
            ///
            /// - Parameters:
            ///   - kind: What sent the message.
            ///   - sessionId: The session that sent it, or `nil`.
            ///   - title: The title of that session, or `nil`.
            ///   - agent: The name of the agent of that session, or `nil`.
            ///   - cwd: The working folder of that session, or `nil`.
            public init(
                kind: Kind,
                sessionId: SessionId? = nil,
                title: String? = nil,
                agent: String? = nil,
                cwd: String? = nil
            ) {
                self.kind = kind
                self.sessionId = sessionId
                self.title = title
                self.agent = agent
                self.cwd = cwd
            }

            /// What sent a message.
            ///
            /// The value is open. A peer can send a kind that this library
            /// does not know, and the value decodes with its raw text.
            public struct Kind: WireRawValueCodable, Hashable, Sendable {
                /// The kind name as it crosses the wire.
                public let rawValue: String

                /// Makes a kind from its wire name.
                ///
                /// - Parameter rawValue: The kind name.
                public init(rawValue: String) {
                    self.rawValue = rawValue
                }

                /// Another session sent the message.
                public static let session = Kind(rawValue: "session")

                /// The user sent the message through a UI.
                public static let user = Kind(rawValue: "user")
            }
        }

        /// Reads the object from `_meta.sah.message` of a session update.
        ///
        /// - Parameter meta: The `_meta` value, or `nil`.
        /// - Returns: The object, or `nil` when it is absent or is not valid.
        public static func extract(from meta: JSONValue?) -> SessionMessage? {
            SAH.payload(SessionMessage.self, inSAHObjectOf: meta, member: metaKey)
        }

        /// Writes this object into `_meta.sah.message` of a `_meta` value.
        ///
        /// The function keeps every other member of `_meta` and of
        /// `_meta.sah`. When `meta` or `_meta.sah` is a value that is not an
        /// object, the function returns `meta` unchanged.
        ///
        /// - Parameter meta: The `_meta` value to write into, or `nil`.
        /// - Returns: The `_meta` value to send.
        /// - Throws: `EncodingError` when the object cannot be encoded.
        public func inject(into meta: JSONValue?) throws -> JSONValue {
            try SAH.inject(self, intoSAHObjectOf: meta, member: Self.metaKey)
        }
    }
}

// MARK: - Rule denial

extension SAH {
    /// A rule denial, in `_meta["sah/ruleDenial"]` of a tool call update.
    ///
    /// When a rule denies a `runCode` snippet, the snippet does not run. The
    /// agent sends the tool call update with the status `failed` and the
    /// denial message as its content. This object goes with it, so that a UI
    /// can show the denial as a special case. The agent maps the
    /// `RuleDenial` of FoundationModelsRules to this wire type.
    public struct RuleDenial: Codable, Hashable, Sendable {
        /// The `_meta` member name of the object: `sah/ruleDenial`.
        public static let metaKey = "sah/ruleDenial"

        /// The rules that applied. It is empty for the basis
        /// ``Basis/checkFailed`` and for ``Basis/incomplete``.
        public var rules: [Entry]

        /// How the check got to the denial.
        public var basis: Basis

        /// The layer that is not complete, for the basis
        /// ``Basis/incomplete``, or `nil`.
        public var layer: Layer?

        /// The type of the error, for the basis ``Basis/checkFailed``, or
        /// `nil`. It is never the text of the error.
        public var errorType: String?

        /// The text for the model and the user. It is the same text as the
        /// content of the tool call update.
        public var message: String

        /// Makes a rule denial.
        ///
        /// - Parameters:
        ///   - rules: The rules that applied.
        ///   - basis: How the check got to the denial.
        ///   - layer: The layer that is not complete, or `nil`.
        ///   - errorType: The type of the error, or `nil`.
        ///   - message: The text for the model and the user.
        public init(
            rules: [Entry],
            basis: Basis,
            layer: Layer? = nil,
            errorType: String? = nil,
            message: String
        ) {
            self.rules = rules
            self.basis = basis
            self.layer = layer
            self.errorType = errorType
            self.message = message
        }

        /// One rule that applied.
        public struct Entry: Codable, Hashable, Sendable {
            /// The full id of the rule, for example `user:no-push-to-main`.
            /// For the hard check, the id of the hard check entry.
            public var id: String

            /// The layer of the rule.
            public var layer: Layer

            /// The sentence of the rule. For the hard check, the text of the
            /// entry.
            public var sentence: String

            /// The reason of the judge. For the hard check, the command that
            /// matched.
            public var reason: String

            /// The URL of the rule file, or `nil` for the hard check.
            public var file: String?

            /// The hash of the content of the rule, or `nil` for the hard
            /// check.
            public var contentHash: String?

            /// Makes an entry.
            ///
            /// - Parameters:
            ///   - id: The full id of the rule.
            ///   - layer: The layer of the rule.
            ///   - sentence: The sentence of the rule.
            ///   - reason: The reason of the judge.
            ///   - file: The URL of the rule file, or `nil`.
            ///   - contentHash: The hash of the content of the rule, or `nil`.
            public init(
                id: String,
                layer: Layer,
                sentence: String,
                reason: String,
                file: String? = nil,
                contentHash: String? = nil
            ) {
                self.id = id
                self.layer = layer
                self.sentence = sentence
                self.reason = reason
                self.file = file
                self.contentHash = contentHash
            }
        }

        /// A layer of the rule book.
        public struct Layer: Codable, Hashable, Sendable {
            /// The kind of the layer.
            public var kind: Kind

            /// The id of the agent, for the kind ``Kind/agent``, or `nil`.
            public var agentId: String?

            /// Makes a layer.
            ///
            /// - Parameters:
            ///   - kind: The kind of the layer.
            ///   - agentId: The id of the agent, or `nil`.
            public init(kind: Kind, agentId: String? = nil) {
                self.kind = kind
                self.agentId = agentId
            }

            /// The kind of a layer.
            ///
            /// The value is open. A peer can send a kind that this library
            /// does not know, and the value decodes with its raw text.
            public struct Kind: WireRawValueCodable, Hashable, Sendable {
                /// The kind name as it crosses the wire.
                public let rawValue: String

                /// Makes a kind from its wire name.
                ///
                /// - Parameter rawValue: The kind name.
                public init(rawValue: String) {
                    self.rawValue = rawValue
                }

                /// The built-in rules. They are locked.
                public static let builtIn = Kind(rawValue: "builtIn")

                /// The rules of the user.
                public static let user = Kind(rawValue: "user")

                /// The rules of one agent.
                public static let agent = Kind(rawValue: "agent")

                /// The rules of the project folder.
                public static let project = Kind(rawValue: "project")
            }
        }

        /// How the check got to a denial.
        ///
        /// The value is open. A peer can send a basis that this library does
        /// not know, and the value decodes with its raw text.
        public struct Basis: WireRawValueCodable, Hashable, Sendable {
            /// The basis name as it crosses the wire.
            public let rawValue: String

            /// Makes a basis from its wire name.
            ///
            /// - Parameter rawValue: The basis name.
            public init(rawValue: String) {
                self.rawValue = rawValue
            }

            /// The hard check denied the snippet, with no model.
            public static let hardCheck = Basis(rawValue: "hardCheck")

            /// The judge denied the snippet.
            public static let judged = Basis(rawValue: "judged")

            /// A saved verdict of the judge denied the snippet.
            public static let saved = Basis(rawValue: "saved")

            /// The check could not judge the snippet, so it denied it.
            public static let checkFailed = Basis(rawValue: "checkFailed")

            /// A layer of the rule book is not complete, so the check denied
            /// the snippet.
            public static let incomplete = Basis(rawValue: "incomplete")

            /// The snippet is too long to judge, so the check denied it.
            public static let tooLong = Basis(rawValue: "tooLong")
        }

        /// Reads the denial from `_meta["sah/ruleDenial"]` of a tool call
        /// update.
        ///
        /// - Parameter meta: The `_meta` value, or `nil`.
        /// - Returns: The denial, or `nil` when it is absent or is not valid.
        public static func extract(from meta: JSONValue?) -> RuleDenial? {
            SAH.payload(RuleDenial.self, in: meta, member: metaKey)
        }

        /// Writes this denial into `_meta["sah/ruleDenial"]` of a `_meta`
        /// value.
        ///
        /// The function keeps every other member of `_meta`. When `meta` is a
        /// value that is not an object, the function returns `meta` unchanged.
        ///
        /// - Parameter meta: The `_meta` value to write into, or `nil`.
        /// - Returns: The `_meta` value to send.
        /// - Throws: `EncodingError` when the denial cannot be encoded.
        public func inject(into meta: JSONValue?) throws -> JSONValue {
            try SAH.inject(self, into: meta, member: Self.metaKey)
        }
    }
}
