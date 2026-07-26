# FoundationModelsACP

[![CI](https://github.com/swissarmyhammer/FoundationModelsACP/actions/workflows/ci.yml/badge.svg)](https://github.com/swissarmyhammer/FoundationModelsACP/actions/workflows/ci.yml)
![Swift 6.4](https://img.shields.io/badge/Swift-6.4-orange)
![macOS 27](https://img.shields.io/badge/macOS-27-blue)
[![License](https://img.shields.io/github/license/swissarmyhammer/FoundationModelsACP)](LICENSE)

The [Agent Client Protocol](https://agentclientprotocol.com) **v2** wire layer
for Swift: schema types generated from the vendored v2 schema, `Agent`/`Client`
role protocols, full-duplex JSON-RPC connections, ndJSON framing, and
transports — with zero library dependencies.

> **Status: under construction.** This package is being rewritten for ACP v2.
> The wire layer — types, role protocols, connections, transports — is not
> implemented yet; only the schema code-generation pipeline is in place. See
> [`plan.md`](plan.md) for the milestones and what each one delivers.

## Two things to know before depending on this

**ACP v2 is a draft.** Its shape can still move. We track drafts by re-vendoring
the schema and regenerating, so a version bump can change generated types.

**v1 is not served.** This package implements v2 only — no v1 surface, no
version branching, no dual namespaces. Clients that speak only v1 cannot talk to
an agent built on this package. The reasoning, and its cost, is recorded under
*Decision: v2 only* in [`plan.md`](plan.md).

## What v2 looks like

ACP is a JSON-RPC protocol where a *client* (an editor or host) drives an
*agent* (a coding model) over a bidirectional stream. In v2:

- `session/prompt` **acknowledges immediately** and returns `{}`. Progress and
  completion arrive as `state_update` notifications (`running`, `idle` carrying
  a `stopReason`, `requires_action`).
- The **agent owns history and message identity** — every chunk and update
  carries an agent-generated `messageId`.
- **Upserts, not appends**: `tool_call_update` both creates and patches, keyed
  by `toolCallId`.
- **No client filesystem and no client terminals.** Agents reach the client's
  world through MCP instead.
- **Replay is first-class**: `session/resume` handles both plain reconnect and
  full history replay.

## Install

```swift
dependencies: [
    .package(url: "https://github.com/swissarmyhammer/FoundationModelsACP", branch: "main")
]
```

Requires macOS 27 and Swift 6.4.

## Documentation

- [Plan](plan.md) — the v2 design, decisions, and milestones.
- [Contributing](CONTRIBUTING.md) — regenerating the ACP types from the vendored schema.

A usage guide lands with the role protocols and connections (milestones M2–M3);
there is no stable API to document until then.

## License

Apache-2.0. See [LICENSE](LICENSE).
