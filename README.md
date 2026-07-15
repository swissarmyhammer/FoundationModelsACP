# FoundationModelsACP

Expose an Apple-native `LanguageModelSession` as an [Agent Client Protocol](https://agentclientprotocol.com) agent — drivable by any ACP client (Zed, an editor, your own runtime) with no glue.

The [Agent Client Protocol](https://agentclientprotocol.com) (ACP) is a JSON-RPC protocol that lets a *client* (an editor or host) drive an *agent* (a coding model) over a bidirectional stream: the client sends `session/prompt`, the agent streams back `session/update` notifications and may call back into the client mid-turn to read files, run terminals, or ask permission. This package is a complete Swift 6 implementation of both roles, plus a FoundationModels bridge that turns a `LanguageModelSession` into an ACP agent for free.

```swift
import FoundationModels
import FoundationModelsACP

// AgentSideConnection starts serving as soon as it is created; the factory
// hands the agent its connection so it can stream updates and make reverse
// calls back to the client. `.stdio` speaks ACP over this process's stdin/stdout.
let connection = await AgentSideConnection(stream: .stdio, logger: .standardError) { conn in
    FoundationModelsAgent(
        connection: conn,
        session: LanguageModelSession(model: SystemLanguageModel.default, tools: myTools)
    )
}

// The read loop serves inbound calls in the background; keep the process alive
// until the client closes stdin.
while !Task.isCancelled {
    try? await Task.sleep(for: .seconds(3600))
}
```

That one wrapper maps a FoundationModels turn onto ACP: `session/prompt` drives `streamResponse(to:)`, the growing `Transcript` becomes a stream of `session/update` notifications, and the turn answers with a `StopReason` (`.endTurn`, `.maxTokens`, `.refusal`, `.cancelled`).

## Installation

Add the package to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/swissarmyhammer/FoundationModelsACP", branch: "main")
]
```

Requires macOS 27 (FoundationModels is always present) and Swift 6.4.

## stdout is sacred

**An agent speaking ACP over stdio must write nothing to stdout but valid, newline-delimited ACP frames.** The wire owns stdout. A stray `print`, a startup banner, a `dotenv`-style dump, or a progress bar on stdout corrupts the JSON-RPC framing and silently drops messages — the single most common field failure for stdio agents.

- Route **every** diagnostic to stderr or to the injected `ACPLogger` (`ACPLogger.standardError` writes each line to stderr; `.disabled` discards).
- The package prints nothing on its own; `StdioTransport` writes only the whole frames handed to it.
- Audit your dependencies too: a library that logs to stdout will break the wire just as badly as your own `print`.

If your agent misbehaves the moment it connects, this is the first thing to check.

## The two roles

Both roles ride one shared full-duplex JSON-RPC connection. You implement a protocol and hand a factory to a connection; the connection dispatches inbound calls to your conformer and exposes the outbound calls of the opposite direction.

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

`FoundationModelsAgent` is the flagship. The one-liner `init(connection:session:)` above is sugar; where sessions come from is otherwise supplied by a `SessionProvider`. There is deliberately no engine protocol — the bridge always drives a real `LanguageModelSession`, and only the *origin* of sessions varies.

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

## Contributing: regenerating the ACP types

The protocol types under `Sources/FoundationModelsACP/Generated/` are generated from the vendored JSON schema in `Schema/` and checked in, so consumers just compile source — no plugin or tool needed to build the package.

- **Regenerate:** `swift package generate-acp`. A build does zero codegen work unless the schema's content hash changed, so this is a no-op after a normal checkout.
- **Bump the ACP version:** drop in the new `schema.json` / `meta.json` / `meta.unstable.json` artifact set and run `swift package generate-acp` — nothing else changes by hand. The full procedure (pinned release, SHA-256 verification, the routing manifest) lives in [`Schema/README.md`](Schema/README.md).
- **CI diff gate:** CI regenerates from the vendored schema and runs `git diff --exit-code`, failing on any drift — the committed output always matches the schema. A separate step builds the DocC documentation with warnings-as-errors, so the public API always documents cleanly.

## License

See [LICENSE](LICENSE).
