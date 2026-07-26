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
| `Sources/ACPGenerateCore/` | The schema→Swift generator: schema model, emitter, tagged/anyOf union stages, routing-table builder, hash stamp. Mostly schema-vocabulary-independent — M0 had to teach it v2's `anyOf` union vocabulary, see below. |
| `Sources/acp-generate/`, `Plugins/GenerateACP/` | The CLI and the `swift package generate-acp` command plugin. |
| `Tests/ACPGenerateTests/` | Generator tests driven by inline synthetic schemas, plus `VendoredSchemaTests` against the real artifacts. |
| `Core/JSONValue.swift`, `AbsolutePath.swift`, `MethodInfo.swift`, `WireRawValueCodable.swift` | The hand-written support types the generator itself imports. |

**Deleted, and must be rebuilt:** every generated model/union/enum; the `Agent`
and `Client` role protocols; `Connection`, `RoleDispatch`, `RoleConnectionCore`,
both side connections, `SessionUpdateRouter`, `RequestError`; all transports
(`Stdio`, `InMemory`, `Subprocess`, `Replay`, `NDJSONCodec`); `LineNumber` and
`ACP`; the whole `FoundationModelsACPTests` target and the `acp-test-agent`
fixture binary; the v1 schema artifacts; `docs/GUIDE.md`.

`ProtocolVersion` and `ForgivingDecoding` came back in **M0**, because the
regenerated v2 output references them and would not compile otherwise;
`ProtocolVersion` now carries `.v2` rather than `.v1`.

**Test coverage deliberately dropped, to be re-established against v2** — call
this out in the milestone that restores it, because it is easy to lose quietly:

- Vendored-schema emission assertions (models, unions, enums, routing table)
  — **done in M0** (`Tests/ACPGenerateTests/VendoredSchemaTests.swift`), which
  also pins the checked-in output against a fresh in-memory run.
- `TaggedUnionRoundTripTests` and `UnknownFallbackRoundTripTests`: runtime
  decode/encode of generated unions and `unknown(String)` fallbacks — **M1**.
- `ForgivingDecodingTests` — **M1**.
- The compiled-routing-table acceptance suite (the wrong-wiring regression
  guard) — **M2**.
- Every connection, transport, replay, and end-to-end test — **M3** onward.

**Resolved by M0.** `Schema/` now holds `acp-v2.json` and both meta manifests,
vendored from the tagged pre-release `schema-v2.0.0-alpha.2`;
`SchemaSet.acpV2` / `GeneratorConfig.acpV2` point at them, generation is
idempotent, and the CI codegen diff gate passes again. v2 **does** publish an
unstable manifest, so the generator's `Unstable` namespace is live code, not
dead: the manifest declares 26 agent, 7 client, and 1 protocol method, and the
emitted namespace routes the 20 entries the stable table does not already carry
(15 agent, 5 client — `mcp/message` is routed on both sides, so it is two
entries under one wire name).

The gate needed one fix to mean anything: because the content-hash stamp is
checked in, a fresh checkout regenerated nothing and `git diff --exit-code`
passed trivially. The job now deletes the stamp first, so a hand-edited
generated file is overwritten and shows up as drift — verified.

**M0 also found that the codegen pipeline was *not* fully
schema-vocabulary-independent.** v2 rewrote the union vocabulary: every union is
`anyOf` (v1 used `oneOf` for enums and tagged unions), and 14 of them close with
an explicit unknown-discriminator variant that `not`-excludes every known tag —
the fallback v1 left implicit and the generator already synthesizes as
`unknown(String)`. Generation aborted on that construct. The generator now
recognizes it, mapping it onto whatever fallback each union family already
emits, and reads `anyOf` string enums with an open tail.

**Where the schema's catch-all carries more than the tag, the whole definition
defers to raw JSON rather than truncate it.** Four do, in two shapes that fail
in opposite directions:

- **Three tagged unions lose the payload and keep the tag.** `AuthMethod`
  requires `methodId` and `name` beside the unrecognized tag,
  `PlanUpdateContent` requires `planId`, `ReplayFrom` carries `_meta`. Their
  variants flatten `$ref` payloads, so the emitter's synthesized
  `unknown(String)` has nowhere to put those members and drops them.
- **`SetSessionConfigOptionRequest` is the inverse: it loses the tag and keeps
  the payload.** It is an object (`sessionId`, `configId`, `_meta`) that also
  carries a value union on `type`, and its catch-all re-declares `type`
  *unpinned* alongside the very `value` the union is built around. The emitted
  value-union default case is keyed on the value member alone, so it preserves
  `value` and cannot re-encode the discriminator it matched.

Either loss would contradict *Conventions* below and the schema's own
instruction to "preserve the raw payload when storing, replaying, proxying, or
forwarding". `JSONValue` is lossless, so that is what all four emit until M1
gives each fallback somewhere to keep what it currently drops.

**Left on the placeholder seam, for M1.** The last two rows carry the API
surface each deferral untypes, because a definition name alone does not convey
that three ordinary stable fields and one whole params object are raw JSON
today. Rows 1 and 2 untype six more properties — `ACPError.code`,
`Diff.changes`, and `configOptions` on `NewSessionResponse`,
`ResumeSessionResponse`, `SetSessionConfigOptionResponse`, and
`ConfigOptionUpdate` — for fourteen placeholder-typed properties in all:

| Shape | Definitions, and the API surface each untypes |
|---|---|
| Integer enum with an open tail | `ErrorCode` |
| Base object plus a tagged (`allOf`-payload) union | `DiffChange`, `SessionConfigOption` |
| Tagged union whose catch-all carries payload | `AuthMethod` → `InitializeResponse.authMethods: [JSONValue]?`; `PlanUpdateContent` → `PlanUpdate.plan: JSONValue` (required, not optional); `ReplayFrom` → `ResumeSessionRequest.replayFrom: JSONValue?` |
| Object plus a value union whose catch-all leaves the tag unpinned | `SetSessionConfigOptionRequest` → the entire `session/set_config_option` params object. `MethodTable.generated.swift` routes it as `paramsTypeName: "SetSessionConfigOptionRequest"`, which resolves to `JSONValue`, so `sessionId`, `configId`, `value`, and `_meta` are all untyped at the one routed stable method that has no typed params |
| Pre-existing (also deferred under v1) | `AgentResponse`, `ClientResponse`, `EmbeddedResourceResource`, `ExtRequest`, `ExtResponse`, `ExtNotification`, `RequestID`, `SessionConfigSelectOptions` |

The seam is also why so much of the generated surface is unreachable.
`Sources/FoundationModelsACP/Generated/` holds **26** declarations that nothing
else in the generated surface references. The triage below accounts for every
one of the 26, so an M1 that satisfies it leaves no orphan behind:

- **Ten are unlocked by rows 1-4 — this group is M1's completion signal.**
  Eight structs (`AuthMethodAgent`, `DiffPathChange`, `DiffPathPairChange`,
  `PlanItems`, `ReplayFromStart`, `SessionConfigBoolean`, `SessionConfigId`,
  `SessionConfigSelect`) and two enums (`DiffFileType`,
  `SessionConfigOptionCategory`). `SessionConfigId` is reached from two rows —
  `SessionConfigOption` in row 2 and `SetSessionConfigOptionRequest` in row 4 —
  and every other member from exactly one.
- **Four hang off row 5 and stay orphaned past M1.** `TextResourceContents`
  and `BlobResourceContents` are `$ref`'d only by `EmbeddedResourceResource`;
  `SessionConfigSelectGroup` only by `SessionConfigSelectOptions`; and
  `ACPError` only by `AgentResponse` and `ClientResponse`. The last is easy to
  file under the envelope types below — it is not one. The schema does `$ref`
  it, from two row-5 placeholders, so it is reachable in principle even though
  nothing plans to resolve those rows.
- **Five are row-5 placeholders that are themselves orphans** —
  `AgentResponse`, `ClientResponse`, `ExtRequest`, `ExtResponse`,
  `ExtNotification`. Row 5's other three (`EmbeddedResourceResource`,
  `RequestID`, `SessionConfigSelectOptions`) are referenced, so they are not.
- **Five are JSON-RPC envelope types no row will ever reach** — `AgentRequest`,
  `AgentNotification`, `ClientRequest`, `ClientNotification`,
  `ProtocolLevelNotification`. Unlike everything above, these have **zero**
  `$ref`s anywhere in the schema. The routing table supersedes them; exclude
  them from the signal or it can never go green.
- **Two are the routing roots** — `ACPMethodTable` and `Unstable`. Nothing in
  the generated surface references them by design; consumers do.

## What v2 is, in one page

*Read off the vendored `Schema/acp-v2.meta.json` and `acp-v2.json`, not from the
docs pages — M0 reconciled the two and the schema wins.*

**Agent methods** (Client → Agent): `initialize`, `auth/login`, `auth/logout`,
`session/new`, `session/list`, `session/resume`, `session/close`,
`session/delete`, `session/prompt`, `session/set_config_option`.
**Agent notifications** (Client → Agent): `session/cancel`.

**Client methods** (Agent → Client): `session/request_permission`.
**Client notifications** (Agent → Client): `session/update`.

**Protocol-level**: `$/cancel_request`.

That is the whole stable surface — and the Client half is *two entry points*.
When `capabilities.session` is advertised, an agent must implement the baseline:
`session/new`, `session/list`, `session/resume`, `session/close`,
`session/prompt`, `session/cancel`, `session/update`. Capability sub-objects are
`session.prompt` (`audio` / `image` / `embeddedContext`), `session.mcp`
(`stdio` / `http`), `session.additionalDirectories`, and `session.delete`;
`AgentCapabilities` adds `auth`. `ClientCapabilities` carries `_meta` and
nothing else — *"stable v2 defines no standard client capability fields"* is
literally true.

**Unstable-only, and nothing may be built on it** (`acp-v2.meta.unstable.json`,
routed by name and side only): `elicitation/create`, `elicitation/complete`,
`mcp/connect`, `mcp/message`, `mcp/disconnect`, `session/fork`,
`providers/list` / `providers/set` / `providers/disable`, `nes/*`, and
`document/did*`. Elicitation in particular is **not** in the stable surface of
the vendored `schema-v2.0.0-alpha.2`, though upstream `main` has already
promoted it — expect it stable on the next re-vendor.

**`session/update` carries everything that happens** — the sixteen variants the
schema lists, in order: `user_message_chunk`, `user_message`,
`agent_message_chunk`, `agent_message`, `agent_thought_chunk`, `agent_thought`,
`state_update`, `tool_call_content_chunk`, `tool_call_update`,
`terminal_update`, `terminal_output_chunk`, `plan_update`,
`available_commands_update`, `config_option_update`, `session_info_update`,
`usage_update` — plus an explicit unknown-discriminator fallback.

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
   **An upsert cannot delete a message.** `UserMessage` / `AgentMessage` /
   `AgentThought` require only `messageId`, and the only removal the schema
   offers is clearing `content` with `null` or `[]`: *"`content` is replaced as a
   whole array; send `[]` or `null` to clear it."* There is no tombstone, no
   `deleted` flag, and no `session/update` variant that retracts a `messageId`.
   Whole-session removal is `session/delete`, gated on
   `capabilities.session.delete`, and is a different thing from `session/close`.
4. **No client filesystem, no client-run terminals.** `fs/*` and `terminal/*` are
   removed, and *"stable v2 defines no standard client capability fields."* Agents
   reach the client's world through **MCP** instead.

   **The display-terminal successor is real and stable — M0 confirmed it against
   the vendored schema.** The earlier doubt came from a truncated schema fetch;
   reading `Schema/acp-v2.json` directly settles it. `TerminalUpdate` and
   `TerminalOutputChunk` are `session/update` variants (`terminal_update`,
   `terminal_output_chunk`), and `Terminal` — *"a display-only reference to an
   agent-owned terminal"* — is a variant of **`ToolCallContent`**, alongside
   `content` and `diff`. That is why the content page's five variants
   (`text` / `image` / `audio` / `resource` / `resource_link`) showed no
   terminal: those are `ContentBlock`, the message-level union, and the terminal
   reference does not live there. `TerminalOutputChunk.data` is *"independently
   base64-encoded terminal output bytes"*; the schema carries no input, resize,
   interrupt, kill, wait, release, or execution surface. `TerminalId` also
   appears on `CommandPermissionSubject` as *"the associated terminal, when
   already known."*
5. **Replay is first-class.** `session/load` is gone; `session/resume` handles both
   plain reconnect and, with `replayFrom: {"type": "start"}`, full history replay
   as ordinary session updates. `ReplayFrom` has exactly one known variant,
   `start`, plus the unknown fallback.

### Conventions the type system should enforce

Absolute paths everywhere, `camelCase` object keys, `snake_case` discriminator
values. Unknown enum and tagged-union values must be **accepted and preserved
when proxying**; values beginning with `_` are implementation-specific, and
unknown non-underscore values are reserved for future versions. `_meta` follows
patch semantics in updates.

v2 gives absolute paths a first-class `AbsolutePath` definition, so the
invariant rides the `$ref` and the generator needs no per-field override table —
`AbsolutePath` is simply listed as hand-written in `GeneratorConfig.acpV2`.

**There is no 1-based line-number invariant in v2.** The vendored schema has
exactly one line-valued field, `ToolCallLocation.line`, described only as
*"Optional line number within the file"* with `minimum: 0`; the v2 tool-calls
page does not state a base either. The hand-written `LineNumber` type and the
`.lineNumber` config mapping therefore have no v2 field to attach to. The
generator keeps the mechanism (still covered by `GeneratorCoreTests`) for a
revision that states the invariant in prose, but nothing uses it today, and
`LineNumber` is not restored until something needs it.

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
acknowledging immediately, no request is held open for the duration of a turn.
The one remaining long-lived request in the stable surface is the one that
genuinely waits on a human — `session/request_permission` — and it must never
block the read loop. (`elicitation/create` would join it if and when elicitation
becomes stable.)

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
- **Conventions** — relative paths must fail at decode time. (v2 states no
  line-number base, so there is no 0-based case to reject; see *Conventions*.)

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

- [x] **M0 — Vendor v2 and restart the pipeline.** `acp-v2.json` and both meta
  manifests vendored from `schema-v2.0.0-alpha.2`; `SchemaSet.acpV2` /
  `GeneratorConfig.acpV2` re-pointed; the generator taught v2's `anyOf` union
  vocabulary; plugin, content-hash no-op, and CI diff gate green. The method and
  payload inventory above is now read off the schema, and every question the
  plan had open about it — `session/delete`, the `session/update` variant list,
  display terminals, `mcp/*`, message deletion — is answered in place.
- [ ] **M1 — Types and conventions.** Generated models/unions/enums, plus the
  hand-written `JSONValue`, `AbsolutePath`, `RequestError`, and the
  `unknown(String)` fallbacks. Decode-time enforcement of absolute paths.
  Resolve the four union shapes M0 left on the placeholder seam (table under
  *Starting point*) — which for the payload-bearing catch-alls means giving each
  fallback somewhere to keep what it currently drops: `unknown(String, JSONValue)`
  for the three tagged unions, and a two-associated-value default
  (`other(String, JSONValue)` in `ValueUnionCaseModel` and
  `objectValueUnionDeclaration`) for the value union, so unknown-value
  preservation is real rather than asserted.

  **Take `SetSessionConfigOptionRequest` first.** It is the cheapest of the four
  and the most expensive to leave: it is the one deferral that untypes a *routed
  stable method's entire params object* rather than a single field. Three
  coupled generator edits, all in `SchemaGenerator.swift`:

  1. Relax `isUnknownFallbackVariant` **for the value-union family only** — a
     catch-all member the modeled variants already declare is not new payload.
     Leave it strict for tagged unions, where the three above must keep
     deferring until their fallback can carry a payload.
  2. Give `ValueUnionCaseModel` the matched discriminator, and emit
     `other(String, JSONValue)` from `objectValueUnionDeclaration`.
  3. Drop the `objectValueUnionModel` guard that rejects a default variant
     declaring the discriminator. It is correct only while the default case
     cannot re-encode a tag; step 2 is exactly what makes it obsolete. Skipping
     this makes generation *throw* rather than emit.

  Then add the round-trip test in the same change — decode
  `{"type": "_vendor_x", "value": 42}`, re-encode, assert both members survive.
  Nothing currently exercises generated runtime types, but the harness is
  already there: `ACPGenerateTests` depends on `ACPGenerateCore`, which itself
  depends on `FoundationModelsACP`, so the generated module is linked into the
  test binary today and the test costs one `import`. Do not defer this step —
  an unexercised two-associated-value `Codable` case is the
  "preservation asserted rather than real" failure this milestone exists to
  close.

  M0 left it deferred because none of that is M0's remit — vendor, re-point,
  verify — and deferring costs nothing that is not recoverable: `JSONValue` is
  lossless, and M1 lands before M2, so nothing generates against the placeholder
  in between. Do this one first, then the tagged-union three, so both families
  get the same answer to the same question.
- [ ] **M2 — Role protocols.** `Agent` (ten methods plus `session/cancel`) and
  `Client` (`session/request_permission` plus the `session/update`
  notification). Capability-gated methods default to method-not-found.
  *Blocked on the M1 seam:* `session/set_config_option` has no params type until
  `SetSessionConfigOptionRequest` resolves — generated against today's output it
  would emit `setSessionConfigOption(_ params: JSONValue)`.
- [ ] **M3 — Connections and transports.** Both connection sides, the read loop,
  continuation correlation, per-request `Task` dispatch, fail-loud disconnect,
  stdio and `InMemoryTransport`.
- [ ] **M4 — Initialization and capabilities.** `initialize` with required `info`
  and `capabilities`, empty-object support markers, nested
  `capabilities.session.*` (including `mcp.stdio` / `mcp.http` /
  `additionalDirectories`), and `protocolVersion: 2`.
  *Blocked on the M1 seam:* `InitializeResponse.authMethods` is `[JSONValue]?`
  until `AuthMethod` resolves.
- [ ] **M5 — Sessions.** `session/new` / `list` / `resume` / `close` / `delete`, `mcpServers`
  on new and resume, `replayFrom`, config options.
  *Blocked on the M1 seam:* `ResumeSessionRequest.replayFrom` is `JSONValue?`
  until `ReplayFrom` resolves, and config options are untyped end to end —
  `SessionConfigOption` on the listing side, the whole
  `session/set_config_option` params object on the setting side.
- [ ] **M6 — Prompt lifecycle.** `session/prompt` immediate ack, `state_update`
  states, `stopReason` on idle, `session/cancel` → cancelled idle.
- [ ] **M7 — Updates.** All sixteen `session/update` variants: messages and
  chunks with `messageId`, tool-call upserts and content chunks, terminal
  upserts and base64 output chunks (confirmed stable in M0), plans, available
  commands, config options, session info, usage.
  *Blocked on the M1 seam:* `PlanUpdate.plan` is `JSONValue` — required, so
  every `plan_update` carries an untyped payload — until `PlanUpdateContent`
  resolves.
- [ ] **M8 — Permissions.** `session/request_permission` with `title` /
  `description` / tagged `subject` (`tool_call` or `command`, the latter
  optionally naming a `terminalId`). **Elicitation is out of scope until it is
  stable** — `elicitation/create` and `elicitation/complete` are unstable-only
  in the vendored `schema-v2.0.0-alpha.2`, with no request/response types in the
  stable schema to generate from. Pick this up when a re-vendor promotes them.
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
