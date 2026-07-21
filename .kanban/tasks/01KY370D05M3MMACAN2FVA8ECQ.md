---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01ky3betwpf9c9z2z4hmpq16a2
  text: 'Picked up ^fva8ecq. Plan: research current test files + BridgeTestSupport coupling, then TDD-port EndToEndSupport/EndToEndTests/GoldenReplayTests onto a scripted wire Agent, regenerate golden fixture string, keep bridge untouched.'
  timestamp: 2026-07-21T22:06:35.414796+00:00
- actor: claude-code
  id: 01ky3brkwjeta3tzca7mcqcnzs
  text: |-
    Research done. Design: new Tests/FoundationModelsACPTests/ScriptedAgentSupport.swift holds a pure-wire `ScriptedAgent` (Agent conformance; queued `ScriptedTurn = (ScriptedTurnContext) async throws -> StopReason`; prompt runs turn in a registered Task so `session/cancel` cancels it and maps to StopReason.cancelled — mirrors bridge runTurn semantics). Its initialize() reproduces the golden fixture's InitializeResponse (promptCapabilities audio:false/embeddedContext:true/image:false, agentInfo FoundationModelsACP 0.1.0) so the fixture stays byte-identical apart from the message string.

    Moves (same module, so Bridge tests keep compiling — no Bridge file deleted):
    - messageChunkUpdate/thoughtChunkUpdate/TurnRecorder/TurnGate/waitUntil: BridgeTestSupport -> ScriptedAgentSupport
    - ClientCapabilities .readOnly/.writeOnly/.terminalOnly extension: ToolBridgeTestSupport -> RoleTestSupport (EndToEndSupport's default capabilities depend on .readOnly; it would otherwise die with Bridge deletion)
    - new wire `newSessionRequest(mcpServers:)` in RoleTestSupport; bridgeNewSessionRequest delegates to it
    - ClientEnvironment.current reverse calls replaced by direct context.connection.readTextFile/requestPermission; RecordingEnvironmentClient (Bridge symbol) replaced by SpyClient+RoleRecorder / MinimalClient
    - GoldenReplay rawInput built as structural JSONValue literal (drops Bridge jsonValue helper)

    Fixture: hand-edit golden-session-agent.ndjson line 4 "Hello from the bridge." -> "Hello from the agent."; RED first by running ported golden test against old fixture to watch drift reporting fire, then edit -> GREEN.

    Two green checkpoints: (1) support moves + ScriptedAgent added, suite green; (2) port the three files + fixture, suite green.
  timestamp: 2026-07-21T22:11:55.922656+00:00
- actor: claude-code
  id: 01ky3cd189z2hgyg114n4yfcst
  text: 'Checkpoint 1 green: ScriptedAgentSupport.swift added (ScriptedAgent + ScriptedTurn/Context + moved messageChunkUpdate/thoughtChunkUpdate/TurnRecorder/TurnGate/waitUntil); BridgeTestSupport slimmed (bridgeNewSessionRequest now delegates to new wire newSessionRequest in RoleTestSupport); ClientCapabilities fixtures moved ToolBridgeTestSupport -> RoleTestSupport. swift test: 187+3+116 pass, exit 0. One compile fix along the way: the empty-queue fallback closure in takeTurn needed an explicit @Sendable annotation.'
  timestamp: 2026-07-21T22:23:04.969433+00:00
- actor: claude-code
  id: 01ky3d34gzg5v8q9t4ta8wnwfz
  text: |-
    Checkpoint 2 done — port landed. TDD RED observed exactly as planned: ported goldenSessionReplayMatchesFixture failed against the committed fixture with a single drift at line 4 ("Hello from the bridge." expected vs "Hello from the agent." actual) and NO other drift — proving the ScriptedAgent reproduces the entire agent byte stream byte-identically apart from the one deliberate string, and that the golden comparison bites. Then edited golden-session-agent.ndjson line 4 (only bytes changed in any fixture: "Hello from the bridge." -> "Hello from the agent.") -> GREEN.

    Files changed:
    - NEW Tests/FoundationModelsACPTests/ScriptedAgentSupport.swift (ScriptedAgent, ScriptedTurn/ScriptedTurnContext, moved messageChunkUpdate/thoughtChunkUpdate/TurnRecorder/TurnGate/waitUntil)
    - EndToEndSupport.swift: no FoundationModels import; EndToEndPair.agent: ScriptedAgent; makeEndToEndPair(sessionId:client:); makeGoldenDriver(sessionId:scriptedTurn:); removed now-unused grantedPermissionOutcome
    - EndToEndTests.swift: SpyClient+RoleRecorder replaces RecordingEnvironmentClient; reverse calls go through context.connection (readTextFile/requestPermission) instead of ClientEnvironment.current; same assertions incl. 100x determinism loop
    - GoldenReplayTests.swift: four wire updates scripted directly (rawInput as structural JSONValue literal), end_turn; adversarial test unchanged in assertions
    - BridgeTestSupport.swift: moved helpers removed; bridgeNewSessionRequest delegates to newSessionRequest
    - ToolBridgeTestSupport.swift: capability fixtures extension moved out
    - RoleTestSupport.swift: + newSessionRequest, + ClientCapabilities .readOnly/.writeOnly/.terminalOnly
    - Fixtures/golden-session-agent.ndjson: one line, one string

    Verification: swift test exit 0 (187+3+116 tests, all pass); clean rebuild of test target after touching all test files: 0 warnings 0 errors. Acceptance greps verified: ported files match only symbols now defined in ScriptedAgentSupport/RoleTestSupport; no FoundationModels/FoundationModelsAgent/SessionProvider/ClientEnvironment/RecordingEnvironmentClient/TurnGenerator references. No Bridge file deleted. double-check agent running.
  timestamp: 2026-07-21T22:35:09.215658+00:00
- actor: claude-code
  id: 01ky3desrm1ar7wffq1q674kt2
  text: 'really-done complete. Verification: swift test exit 0 — 187+3+116 tests pass, 0 warnings on a forced clean recompile of the test target. Adversarial double-check verdict: PASS — confirmed no Bridge file deletions, ported files reference zero Bridge-defined symbols, Bridge tests still green via delegating bridgeNewSessionRequest and module-wide moved helpers, fixture diff is exactly the one message-string line, all original coverage mapped 1:1 (incl. 100x determinism loop and trailing-update-after-cancel), and ScriptedAgent''s cancel semantics match spec (always resolves cancelled on session/cancel). Work done and green; leaving task in doing for /review.'
  timestamp: 2026-07-21T22:41:31.412465+00:00
position_column: doing
position_ordinal: '80'
title: Port end-to-end and golden-replay tests off the bridge onto a scripted wire Agent
---
## What
`Tests/FoundationModelsACPTests/EndToEndSupport.swift`, `EndToEndTests.swift`, and `GoldenReplayTests.swift` currently drive the concrete `FoundationModelsAgent` bridge with scripted FoundationModels `Transcript` entries (`import FoundationModels`, `SessionProvider`, `makeEndToEndPair(provider:client:)`, `makeGoldenDriver`). The bridge is superseded (plan.md §9.1) and will be deleted; the wire coverage these tests provide (framing, ordering, tool-call pairing, late updates, `StopReason`, full bidirectional surface) must survive model-free.

Add a scripted pure-wire `Agent` test double (e.g. `ScriptedAgent` in a new `Tests/FoundationModelsACPTests/ScriptedAgentSupport.swift` or folded into `RoleTestSupport.swift`): an `Agent` conformance whose `prompt()` emits a scripted sequence of `session/update` notifications (agent_thought_chunk, agent_message_chunk, tool_call, tool_call_update) through its `AgentSideConnection`, then resolves with a scripted `StopReason`. Port:
- `EndToEndSupport.swift`: `makeEndToEndPair` takes a `ScriptedAgent` factory instead of a `SessionProvider`; drop `import FoundationModels`.
- `EndToEndTests.swift`: same behaviors asserted (initialize/new/prompt/cancel flows, reverse Agent→Client calls) via scripted updates instead of transcript entries. Note it currently also uses the Bridge *source* type `ClientEnvironment.current` — replace with a wire-only equivalent or drop.
- `GoldenReplayTests.swift`: script the four updates + `end_turn` currently produced via transcript mapping.

**Cross-file coupling (must be fully severed):** these files call helpers defined only in `Tests/FoundationModelsACPTests/Bridge/BridgeTestSupport.swift` — `bridgeNewSessionRequest()`, `bridgeInitializeRequest()`, `messageChunkUpdate()`, `thoughtChunkUpdate()`, `TurnRecorder`, `TurnGate`, `waitUntil(_:records:)`, `responseEntry`/`reasoningEntry`/`toolCallEntry`/`toolOutputEntry`, `singleSessionProvider`, `makeModelSession`, `enqueueScriptedTurn`. Port the *generic* helpers (session-update builders, `TurnRecorder`/`TurnGate`/`waitUntil(records:)`, a wire `newSessionRequest` helper) into `ScriptedAgentSupport.swift`/`RoleTestSupport.swift`; the transcript-entry builders and provider helpers stay behind in Bridge and die with it.

**Golden fixture content:** `Fixtures/golden-session-agent.ndjson` pins the legacy string "Hello from the bridge.". Do a one-time deliberate regeneration replacing it with a wire-neutral message (e.g. "Hello from the agent."), with a commit note stating exactly which bytes changed and why. Framing/ordering/pairing/stop-reason structure must be byte-identical apart from that string.

Do NOT delete any Bridge source or Bridge test in this task — the bridge stays green until the deletion task.

## Acceptance Criteria
- [ ] `EndToEndSupport.swift`, `EndToEndTests.swift`, `GoldenReplayTests.swift` contain no `import FoundationModels` and no reference to `FoundationModelsAgent`/`SessionProvider`
- [ ] Machine-checked decoupling: `grep -E 'bridgeNewSessionRequest|bridgeInitializeRequest|messageChunkUpdate|thoughtChunkUpdate|TurnRecorder|TurnGate|ClientEnvironment|responseEntry|reasoningEntry|toolCallEntry|toolOutputEntry|singleSessionProvider|makeModelSession|enqueueScriptedTurn' Tests/FoundationModelsACPTests/EndToEndSupport.swift Tests/FoundationModelsACPTests/EndToEndTests.swift Tests/FoundationModelsACPTests/GoldenReplayTests.swift` matches only symbols now defined in `ScriptedAgentSupport.swift`/`RoleTestSupport.swift` (none resolve into `Tests/FoundationModelsACPTests/Bridge/` or `Sources/FoundationModelsACP/Bridge/`)
- [ ] Golden replay still asserts frame-for-frame against committed fixtures in `Tests/FoundationModelsACPTests/Fixtures`; only the legacy message string changed, noted in the commit
- [ ] Full suite green: `swift test`

## Tests
- [ ] Ported `EndToEndTests` cover: initialize handshake, session/new, prompt turn streaming updates then `end_turn`, session/cancel resolving with `cancelled`, reverse Agent→Client call landing on the served client
- [ ] Ported `GoldenReplayTests` pass against the regenerated golden fixture
- [ ] `swift test` exits 0

## Workflow
- Use `/tdd` — port one test file at a time, keeping the suite green after each file.