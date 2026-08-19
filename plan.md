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
  decode/encode of generated unions and their unknown fallbacks — **done in
  M1**, in the new `Tests/FoundationModelsACPTests` target, alongside
  `JSONValueTests`, `WireInvariantTests`, `MetaFieldTests`, and
  `RequestErrorTests`.
- `ForgivingDecodingTests` — **done in M1**, same target.
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
the fallback v1 left implicit and the generator already synthesizes.
Generation aborted on that construct. The generator now
recognizes it, mapping it onto whatever fallback each union family already
emits, and reads `anyOf` string enums with an open tail.

**Where the schema's catch-all carries more than the tag, the fallback carries
it too.** M0 left four definitions deferring to raw `JSONValue` rather than
truncate what their catch-all declared; **M1 resolved all of them**, along with
the two other deferred shapes beside them. What changed, and why each mattered:

| Shape | Definitions | What M1 did |
|---|---|---|
| Integer enum with an open tail | `ErrorCode` | The enum stage became scalar rather than string-only: one `enumRawKinds` table maps the JSON `type` keyword to the emitted raw type, so `ErrorCode` emits `unknown(Int)` beside its eight named codes. An integer cannot name its own case, so those come from each variant's `title`. |
| Base object plus a tagged (`allOf`-payload) union | `DiffChange`, `SessionConfigOption` | A new `.objectTaggedUnion` family: the base object becomes a struct with a nested `Payload` enum whose payload flattens beside the base members. Fixed name rather than one derived from the discriminator, because `SessionConfigOption`'s discriminator is `type` and `SessionConfigOption.Type` is metatype syntax. |
| Tagged union whose catch-all carries payload | `AuthMethod`, `PlanUpdateContent`, `ReplayFrom` | The synthesized fallback became `unknown(String, JSONValue)`, holding the raw object *less* the discriminator. This is an emitter-wide change, so all eleven stand-alone tagged unions gained it — a `session/update` variant a newer peer adds was being truncated too. |
| Object plus a value union whose catch-all leaves the tag unpinned | `SetSessionConfigOptionRequest` | The value union's default case gained the matched tag: `other(String, JSONValue)`. `session/set_config_option` now routes a typed params object. |
| Pre-existing (also deferred under v1) | `AgentResponse`, `ClientResponse`, `EmbeddedResourceResource`, `ExtRequest`, `ExtResponse`, `ExtNotification`, `RequestID`, `SessionConfigSelectOptions` | Still deferred, and deliberately. Three are the extension escape hatch, which states no shape at all; the other five are untagged unions whose branches pin no discriminator, so there is nothing to key a Swift enum on. |

The raw payload is the variant's object minus the members something else already
owns — the discriminator, which the case holds as its own associated value, and
for a nested union the base object's members, which the struct decodes and
re-encodes itself. Keeping a second copy of either is how a stale value wins on
re-encode: two keyed containers over one encoder share an object, and the later
write wins. `JSONValue.init(from:excludingMembers:)` drops those names on the
way in and `encodeMembers(to:reserving:)` rejects them on the way out — the
fallback cases are public and take two associated values, so a payload built in
Swift, unlike one decoded from the wire, can claim a name it does not own.

`Unresolved.generated.swift` is down from 15 placeholders to those 8, and
`VendoredSchemaTests.onlyTheDeliberatelyFreeFormDefinitionsStayUntyped` pins the
list by name, so a definition sliding back onto the seam has to be spelled out
there to pass.

**The unreachable generated surface, before and after.** M0 counted 26
declarations in `Sources/FoundationModelsACP/Generated/` that nothing else in
the generated surface referenced. Ten of them were reachable only through the
rows above, and resolving those rows was M1's completion signal; the count is
now 16, and the difference is exactly those ten — the eight structs
`AuthMethodAgent`, `DiffPathChange`, `DiffPathPairChange`, `PlanItems`,
`ReplayFromStart`, `SessionConfigBoolean`, `SessionConfigId`,
`SessionConfigSelect`, and the two enums `DiffFileType` and
`SessionConfigOptionCategory`. The 16 that remain are the groups the triage said
would:

- **Four hang off the still-deferred row.** `TextResourceContents` and
  `BlobResourceContents` are `$ref`'d only by `EmbeddedResourceResource`;
  `SessionConfigSelectGroup` only by `SessionConfigSelectOptions`; and
  `ACPError` by `AgentResponse` and `ClientResponse` — plus twice more from the
  schema root's batch-response branches, four inbound `$ref`s in all. The last
  is easy to file under the envelope types below — it is not one. The schema
  does `$ref` it, from two placeholders, so it is reachable in principle even
  though nothing plans to resolve them.
- **Five are those placeholders, themselves orphans** — `AgentResponse`,
  `ClientResponse`, `ExtRequest`, `ExtResponse`, `ExtNotification`. The other
  three (`EmbeddedResourceResource`, `RequestID`, `SessionConfigSelectOptions`)
  are referenced, so they are not.
- **Five are JSON-RPC envelope types nothing will ever reach** — `AgentRequest`,
  `AgentNotification`, `ClientRequest`, `ClientNotification`,
  `ProtocolLevelNotification`. Each is `$ref`'d exactly twice and only from the
  schema root's message envelope — the four request and notification types from
  their side's single-message branch and its batch-call branch,
  `ProtocolLevelNotification` from both batch-call branches — and by no other
  definition. That position is not what distinguishes them: `AgentResponse` and
  `ClientResponse`, in the group immediately above, are also referenced only
  from the root and by no other definition — once each rather than twice, since
  the batch-response branches reach `ACPError` directly instead of `$ref`ing
  them. What distinguishes the five is that the routing table supersedes them.
- **Two are the routing roots** — `ACPMethodTable` and `Unstable`. Nothing in
  the generated surface references them by design; consumers do.

## What v2 is, in one page

*Read off the vendored `Schema/acp-v2.meta.json` and `acp-v2.json`, not from the
docs pages — M0 reconciled the two and the schema wins.*

**Agent methods** (Client → Agent): `initialize`, `auth/login`, `auth/logout`,
`session/new`, `session/list`, `session/resume`, `session/close`,
`session/delete`, `session/prompt`, `session/set_config_option`.
**Agent notifications** (Client → Agent): `session/cancel`.

**Client methods** (Agent → Client): `session/request_permission`,
`elicitation/create`.
**Client notifications** (Agent → Client): `session/update`,
`elicitation/complete`.

**Protocol-level**: `$/cancel_request`.

That is the whole stable surface — and the Client half is *four entry points*.
When `capabilities.session` is advertised, an agent must implement the baseline:
`session/new`, `session/list`, `session/resume`, `session/close`,
`session/prompt`, `session/cancel`, `session/update`. Capability sub-objects are
`session.prompt` (`audio` / `image` / `embeddedContext`), `session.mcp`
(`stdio` / `http`), `session.additionalDirectories`, and `session.delete`;
`AgentCapabilities` adds `auth`. `ClientCapabilities` carries `elicitation`
and `_meta`. The `elicitation` field gates the elicitation methods; an omitted
field and `null` both mean the client gives no elicitation support.

**Unstable-only, and nothing may be built on it** (`acp-v2.meta.unstable.json`,
routed by name and side only): `mcp/connect`, `mcp/message`, `mcp/disconnect`,
`session/fork`, `providers/list` / `providers/set` / `providers/disable`,
`nes/*`, and `document/did*`. Elicitation is **stable** in the pinned upstream
commit `7a13081`: `elicitation/create` and `elicitation/complete` route on the
stable client surface, and this package implements them.

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
`JSONValue`, and `AbsolutePath`. The `unknown` fallbacks that make unknown-value
preservation real *are* generated — one per union, synthesized by the emitter
rather than written into the schema. `RequestError` is a `typealias` for the
generated `ACPError` plus an `Error` conformance and its named constructors.

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
Two long-lived requests in the stable surface genuinely wait on a human —
`session/request_permission` and `elicitation/create` — and they must never
block the read loop.

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
- [x] **M1 — Types and conventions.** Generated models, unions, and enums from
  the v2 schema, plus the hand-written pieces that are deliberately never
  generated: `JSONValue`, `AbsolutePath`, `ACP`, and `RequestError`. Every
  deferred union shape resolved — see the table under *Starting point* for what
  each one needed.

  **`RequestError` is a `typealias` for the generated `ACPError`**, plus an
  `Error` conformance and one named constructor per predefined code. v2 defines
  the error object in the schema, so a second hand-written copy of code, message,
  and `data` would only be able to disagree with it; and now that `ErrorCode`
  generates, no code number is restated anywhere in hand-written source.

  **Absolute paths ride the schema's own `AbsolutePath` `$def`**, so the
  invariant reaches every path field through its `$ref` with no per-field
  configuration. **No line-number invariant** — see *Conventions* above.

  **One conformance gap, deliberately left for M7.** Six upsert `_meta` fields
  say "Omitted means no metadata update; `null` is an explicit clear signal",
  and the same three-state rule governs the other fields of `UserMessage`,
  `AgentMessage`, `AgentThought`, `TerminalUpdate`, and `ToolCallUpdate`. A
  Swift `Optional` has two states, so `null` currently reads as omitted.
  `MetaFieldTests.upsertMetaCannotYetDistinguishOmittedFromNull` pins the gap so
  it stays visible.

- [x] **M2 — Role protocols.** `Agent` (ten methods plus `session/cancel`) and
  `Client` (`session/request_permission` plus the `session/update`
  notification). Capability-gated methods default to method-not-found.
- [x] **M3 — Connections and transports.** Both connection sides, the read loop,
  continuation correlation, per-request `Task` dispatch, fail-loud disconnect,
  stdio and `InMemoryTransport`.
- [x] **M4 — Initialization and capabilities.** `initialize` with required `info`
  and `capabilities`, empty-object support markers, nested
  `capabilities.session.*` (including `mcp.stdio` / `mcp.http` /
  `additionalDirectories`), and `protocolVersion: 2`.
- [x] **M5 — Sessions.** `session/new` / `list` / `resume` / `close` / `delete`, `mcpServers`
  on new and resume, `replayFrom`, config options.
- [x] **M6 — Prompt lifecycle.** `session/prompt` immediate ack, `state_update`
  states, `stopReason` on idle, `session/cancel` → cancelled idle.
- [x] **M7 — Updates.** All sixteen `session/update` variants: messages and
  chunks with `messageId`, tool-call upserts and content chunks, terminal
  upserts and base64 output chunks (confirmed stable in M0), plans, available
  commands, config options, session info, usage.
  *Carried in from M1:* the six upsert types have three-state patch semantics
  (omitted leaves unchanged, `null` clears, a value replaces) that a Swift
  `Optional` cannot express. M1 typed their payloads; expressing the third
  state is this milestone's.
- [x] **M8 — Permissions.** `session/request_permission` with `title` /
  `description` / tagged `subject` (`tool_call` or `command`, the latter
  optionally naming a `terminalId`). **Elicitation is now stable and
  implemented** — the pinned upstream commit `7a13081` promotes
  `elicitation/create` and `elicitation/complete` to the stable client
  surface. `Client` carries `createElicitation` and `elicitationComplete`,
  both connections route them, and `ElicitationLifecycleTests` covers the
  lifecycle. (At M8 time the vendored `schema-v2.0.0-alpha.2` held them
  unstable-only, so M8 deferred them; the re-vendor picked them up.)
- [x] **M9 — Replay and interop.** `ReplayTransport` recovered from git history
  (protocol-version-agnostic, as M3's connection layer was) and re-tested on
  its own mechanics, plus a session-level fixture proving unrecognized enum
  values and `_`-prefixed extensions round-trip losslessly across a whole
  transcript, not one decoded value at a time. A live-`InMemoryTransport`
  golden fixture (`GoldenSessionEndToEndTests`) covers the representative full
  session end to end — `initialize`, `session/new`, `session/prompt`, streamed
  thought/message chunks, a tool call with a content chunk and a display
  terminal reference, the terminal's own upserts, a
  `session/request_permission` round trip, and the closing `idle` — captured
  byte-for-byte against a committed golden fixture.

  **`ReplayTransport` deliberately does not drive the permission-inclusive
  session.** Its whole script is queued into `bytes` at construction rather
  than paced by consumption, so a live `Connection`'s read loop can race ahead
  of an outbound call's pending-continuation registration — safe for scripts
  where the code under test only answers inbound calls and emits
  notifications, unsafe for anything requiring a peer's *reactive* answer to
  an outbound request. The representative session's
  `session/request_permission` round trip is exactly that case, so it runs
  over a live pair instead; `OutOfOrderConvergenceTests` and the unknown-value
  transcript stay with `ReplayTransport` because neither needs one.

  **Routing coverage extends M2's static `RoleRoutingTests`
  (`RoleDispatchTests.swift`) rather than duplicating it.** That suite pins
  `ACPMethodTable`'s own internal consistency but never calls
  `AgentSideConnection`/`ClientSideConnection`'s hand-written dispatch
  switches — precisely where the real TS-SDK `setSessionModel` /
  `session/set_mode` bug class lives. `RoutingCoverageTests` drives every
  stable agent-side and client-side handler through a live
  connection with recording stand-ins, confirmed sensitive by two separate
  mutations (a swapped case-label pair, and a shadowed case) during
  development, both reverted afterward.

  **Third-party interop is explicitly deferred, not silently skipped or
  faked.** No real v2 agent or client exists yet to round-trip against — both
  intended consumers (`FoundationModelsACPAgent`, `FoundationModelsACPClient`)
  are themselves unimplemented, and this is a draft schema with no known
  independent implementation. A mock "interop" test against our own `Agent`/
  `Client` would only rename a unit test and cannot falsify "we implement v2"
  versus "we implement our reading of v2" — the entire point of this
  criterion. See `Tests/FoundationModelsACPTests/ThirdPartyInterop.swift` for
  the full reasoning and the follow-up task carding the real round trip once
  a peer exists.

  This closes the last open milestone. Every wire-layer guarantee this plan
  set out to establish — types, both role protocols, connections and
  transports, initialization, sessions, the prompt lifecycle, all sixteen
  `session/update` variants, permissions, and now replay/interop — has test
  coverage exercising the real generated v2 types end to end, not just
  hand-asserted shapes.

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
