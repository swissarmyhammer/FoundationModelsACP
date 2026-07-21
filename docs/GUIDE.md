# FoundationModelsACP — usage guide

A complete Swift 6 implementation of both [Agent Client Protocol](https://agentclientprotocol.com) roles: schema types generated from the pinned `schema-v1.19.0` release, role protocols, full-duplex connections, ndJSON framing, and transports. This guide covers the full surface; the [README](../README.md) covers the flagship examples.

## The two roles

Both roles ride one shared full-duplex JSON-RPC connection. You implement a protocol and hand a factory to a connection; the connection dispatches inbound calls to your conformer and exposes the outbound calls of the opposite direction. The factory receives the connection so your conformer can capture it and make reverse-direction calls.

### Agent

Conform to `Agent` and serve it with `AgentSideConnection`. A minimal agent implements only `initialize`, `newSession`, `prompt`, and `cancel`:

```swift
struct MyAgent: Agent {
    func initialize(_ params: InitializeRequest) async throws -> InitializeResponse {
        InitializeResponse(protocolVersion: .latest)
    }
    func newSession(_ params: NewSessionRequest) async throws -> NewSessionResponse {
        NewSessionResponse(sessionId: SessionId(rawValue: UUID().uuidString))
    }
    func prompt(_ params: PromptRequest) async throws -> PromptResponse {
        PromptResponse(stopReason: .endTurn)
    }
    func cancel(_ params: CancelNotification) async {}
}

let connection = await AgentSideConnection(stream: .stdio, logger: .standardError) { _ in MyAgent() }
```

The connection also exposes the outbound Agent→Client surface — `sessionUpdate`, `requestPermission`, the `fs/*` and `terminal/*` methods — so an agent can stream updates and reach into the client's world mid-turn.

### Client

Conform to `Client` and drive an agent with `ClientSideConnection`. Its outbound methods (`initialize`, `newSession`, `prompt`, …) let a host run the agent, and `updates(for:)` demultiplexes the agent's `session/update` notifications into a per-session stream:

```swift
let client = await ClientSideConnection(stream: transport) { _ in MyClient() }

_ = try await client.initialize(InitializeRequest(protocolVersion: .latest))
let session = try await client.newSession(NewSessionRequest(cwd: cwd, mcpServers: []))

// Subscribe before driving the turn — updates for a session with no active
// subscriber are dropped.
let updates = client.updates(for: session.sessionId)
let outcome = try await client.prompt(
    PromptRequest(prompt: [.text(TextContent(text: "Hello"))], sessionId: session.sessionId)
)
```

A session's update stream lives from subscription until the connection closes, deliberately independent of any single prompt turn: a `tool_call_update` arriving after the prompt response — or after a `session/cancel` — is still delivered.

## Capability gating

Only the required methods are unconditional; everything else is negotiated during `initialize` and defaulted to method-not-found:

- **Agent side.** Every optional `Agent` method (`loadSession`, `listSessions`, `resumeSession`, `deleteSession`, `closeSession`, `authenticate`, `setSessionConfigOption`, `logout`) has a default implementation answering `RequestError.methodNotFound`. Override exactly the methods whose capabilities your `InitializeResponse` advertises — an un-advertised method stays a wire-correct method-not-found without any code.
- **Client side.** The `fs/*` and `terminal/*` methods are gated by the `ClientCapabilities` the client advertises in `InitializeRequest`. Capability-gated fields are optionals whose absence means "unsupported": they are omitted on encode (never JSON `null`), and a malformed capability degrades to unsupported on decode instead of failing `initialize`.

Unknown wire values never crash decoding either — string enums such as `StopReason` and `ToolCallStatus` route unrecognized values to an `unknown(String)` case, so a newer peer degrades gracefully.

## The connection model

Both role connections share one full-duplex JSON-RPC engine (`Connection`):

- **Full duplex.** Requests and notifications flow in both directions concurrently over one transport; either side may call the other at any time.
- **Per-request dispatch.** Each inbound request runs in its own `Task`, so a slow `session/prompt` never head-of-line-blocks an incoming `session/cancel`, `session/request_permission`, or `fs/*` callback. Notifications are awaited inline, in arrival order — the `session/update` stream depends on that ordering.
- **Timeouts.** Both connection initializers take a `requestTimeout`; the default `nil` waits forever, which long-lived calls like `session/prompt` rely on. A timed-out request throws `ConnectionError.timedOut`.
- **Fail-loud disconnect.** On EOF or a transport error, every pending request is rejected with `ConnectionError.closed` and per-session update streams finish — callers are never left hung.

## ndJSON framing

The wire is newline-delimited JSON: one JSON-RPC 2.0 envelope per line. Two rules keep it healthy:

- **stdout is sacred.** An agent speaking ACP over stdio must write nothing to stdout but valid ACP frames. Route diagnostics through the injected `ACPLogger` — `.standardError` writes lines to stderr, `.disabled` discards — never `print`.
- **Garbage does not kill the connection.** A line that fails to parse is logged and skipped; framing resynchronizes on the next newline.

## Transports

Any `ACPTransport` conformer carries the wire; four ship with the package:

- `StdioTransport` (spelled `.stdio`) binds the connection to this process's stdin/stdout — the standard way an editor hosts an agent.
- `SubprocessTransport` spawns an external agent process and wires its standard streams: the child's stdout becomes the inbound bytes, writes feed its stdin, and its stderr forwards to this process's stderr. The child is reaped exactly once, on close, teardown, or deinit.
- `InMemoryTransport.pair()` wires a client and an agent back-to-back over a single in-memory pipe — the full bidirectional surface, no I/O — ideal for deterministic tests.
- `ReplayTransport(script:)` replays a recorded client→agent ndJSON script and captures every write, so a captured session becomes a replayable golden fixture.

```swift
let (clientEnd, agentEnd) = InMemoryTransport.pair()
let agentConnection = await AgentSideConnection(stream: agentEnd) { conn in MyAgent() }
let client = await ClientSideConnection(stream: clientEnd) { _ in MyClient() }
```

## Regenerating the types

The types under `Sources/FoundationModelsACP/Generated/` are generated from the vendored JSON schema and checked in — consumers just compile source. See [CONTRIBUTING](../CONTRIBUTING.md) for the `swift package generate-acp` workflow and [Schema/README.md](../Schema/README.md) for bumping the pinned ACP release.
