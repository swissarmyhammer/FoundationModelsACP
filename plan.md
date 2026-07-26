# FoundationModelsACP — Plan

A Swift implementation of the **[Agent Client Protocol](https://agentclientprotocol.com)
v2** wire: types, role protocols, connections, transports. Zero external
dependencies. Both roles, so this package can be driven *or* drive.

Consumers: **`FoundationModelsACPAgent`** (the Agent role, composing our runtime)
and **`FoundationModelsACPClient`** (the Client role, an `@Observable` container for
SwiftUI). One package per role, both on top of this wire.

> Target: **OS 27+**, matching the family. Portable by construction — this package
> imports no UI framework and no platform runtime, so it stays usable anywhere
> Swift runs.

## Decision: v2 only

**We implement ACP v2 and do not serve v1.** *(Supersedes the previous plan, which
targeted v1.19.x with v2 hedged behind an unstable namespace, and supersedes the
brief dual-version design that replaced it.)*

The spec's own migration guidance recommends serving both versions indefinitely,
and we are deliberately not doing that. Recorded plainly, because it is a real
tradeoff:

- **Cost:** v2 is **draft**. Its shape can still move, and clients that speak only
  v1 today cannot talk to our agent at all. We are betting on where the protocol is
  going rather than where its deployed base is.
- **Why it is still right for us:** nothing here is shipped or depended upon yet.
  Both consumers are unimplemented. v2 is a **large** simplification, not a
  cosmetic revision — it deletes the entire client-side filesystem and terminal
  surface, replaces the long-lived prompt request with immediate acknowledgement
  plus state notifications, and makes history replay and message identity
  first-class. Carrying v1 as well would mean two generated namespaces, two role
  protocol shapes, per-connection version branching, and double the test matrix —
  permanent complexity to support peers we have never had.

Revisit only if a specific v1 client we care about becomes a requirement.

## Starting point: this is a rewrite, not a greenfield build

A complete v1 implementation existed in this repo and **was deleted** on the
reset branch — roughly 2,850 lines of hand-written wire code, 8,050 lines of
generated types, and 4,500 lines of wire tests. Read the milestones below as
*rebuild against v2*, not *build for the first time*. All of it remains in git
history (`git log -p`) and is worth consulting: the connection design in
particular was sound and its v2 equivalent will look similar.

**Survives, and is not rewritten:**

| Kept | Why |
|---|---|
| `Sources/ACPGenerateCore/` | The schema→Swift generator: schema model, emitter, tagged/anyOf union stages, routing-table builder, hash stamp. Schema-vocabulary-independent. |
| `Sources/acp-generate/`, `Plugins/GenerateACP/` | The CLI and the `swift package generate-acp` command plugin. |
| `Tests/ACPGenerateTests/` | 43 generator tests driven by inline synthetic schemas. |
| `Core/JSONValue.swift`, `AbsolutePath.swift`, `MethodInfo.swift`, `WireRawValueCodable.swift` | The hand-written support types the generator itself imports. |

**Deleted, and must be rebuilt:** every generated model/union/enum; the `Agent`
and `Client` role protocols; `Connection`, `RoleDispatch`, `RoleConnectionCore`,
both side connections, `SessionUpdateRouter`, `RequestError`; all transports
(`Stdio`, `InMemory`, `Subprocess`, `Replay`, `NDJSONCodec`); `LineNumber`,
`ProtocolVersion`, `ForgivingDecoding`, `ACP`; the whole
`FoundationModelsACPTests` target and the `acp-test-agent` fixture binary; the
v1 schema artifacts; `docs/GUIDE.md`.

**Test coverage deliberately dropped, to be re-established against v2** — call
this out in the milestone that restores it, because it is easy to lose quietly:

- Vendored-schema emission assertions (models, unions, enums, routing table)
  — **M0/M1**.
- `TaggedUnionRoundTripTests` and `UnknownFallbackRoundTripTests`: runtime
  decode/encode of generated unions and `unknown(String)` fallbacks — **M1**.
- `ForgivingDecodingTests` — **M1**.
- The compiled-routing-table acceptance suite (the wrong-wiring regression
  guard) — **M2**.
- Every connection, transport, replay, and end-to-end test — **M3** onward.

**Known consequence of the reset:** `Schema/` is empty, so
`swift package generate-acp` and the CI codegen diff gate both fail until M0
vendors `acp-v2.json`. `swift build` and `swift test` are green. Also,
`SchemaSet.acpV1` and `GeneratorConfig.acpV1` still carry v1 names and
v1-specific field mappings (`ReadTextFileRequest.path`,
`CreateTerminalRequest.cwd`, `LoadSessionRequest.*`) for types v2 deletes; M0
re-points them. The generator's `Unstable` namespace support also survives — if
v2 publishes no unstable manifest, that code path is dead and M0 should say so.

## What v2 is, in one page

**Agent methods** (Client → Agent): `initialize`, `auth/login`, `auth/logout`,
`session/new`, `session/list`, `session/resume`, `session/close`, `session/prompt`,
`session/set_config_option`.
**Agent notifications** (Client → Agent): `session/cancel`.

**Client methods** (Agent → Client): `session/request_permission`,
`elicitation/create`.
**Client notifications** (Agent → Client): `session/update`,
`elicitation/complete`.

That is the whole surface — and the Client half is *four entry points*. When
`capabilities.session` is advertised, an agent must implement the baseline:
`session/new`, `session/list`, `session/resume`, `session/close`,
`session/prompt`, `session/cancel`, `session/update`.

**`session/update` carries everything that happens**: `state_update`,
`user_message` / `user_message_chunk`, `agent_message` / `agent_message_chunk`,
`agent_thought` / `agent_thought_chunk`, `tool_call_update`,
`tool_call_content_chunk`, `plan_update`, `config_option_update`, and
slash-command availability — plus `terminal_update` / `terminal_output_chunk`
**only if M0 confirms they exist** (see below).

### The five changes that reshape the design

1. **`session/prompt` acknowledges, it does not complete.** It returns `{}`
   immediately. Progress and completion arrive as **`state_update`** notifications
   with three states: `running`, `idle` (carrying `stopReason`), and
   **`requires_action`** (foreground work blocked on the user). Cancellation is
   confirmed by an `idle` state with `stopReason: "cancelled"`.
   *This deletes the previous design's central complication — a request left
   pending for a whole turn.*
2. **The agent owns history and message identity.** Every message chunk and update
   carries a required, **agent-generated `messageId`**: *"the Agent owns session
   history, so it is the single source of message identity."*
3. **Upserts, not appends.** `tool_call` create is gone; `tool_call_update` both
   creates and patches, keyed by `toolCallId`. Whole-message upserts take `content`
   arrays with three-state semantics — omitted means unchanged, `null`/`[]` clears,
   a concrete array replaces — while `*_chunk` variants append.
4. **No client filesystem, no client terminals.** `fs/*` and `terminal/*` are
   removed, and *"stable v2 defines no standard client capability fields."* Agents
   reach the client's world through **MCP** instead.

   ⚠️ **The display-terminal successor is unconfirmed — do not build on it.** The
   migration guide describes an agent-owned display terminal stream
   (`terminal_update`, `terminal_output_chunk`, a `terminal` content reference,
   explicitly with *"no input, resize, interrupt, kill, wait, release, or execution
   semantics"*). But the surfaces that generate code do not show it: the v2 content
   variants are `text` / `image` / `audio` / `resource` / `resource_link`, the
   schema shows no terminal updates or content block, and there is **no v2
   Terminals page** where v1 has one. What the schema *does* carry is a
   `TerminalId` type and a `terminalId` on `CommandPermissionSubject` — *"the
   associated terminal, when already known."* The migration guide appears to be
   ahead of the schema, which is unremarkable for a draft. **M0 resolves it.**
5. **Replay is first-class.** `session/load` is gone; `session/resume` handles both
   plain reconnect and, with `replayFrom: {"type": "start"}`, full history replay
   as ordinary session updates.

### Conventions the type system should enforce

Absolute paths everywhere, 1-based line numbers, `camelCase` object keys,
`snake_case` discriminator values. Unknown enum and tagged-union values must be
**accepted and preserved when proxying**; values beginning with `_` are
implementation-specific, and unknown non-underscore values are reserved for future
versions. `_meta` follows patch semantics in updates.

## The wire specification: generate it, don't transcribe it

**Generated from the vendored `acp-v2.json` schema:** every model, union, enum, and
the **routing table** (from the schema's `x-side`/`x-method` metadata). Generating
the routing table is what structurally prevents the TS-SDK bug class where
`setSessionModel` was wired to `session/set_mode` — a wrong mapping cannot be
written by hand if no mapping is written by hand.

- **No-op unless the schema changed** (content-hash stamp in the output).
- **Generated code is checked in** — consumers compile source, no build-time
  generation.
- A **SwiftPM command plugin** (`swift package generate-acp`) writes the files;
  command plugins may write to the package directory, build-tool plugins may not.
  CI runs it and **fails on any diff**.
- v2 is **draft**: expect to re-vendor. That is a `git diff` of generated files,
  which is exactly the workflow this pipeline is for.

**Hand-written, never generated:** transports, connections, role protocols,
`JSONValue`, `AbsolutePath`, `RequestError`, and the `unknown(String)` fallbacks
that make unknown-value preservation real.

## Connection model: full-duplex, notification-first

Two symmetric connection objects over one byte stream, each taking a **factory
closure** so a handler can capture its own connection for reverse calls:

```swift
AgentSideConnection(stream:)  { conn  in RoutedACPAgent(conn, router) }
ClientSideConnection(stream:) { agent in MyClient(agent) }
```

Either peer sends requests and notifications at any time, many in flight both
directions. Implementation: **one read loop per connection**; correlation via a
monotonic id and `[RequestID: CheckedContinuation]` inside the connection actor
(which also serializes writes); **each inbound request dispatches as its own
`Task`**, so a slow handler cannot head-of-line-block a `session/cancel` or a
reverse request.

v2 makes this materially simpler than v1 would have: with `session/prompt`
acknowledging immediately, no request is held open for the duration of a turn. The
remaining long-lived requests are the ones that genuinely wait on a human —
`session/request_permission` and `elicitation/create` — and those must never block
the read loop.

**Fail loud on disconnect** (a real TS-SDK gap): on EOF or error, reject every
pending continuation and finish every stream; per-request timeouts; honor `Task`
cancellation. **Tolerate late and out-of-order notifications** — an upsert may
arrive after the state it refers to has moved on, and correlation is by
`messageId` / `toolCallId` / `terminalId`, never by arrival order.

**Transports:** stdio (ndJSON framing) for subprocess agents, and
`InMemoryTransport.pair()` for in-process pairing. The in-process pair is a
**production** mechanism, not only a test fixture: it is how a SwiftUI app runs an
agent in the same process while still speaking the protocol.

## Testing strategy

ndJSON makes a session trivially recordable — tee the byte stream and you have a
replayable script.

- **`ReplayTransport`** replays a recorded client↔agent script against golden
  fixtures: framing, ordering, upsert application, late updates, `stopReason`.
  Deterministic; no model, no network.
- **`InMemoryTransport`** wires a `Client` and an `Agent` back-to-back with no
  pipes, for full-session tests.
- **Routing tests** assert every method reaches the correct side's handler — the
  regression guard for the wrong-wiring bug class.
- **Unknown-value preservation** — decode a payload carrying an unrecognized enum
  case and a `_`-prefixed extension, re-encode, and assert nothing was dropped.
  This is a protocol requirement, not politeness.
- **Conventions** — relative paths and 0-based line numbers must fail at
  decode time.

## Decisions

- **v2 only (decided):** see above. No v1 surface, no version branching, no dual
  namespaces.
- **Schema-driven codegen with checked-in output (decided):** models, unions, and
  the routing table are generated; consumers compile source. Regenerate, never
  hand-patch.
- **Zero external dependencies (decided):** this is the wire. No UI framework, no
  platform runtime, no third-party JSON. `Observation` and SwiftUI belong to
  `FoundationModelsACPClient`, not here.
- **Both roles (decided):** ship `Agent` and `Client` protocols and both connection
  sides. The two consumer packages each implement one.
- **In-memory transport is production (decided):** it is how an in-process SwiftUI
  client drives an in-process agent over the real protocol.
- **Draft tracking (decided):** track v2 drafts by re-vendoring the schema and
  regenerating, and state the draft status in the README so consumers know the
  surface can move.

## Milestones

- [ ] **M0 — Vendor v2 and restart the pipeline.** The v1 schema and its generated
  output are already gone (see *Starting point*); vendor `acp-v2.json` (+ meta),
  re-point `SchemaSet` and `GeneratorConfig` off their v1 names and field
  mappings, and regenerate. Confirm the plugin, content-hash no-op, and CI diff
  gate come back green. **Verify the method and payload
  inventory against the schema** rather than against this plan — only the overview,
  migration, session-setup, and content pages have been read closely, and the
  migration guide has already proven to run ahead of the schema on terminals.
- [ ] **M1 — Types and conventions.** Generated models/unions/enums, plus the
  hand-written `JSONValue`, `AbsolutePath`, `RequestError`, and `unknown(String)`
  fallbacks. Decode-time enforcement of absolute paths and 1-based lines.
- [ ] **M2 — Role protocols.** `Agent` (nine methods plus `session/cancel`) and
  `Client` (four entry points). Capability-gated methods default to
  method-not-found.
- [ ] **M3 — Connections and transports.** Both connection sides, the read loop,
  continuation correlation, per-request `Task` dispatch, fail-loud disconnect,
  stdio and `InMemoryTransport`.
- [ ] **M4 — Initialization and capabilities.** `initialize` with required `info`
  and `capabilities`, empty-object support markers, nested
  `capabilities.session.*` (including `mcp.stdio` / `mcp.http` /
  `additionalDirectories`), and `protocolVersion: 2`.
- [ ] **M5 — Sessions.** `session/new` / `list` / `resume` / `close`, `mcpServers`
  on new and resume, `replayFrom`, config options.
- [ ] **M6 — Prompt lifecycle.** `session/prompt` immediate ack, `state_update`
  states, `stopReason` on idle, `session/cancel` → cancelled idle.
- [ ] **M7 — Updates.** Every `session/update` variant: messages and chunks with
  `messageId`, tool-call upserts and content chunks, terminal upserts and output
  chunks, plans, config options, slash commands.
- [ ] **M8 — Permissions and elicitation.** `session/request_permission` with
  `title` / `description` / tagged `subject`; `elicitation/create` and
  `elicitation/complete` with form and URL modes.
- [ ] **M9 — Replay and interop.** `ReplayTransport` with golden fixtures, and a
  round-trip against a real third-party v2 agent or client once one exists.

## References

- ACP v2 overview — https://agentclientprotocol.com/protocol/v2/overview
- v1 → v2 migration (the authoritative change list) — https://agentclientprotocol.com/protocol/v2/migration
- v2 schema — https://agentclientprotocol.com/protocol/v2/schema
- v2 prompt lifecycle — https://agentclientprotocol.com/protocol/v2/prompt-lifecycle
- v2 tool calls — https://agentclientprotocol.com/protocol/v2/tool-calls
- v2 session setup — https://agentclientprotocol.com/protocol/v2/session-setup
- v2 elicitation — https://agentclientprotocol.com/protocol/v2/elicitation
- v2 extensibility — https://agentclientprotocol.com/protocol/v2/extensibility
- Documentation index — https://agentclientprotocol.com/llms.txt
- FoundationModelsACPAgent (the Agent role) — ../FoundationModelsACPAgent
- FoundationModelsACPClient (the Client role, `@Observable` for SwiftUI) — ../FoundationModelsACPClient
- FoundationModelsMCP (v2 routes client-side file access and execution through MCP) — ../FoundationModelsMCP
- Previous v1-targeted plan, and the entire v1 implementation it produced — in
  git history (`git log -p -- plan.md`; `git show <reset-commit>^` for the
  sources). See *Starting point* above for exactly what was kept and dropped.
