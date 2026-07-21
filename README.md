# FoundationModelsACP

[![CI](https://github.com/swissarmyhammer/FoundationModelsACP/actions/workflows/ci.yml/badge.svg)](https://github.com/swissarmyhammer/FoundationModelsACP/actions/workflows/ci.yml)
![Swift 6.4](https://img.shields.io/badge/Swift-6.4-orange)
![macOS 27](https://img.shields.io/badge/macOS-27-blue)
[![License](https://img.shields.io/github/license/swissarmyhammer/FoundationModelsACP)](LICENSE)

The [Agent Client Protocol](https://agentclientprotocol.com) wire layer for Swift: schema types generated from the pinned `schema-v1.19.0` release, `Agent`/`Client` role protocols, full-duplex JSON-RPC connections, ndJSON framing, and transports — with zero library dependencies.

ACP is a JSON-RPC protocol where a *client* (an editor or host) drives an *agent* (a coding model) over a bidirectional stream: the client sends `session/prompt`, the agent streams back `session/update` notifications and may call back mid-turn to read files, run terminals, or ask permission. This package is a complete Swift 6 implementation of both roles; you implement a protocol, and the connection speaks the wire.

A minimal agent implements just `initialize`, `newSession`, `prompt`, and `cancel` — every other method has a method-not-found default:

```swift
import FoundationModelsACP

/// Streams each prompt block back as an agent message chunk, then ends the turn.
struct EchoAgent: Agent {
    let connection: AgentSideConnection

    func initialize(_ params: InitializeRequest) async throws -> InitializeResponse {
        InitializeResponse(protocolVersion: .latest)
    }

    func newSession(_ params: NewSessionRequest) async throws -> NewSessionResponse {
        NewSessionResponse(sessionId: SessionId(rawValue: UUID().uuidString))
    }

    func prompt(_ params: PromptRequest) async throws -> PromptResponse {
        for block in params.prompt {
            try await connection.sessionUpdate(
                SessionNotification(
                    sessionId: params.sessionId,
                    update: .agentMessageChunk(ContentChunk(content: block))
                )
            )
        }
        return PromptResponse(stopReason: .endTurn)
    }

    func cancel(_ params: CancelNotification) async {}
}

// AgentSideConnection starts serving as soon as it is created; the factory
// hands the agent its connection so it can stream updates and make reverse
// calls back to the client. `.stdio` speaks ACP over this process's
// stdin/stdout.
let connection = await AgentSideConnection(stream: .stdio, logger: .standardError) { conn in
    EchoAgent(connection: conn)
}

// The read loop serves inbound calls in the background; keep the process alive
// until the client closes stdin.
while !Task.isCancelled {
    try? await Task.sleep(for: .seconds(3600))
}
```

> **stdout is sacred.** An agent speaking ACP over stdio must write *nothing* to stdout but valid ACP frames — route every log to stderr or the injected `ACPLogger`. A stray `print`, banner, or progress bar corrupts the JSON-RPC framing and silently drops messages. It is the single most common field failure for stdio agents.

The other role is just as direct — a host drives any ACP agent through `ClientSideConnection`:

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

## Install

```swift
dependencies: [
    .package(url: "https://github.com/swissarmyhammer/FoundationModelsACP", branch: "main")
]
```

Requires macOS 27 and Swift 6.4.

## Documentation

- [Usage guide](docs/GUIDE.md) — both roles, capability gating, the connection model, ndJSON rules, and the transports.
- [Contributing](CONTRIBUTING.md) — regenerating the ACP types from the vendored schema.

## License

Apache-2.0. See [LICENSE](LICENSE).
