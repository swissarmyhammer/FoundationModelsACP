---
depends_on:
- 01KXHBBTQ24BC8586M5K0N872Z
position_column: todo
position_ordinal: '8e80'
title: 'FoundationModelsAgent core: SessionProvider, one-liner init, turn serialization'
---
## What
Build the bridge's skeleton (spec §7, §7.1) in `Sources/FoundationModelsACP/Bridge/`:

- `SessionProvider` struct exactly per §7.1: required `makeSession: @Sendable (AbsolutePath, [MCPServerConfig]) async throws -> (SessionId, LanguageModelSession)`; optional hooks `listSessions`, `restoreSession`, `deleteSession`, `onTurnEnded: (@Sendable (SessionId, Transcript) async -> Void)?`.
- `FoundationModelsAgent` (an actor) conforming to `Agent`, constructed with a connection + provider. There is deliberately **no engine protocol** — the bridge always drives a real `LanguageModelSession`; only where sessions come from varies.
- The flagship one-liner stays: `FoundationModelsAgent(connection:session:)` is sugar for a provider whose `makeSession` returns that session and whose hooks are nil.
- Implement `initialize` (advertise capabilities: prompt caps; session-management caps gated on hook presence) and `newSession` (cwd + MCP configs → provider → track `SessionId` → session map).
- Overlapping `session/prompt` requests **serialize naturally on the actor** — a `LanguageModelSession` runs one turn at a time; each pending request resolves at its own turn's end. No queue abstraction.
- Actual turn execution, tool bridging, and session-management forwarding are follow-on tasks — stub `prompt` minimally (e.g. drive a trivial turn) so tests pass.

## Acceptance Criteria
- [ ] One-liner construction compiles and behaves identically on the wire to an explicit single-session provider
- [ ] `initialize` advertises session-management capabilities iff the corresponding hooks are non-nil
- [ ] `newSession` invokes `makeSession` with the cwd and MCP configs from the request and returns its `SessionId`
- [ ] Two concurrent `prompt` requests to one session execute strictly serially (observable via instrumented fake ordering)

## Tests
- [ ] `Tests/FoundationModelsACPTests/Bridge/SessionProviderTests.swift` — capability gating by hook presence; one-liner equivalence; newSession plumbing
- [ ] `Tests/FoundationModelsACPTests/Bridge/PromptSerializationTests.swift` — overlapping prompts serialize; each resolves at its own turn end
- [ ] Run `swift test` — exits 0

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.