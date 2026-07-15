import Foundation
import Testing

import FoundationModelsACP

// MARK: - initialize (spec §2: protocolVersion is the bare integer 1)

@Test func initializeRequestRoundTripsAndCarriesBareIntegerProtocolVersion() throws {
    let fixture = """
    {
      "protocolVersion": 1,
      "clientCapabilities": {
        "fs": { "readTextFile": true, "writeTextFile": true },
        "terminal": true
      },
      "clientInfo": { "name": "example-client", "version": "1.0.0" }
    }
    """
    try expectStableRoundTrip(InitializeRequest.self, fixture: fixture)

    let model = try decoded(InitializeRequest.self, fixture: fixture)
    #expect(model.protocolVersion == .v1)
    #expect(field("protocolVersion", of: try encodedValue(model)) == .number(1))
}

@Test func initializeResponseRoundTripsAndCarriesBareIntegerProtocolVersion() throws {
    let fixture = """
    {
      "protocolVersion": 1,
      "agentCapabilities": {
        "loadSession": true,
        "promptCapabilities": { "image": true, "embeddedContext": true }
      },
      "agentInfo": { "name": "example-agent", "version": "2.3.1" },
      "authMethods": []
    }
    """
    try expectStableRoundTrip(InitializeResponse.self, fixture: fixture)

    let model = try decoded(InitializeResponse.self, fixture: fixture)
    #expect(model.protocolVersion == .v1)
    #expect(field("protocolVersion", of: try encodedValue(model)) == .number(1))
}

@Test func unknownCapabilityFieldsDegradeToDefaults() throws {
    // A newer peer advertises a capability this version does not model; the
    // unknown field must be dropped and the known surface fall back to defaults.
    let fixture = """
    {
      "protocolVersion": 1,
      "clientCapabilities": {
        "terminal": true,
        "futureCapabilityFromANewerPeer": { "enabled": true }
      }
    }
    """
    let model = try decoded(InitializeRequest.self, fixture: fixture)
    #expect(model.clientCapabilities == ClientCapabilities(terminal: true))

    let encoded = try encodedValue(model)
    let capabilities = try #require(field("clientCapabilities", of: encoded))
    #expect(field("futureCapabilityFromANewerPeer", of: capabilities) == nil)
}

@Test func absentOptionalsAreOmittedNotEncodedAsNull() throws {
    // No clientInfo, no _meta, default capabilities: encode must omit the
    // optionals entirely rather than emit JSON null.
    let request = InitializeRequest(protocolVersion: .v1)
    let encoded = try encodedValue(request)

    #expect(field("clientInfo", of: encoded) == nil)
    #expect(field("_meta", of: encoded) == nil)
    #expect(!containsNull(encoded))
}

@Test func initializeResponseOmitsAbsentOptionalsNotEncodedAsNull() throws {
    // The response side has its own optionals (agentInfo, _meta); a decode →
    // encode → decode check would mask a spurious null, so assert directly on
    // the encoded wire shape.
    let response = InitializeResponse(protocolVersion: .v1)
    let encoded = try encodedValue(response)

    #expect(field("agentInfo", of: encoded) == nil)
    #expect(field("_meta", of: encoded) == nil)
    #expect(!containsNull(encoded))
}

// MARK: - session/new

@Test func newSessionRequestRoundTrips() throws {
    let fixture = """
    { "cwd": "/home/user/project", "mcpServers": [] }
    """
    try expectExactRoundTrip(NewSessionRequest.self, fixture: fixture)
}

@Test func newSessionRequestOmitsAbsentAdditionalDirectories() throws {
    let cwd = try #require(AbsolutePath(rawValue: "/home/user/project"))
    let request = NewSessionRequest(cwd: cwd, mcpServers: [])
    let encoded = try encodedValue(request)
    #expect(field("additionalDirectories", of: encoded) == nil)
    #expect(!containsNull(encoded))
}

@Test func newSessionResponseRoundTrips() throws {
    let fixture = """
    { "sessionId": "sess_abc123" }
    """
    try expectExactRoundTrip(NewSessionResponse.self, fixture: fixture)
}

// MARK: - session/prompt

@Test func promptRequestRoundTrips() throws {
    let fixture = """
    {
      "sessionId": "sess_abc123",
      "prompt": [
        { "type": "text", "text": "Summarize the README." },
        { "type": "resource_link", "uri": "file:///home/user/project/README.md", "name": "README.md" }
      ]
    }
    """
    try expectExactRoundTrip(PromptRequest.self, fixture: fixture)
}

@Test(arguments: [
    "end_turn", "max_tokens", "max_turn_requests", "refusal", "cancelled",
])
func promptResponseRoundTripsForEveryStopReason(stopReason: String) throws {
    let fixture = """
    { "stopReason": "\(stopReason)" }
    """
    try expectExactRoundTrip(PromptResponse.self, fixture: fixture)
    let model = try decoded(PromptResponse.self, fixture: fixture)
    #expect(model.stopReason.wireValue == stopReason)
}

// MARK: - session/update (every SessionUpdate variant)

/// Every published `session/update` variant, keyed by its `sessionUpdate`
/// discriminator, as it appears in a notification's `update` payload.
private let sessionUpdateFixtures: [String] = [
    """
    { "sessionUpdate": "user_message_chunk", "content": { "type": "text", "text": "hello" } }
    """,
    """
    { "sessionUpdate": "agent_message_chunk", "content": { "type": "text", "text": "hi there" } }
    """,
    """
    { "sessionUpdate": "agent_thought_chunk", "content": { "type": "text", "text": "considering options" } }
    """,
    """
    { "sessionUpdate": "tool_call", "toolCallId": "call_1", "title": "Reading file", "kind": "read", "status": "pending" }
    """,
    """
    { "sessionUpdate": "tool_call_update", "toolCallId": "call_1", "status": "in_progress" }
    """,
    """
    { "sessionUpdate": "plan", "entries": [ { "content": "Write tests", "priority": "high", "status": "pending" } ] }
    """,
    """
    { "sessionUpdate": "available_commands_update", "availableCommands": [] }
    """,
    """
    { "sessionUpdate": "current_mode_update", "currentModeId": "mode_edit" }
    """,
    """
    { "sessionUpdate": "config_option_update", "configOptions": [] }
    """,
    """
    { "sessionUpdate": "session_info_update", "title": "Refactor pass", "updatedAt": "2026-07-15T00:00:00Z" }
    """,
    """
    { "sessionUpdate": "usage_update", "size": 200000, "used": 1234 }
    """,
]

@Test(arguments: sessionUpdateFixtures)
func sessionUpdateVariantRoundTrips(fixture: String) throws {
    try expectExactRoundTrip(SessionUpdate.self, fixture: fixture)
}

@Test func sessionUpdateFixturesCoverEveryKnownVariant() throws {
    // SessionUpdate carries associated values, so it cannot be CaseIterable;
    // this test enforces two things it can check: the fixture set matches the
    // discriminators expected here (so dropping a fixture is caught), and every
    // fixture decodes to a recognized variant rather than the .unknown fallback.
    let expected: Set<String> = [
        "user_message_chunk", "agent_message_chunk", "agent_thought_chunk",
        "tool_call", "tool_call_update", "plan", "available_commands_update",
        "current_mode_update", "config_option_update", "session_info_update",
        "usage_update",
    ]
    let covered = try Set(sessionUpdateFixtures.map { fixture in
        try #require(field("sessionUpdate", of: jsonValue(fixture: fixture)))
    }.map { value -> String in
        guard case .string(let discriminator) = value else { return "" }
        return discriminator
    })
    #expect(covered == expected)

    for fixture in sessionUpdateFixtures {
        let update = try decoded(SessionUpdate.self, fixture: fixture)
        if case .unknown = update {
            Issue.record("fixture decoded to .unknown: \(fixture)")
        }
    }
}

@Test func sessionNotificationWrapsUpdateOnTheWire() throws {
    let fixture = """
    {
      "sessionId": "sess_abc123",
      "update": { "sessionUpdate": "agent_message_chunk", "content": { "type": "text", "text": "hi" } }
    }
    """
    try expectExactRoundTrip(SessionNotification.self, fixture: fixture)
}

// MARK: - tool_call lifecycle (create → in_progress → completed)

/// A tool call's published progression: initial creation, an in-progress
/// update carrying content, then completion with output.
private let toolCallLifecycleFixtures: [String] = [
    """
    { "sessionUpdate": "tool_call", "toolCallId": "call_42", "title": "Run tests", "kind": "execute", "status": "pending" }
    """,
    """
    {
      "sessionUpdate": "tool_call_update",
      "toolCallId": "call_42",
      "status": "in_progress",
      "content": [ { "type": "content", "content": { "type": "text", "text": "running..." } } ]
    }
    """,
    """
    {
      "sessionUpdate": "tool_call_update",
      "toolCallId": "call_42",
      "status": "completed",
      "content": [ { "type": "diff", "path": "/home/user/project/out.txt", "newText": "ok" } ],
      "rawOutput": { "exitCode": 0 }
    }
    """,
]

@Test(arguments: toolCallLifecycleFixtures)
func toolCallLifecycleRoundTrips(fixture: String) throws {
    try expectExactRoundTrip(SessionUpdate.self, fixture: fixture)
}

// MARK: - RequestError (spec §3: typed codes, structured data — never in the message)

/// The JSON-RPC and ACP error codes carried by `RequestError`, each with a
/// representative structured `data` payload.
private let requestErrorFixtures: [(code: Int, fixture: String)] = [
    (-32700, #"{ "code": -32700, "message": "Parse error" }"#),
    (-32600, #"{ "code": -32600, "message": "Invalid request" }"#),
    (-32601, #"{ "code": -32601, "message": "Method not found", "data": { "method": "session/bogus" } }"#),
    (-32602, #"{ "code": -32602, "message": "Invalid params", "data": { "field": "cwd" } }"#),
    (-32603, #"{ "code": -32603, "message": "Internal error", "data": { "detail": "boom" } }"#),
    (-32000, #"{ "code": -32000, "message": "Authentication required" }"#),
    (-32002, #"{ "code": -32002, "message": "Resource not found", "data": { "uri": "file:///missing.txt" } }"#),
]

@Test(arguments: requestErrorFixtures)
func requestErrorRoundTripsWithStructuredData(code: Int, fixture: String) throws {
    try expectExactRoundTrip(RequestError.self, fixture: fixture)
    let model = try decoded(RequestError.self, fixture: fixture)
    #expect(model.code == code)
}

@Test func requestErrorStructuredDataIsNotSmuggledThroughMessage() throws {
    // The structured details live in `data` as JSON, not concatenated into the
    // human-readable message string.
    let error = RequestError.resourceNotFound(uri: "file:///missing.txt")
    #expect(error.message == "Resource not found")

    let encoded = try encodedValue(error)
    #expect(field("data", of: encoded) == .object(["uri": .string("file:///missing.txt")]))
    #expect(field("message", of: encoded) == .string("Resource not found"))
}

@Test func requestErrorOmitsAbsentDataNotEncodedAsNull() throws {
    let encoded = try encodedValue(RequestError.parseError)
    #expect(field("data", of: encoded) == nil)
    #expect(!containsNull(encoded))
}
