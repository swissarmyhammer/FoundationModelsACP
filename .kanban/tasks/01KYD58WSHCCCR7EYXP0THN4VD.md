---
comments:
- actor: claude-code
  id: 01kyk03gftk0axm341ah8fbjey
  text: |-
    Implementation landed. Checked the generated InitializeRequest/InitializeResponse/AgentCapabilities/ClientCapabilities/SessionCapabilities/MCPCapabilities types in Sources/FoundationModelsACP/Generated/Models.generated.swift before starting — M1 already generated all of these correctly: required info+capabilities, empty-object markers (structs holding only `meta: JSONValue?`, so {} decodes non-nil and both null/omitted decode nil via forgivingDecodeIfPresent), and full nested capabilities.session.* including mcp.stdio, mcp.http, additionalDirectories, and prompt sub-capabilities. M2/M3 already wired initialize as an ordinary request through ClientSideConnection/AgentSideConnection/RoleConnectionCore.

    The actual gap for M4 was protocol-version negotiation: nothing validated that a peer's initialize response actually answered with protocolVersion 2. Added (via TDD — wrote the mismatch tests first, watched them fail to compile with "cannot find type ProtocolVersionMismatchError", then implemented):

    - Sources/FoundationModelsACP/Core/ProtocolVersion.swift: new `ProtocolVersionMismatchError` (Error, Hashable, Sendable, CustomStringConvertible) carrying `sent`/`received` ProtocolVersion, with a description naming both versions explicitly.
    - Sources/FoundationModelsACP/Connection/ClientSideConnection.swift: `initialize(_:)` now compares `response.protocolVersion` against `params.protocolVersion` (what was actually sent, not a hardcoded constant) and throws the new error on any mismatch — not just "lower version", any deviation, since this package is v2-only by decision.

    Deliberately did NOT add matching logic to AgentSideConnection: the spec text itself puts the disconnect decision on the client ("The client should disconnect, if it doesn't support this version"), and existing Agent conformers (TestAgent/BaselineAgent/FullAgent) already just answer .v2 unconditionally regardless of what was requested, which is correct v2-only behavor. Client-side-only validation is the right layering.

    New test file Tests/FoundationModelsACPTests/InitializeNegotiationTests.swift, 13 tests covering every checkbox: full initialize round trip over InMemoryTransport with a rich nested capability tree (auth, both MCP transports, additionalDirectories, all three prompt extensions); protocolVersion 2 asserted on the raw wire; a v1-answering peer and a v3-answering peer both produce ProtocolVersionMismatchError naming both versions; {} vs null vs omitted tested as three distinct, separately-named tests at both single-nesting (capabilities.session) and double-nesting (capabilities.session.mcp.stdio) depth; a boolean-vs-empty-object encoding check; and a capability round-trip preserving unknown nested _meta keys at three nesting depths simultaneously.

    Verified: swift build --build-tests clean, 0 warnings. swift test: 227 tests / 22 suites / 0 failures (up from the 214/21 baseline — added 13 tests and 1 suite). mcp__sah__diagnostics check working: 0 errors/0 warnings. Adversarial double-check dispatched to verify before handoff.
  timestamp: 2026-07-27T23:56:00.890733+00:00
depends_on:
- 01KYD58WR23B5R69691FKDWJSG
position_column: done
position_ordinal: '8480'
title: M4 Initialization and capability negotiation
---
## Starting point

**This is a rewrite** — see `plan.md` -> *Starting point*. v1 `initialize` handling, `ProtocolVersionTests`, and `Core/ProtocolVersion.swift` were deleted; M1 restores `ProtocolVersion`. The v1 negotiation code is in git history, but the initialize payload shape changed substantially in v2 (see below), so treat it as reference only, not a port.

## What

`plan.md` -> **M4**.

v2 restructures initialize and both roles now use **identical field names**:

- Required **`info`** object (v1 had optional, role-specific `clientInfo` / `agentInfo`).
- Required **`capabilities`** object (v1 had role-specific `clientCapabilities` / `agentCapabilities`).
- **Support markers are empty objects `{}`**, not booleans. Omitted or `null` means unsupported.
- Prompt and MCP capabilities **nest under `capabilities.session`** -- including `session.mcp.stdio`, `session.mcp.http`, and `session.additionalDirectories`.
- `loadSession` is gone, as are individual `list` / `resume` / `close` markers (baseline when `session` is advertised).
- `clientCapabilities.fs` and `.terminal` are **entirely removed**.

Send `"protocolVersion": 2`. A peer that answers with a lower version is one we **cannot serve** -- we are v2-only by decision -- so that must fail with a clear, actionable error naming the version mismatch, not a vague handshake failure. This is the single most likely real-world friction point of the v2-only decision, so make the diagnostic good.

## Acceptance Criteria

- [x] `initialize` round-trips required `info` and `capabilities`.
- [x] Empty-object markers distinguish supported / unsupported / absent correctly.
- [x] Nested `capabilities.session.*` modeled, including both MCP transports and `additionalDirectories`.
- [x] `protocolVersion: 2` sent and asserted.
- [x] A non-2 peer produces a clear version-mismatch error naming both versions.

## Tests

- [x] Full initialize exchange over `InMemoryTransport`.
- [x] `{}` vs `null` vs omitted each map to the right support state.
- [x] A peer replying `protocolVersion: 1` yields the version-mismatch error, and the message names v1 and v2 explicitly.
- [x] Capability round-trip preserves unknown nested keys.

## Implementation notes (M4, done)

M1 had already generated `InitializeRequest`/`InitializeResponse` and the full `AgentCapabilities`/`ClientCapabilities`/`SessionCapabilities`/`MCPCapabilities`/`PromptCapabilities` tree correctly (required `info`/`capabilities`, `{meta: JSONValue?}`-only empty-object markers, nested `capabilities.session.*`), and M2/M3 already wired `initialize` as an ordinary request through `ClientSideConnection`/`AgentSideConnection`. The actual gap was protocol-version negotiation itself: nothing validated that a peer answered `initialize` with the version actually sent.

Added:
- `Sources/FoundationModelsACP/Core/ProtocolVersion.swift`: `ProtocolVersionMismatchError` (`Error`, `Hashable`, `Sendable`, `CustomStringConvertible`), carrying `sent`/`received` `ProtocolVersion` and a description naming both explicitly.
- `Sources/FoundationModelsACP/Connection/ClientSideConnection.swift`: `initialize(_:)` now compares `response.protocolVersion` against `params.protocolVersion` (what was actually sent) and throws on any mismatch — not just a lower version, any deviation, per the v2-only decision.
- `Tests/FoundationModelsACPTests/InitializeNegotiationTests.swift`: 13 new tests.

Deliberately no matching check added to `AgentSideConnection`/`Agent`: the spec puts the disconnect decision on the client ("The client should disconnect, if it doesn't support this version"), and existing `Agent` conformers already just answer `.v2` unconditionally. Client-side-only validation is the correct layering.

Verified: `swift build --build-tests` clean, 0 warnings. `swift test`: 227 tests / 22 suites / 0 failures (baseline was 214/21).