# FoundationModelsACP — usage guide

A complete Swift 6 implementation of both [Agent Client Protocol](https://agentclientprotocol.com) roles, plus a FoundationModels bridge. This guide covers the full surface; the [README](../README.md) covers the flagship one-liner.

## The two roles

Both roles ride one shared full-duplex JSON-RPC connection. You implement a protocol and hand a factory to a connection; the connection dispatches inbound calls to your conformer and exposes the outbound calls of the opposite direction. The factory receives the connection so your conformer can capture it and make reverse-direction calls.

### Agent

Conform to `Agent` and serve it with `AgentSideConnection`. Every capability-gated method has a method-not-found default, so a minimal agent implements only `initialize`, `newSession`, `prompt`, and `cancel`:

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

### Client

Conform to `Client` and drive an agent with `ClientSideConnection`. Its outbound methods (`initialize`, `newSession`, `prompt`, …) let a host run the agent, and `updates(for:)` demultiplexes the agent's `session/update` notifications into a per-session stream:

```swift
let client = await ClientSideConnection(stream: transport) { _ in MyClient() }

_ = try await client.initialize(InitializeRequest(protocolVersion: .latest, clientCapabilities: .readOnly))
let session = try await client.newSession(NewSessionRequest(cwd: cwd, mcpServers: []))

// Subscribe before driving the turn — updates for a session with no active
// subscriber are dropped.
let updates = client.updates(for: session.sessionId)
let outcome = try await client.prompt(
    PromptRequest(prompt: [.text(TextContent(text: "Hello"))], sessionId: session.sessionId)
)
```

## The FoundationModels bridge

`FoundationModelsAgent` is the flagship. The one-liner `init(connection:session:)` is sugar; where sessions come from is otherwise supplied by a `SessionProvider`. There is deliberately no engine protocol — the bridge always drives a real `LanguageModelSession`, and only the *origin* of sessions varies.

A provider supplies the required `makeSession` factory and, optionally, store hooks. **The presence of each hook gates the matching agent capability** — advertise `session/list`, `session/resume`, and `session/delete` only when you actually back them:

```swift
let provider = SessionProvider(
    makeSession: { cwd, mcpServers in
        let id = SessionId(rawValue: UUID().uuidString)
        return (id, LanguageModelSession(model: SystemLanguageModel.default, tools: myTools))
    },
    restoreSession: { id in LanguageModelSession(model: SystemLanguageModel.default) },
    onTurnEnded: { sessionId, transcript in /* persist the final transcript */ }
)
let agent = FoundationModelsAgent(connection: conn, provider: provider)
```

### Reaching the client's world from a tool

A FoundationModels `Tool` runs in-process, but its work often needs the *client's* filesystem, terminals, or consent. `ClientEnvironment.current` is bound for the duration of a prompt turn; a tool reads it to turn an operation into the matching reverse ACP request (`fs/*`, `terminal/*`, `session/request_permission`). Each operation checks the negotiated `ClientCapabilities` first and throws locally when the capability was not advertised, so an un-advertised call never reaches the wire:

```swift
let contents = try await ClientEnvironment.current?.readTextFile(path: path)
let result = try await ClientEnvironment.current?.runCommand(toolCallId: id, command: "ls", arguments: ["-la"])
```

## ACP → Transcript

`TranscriptBuilder` is the client-side inverse of the bridge's projection: it folds a `session/update` stream back into a FoundationModels `Transcript`, so an ACP client becomes just another producer of the same transcript your UI already renders.

```swift
// Fold a whole session's updates into one transcript (drains the stream).
let transcript = await TranscriptBuilder.transcript(folding: client.updates(for: sessionId))

// Or fold incrementally.
var builder = TranscriptBuilder()
for await update in client.updates(for: sessionId) {
    builder.fold(update)
    render(builder.transcript)
}
```

## Test transports

Two in-process transports make the wire deterministic in tests without pipes or subprocesses:

- `InMemoryTransport.pair()` wires a client and an agent back-to-back over a single in-memory pipe — the full bidirectional surface, no I/O.
- `ReplayTransport(script:)` replays a recorded client→agent ndJSON script and captures every write, so a captured session becomes a replayable golden fixture.

```swift
let (clientEnd, agentEnd) = InMemoryTransport.pair()
let agentConnection = await AgentSideConnection(stream: agentEnd) { conn in MyAgent() }
let client = await ClientSideConnection(stream: clientEnd) { _ in MyClient() }
```
