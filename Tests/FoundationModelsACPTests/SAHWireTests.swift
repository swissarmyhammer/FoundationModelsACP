import Foundation
import Testing

@testable import FoundationModelsACP

/// The wire of the SAH extension types (ACP-5): each type against a fixed JSON
/// document, and the read and write of the `_meta` payloads.
@Suite("SAH extension wire types")
struct SAHWireTests {
    // MARK: - Method names

    @Test("the tunnel method names are the _sah/graphql/* names")
    func methodNames() {
        #expect(SAH.GraphQL.Method.execute == "_sah/graphql/execute")
        #expect(SAH.GraphQL.Method.subscribe == "_sah/graphql/subscribe")
        #expect(SAH.GraphQL.Method.unsubscribe == "_sah/graphql/unsubscribe")
        #expect(SAH.GraphQL.Method.endpoints == "_sah/graphql/endpoints")
        #expect(SAH.GraphQL.Method.next == "_sah/graphql/next")
        #expect(SAH.GraphQL.Method.error == "_sah/graphql/error")
        #expect(SAH.GraphQL.Method.complete == "_sah/graphql/complete")
    }

    // MARK: - Tunnel messages

    @Test("execute params carry the document as text and the variables as JSON")
    func executeRequest() throws {
        let request = try WireRoundTrip.expectLossless(
            SAH.GraphQL.ExecuteRequest.self,
            """
            {"endpoint": "kanban", "sessionId": "s-1",
             "query": "query Board($id: ID!) { board(id: $id) { name } }",
             "variables": {"id": "b-1", "deep": {"list": [1, true, null]}},
             "operationName": "Board", "extensions": {"trace": "x"},
             "_meta": {"traceparent": "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01"}}
            """
        )
        #expect(request.endpoint == "kanban")
        #expect(request.sessionId == SessionId(rawValue: "s-1"))
        #expect(request.operationName == "Board")
        #expect(request.variables?["id"] == .string("b-1"))
    }

    @Test("execute params with only the required members encode no null")
    func executeRequestMinimal() throws {
        let request = SAH.GraphQL.ExecuteRequest(endpoint: "sessions", query: "{ sessions { id } }")
        #expect(try WireRoundTrip.encode(request) == WireRoundTrip.parse(#"{"endpoint": "sessions", "query": "{ sessions { id } }"}"#))
        try WireRoundTrip.expectLossless(SAH.GraphQL.ExecuteRequest.self, #"{"endpoint": "sessions", "query": "{ x }"}"#)
    }

    @Test("an execution result keeps data, errors and extensions as JSON")
    func executionResult() throws {
        let result = try WireRoundTrip.expectLossless(
            SAH.GraphQL.ExecutionResult.self,
            """
            {"data": {"board": {"name": "Main"}},
             "errors": [{"message": "no column", "path": ["board", "columns"], "extensions": {"code": "NOT_FOUND"}}],
             "extensions": {"rewrites": [{"from": "cards", "to": "tasks"}]}}
            """
        )
        #expect(result.errors?.count == 1)
        try WireRoundTrip.expectLossless(SAH.GraphQL.ExecutionResult.self, #"{"data": {}}"#)
        #expect(try WireRoundTrip.encode(SAH.GraphQL.ExecutionResult()) == WireRoundTrip.parse("{}"))
    }

    @Test("subscribe params are the execute input plus a subscription id")
    func subscribeRequest() throws {
        let request = try WireRoundTrip.expectLossless(
            SAH.GraphQL.SubscribeRequest.self,
            """
            {"subscriptionId": "sub-7", "endpoint": "kanban", "sessionId": "s-1",
             "query": "subscription { changes { cursor } }", "variables": {"after": 12},
             "operationName": "Changes", "extensions": {}, "_meta": {}}
            """
        )
        #expect(request.subscriptionId == SAH.GraphQL.SubscriptionId(rawValue: "sub-7"))
        try WireRoundTrip.expectLossless(SAH.GraphQL.SubscribeResponse.self, "{}")
        try WireRoundTrip.expectLossless(SAH.GraphQL.SubscribeResponse.self, #"{"_meta": {"a": 1}}"#)
    }

    @Test("the subscription notifications follow the graphql-transport-ws shape")
    func subscriptionNotifications() throws {
        let next = try WireRoundTrip.expectLossless(
            SAH.GraphQL.NextNotification.self,
            #"{"subscriptionId": "sub-7", "payload": {"data": {"changes": {"cursor": 13}}}}"#
        )
        #expect(next.payload.data?["changes"]?["cursor"] == .number(13))

        let error = try WireRoundTrip.expectLossless(
            SAH.GraphQL.ErrorNotification.self,
            #"{"subscriptionId": "sub-7", "payload": [{"message": "board closed"}], "_meta": {"x": true}}"#
        )
        #expect(error.payload == [.object(["message": .string("board closed")])])

        try WireRoundTrip.expectLossless(SAH.GraphQL.CompleteNotification.self, #"{"subscriptionId": "sub-7"}"#)
        try WireRoundTrip.expectLossless(SAH.GraphQL.UnsubscribeNotification.self, #"{"subscriptionId": "sub-7"}"#)
    }

    @Test("a notification with no subscription id does not decode")
    func missingSubscriptionId() {
        #expect(throws: DecodingError.self) {
            try WireRoundTrip.decode(SAH.GraphQL.CompleteNotification.self, from: "{}")
        }
        #expect(throws: DecodingError.self) {
            try WireRoundTrip.decode(SAH.GraphQL.NextNotification.self, from: #"{"payload": {}}"#)
        }
    }

    @Test("the endpoint list carries names, versions, scopes and schemas")
    func endpoints() throws {
        try WireRoundTrip.expectLossless(SAH.GraphQL.EndpointsRequest.self, "{}")
        let response = try WireRoundTrip.expectLossless(
            SAH.GraphQL.EndpointsResponse.self,
            """
            {"endpoints": [
              {"name": "kanban", "version": "3", "scope": "sessionFolder", "schema": "type Query { board: Board }"},
              {"name": "sessions", "version": "1", "scope": "server", "schema": "type Query { sessions: [Session] }"},
              {"name": "future", "version": "1.2", "scope": "galaxy", "schema": ""}
            ]}
            """
        )
        #expect(response.endpoints.map(\.scope) == [.sessionFolder, .server, SAH.GraphQL.Scope(rawValue: "galaxy")])
        #expect(response.endpoints.map(\.version) == ["3", "1", "1.2"])
        #expect(throws: DecodingError.self) {
            try WireRoundTrip.decode(SAH.GraphQL.Endpoint.self, from: #"{"name": "kanban", "version": "1", "scope": "server"}"#)
        }
    }

    // MARK: - initialize

    @Test("initialize gives the endpoint list in _meta.sah.graphql")
    func initializeMeta() throws {
        let meta = try WireRoundTrip.parse(
            """
            {"traceparent": "t", "sah": {"version": 1, "graphql": [{"name": "kanban", "version": "1", "scope": "sessionFolder", "schema": "type Query { a: Int }"}]}}
            """
        )
        let sah = try #require(SAH.InitializeMeta.extract(from: meta))
        #expect(sah.version == SAH.version)
        #expect(sah.graphql == [SAH.GraphQL.Endpoint(name: "kanban", version: "1", scope: .sessionFolder, schema: "type Query { a: Int }")])
        #expect(try sah.inject(into: .object(["traceparent": .string("t")])) == meta)
        #expect(try sah.inject(into: nil) == WireRoundTrip.parse(#"{"sah": {"version": 1, "graphql": [{"name": "kanban", "version": "1", "scope": "sessionFolder", "schema": "type Query { a: Int }"}]}}"#))
    }

    @Test("an agent with no valid _meta.sah has no SAH extensions")
    func initializeMetaAbsent() throws {
        #expect(SAH.InitializeMeta.extract(from: nil) == nil)
        #expect(SAH.InitializeMeta.extract(from: .string("x")) == nil)
        #expect(SAH.InitializeMeta.extract(from: try WireRoundTrip.parse("{}")) == nil)
        #expect(SAH.InitializeMeta.extract(from: try WireRoundTrip.parse(#"{"sah": {"version": 1}}"#)) == nil)
    }

    // MARK: - Messages between sessions

    @Test("a message from another session names its sender in _meta.sah.message")
    func sessionMessage() throws {
        let json = """
            {"messageId": "m-2", "inReplyTo": "m-1",
             "sender": {"kind": "session", "sessionId": "s-9", "title": "Fix the build", "agent": "coder", "cwd": "/Users/u/code/api"}}
            """
        let message = try WireRoundTrip.expectLossless(SAH.SessionMessage.self, json)
        #expect(message.sender.kind == .session)
        #expect(message.sender.sessionId == SessionId(rawValue: "s-9"))

        let fromUser = try WireRoundTrip.expectLossless(SAH.SessionMessage.self, #"{"sender": {"kind": "user"}}"#)
        #expect(fromUser.sender.kind == .user)
        #expect(fromUser.sender.sessionId == nil)
    }

    @Test("the session message goes under _meta.sah and keeps the other members")
    func sessionMessagePlacement() throws {
        let message = SAH.SessionMessage(sender: .init(kind: .session, sessionId: SessionId(rawValue: "s-9")))
        let meta = try message.inject(into: WireRoundTrip.parse(#"{"other": 1, "sah": {"keep": true}}"#))
        #expect(
            meta == (try WireRoundTrip.parse(
                #"{"other": 1, "sah": {"keep": true, "message": {"sender": {"kind": "session", "sessionId": "s-9"}}}}"#
            ))
        )
        #expect(SAH.SessionMessage.extract(from: meta) == message)
        #expect(try message.inject(into: .null) == WireRoundTrip.parse(#"{"sah": {"message": {"sender": {"kind": "session", "sessionId": "s-9"}}}}"#))
    }

    @Test("the session message does not replace a _meta or a _meta.sah that is not an object")
    func sessionMessageKeepsForeignValues() throws {
        let message = SAH.SessionMessage(sender: .init(kind: .user))
        #expect(try message.inject(into: .array([])) == .array([]))
        let foreign = try WireRoundTrip.parse(#"{"sah": "not ours"}"#)
        #expect(try message.inject(into: foreign) == foreign)
        #expect(SAH.SessionMessage.extract(from: foreign) == nil)
    }

    // MARK: - Rule denial

    @Test("a rule denial carries the rules, the basis and the message")
    func ruleDenial() throws {
        let denial = try WireRoundTrip.expectLossless(
            SAH.RuleDenial.self,
            """
            {"rules": [
              {"id": "user:no-push-to-main", "layer": {"kind": "user"},
               "sentence": "Never push to the main branch.", "reason": "The code pushes the branch main.",
               "file": "file:///Users/u/.sah/rules/no-push.md", "contentHash": "abc123"},
              {"id": "agent:coder:no-net", "layer": {"kind": "agent", "agentId": "coder"},
               "sentence": "No network.", "reason": "The code calls curl."}
             ],
             "basis": "judged",
             "message": "Denied by rule user:no-push-to-main. The snippet did not run."}
            """
        )
        #expect(denial.basis == .judged)
        #expect(denial.rules.map(\.layer) == [.init(kind: .user), .init(kind: .agent, agentId: "coder")])

        let incomplete = try WireRoundTrip.expectLossless(
            SAH.RuleDenial.self,
            #"{"rules": [], "basis": "incomplete", "layer": {"kind": "project"}, "message": "m"}"#
        )
        #expect(incomplete.layer?.kind == .project)
        let failed = try WireRoundTrip.expectLossless(
            SAH.RuleDenial.self,
            #"{"rules": [], "basis": "checkFailed", "errorType": "TimeoutError", "message": "m"}"#
        )
        #expect(failed.errorType == "TimeoutError")
        let future = try WireRoundTrip.expectLossless(SAH.RuleDenial.self, #"{"rules": [], "basis": "laterBasis", "message": "m"}"#)
        #expect(future.basis == SAH.RuleDenial.Basis(rawValue: "laterBasis"))
    }

    @Test("the rule denial goes under the flat _meta key sah/ruleDenial")
    func ruleDenialPlacement() throws {
        let denial = SAH.RuleDenial(
            rules: [.init(id: "builtin:system-delete", layer: .init(kind: .builtIn), sentence: "s", reason: "rm -rf /")],
            basis: .hardCheck,
            message: "m"
        )
        let meta = try denial.inject(into: WireRoundTrip.parse(#"{"traceparent": "t"}"#))
        #expect(meta["sah/ruleDenial"]?["basis"] == .string("hardCheck"))
        #expect(meta["traceparent"] == .string("t"))
        #expect(meta["sah"] == nil)
        #expect(SAH.RuleDenial.extract(from: meta) == denial)
        #expect(SAH.RuleDenial.extract(from: try WireRoundTrip.parse(#"{"sah/ruleDenial": {"basis": "judged"}}"#)) == nil)
        #expect(try denial.inject(into: .number(1)) == .number(1))
    }
}
