# FoundationModelsACP

[![CI](https://github.com/swissarmyhammer/FoundationModelsACP/actions/workflows/ci.yml/badge.svg)](https://github.com/swissarmyhammer/FoundationModelsACP/actions/workflows/ci.yml)
![Swift 6.4](https://img.shields.io/badge/Swift-6.4-orange)
![macOS 27](https://img.shields.io/badge/macOS-27-blue)
[![License](https://img.shields.io/github/license/swissarmyhammer/FoundationModelsACP)](LICENSE)

The [Agent Client Protocol](https://agentclientprotocol.com) **v2** wire layer
for Swift: generated schema types, `Agent`/`Client` role protocols, full-duplex
JSON-RPC connections, ndJSON framing, and transports — with zero library
dependencies.

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

## Two things to know before you depend on this

**ACP v2 is a draft.** Its shape can still move. This package tracks drafts by
re-vendoring the schema and regenerating, so a version bump can change
generated types.

**v1 is not served.** This package implements v2 only — no v1 surface, no
version branching, no dual namespaces. A client that speaks only v1 cannot
talk to an agent built on this package. See *Decision: v2 only* in
[`plan.md`](plan.md) for the full reasoning.

## Install

```swift
dependencies: [
    .package(url: "https://github.com/swissarmyhammer/FoundationModelsACP", branch: "main")
]
```

## Documentation

- [Plan](plan.md) — the v2 design, decisions, and milestones.
- [Contributing](CONTRIBUTING.md) — regenerating the ACP types from the vendored schema.

## License

Apache-2.0. See [LICENSE](LICENSE).
