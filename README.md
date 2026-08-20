# FoundationModelsACP

[![CI](https://github.com/swissarmyhammer/FoundationModelsACP/actions/workflows/ci.yml/badge.svg)](https://github.com/swissarmyhammer/FoundationModelsACP/actions/workflows/ci.yml)
[![License](https://img.shields.io/github/license/swissarmyhammer/FoundationModelsACP)](LICENSE)

The [Agent Client Protocol](https://agentclientprotocol.com) **v2** wire layer
for Swift. It supplies generated schema types, `Agent` and `Client` role
protocols, full-duplex JSON-RPC connections, ndJSON framing, and transports.
It has zero library dependencies and it requires macOS 27.

```swift
import FoundationModelsACP

struct MyAgent: Agent {
    func initialize(_ params: InitializeRequest) async throws -> InitializeResponse {
        InitializeResponse(
            info: Implementation(name: "my-agent", version: "1.0.0"),
            protocolVersion: .latest,
            capabilities: AgentCapabilities(session: SessionCapabilities())
        )
    }

    func newSession(_ params: NewSessionRequest) async throws -> NewSessionResponse {
        NewSessionResponse(sessionId: SessionId(rawValue: "session-1"))
    }

    func listSessions(_ params: ListSessionsRequest) async throws -> ListSessionsResponse {
        ListSessionsResponse(sessions: [])
    }

    func resumeSession(_ params: ResumeSessionRequest) async throws -> ResumeSessionResponse {
        ResumeSessionResponse()
    }

    func closeSession(_ params: CloseSessionRequest) async throws -> CloseSessionResponse {
        CloseSessionResponse()
    }

    func prompt(_ params: PromptRequest) async throws -> PromptResponse {
        PromptResponse()
    }

    func sessionCancel(_ params: CancelSessionNotification) async {}
}

let connection = await AgentSideConnection(stream: .stdio) { _ in MyAgent() }
```

## Install

```swift
dependencies: [
    .package(url: "https://github.com/swissarmyhammer/FoundationModelsACP", branch: "main")
]
```

## Cautions

**ACP v2 is a draft.** The protocol shape can change. This package tracks each
draft: it vendors the new schema and regenerates the types. Thus an update can
change the generated types.

**This package does not serve v1.** It implements only v2. A client that
speaks only v1 cannot talk to an agent that you build with this package. See
*Decision: v2 only* in [`plan.md`](plan.md) for the full analysis.

## Documentation

- [Plan](plan.md) — the v2 design, the decisions, and the milestones.
- [Contributing](CONTRIBUTING.md) — how to regenerate the ACP types from the vendored schema.

## License

Apache-2.0. See [LICENSE](LICENSE).
