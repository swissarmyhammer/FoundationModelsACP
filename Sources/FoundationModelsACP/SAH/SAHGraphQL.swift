extension SAH {
    /// The wire types of the SAH GraphQL tunnel.
    ///
    /// The tunnel carries GraphQL over ACP to named endpoints of the server. The
    /// client sends a GraphQL document as text, with its variables as JSON, and
    /// gets the result as JSON. The server runs the GraphQL engine. These types do
    /// not parse GraphQL.
    ///
    /// | Method | Direction | Params | Result |
    /// |---|---|---|---|
    /// | `_sah/graphql/execute` | client to server, request | ``ExecuteRequest`` | ``ExecutionResult`` |
    /// | `_sah/graphql/subscribe` | client to server, request | ``SubscribeRequest`` | ``SubscribeResponse`` |
    /// | `_sah/graphql/unsubscribe` | client to server, notification | ``UnsubscribeNotification`` | — |
    /// | `_sah/graphql/endpoints` | client to server, request | ``EndpointsRequest`` | ``EndpointsResponse`` |
    /// | `_sah/graphql/next` | server to client, notification | ``NextNotification`` | — |
    /// | `_sah/graphql/error` | server to client, notification | ``ErrorNotification`` | — |
    /// | `_sah/graphql/complete` | server to client, notification | ``CompleteNotification`` | — |
    ///
    /// A subscription follows the `graphql-transport-ws` protocol. `subscribe`
    /// starts it with an id that the client makes. Then the server sends zero or
    /// more `next` messages, and one `error` or one `complete` message ends it. The
    /// client sends `unsubscribe` to stop it before the end. A subscription id is
    /// unique for each connection.
    public enum GraphQL {
        /// The method names of the tunnel.
        public enum Method {
            /// `_sah/graphql/execute`: a request that runs a query or a
            /// mutation.
            public static let execute = "_sah/graphql/execute"

            /// `_sah/graphql/subscribe`: a request that starts a subscription.
            public static let subscribe = "_sah/graphql/subscribe"

            /// `_sah/graphql/unsubscribe`: a notification from the client that
            /// stops a subscription.
            public static let unsubscribe = "_sah/graphql/unsubscribe"

            /// `_sah/graphql/endpoints`: a request that lists the endpoints.
            public static let endpoints = "_sah/graphql/endpoints"

            /// `_sah/graphql/next`: a notification from the server with the
            /// next result of a subscription.
            public static let next = "_sah/graphql/next"

            /// `_sah/graphql/error`: a notification from the server that ends a
            /// subscription with errors.
            public static let error = "_sah/graphql/error"

            /// `_sah/graphql/complete`: a notification from the server that
            /// ends a subscription with no error.
            public static let complete = "_sah/graphql/complete"
        }
    }
}

// MARK: - Endpoints

extension SAH.GraphQL {
    /// The scope of an endpoint: what selects the data of a call.
    ///
    /// The value is open. A peer can send a scope that this library does not
    /// know, and the value decodes with its raw text.
    public struct Scope: WireRawValueCodable, Hashable, Sendable {
        /// The scope name as it crosses the wire.
        public let rawValue: String

        /// Makes a scope from its wire name.
        ///
        /// - Parameter rawValue: The scope name.
        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        /// The endpoint has one instance for the server. The `sessionId` of a
        /// call does not select its data.
        public static let server = Scope(rawValue: "server")

        /// The endpoint has one instance for each session folder. The
        /// `sessionId` of a call selects the folder.
        public static let sessionFolder = Scope(rawValue: "sessionFolder")
    }

    /// One named GraphQL endpoint of the server.
    public struct Endpoint: Codable, Hashable, Sendable {
        /// The name of the endpoint, for example `kanban`. A call names the
        /// endpoint with it.
        public var name: String

        /// The version of the schema of the endpoint, for example `1`. The
        /// value is opaque text.
        public var version: String

        /// The scope of the endpoint.
        public var scope: Scope

        /// The SDL text of the schema.
        public var schema: String

        /// Makes an endpoint entry.
        ///
        /// - Parameters:
        ///   - name: The name of the endpoint.
        ///   - version: The version of its schema.
        ///   - scope: The scope of the endpoint.
        ///   - schema: The SDL text of the schema.
        public init(name: String, version: String, scope: Scope, schema: String) {
            self.name = name
            self.version = version
            self.scope = scope
            self.schema = schema
        }
    }

    /// The params of `_sah/graphql/endpoints`.
    public struct EndpointsRequest: Codable, Hashable, Sendable {
        /// The ACP `_meta` value, or `nil`.
        public var meta: JSONValue?

        /// Makes the params.
        ///
        /// - Parameter meta: The ACP `_meta` value, or `nil`.
        public init(meta: JSONValue? = nil) {
            self.meta = meta
        }

        private enum CodingKeys: String, CodingKey {
            case meta = "_meta"
        }
    }

    /// The result of `_sah/graphql/endpoints`.
    public struct EndpointsResponse: Codable, Hashable, Sendable {
        /// The endpoints of the server, each with its schema.
        public var endpoints: [Endpoint]

        /// The ACP `_meta` value, or `nil`.
        public var meta: JSONValue?

        /// Makes the result.
        ///
        /// - Parameters:
        ///   - endpoints: The endpoints of the server.
        ///   - meta: The ACP `_meta` value, or `nil`.
        public init(endpoints: [Endpoint], meta: JSONValue? = nil) {
            self.endpoints = endpoints
            self.meta = meta
        }

        private enum CodingKeys: String, CodingKey {
            case endpoints
            case meta = "_meta"
        }
    }
}

// MARK: - Operations

extension SAH.GraphQL {
    /// The id of one subscription. The client makes it, and it is unique for
    /// each connection.
    public struct SubscriptionId: WireRawValueCodable, Hashable, Sendable {
        /// The opaque id text as it crosses the wire.
        public let rawValue: String

        /// Makes a subscription id from its wire text.
        ///
        /// - Parameter rawValue: The opaque id text.
        public init(rawValue: String) {
            self.rawValue = rawValue
        }
    }

    /// The params of `_sah/graphql/execute`: one query or mutation.
    public struct ExecuteRequest: Codable, Hashable, Sendable {
        /// The name of the endpoint that runs the operation.
        public var endpoint: String

        /// The session of the call, or `nil`.
        ///
        /// For an endpoint with the scope ``Scope/sessionFolder``, the session
        /// selects the folder, and the server refuses a call with no session.
        /// An endpoint with the scope ``Scope/server`` accepts a call with no
        /// session.
        public var sessionId: SessionId?

        /// The GraphQL document, as text.
        public var query: String

        /// The values of the variables of the document, as a JSON object, or
        /// `nil`.
        public var variables: JSONValue?

        /// The name of the operation to run, when the document has more than
        /// one, or `nil`.
        public var operationName: String?

        /// The GraphQL `extensions` of the request, as JSON, or `nil`.
        public var extensions: JSONValue?

        /// The ACP `_meta` value, or `nil`.
        public var meta: JSONValue?

        /// Makes the params.
        ///
        /// - Parameters:
        ///   - endpoint: The name of the endpoint.
        ///   - sessionId: The session of the call, or `nil`.
        ///   - query: The GraphQL document.
        ///   - variables: The values of the variables, or `nil`.
        ///   - operationName: The name of the operation, or `nil`.
        ///   - extensions: The GraphQL `extensions`, or `nil`.
        ///   - meta: The ACP `_meta` value, or `nil`.
        public init(
            endpoint: String,
            sessionId: SessionId? = nil,
            query: String,
            variables: JSONValue? = nil,
            operationName: String? = nil,
            extensions: JSONValue? = nil,
            meta: JSONValue? = nil
        ) {
            self.endpoint = endpoint
            self.sessionId = sessionId
            self.query = query
            self.variables = variables
            self.operationName = operationName
            self.extensions = extensions
            self.meta = meta
        }

        private enum CodingKeys: String, CodingKey {
            case endpoint
            case sessionId
            case query
            case variables
            case operationName
            case extensions
            case meta = "_meta"
        }
    }

    /// The result of one GraphQL operation: the result of
    /// `_sah/graphql/execute`, and the payload of `_sah/graphql/next`.
    ///
    /// This is the GraphQL `ExecutionResult` shape. The data, the errors and
    /// the extensions stay JSON.
    public struct ExecutionResult: Codable, Hashable, Sendable {
        /// The `data` of the result, or `nil` when the result has none.
        public var data: JSONValue?

        /// The GraphQL errors, each as a JSON object, or `nil` when there are
        /// none.
        public var errors: [JSONValue]?

        /// The GraphQL `extensions` of the result, or `nil`.
        public var extensions: JSONValue?

        /// Makes a result.
        ///
        /// - Parameters:
        ///   - data: The `data` of the result, or `nil`.
        ///   - errors: The GraphQL errors, or `nil`.
        ///   - extensions: The GraphQL `extensions`, or `nil`.
        public init(data: JSONValue? = nil, errors: [JSONValue]? = nil, extensions: JSONValue? = nil) {
            self.data = data
            self.errors = errors
            self.extensions = extensions
        }
    }

    /// The params of `_sah/graphql/subscribe`: the input of an execute, and a
    /// subscription id.
    public struct SubscribeRequest: Codable, Hashable, Sendable {
        /// The id of the new subscription.
        public var subscriptionId: SubscriptionId

        /// The name of the endpoint that runs the subscription.
        public var endpoint: String

        /// The session of the call, or `nil`.
        ///
        /// For an endpoint with the scope ``Scope/sessionFolder``, the session
        /// selects the folder, and the server refuses a call with no session.
        /// An endpoint with the scope ``Scope/server`` accepts a call with no
        /// session.
        public var sessionId: SessionId?

        /// The GraphQL document, as text.
        public var query: String

        /// The values of the variables of the document, as a JSON object, or
        /// `nil`.
        public var variables: JSONValue?

        /// The name of the operation to run, when the document has more than
        /// one, or `nil`.
        public var operationName: String?

        /// The GraphQL `extensions` of the request, as JSON, or `nil`.
        public var extensions: JSONValue?

        /// The ACP `_meta` value, or `nil`.
        public var meta: JSONValue?

        /// Makes the params.
        ///
        /// - Parameters:
        ///   - subscriptionId: The id of the new subscription.
        ///   - endpoint: The name of the endpoint.
        ///   - sessionId: The session of the call, or `nil`.
        ///   - query: The GraphQL document.
        ///   - variables: The values of the variables, or `nil`.
        ///   - operationName: The name of the operation, or `nil`.
        ///   - extensions: The GraphQL `extensions`, or `nil`.
        ///   - meta: The ACP `_meta` value, or `nil`.
        public init(
            subscriptionId: SubscriptionId,
            endpoint: String,
            sessionId: SessionId? = nil,
            query: String,
            variables: JSONValue? = nil,
            operationName: String? = nil,
            extensions: JSONValue? = nil,
            meta: JSONValue? = nil
        ) {
            self.subscriptionId = subscriptionId
            self.endpoint = endpoint
            self.sessionId = sessionId
            self.query = query
            self.variables = variables
            self.operationName = operationName
            self.extensions = extensions
            self.meta = meta
        }

        private enum CodingKeys: String, CodingKey {
            case subscriptionId
            case endpoint
            case sessionId
            case query
            case variables
            case operationName
            case extensions
            case meta = "_meta"
        }
    }

    /// The result of `_sah/graphql/subscribe`.
    ///
    /// The result tells that the server started the subscription. The results
    /// of the subscription come in `_sah/graphql/next`.
    public struct SubscribeResponse: Codable, Hashable, Sendable {
        /// The ACP `_meta` value, or `nil`.
        public var meta: JSONValue?

        /// Makes the result.
        ///
        /// - Parameter meta: The ACP `_meta` value, or `nil`.
        public init(meta: JSONValue? = nil) {
            self.meta = meta
        }

        private enum CodingKeys: String, CodingKey {
            case meta = "_meta"
        }
    }

    /// The params of `_sah/graphql/unsubscribe`: the client stops a
    /// subscription.
    public struct UnsubscribeNotification: Codable, Hashable, Sendable {
        /// The id of the subscription to stop.
        public var subscriptionId: SubscriptionId

        /// The ACP `_meta` value, or `nil`.
        public var meta: JSONValue?

        /// Makes the params.
        ///
        /// - Parameters:
        ///   - subscriptionId: The id of the subscription to stop.
        ///   - meta: The ACP `_meta` value, or `nil`.
        public init(subscriptionId: SubscriptionId, meta: JSONValue? = nil) {
            self.subscriptionId = subscriptionId
            self.meta = meta
        }

        private enum CodingKeys: String, CodingKey {
            case subscriptionId
            case meta = "_meta"
        }
    }

    /// The params of `_sah/graphql/next`: the next result of a subscription.
    public struct NextNotification: Codable, Hashable, Sendable {
        /// The id of the subscription.
        public var subscriptionId: SubscriptionId

        /// The next result.
        public var payload: ExecutionResult

        /// The ACP `_meta` value, or `nil`.
        public var meta: JSONValue?

        /// Makes the params.
        ///
        /// - Parameters:
        ///   - subscriptionId: The id of the subscription.
        ///   - payload: The next result.
        ///   - meta: The ACP `_meta` value, or `nil`.
        public init(subscriptionId: SubscriptionId, payload: ExecutionResult, meta: JSONValue? = nil) {
            self.subscriptionId = subscriptionId
            self.payload = payload
            self.meta = meta
        }

        private enum CodingKeys: String, CodingKey {
            case subscriptionId
            case payload
            case meta = "_meta"
        }
    }

    /// The params of `_sah/graphql/error`: the subscription ends with errors.
    ///
    /// The server sends no other message for the subscription after this one.
    public struct ErrorNotification: Codable, Hashable, Sendable {
        /// The id of the subscription.
        public var subscriptionId: SubscriptionId

        /// The GraphQL errors, each as a JSON object.
        public var payload: [JSONValue]

        /// The ACP `_meta` value, or `nil`.
        public var meta: JSONValue?

        /// Makes the params.
        ///
        /// - Parameters:
        ///   - subscriptionId: The id of the subscription.
        ///   - payload: The GraphQL errors.
        ///   - meta: The ACP `_meta` value, or `nil`.
        public init(subscriptionId: SubscriptionId, payload: [JSONValue], meta: JSONValue? = nil) {
            self.subscriptionId = subscriptionId
            self.payload = payload
            self.meta = meta
        }

        private enum CodingKeys: String, CodingKey {
            case subscriptionId
            case payload
            case meta = "_meta"
        }
    }

    /// The params of `_sah/graphql/complete`: the subscription ends with no
    /// error.
    ///
    /// The server sends no other message for the subscription after this one.
    public struct CompleteNotification: Codable, Hashable, Sendable {
        /// The id of the subscription.
        public var subscriptionId: SubscriptionId

        /// The ACP `_meta` value, or `nil`.
        public var meta: JSONValue?

        /// Makes the params.
        ///
        /// - Parameters:
        ///   - subscriptionId: The id of the subscription.
        ///   - meta: The ACP `_meta` value, or `nil`.
        public init(subscriptionId: SubscriptionId, meta: JSONValue? = nil) {
            self.subscriptionId = subscriptionId
            self.meta = meta
        }

        private enum CodingKeys: String, CodingKey {
            case subscriptionId
            case meta = "_meta"
        }
    }
}
