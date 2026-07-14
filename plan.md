# FoundationModelsACP — package spec

**Status:** v0.6 · **Target:** Swift 6, macOS 27, Apple Silicon · **Updated:** 2026-07-14

A standalone Swift Package — **`FoundationModelsACP`** — implementing the Agent Client Protocol (ACP)
— idiomatic Swift analogs of the ACP types, both protocol roles, and JSON-RPC-over-stdio transport —
plus a **FoundationModels bridge** (§7) that turns anything speaking the WWDC 2026 `LanguageModel`
interface — Apple's on-device model, PCC, or a conforming Claude / Gemini / MLX / llama — into an ACP
agent, so Apple-native → ACP is one wrapper. The name leads with the bridge because that is the
package's flagship: it is the one ACP implementation that makes an Apple-native `LanguageModelSession`
an ACP agent for free. One target, macOS 27. Reusable and open-sourceable, like the AgentViewKit and
EditorKit packages. The runtime uses it for its ACP agent surface (runtime-spec §4.3); it has no
dependency on the runtime or the registry.

---

## 1. Why a Swift package

ACP is JSON-RPC over stdio at the app/editor surface, and it's **full-duplex and notification-first**
— a prompt turn is a long-lived request during which the agent streams many `session/update`
notifications and calls back into the client (files, permission, terminals), all concurrently. That
streaming, bidirectional surface belongs in Swift with the app, not marshaled across UniFFI per
message. **Rust is the source of truth** — the official SDKs (Rust, TypeScript, Python, Kotlin, Java)
are all generated from the Rust `agent-client-protocol-schema` crate's emitted JSON Schema. There is
**no official Swift SDK**; the three community ones (`aptove/swift-sdk`, `wiedymi/swift-acp`,
`rebornix/acp-swift-sdk`) are all pre-1.0, hand-write their types (so they lag the schema), and are
partial — none covers both roles with generated types — so we build our own and steal their good ideas:
actor-based connection, `AsyncStream` for `session/update`, and an in-memory test transport. We license
**Apache-2.0** to match the spec and every reference SDK. Our data types are generated from ACP's
published JSON schema (the `schema/v1/schema.json` + `meta.json` artifacts attached to the
`agentclientprotocol` org's schema releases — the project relocated there from `zed-industries`, which
now hosts only the schema crate) so they track the spec automatically; the connection, role protocols,
and transport are hand-written, **porting the classic Rust async-trait connection design** (faithful
through `rust-sdk` v0.10.4 — symmetric `*SideConnection` objects, oneshot + pending-map JSON-RPC
engine), not the heavier `Role`/`Builder`/actor rewrite in runtime 1.0.0, which is more machinery than
Swift's native concurrency needs.

**Scope.** One target: both roles (`Agent` and `Client`), the full v1 type surface, stdio transport, a
build-time codegen step (incremental; output checked in, §6), and the FoundationModels bridge (§7).
macOS 27, so FoundationModels is always available — no reason to split it out.

---

## 2. Type-mapping rules (schema → Swift)

The generator turns the ACP JSON schema into idiomatic Swift, not a literal transliteration:

- **Tagged unions** (`oneOf` with a discriminator: `type`, `kind`, `sessionUpdate`) → Swift `enum`
  with associated values + hand-rolled `Codable` keyed on the discriminator.
- **Objects** → `struct` with `Codable` and explicit `CodingKeys` (wire is camelCase: `sessionId`,
  `toolCallId`).
- **String enums** (`ToolKind`, `ToolCallStatus`, `StopReason`, permission kinds) → a Swift `enum`
  with **hand-rolled `Codable`** that maps the known wire strings and routes anything unrecognized to
  an `unknown(String)` case, so a newer peer's value can't crash decoding. (A raw-value `enum: String`
  can't carry that payload, so these are hand-rolled rather than raw-value enums.)
- **ID newtypes** (`SessionId`, `ToolCallId`, `PermissionOptionId`, …) → distinct
  `RawRepresentable` Swift structs, never bare `String` — the type system prevents mixing IDs.
- **`_meta` and free-form fields** (`rawInput`, `rawOutput`, MCP server env) → `JSONValue`, a small
  enum over arbitrary JSON. `_meta` is preserved round-trip and never interpreted.
- **Capability-gated optional fields** → Swift optionals; absence = unsupported.
- **Forgiving decoding for negotiated/optional surfaces.** Capability and `info` objects decode with
  defaults-on-error (the Rust SDK uses `serde_as` `DefaultOnError` / `VecSkipError`): an unknown or
  malformed capability field must degrade to "unsupported", never fail the `initialize` handshake. On
  encode, omit `nil` (the equivalent of `skip_serializing_none`) — don't emit `null` for absent fields.
- **`protocolVersion` is a wire integer, not a string.** Model it as a `ProtocolVersion` newtype over
  `UInt16` that encodes/decodes as the bare integer `1` (`.v1 = 1`, `.latest = .v1`); it must **reject**
  `"v1"` / `"1.0.0"`. The doc set and schema dir are *labelled* v1, but the value on the wire is `1`.
- **Versioning** — target ACP **v1** (`protocolVersion == 1`); the version bumps only for breaking
  changes, while everything else grows via capabilities + `_meta`. Generated code is checked in and
  regenerated on a schema bump, not on every build.

---

## 3. Core type analogs

Representative — the generator emits the full set; these are the load-bearing ones.

```swift
// IDs — distinct types, not String
public struct SessionId: RawRepresentable, Codable, Hashable, Sendable { public let rawValue: String }
public struct ToolCallId: RawRepresentable, Codable, Hashable, Sendable { public let rawValue: String }
public struct TerminalId: RawRepresentable, Codable, Hashable, Sendable { public let rawValue: String }

// ProtocolVersion — encodes/decodes as a bare integer (wire value 1), NOT "v1"/"1.0.0"
public struct ProtocolVersion: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: UInt16
    public static let v1 = ProtocolVersion(rawValue: 1)
    public static let latest = v1
}

// ContentBlock — baseline Text + ResourceLink; others gated by PromptCapabilities
public enum ContentBlock: Codable, Sendable {
    case text(TextContent)
    case image(ImageContent)
    case audio(AudioContent)
    case resource(EmbeddedResource)
    case resourceLink(ResourceLink)
}

// SessionUpdate — the streaming notification payload (discriminator: `sessionUpdate`)
public enum SessionUpdate: Codable, Sendable {
    case userMessageChunk(ContentBlock)
    case agentMessageChunk(ContentBlock)
    case agentThoughtChunk(ContentBlock)
    case toolCall(ToolCall)
    case toolCallUpdate(ToolCallUpdate)
    case plan(Plan)
    case availableCommandsUpdate([AvailableCommand])
    case usageUpdate(UsageUpdate)              // token/usage accounting for the turn
    case currentModeUpdate(SessionModeId)      // agent switched the active session mode
}

// JSON-RPC errors — standard codes plus ACP's two custom ones; carry structured `data`, never
// smuggle JSON through the message string.
public struct RequestError: Error, Codable, Sendable {
    public var code: Int           // -32700 parse, -32600 invalid request, -32601 method-not-found,
    public var message: String     // -32602 invalid params, -32603 internal,
    public var data: JSONValue?    // ACP: -32000 authRequired, -32002 resourceNotFound
}

// Tool calls — string enums carry unknown(String) for forward-compat; Codable is hand-rolled
// (a raw-value enum can't hold the unknown payload), mapping wire strings like "in_progress".
public enum ToolKind: Codable, Sendable, Hashable {
    case read, edit, delete, move, search, execute, think, fetch, other
    case unknown(String)
}
public enum ToolCallStatus: Codable, Sendable, Hashable {
    case pending, inProgress, completed, failed
    case unknown(String)
}
public struct ToolCall: Codable, Sendable {
    public var toolCallId: ToolCallId
    public var title: String
    public var kind: ToolKind?
    public var status: ToolCallStatus?
    public var locations: [ToolCallLocation]?
    public var rawInput: JSONValue?
    public var content: [ToolCallContent]?
}
public struct ToolCallUpdate: Codable, Sendable {   // all optional → partial update
    public var toolCallId: ToolCallId
    public var status: ToolCallStatus?
    public var content: [ToolCallContent]?
    public var rawOutput: JSONValue?
}
public enum ToolCallContent: Codable, Sendable {
    case content(ContentBlock)
    case diff(Diff)
    case terminal(TerminalId)          // { type: "terminal", terminalId }
}

// Plan, stop reason
public struct PlanEntry: Codable, Sendable { public var content: String; public var status: PlanEntryStatus; public var priority: PlanEntryPriority? }
public struct Plan: Codable, Sendable { public var entries: [PlanEntry] }
public enum StopReason: Codable, Sendable { case endTurn, maxTokens, refusal, cancelled; case unknown(String) }  // wire: end_turn, max_tokens, …

// Permission
public struct PermissionOption: Codable, Sendable { public var optionId: PermissionOptionId; public var name: String; public var kind: PermissionOptionKind }
public enum PermissionOptionKind: Codable, Sendable { case allowOnce, allowAlways, rejectOnce, rejectAlways; case unknown(String) }  // wire: allow_once, …
public enum RequestPermissionOutcome: Codable, Sendable { case selected(PermissionOptionId); case cancelled }

// Capabilities (negotiated in initialize)
public struct PromptCapabilities: Codable, Sendable { public var image: Bool?; public var audio: Bool?; public var embeddedContext: Bool? }
public struct AgentCapabilities: Codable, Sendable { public var promptCapabilities: PromptCapabilities?; public var loadSession: Bool? /* … */ }

// Free-form JSON for _meta / rawInput / rawOutput
public enum JSONValue: Codable, Sendable {
    case null, bool(Bool), number(Double), string(String), array([JSONValue]), object([String: JSONValue])
}
```

---

## 4. Role protocols

Hand-written. Implement `Agent` to be driven by an editor; implement `Client` to drive an agent.

```swift
public protocol Agent: Sendable {
    func initialize(_ p: InitializeRequest) async throws -> InitializeResponse
    func newSession(_ p: NewSessionRequest) async throws -> NewSessionResponse
    func loadSession(_ p: LoadSessionRequest) async throws -> LoadSessionResponse   // optional cap
    func prompt(_ p: PromptRequest) async throws -> PromptResponse                  // returns StopReason
    func cancel(_ p: CancelNotification) async                                       // notification
    func authenticate(_ p: AuthenticateRequest) async throws -> AuthenticateResponse // optional
    func setSessionConfigOption(_ p: SetSessionConfigOptionRequest) async throws -> SetSessionConfigOptionResponse // optional; supersedes session/set_mode
    @available(*, deprecated, message: "Use setSessionConfigOption; session/set_mode is being removed")
    func setSessionMode(_ p: SetSessionModeRequest) async throws -> SetSessionModeResponse // deprecated
    // Session management — stabilized in the current schema (newer than the published TS/Rust-classic SDKs)
    func listSessions(_ p: ListSessionsRequest) async throws -> ListSessionsResponse   // optional
    func resumeSession(_ p: ResumeSessionRequest) async throws -> ResumeSessionResponse // optional
    func deleteSession(_ p: DeleteSessionRequest) async throws                          // optional
    func closeSession(_ p: CloseSessionRequest) async throws                            // optional
    func logout(_ p: LogoutRequest) async throws                                        // optional
}

public protocol Client: Sendable {
    // Notification the agent FIRES at the client — no response. The dominant traffic.
    func sessionUpdate(_ n: SessionNotification) async               // session/update (notification)
    // Requests the agent makes back INTO the client, mid-turn:
    func requestPermission(_ p: RequestPermissionRequest) async throws -> RequestPermissionResponse
    func readTextFile(_ p: ReadTextFileRequest) async throws -> ReadTextFileResponse   // fs/read_text_file
    func writeTextFile(_ p: WriteTextFileRequest) async throws                         // fs/write_text_file
    // Terminals — the client owns them; the agent drives them. Capability-gated.
    func createTerminal(_ p: CreateTerminalRequest) async throws -> CreateTerminalResponse   // terminal/create → terminalId
    func terminalOutput(_ p: TerminalOutputRequest) async throws -> TerminalOutputResponse   // snapshot: output + truncated + exitStatus?
    func waitForTerminalExit(_ p: WaitForExitRequest) async throws -> WaitForExitResponse     // long-lived: resolves on process exit
    func killTerminal(_ p: KillTerminalRequest) async throws                                  // terminal/kill
    func releaseTerminal(_ p: ReleaseTerminalRequest) async throws                            // terminal/release
}
```

`session/prompt` is **long-lived**: it stays pending for the whole turn while the agent fires many
`session/update` notifications and issues the reverse-direction requests above; its response (a
`StopReason`) arrives only at turn end. `session/update` is a *notification the agent sends on the
connection*, not a value returned from `prompt`. Terminals are the symmetric case in the other
direction — the client runs the process and streams its output to its own UI, while the agent reads
that stream via `terminalOutput` (snapshot, bounded by `outputByteLimit` + `truncated`) and
`waitForTerminalExit` (blocks until exit), and embeds the `terminalId` in a `tool_call` so the client
renders live output.

Method-name mapping is internal: `session/new` → `newSession`, `fs/read_text_file` → `readTextFile`,
`terminal/create` → `createTerminal`, etc. Optional methods are gated by advertised capabilities
(`clientCapabilities.terminal`, `fileSystem`, …); unsupported calls return JSON-RPC
method-not-found.

**Connections.** Two symmetric objects wrap one bidirectional byte stream. Each takes a **factory
closure**, not a finished handler, so the handler can capture its own connection and issue the reverse
calls (the pattern both reference SDKs use — without it an `Agent` has no handle to fire
`sessionUpdate`/`requestPermission` back at the client):
- `AgentSideConnection(stream:) { conn in MyAgent(conn) }` — dispatches incoming Client→Agent calls to
  your `Agent`; the `conn` it hands you exposes the outbound calls the agent makes *into* the client
  (`sessionUpdate`, `requestPermission`, `fs/*`, `terminal/*`).
- `ClientSideConnection(stream:) { agent in MyClient(agent) }` — the editor/host side; drives an agent
  and dispatches its Agent→Client calls/notifications to your `Client`.

Both sit on one shared full-duplex JSON-RPC `Connection` (§5).

**Wire invariants enforced at the type boundary.** All file paths crossing the protocol are
**absolute** and all line numbers are **1-based** — encode these in the path/location types (e.g. an
`AbsolutePath` newtype) so a relative path or 0-based line is a compile- or decode-time error, not a
silent interop bug. Content chunks correlate by message id and tool calls by `toolCallId`
(`pending → in_progress → completed/failed`); the public API surfaces those ids so consumers never
have to infer ordering.

---

## 5. Connection model — two concurrent streams, not request/response

ACP is **full-duplex and notification-first**. A connection is two independent streams of JSON-RPC
messages flowing at once; either peer may send **requests** (carry an `id`, expect a response) and
**notifications** (no `id`, no response) at any time, with multiple requests in flight in both
directions simultaneously. Designing this as request/response with streaming bolted on is the wrong
shape — the dominant traffic is notifications, and long-lived requests overlap freely.

**The shape of a prompt turn.** The client sends `session/prompt` (one request) and it stays pending
for the entire turn. During that window the agent:
- fires **many `session/update` notifications** — `agent_message_chunk`, `agent_thought_chunk`,
  `tool_call`, `tool_call_update`, `plan`, `available_commands_update` (discriminator
  `sessionUpdate`); none of these expect a response, and
- concurrently issues **reverse-direction requests** into the client — `fs/read_text_file`,
  `fs/write_text_file`, `session/request_permission`, `terminal/*` — each awaiting a response from
  the client while the prompt request is still open.

Only at turn end does the agent answer the original `session/prompt` with a `StopReason`. So the
turn's content is a notification stream; the request's "response" is just the terminator.

**The dominant stream → `AsyncStream`.** The client side surfaces per-session `session/update` as an
`AsyncStream<SessionUpdate>` — the bridge AgentViewKit's `AgentViewSession` adapter consumes. The
agent side simply *fires* these (no await). This is the primary API, not an edge case.

**Terminals are the mirror stream.** `terminal/create` returns a `terminalId`; the **client** runs
the process and streams output to its own UI; the **agent** consumes that stream by polling
`terminal/output` (a bounded snapshot) and/or awaiting `terminal/wait_for_exit` (a long-lived
request that resolves on exit), then `terminal/release`. Output is bounded by `outputByteLimit` with
a `truncated` flag. So the client produces a stream the agent reads, mirroring how the agent produces
the `session/update` stream the client reads — two streams, opposite directions.

**Implementation.** One read loop per connection dispatches each inbound message by kind:
request → role handler → send a response keyed by `id`; notification → route to the handler /
per-session `AsyncStream`; response → resolve the pending continuation for that `id`. Correlation is a
monotonic numeric id + a `[RequestID: CheckedContinuation]` map held inside the connection `actor`,
which also serializes writes (no separate write queue needed). **Each inbound request is dispatched as
its own `Task`** — this is *why* a slow `session/prompt` doesn't head-of-line-block an incoming
`session/cancel`, `request_permission`, or `fs/*` callback; cancellation only works because requests
run concurrently. **Long-lived requests** (`session/prompt`, `terminal/wait_for_exit`) are just
suspended continuations — they must never block the read loop or other in-flight traffic.

**Fail loud on disconnect, never hang (a real TS-SDK gap).** When the read loop hits EOF or the stream
errors, **reject every pending continuation** with a connection-closed error and finish the
`AsyncStream`s — the published TS SDK leaves outstanding callers hung forever on disconnect, which we
must not reproduce. Add a **per-request timeout** and honor Swift `Task` cancellation so a stuck peer
can't wedge a caller. Reap the child process on the client side when driving an external agent.

**Tolerate late and out-of-order notifications.** A `tool_call_update` can arrive *after* the prompt
response, or after a `session/cancel`, because the agent may emit final updates before terminating
the turn — clients SHOULD keep accepting them. The consumer must correlate every notification to the
current turn/session and drop or attribute stragglers deliberately (a real interop hazard, not
theoretical). `session/cancel` is itself a **notification**; the turn still ends through the prompt
response with `StopReason.cancelled`, possibly after more updates land.

**Framing & errors.** Newline-delimited JSON over stdio (the `ndJsonStream` framing ACP uses — this
settles the earlier framing question). **One JSON object per `\n`-delimited line, UTF-8, no embedded
newlines, and crucially NO `Content-Length` headers** — this is *not* LSP framing, so we own the codec
rather than reusing an LSP `JSONRPC` library. The read side buffers and retains a trailing partial line
across reads, and tolerates a JSON-escaped slash in method names (`session\/update`). A line that
fails to parse is logged and skipped, not fatal. JSON-RPC errors map to typed `RequestError`s (§3);
`_meta` is preserved on every message.

**stdout is sacred — the #1 field failure.** The agent MUST write nothing to stdout but valid ACP
messages; **all logging goes to stderr.** A stray `print`, a banner, a `dotenv` line, or a progress bar
on stdout corrupts framing and drops frames. The package exposes a logger/delegate and never prints to
stdout itself, and we document this loudly for agent authors.

---

## 6. Codegen pipeline — build-time, incremental, checked-in

- **Vendored schema + routing manifest.** Drop BOTH `schema/v1/schema.json` and `schema/v1/meta.json`
  into the repo (e.g. `Schema/acp-v1.json`, `Schema/acp-v1.meta.json`) — these are the canonical
  artifacts attached to the `agentclientprotocol` org's `schema-v*` GitHub releases (Rust-sourced via
  schemars), **not** a pinned SDK, which is how we pick up the full current method set (the published TS
  0.4.5 / Rust-classic SDKs lag it). Bumping ACP = dropping in the new pair; nothing else changes by
  hand.
- **Generate the method-routing table from `meta.json`, never hand-wire it.** `meta.json` carries each
  method's `x-side`/`x-method` routing, so the dispatch table is derived, not typed by hand — this
  structurally avoids the class of bug in the TS SDK where `setSessionModel` was wired to
  `session/set_mode`. Generate `unstable` methods from `meta.unstable.json` into a separate namespace.
- **Build-time, but a no-op unless the schema changed.** The generator stamps the schema's content
  hash into the generated output; on each run it compares the current schema hash to the stamp and
  exits immediately when unchanged. So a normal build does zero codegen work — real generation fires
  only when a new schema is dropped in.
- **Generated code is checked in.** `Sources/.../Generated/*.swift` plus the hash stamp are
  committed, so consumers just compile source — no plugin or tool needed to build the package. The
  committed output *is* the cache that makes "don't regenerate unless needed" free.
- **Wiring.** Generation runs as a SwiftPM **command plugin** (`swift package generate-acp`) that
  writes the checked-in files — command plugins can write to the package directory with explicit
  permission, whereas build-tool plugins are sandboxed out of the source tree. CI runs it and
  **fails on any diff**, guaranteeing the committed code always matches the vendored schema.

Hand-written, never generated: transport, connections, role protocols, `JSONValue`, the `unknown`
fallbacks, and conveniences.

---

## 7. FoundationModels bridge — Apple-native → ACP for free

The flagship use: expose anything that speaks the WWDC 2026 **`LanguageModel`** interface as an ACP
agent, so an Apple-native `LanguageModelSession` is drivable by any ACP client (Zed, our runtime, an
editor) with no glue. It's part of the package — on macOS 27 FoundationModels is always present, so
there's nothing to split out.

```swift
// One wrapper turns a FoundationModels session into an ACP Agent.
// The factory hands the agent its connection so it can fire session/update + reverse calls (§4).
try await AgentSideConnection(stream: .stdio) { conn in
    FoundationModelsAgent(
        connection: conn,
        session: LanguageModelSession(model: SystemLanguageModel.default, tools: myTools))
}.run()
```

`FoundationModelsAgent` conforms to `Agent` (§4) and maps the two models onto each other:

- **`prompt` → generation.** An ACP `session/prompt` drives `session.streamResponse(to:)`; the
  long-lived request stays open for the turn and returns a `StopReason` at the end (`.endTurn`,
  `.maxTokens`, `.refusal`, `.cancelled`).
- **`Transcript`/stream → `session/update` notifications.** As the response streams, the bridge fires
  notifications off the growing FM `Transcript`: `.response` text segments → `agent_message_chunk`;
  reasoning → `agent_thought_chunk`; `.toolCalls` → `tool_call` then `tool_call_update` as it runs →
  completes, paired with the following `.toolOutput`; a `.structure` segment / Dynamic-Profile plan →
  `plan`. This is the exact inverse of AgentViewKit's mapping (§9 there) — a Transcript becomes a
  `SessionUpdate` stream where AgentViewKit turns a `SessionUpdate` stream back into a Transcript — so
  a turn round-trips FM → ACP → FM losslessly.
- **FM tools ↔ ACP client capabilities.** A FoundationModels `Tool` runs in-process; when its work
  needs the *client's* environment — read/write a file, run a command, ask permission — the bridge
  issues the reverse-direction ACP requests (`fs/*`, `terminal/*`, `session/request_permission`)
  rather than touching the host directly, so an FM tool transparently uses the editor's filesystem and
  consent.
- **Any conformer, not just the system model.** Because it wraps the `LanguageModel` protocol, one
  bridge exposes Apple's on-device model, PCC, or a conforming Claude / Gemini / MLX / llama as an ACP
  agent — the runtime's whole backend set (runtime-spec §4.1) reachable over ACP through a single
  wrapper.

`cancel` maps to FM session cancellation; the turn still terminates through the prompt response with
`StopReason.cancelled` (§5).

### 7.1 One execution path: the bridge drives only `LanguageModelSession`

There is deliberately **no engine protocol**. `FoundationModelsAgent` always drives a real
`LanguageModelSession` — the identical code path for the one-liner above and for a full product like
**`FoundationModelsAgentHarness`** (its plan §8 moves recording/gating into a `LanguageModel`
*handle*, so its sessions are ordinary Apple sessions with nothing to hide). What varies is only
*where sessions come from*, expressed as a small provider the constructor takes:

```swift
public struct SessionProvider: Sendable {
    // Required. The cwd arrives in session/new; the provider builds the session for it
    // (config, tools, instructions) and names it.
    public var makeSession: @Sendable (AbsolutePath, [MCPServerConfig]) async throws
        -> (SessionId, LanguageModelSession)
    // Optional store hooks — presence gates the session-management capabilities.
    public var listSessions: (@Sendable () async throws -> [SessionSummary])?
    public var restoreSession: (@Sendable (SessionId) async throws -> LanguageModelSession)?
        // typically LanguageModelSession(model:tools:transcript:)
    public var deleteSession: (@Sendable (SessionId) async throws -> Void)?

    // Optional. Invoked by the bridge when a prompt turn completes, with the
    // session's final Transcript. Providers use it for turn-boundary work the
    // bridge can see but they cannot — e.g. the harness syncs Router's recording
    // model handle so the turn-final response is durably recorded (channel
    // events are write-only at the LanguageModel boundary; see the harness
    // plan §8). Absence changes nothing.
    public var onTurnEnded: (@Sendable (SessionId, Transcript) async -> Void)?
}
```

- **The one-liner stays.** `FoundationModelsAgent(connection:session:)` is sugar for a provider
  whose `makeSession` returns that session and whose hooks are nil — the flagship
  "Apple-native → ACP for free" story is unchanged on the wire and in code.
- **Overlapping `session/prompt` requests serialize naturally** on the bridge actor — a
  `LanguageModelSession` runs one turn at a time; each pending request resolves at its own turn's
  end. No queue abstraction leaks into this package.
- **Session management forwards to the hooks**; absent hooks → capability off / method-not-found
  (§4). Consumers with a durable store (the harness's `TranscriptStore`) get full `session/list` /
  `load` / `resume` / `delete`; the bare one-liner doesn't pretend to.
- **Recording is invisible here.** The harness's recording happens inside the `LanguageModel` its
  sessions are built over; this package neither knows nor cares.

This supersedes an earlier `ACPTurnEngine` draft of this section: a protocol over "turn engines"
created a second execution path through the bridge, while a session *provider* keeps exactly one.
Dependency direction is unchanged: this package keeps zero family dependencies — the provider's
currency is `LanguageModelSession` itself; consumers (the harness, the runtime) depend on this
package.

### 7.2 Spec drift since v0.5 (checked 2026-07-14)

The schema moved after this plan's 2026-06-28 draft; vendor **schema v1.19.x** and note:

- **Stabilized since:** request cancellation (v1.17.0), boolean session config options (v1.18.0);
  ID naming conventions unified across the schema (affects generated newtypes — regenerate, don't
  patch). Elicitation gained option descriptions but remains unstable (v1.19.0).
- **ACP v2 is in active RFD** (collection went Active 2026-07-02): `session/resume` (with
  `replayFrom` cursors) **replaces** `session/load`; `session/list` / `resume` / `close` become
  **baseline** whenever sessions are supported; permission requests gain required titles +
  structured subjects; typed config values; Content types align with MCP. Consequence for this
  package: the §7.1 session-management seam is not optional polish — it is the v2 baseline shape —
  and the codegen pipeline (§6) should be ready to vendor a second (v2) schema behind a clearly
  labeled unstable namespace when it publishes. Do not chase v2 RFDs into the stable surface yet.

---

## 8. Testing & evaluation — recorded transcripts + local-model evals

Two layers, both runnable in CI on Apple Silicon with no API keys or billing, because the model under
test is the on-device **`SystemLanguageModel`**. Swift Testing throughout (XCTest is legacy as of
WWDC 2026).

- **Recorded transcripts → deterministic wire tests.** The ndJSON framing (§5) makes a session
  trivially recordable: tee the byte stream to a fixture while it runs and you have a replayable script
  of the exact request/notification sequence. A `ReplayTransport` feeds a recorded client→agent script
  and asserts the agent's emitted `session/update` sequence against a golden fixture — no live model
  needed — so protocol-layer correctness (framing, ordering, tool-call pairing, late
  `tool_call_update`, `StopReason`) is tested deterministically. Capture a real run once, replay it
  forever. Alongside `ReplayTransport`, ship an **`InMemoryTransport`** (a pair of in-process
  `AsyncStream`s, as `rebornix/acp-swift-sdk` does) so a `Client` and `Agent` can be wired
  back-to-back in a single test with no pipes or subprocess — the fastest way to exercise the full
  bidirectional handshake.
- **Evaluations framework → behavioral quality.** WWDC 2026's **Evaluations framework** quantifies the
  quality of model-driven behavior as prompts change. Pointed at the `FoundationModelsAgent` over the
  local model, it answers what golden fixtures can't: does this prompt reliably produce a well-formed
  `tool_call`, the right tool, a correct structured result — and does a prompt tweak help or hurt,
  measured statistically across cases. The local model is the basis precisely because it's free,
  on-device, and reproducible enough to gate CI.
- **The two compose.** A captured run is *both* a golden fixture (deterministic replay) and an eval
  case (feed the same prompts to the live local model and score the result). One transcript tests the
  wire and seeds the eval set; the `fm` CLI plus the local model make capturing new fixtures a
  one-liner.

---

## 9. Integration

- **Runtime agent surface (runtime-spec §4.3).** The runtime's `Agent` is the `FoundationModelsAgent`
  bridge (§7): `newSession` runs cwd + two-scope discovery and returns a `SessionId`; `prompt` runs a
  long-lived turn that drives a `LanguageModelSession` and fires `agent_message_chunk` / `tool_call` /
  `tool_call_update` / `plan` off the Transcript, calling back into the client for `requestPermission`
  (the permission gate) and, when a tool runs a command, `terminal/*`; it returns a `StopReason` only
  at turn end. The runtime calls the Rust core (UniFFI) for registry/dispatch only.
- **AgentViewKit.** AgentViewKit observes a FoundationModels `Transcript` directly (its native binding).
  For an ACP-driven agent, the client-side `AsyncStream<SessionUpdate>` is mapped *into* a `Transcript`
  — `agent_message_chunk` → `.response` text, `tool_call`/`tool_call_update` → `.toolCalls`/`.toolOutput`
  — with `agent_thought_chunk`/`plan`/`requestPermission` arriving as custom `.structure` segments. So
  the ACP client is just another producer of the same Transcript the kit already renders (the inverse of
  §7's bridge).
- **Driving other ACP agents.** The `Client` side lets the runtime *drive* an external ACP agent —
  e.g. Gemini CLI's `--experimental-acp` mode — reusing the same package from the other role.

---

## 10. Open questions

- **Generator choice:** a custom SwiftSyntax generator vs an off-the-shelf JSON-schema→Swift tool
  (e.g. quicktype) vs generating from the Rust schemars output. Custom gives the cleanest enums +
  ID newtypes + `unknown` fallbacks; off-the-shelf is less code to own. The checked-in pipeline (§6)
  tilts toward custom — it runs only on a schema change, its output is reviewed as a normal diff, and
  consumers never run it.
- **Stable vs unstable (updated to schema v1.19, 2026-07-14):** **stable** and first-class here are
  terminals (gated by `clientCapabilities.terminal`), `session/set_config_option`, `logout`, the
  session-management methods (`session/list`, `session/resume`, `session/delete`, `session/close`),
  **request cancellation** (v1.17.0), and **boolean session config options** (v1.18.0);
  `session/set_mode` is **deprecated** in favor of `set_config_option`. What remains **unstable**
  (only in `meta.unstable.json`) is **elicitation** (`elicitation/*` — gained option descriptions in
  v1.19.0, still unstable), **providers/\***, **`session/fork`**, **`nes/*`**
  (next-edit-suggestions), **`mcp/*`**, and **`document/did*`**. Generate the unstable set behind an
  `Unstable` namespace, gate behind capability flags, and mark clearly — don't expose them as if
  settled. See §7.2 for the v2 RFD trajectory.
- **Versioning policy:** how aggressively to track ACP point releases, and whether to vendor multiple
  schema versions or pin one.
- **Reasoning representation (bridge):** FM's `Transcript` models prompt/response/tools but reasoning
  isn't a first-class entry — does WWDC 2026 expose a thought stream the bridge maps to
  `agent_thought_chunk`, or does the bridge synthesize it from a `.structure` reasoning segment? Affects
  the FM→ACP mapping (§7) and the inverse in §9.
- **ACP→Transcript as a shipped utility:** the client-side mapping in §9 (a `SessionUpdate` stream into a
  `Transcript` + custom segments) is the natural symmetric half of the bridge — ship it in the package so
  AgentViewKit consumes any ACP agent uniformly, or leave it to the runtime?
