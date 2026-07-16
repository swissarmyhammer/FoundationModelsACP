# FoundationModelsACP

[![CI](https://github.com/swissarmyhammer/FoundationModelsACP/actions/workflows/ci.yml/badge.svg)](https://github.com/swissarmyhammer/FoundationModelsACP/actions/workflows/ci.yml)
![Swift 6.4](https://img.shields.io/badge/Swift-6.4-orange)
![macOS 27](https://img.shields.io/badge/macOS-27-blue)
[![License](https://img.shields.io/github/license/swissarmyhammer/FoundationModelsACP)](LICENSE)

Expose an Apple-native `LanguageModelSession` as an [Agent Client Protocol](https://agentclientprotocol.com) agent — drivable by any ACP client (Zed, an editor, your own runtime) with no glue.

ACP is a JSON-RPC protocol where a *client* (an editor or host) drives an *agent* (a coding model) over a bidirectional stream: the client sends `session/prompt`, the agent streams back `session/update` notifications and may call back mid-turn to read files, run terminals, or ask permission. This package is a complete Swift 6 implementation of both roles, plus a FoundationModels bridge that turns a `LanguageModelSession` into an ACP agent for free.

```swift
import FoundationModels
import FoundationModelsACP

// AgentSideConnection starts serving as soon as it is created; the factory hands
// the agent its connection so it can stream updates and make reverse calls back
// to the client. `.stdio` speaks ACP over this process's stdin/stdout.
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

That one wrapper maps a FoundationModels turn onto ACP: `session/prompt` drives `streamResponse(to:)`, the growing `Transcript` becomes a stream of `session/update` notifications, and the turn answers with a `StopReason`.

> **stdout is sacred.** An agent speaking ACP over stdio must write *nothing* to stdout but valid ACP frames — route every log to stderr or the injected `ACPLogger`. A stray `print`, banner, or progress bar corrupts the JSON-RPC framing and silently drops messages. It is the single most common field failure for stdio agents.

## Install

```swift
dependencies: [
    .package(url: "https://github.com/swissarmyhammer/FoundationModelsACP", branch: "main")
]
```

Requires macOS 27 and Swift 6.4.

## Documentation

- [Usage guide](docs/GUIDE.md) — both roles, the bridge and `SessionProvider`, reaching the client's world from a tool, `TranscriptBuilder`, and the test transports.
- [Contributing](CONTRIBUTING.md) — regenerating the ACP types and running the eval suite.

## License

Apache-2.0. See [LICENSE](LICENSE).
