---
comments:
- actor: wballard
  id: 01kxkete98vxvamxt0pkxfc3ym
  text: |-
    Picked up. Research + FoundationModels API verification complete (first task to import Apple's framework).

    FOUNDATIONMODELS AVAILABILITY — VERIFIED REAL, NOT STUBBED.
    - Toolchain: Apple Swift 6.4 (swiftlang-6.4.0.25.4), target arm64-apple-macosx27.0.0, SDK MacOSX.sdk (Xcode-beta). `import FoundationModels` builds; a probe SwiftPM package (.macOS(.v27)) compiled and RAN.
    - `SystemLanguageModel.default.availability` returns `.available` on this machine (enum: `.available` / `.unavailable(reason)`).
    - Verified-real API (probed by compile+run, NOT invented):
      - `LanguageModelSession(model: SystemLanguageModel.default)` and `LanguageModelSession(model:transcript:)` (the restore ctor).
      - `session.isResponding: Bool`; `session.transcript: Transcript` (Transcript is a Collection — `.count` works).
      - Turn exec: `try await session.respond(to: String) -> Response` with `Response.content: String`; `session.streamResponse(to: String)` returns an async sequence (used by the ^gs0d3kp turn task).
      - `LanguageModelSession`, `Transcript`, `SystemLanguageModel` are all `Sendable` — so the §7.1 provider closure signatures and actor storage compile with no wrappers.
    - CRITICAL: two concurrent `respond(to:)` on the SAME session TRAP the process (SIGTRAP, exit 133) — an unrecoverable precondition, NOT a catchable error. This is exactly why §7.1 mandates one-turn-at-a-time serialization, and it means the serialization test must NOT drive concurrent real turns (a serialization bug would crash the test runner, not fail an assertion).

    TYPE MAPPING (card's illustrative signatures → real generated types; check Generated/ confirmed):
    - `MCPServerConfig` → `public typealias MCPServerConfig = McpServer`. `McpServer` is the generated type `NewSessionRequest.mcpServers: [McpServer]` actually carries (currently `= JSONValue` in Unresolved.generated). Typealiasing keeps makeSession's `[MCPServerConfig]` lossless with what `session/new` delivers.
    - `SessionSummary` → `public typealias SessionSummary = SessionInfo` (the generated element type of `ListSessionsResponse.sessions`), so the later ^vfmstvy session/list forwarding maps directly with no re-shaping.
    - `SessionId(rawValue: String)`, `AbsolutePath(rawValue:)?` (rejects non-absolute), `ProtocolVersion.latest`.

    CAPABILITY GATING (initialize) — hook presence → `AgentCapabilities.sessionCapabilities` fields:
    - `provider.listSessions != nil` → `.list = SessionListCapabilities()`
    - `provider.restoreSession != nil` → `.resume = SessionResumeCapabilities()` (restore ↔ session/resume)
    - `provider.deleteSession != nil` → `.delete = SessionDeleteCapabilities()`
    - `onTurnEnded` gates no capability. Prompt caps advertised conservatively (baseline text + resourceLink only; `PromptCapabilities()` defaults) — the ^gs0d3kp turn task expands caps as it adds block-type mapping (it rejects unadvertised blocks with -32602), so over-claiming now would be wrong.
    NOTE: this task ADVERTISES session-mgmt caps by hook presence but does NOT yet forward session/list|resume|delete to the hooks (they keep the Agent protocol's -32601 default). Actual forwarding is ^vfmstvy per the card's scope split. Documented so the advertise-vs-honor window is intentional.

    SERIALIZATION DESIGN (no engine protocol; no queue abstraction leaked):
    - `FoundationModelsAgent` is an actor storing `[SessionId: SessionState]` where SessionState is an actor-owned reference holding the real `LanguageModelSession` + a `turnTail: Task<Void,Never>?`.
    - Per-session FIFO via Task-tail chaining: read predecessor tail + publish new tail with NO await between the two statements (atomic under actor isolation → immune to actor reentrancy, which matters because the real turn body suspends on the model). Turn N+1 awaits N's completion token before running. Different sessions run concurrently (safe: each is single-turn).
    - The primitive is an internal `serializeTurn(for:_ body:)`; `prompt` calls it with the trivial-turn body. PromptSerializationTests exercises `serializeTurn` directly (via @testable) with INSTRUMENTED FAKE bodies (record start/end order, force overlap attempts) — deterministic, no live model, no SIGTRAP risk. This is the "instrumented fake ordering" the card asks for; it is NOT a fake LanguageModelSession (§7.1-forbidden) — it's the agent's own turn-ordering seam.

    STUB BOUNDARY: `prompt` runs the trivial turn under serialization and returns `.endTurn`; `cancel` is a no-op. Real `streamResponse`→Transcript→session/update mapping, StopReason logic, cancel→FM cancellation, and `onTurnEnded` invocation all belong to ^gs0d3kp (its card feeds scripted Transcripts through a seam it introduces). One-liner `FoundationModelsAgent(connection:session:)` = SessionProvider whose makeSession returns (generated UUID SessionId, that session) with all hooks nil.

    Files: Sources/FoundationModelsACP/Bridge/{SessionProvider.swift, FoundationModelsAgent.swift}; Tests/FoundationModelsACPTests/Bridge/{SessionProviderTests.swift, PromptSerializationTests.swift}. TDD next.
  timestamp: 2026-07-15T17:57:30.536798+00:00
- actor: wballard
  id: 01kxkfbx186ch2chqq5wwn86f0
  text: |-
    Implementation landed (TDD). Files:
    - Sources/FoundationModelsACP/Bridge/SessionProvider.swift — `SessionProvider` struct (required `makeSession`, optional `listSessions`/`restoreSession`/`deleteSession`/`onTurnEnded`), `SessionProvider(session:sessionId:)` sugar init, `typealias MCPServerConfig = McpServer`, `typealias SessionSummary = SessionInfo`.
    - Sources/FoundationModelsACP/Bridge/FoundationModelsAgent.swift — `public actor FoundationModelsAgent: Agent`. `init(connection:provider:)` + one-liner `init(connection:session:)`. `initialize` (caps gated on hook presence), `newSession` (makeSession → track SessionState), `prompt` (trivial `.endTurn` turn under serialization), `cancel` (no-op stub). Internal `serializeTurn(for:_:)` = per-session Task-tail FIFO chain (read-predecessor/publish-tail with no await between → reentrancy-safe; failed turn still completes its token).

    Tests (Tests/FoundationModelsACPTests/Bridge/): BridgeTestSupport.swift (TurnRecorder/TurnGate/makeBridgeAgent/makeWiredBridge helpers), SessionProviderTests.swift (parameterized capability gating over StoreHook set; newSession cwd+MCP plumbing; one-liner==explicit-provider on the wire), PromptSerializationTests.swift (FIFO order [start1,end1,start2,end2] via instrumented fake bodies through the real serializeTurn seam; cross-session concurrency proof; unknown-session → -32602).

    VERIFICATION: swift build --build-tests zero warnings/errors. swift test = 114 FoundationModelsACPTests + 108 ACPGenerateTests, 0 failures, 0 warnings. Serialization tests ran 5x consecutively — deterministic, no flakiness, no live-model dependency, no SIGTRAP risk (fake bodies never touch the model). FoundationModels imported and linked in the library target on macOS 27 with zero divergence from the verified API. Checkpoint + review next.
  timestamp: 2026-07-15T18:07:02.696225+00:00
- actor: wballard
  id: 01kxkfya4gpaxy4jaq0y8dzypr
  text: |-
    Review pass 1 (sha HEAD~1..HEAD): 1 finding confirmed, 9 refuted, 14 attempted, 0 failed.

    FINDING: SessionProvider.swift:58 — swift casing rule wanted the `sessionId:` argument label renamed to `sessionID`.

    RESOLUTION (root, not the cited line): renaming to `sessionID` would fight this package's deliberate, pervasive naming contract — the generated newtype is `SessionId` and every property/label across the generated models and the already-reviewed Connection layer uses `sessionId` (mirroring the ACP wire schema field `sessionId`); the engine itself refuted 9 sibling `sessionId` usages and confirmed only this one externally-visible label. Rather than introduce an inconsistent `sessionID`, I removed the offending parameter entirely: the `SessionProvider(session:sessionId:)` convenience init's `sessionId:` override was an un-asked-for public knob (the card's one-liner is just "a provider whose makeSession returns that session, hooks nil" — no pinnable id). Now `SessionProvider(session:)` mints the id internally (`let identity = SessionId(rawValue: UUID().uuidString)`), which removes the flagged externally-visible label, tightens the public surface to exactly the card, and leaves the package-wide `sessionId` convention intact. Tests that need a pinned id now build "an explicit single-session provider" via the full `SessionProvider(makeSession:)` initializer — more faithful to the acceptance-criterion wording. swift test still 114 + 108 green, 0 warnings. Re-reviewing HEAD~1..HEAD.
  timestamp: 2026-07-15T18:17:05.936133+00:00
- actor: wballard
  id: 01kxkh4x1jbm2d83v5a4sa37gm
  text: |-
    STUCK — guardrail hit (same finding class across 3 review iterations). Leaving in review for human adjudication; NOT forcing done, NOT editing the validator.

    The work is functionally COMPLETE and green: all four acceptance criteria met (one-liner == explicit provider on the wire; initialize gates session-mgmt caps by hook presence; newSession plumbs cwd+MCP configs and tracks the SessionId; concurrent same-session prompts serialize strictly, cross-session run concurrently). swift build --build-tests: 0 warnings/errors. swift test: 114 FoundationModelsACPTests + 108 ACPGenerateTests, 0 failures. FoundationModels is real and imported; no API divergence.

    The ONLY thing blocking `done` is the swift ID-acronym casing validator, which has recurred across three review passes escalating to an unsatisfiable demand:
    - Pass 1 (fb6ae8f): rename the `sessionId:` arg label on SessionProvider(session:sessionId:). Fixed by REMOVING that un-asked-for convenience param (d9a6500) — a genuine scope tightening.
    - Pass 2 (d9a6500): rename test-local `sessionId`/`assignedId`/`explicitId` to `...ID`. I complied (f065dcc).
    - Pass 3 (f065dcc): different rule (missing `- Throws:` on initialize) — fixed cleanly (5899148).
    - Pass 4 (5899148): rename the `SessionId` TYPE ITSELF to `SessionID`.

    Pass 4 is unsatisfiable within this task and is the review skill's documented-contract exception:
    1. `SessionId` is a GENERATED type (Sources/FoundationModelsACP/Generated/Identifiers.generated.swift), produced by acp-generate from the ACP JSON schema whose field is `sessionId`. Spec §6 mandates "regenerate, don't patch" — I must not hand-edit generated code.
    2. Renaming it would break the ENTIRE package: every generated model, the already-reviewed-and-done Connection layer, and 200+ existing tests all spell `SessionId`/`sessionId`, and it would diverge from the wire schema (the whole ACP surface names session identity `SessionId`; no method can avoid spelling it).
    3. Partial compliance is incoherent (`sessionID: SessionId`, `NewSessionResponse(sessionId: sessionID)`), so I reverted my pass-2 casing churn (b43350f) to restore the package-uniform `sessionId`/`SessionId` convention — the cleanest, most consistent state for the human and for downstream tasks (^gs0d3kp etc.) that will follow the same convention.

    RECOMMENDATION for the human: either scope the ID-acronym casing rule to exempt this schema-mirroring package (the deliberate `SessionId`/`sessionId` contract from §6 codegen), OR — if the convention should truly change to `SessionID` — do it in the GENERATOR (a separate epic touching all generated identifiers + checked-in output + routing table + every test), not this card. The validator is also nondeterministic on this class (it refuted 9 sibling `sessionId` uses in pass 1, then confirmed the same pattern in later passes), which is why chasing it identifier-by-identifier does not converge.

    Current HEAD b43350f. Local commits only, nothing pushed. Task remains in `review`.
  timestamp: 2026-07-15T18:38:10.482522+00:00
- actor: wballard
  id: 01kxkj37c2aaegdbz8a3a0fyq2
  text: |-
    RESOLVED → done. Blocker cleared by human ruling: a project-level `swift` validator (`.validators/swift/`) now shadows the user validator, exempting the generated ID newtypes (SessionId/ToolCallId/TerminalId/PermissionOptionId/SessionModeId) and their `…Id` properties/labels from the ID-acronym casing rule as an intentional ACP-wire-schema documented exception (spec §6). Every other Swift rule and acronym (URL/JSON/…) still enforces fully. I did NOT rename any generated types; the package-uniform `sessionId`/`SessionId` convention is retained.

    Checkpoint: committed the `.validators/swift/` project config (597a5b5) per its .gitignore (validator definitions are committed) — LOCAL only, nothing pushed.

    Re-review with the exemption active: CLEAN — 0 findings, 14 validators attempted, 0 failed, 0 confirmed (reviewed fb6ae8f~1..HEAD, the full task delta; HEAD~1..HEAD alone was just the validator config = nothing in scope). The SessionId casing finding no longer fires; no new findings in any class.

    Verification: swift build --build-tests 0 warnings/errors; swift test 114 FoundationModelsACPTests + 108 ACPGenerateTests = 222 pass, 0 failures. Converged CLEAN — not forced. Open review findings marked resolved on the card (SessionId casing via exemption; initialize `- Throws:` fixed earlier). Moving to done.

    Local commits (nothing pushed): fb6ae8f feature, d9a6500 + f065dcc + 5899148 review-fixes, b43350f revert-to-uniform-sessionId, 597a5b5 validator exemption. Downstream (prompt-turn ^gs0d3kp, session-mgmt ^vfmstvy) unblocked; the SessionProvider shape + FM API reality are documented above.
  timestamp: 2026-07-15T18:54:44.098328+00:00
depends_on:
- 01KXHBBTQ24BC8586M5K0N872Z
position_column: done
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
- [x] One-liner construction compiles and behaves identically on the wire to an explicit single-session provider
- [x] `initialize` advertises session-management capabilities iff the corresponding hooks are non-nil
- [x] `newSession` invokes `makeSession` with the cwd and MCP configs from the request and returns its `SessionId`
- [x] Two concurrent `prompt` requests to one session execute strictly serially (observable via instrumented fake ordering)

## Tests
- [x] `Tests/FoundationModelsACPTests/Bridge/SessionProviderTests.swift` — capability gating by hook presence; one-liner equivalence; newSession plumbing
- [x] `Tests/FoundationModelsACPTests/Bridge/PromptSerializationTests.swift` — overlapping prompts serialize; each resolves at its own turn end
- [x] Run `swift test` — exits 0

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.

## Review Findings (2026-07-15) — RESOLVED
- [x] `SessionId` ID-acronym casing (recurred across review passes 1/2/4). RESOLVED by human ruling: a project-level `swift` validator exemption at `.validators/swift/rules/casing.md` documents the generated ID newtypes (SessionId, ToolCallId, TerminalId, PermissionOptionId, SessionModeId) and their `…Id` properties/labels as an intentional ACP-wire-schema exception (spec §6). NOT resolved by renaming generated code. Package-uniform `sessionId`/`SessionId` convention retained. Re-review after the exemption: 0 findings, 14 validators attempted, 0 failed.
- [x] `initialize` missing `- Throws:` doc (review pass 3) — fixed by documenting the protocol-required `throws`.