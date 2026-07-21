# Plan: FoundationModelsACP — the ACP wire for Swift

> **Scope (settled 2026-07-21, after a brief same-day detour).** This package
> is the **pure ACP wire**: generated schema types, the `Agent`/`Client` role
> protocols, the `*SideConnection` runtime, ndJSON framing. **Zero
> dependencies** — no family imports, no Yams, no models; anyone can build an
> ACP agent or client on it. The composed agent (config, tool roster, slash
> commands, `HarnessACPAgent` over the harness) briefly lived in this plan and
> is now its own package:
> [`../FoundationModelsACPAgent`](../FoundationModelsACPAgent/plan.md).
> History for the curious: planned standalone → wire inlined into the harness →
> reborn here carrying the composition → split; each move followed the
> noun-ownership test, and this is the stable shape: the wire's consumers
> should never drag in MLX, Yams, Stencil, or tool packages to decode a
> `SessionUpdate`.

Consumers: `FoundationModelsACPAgent` (the family's agent, primary), any
Swift ACP client (an editor side, a test harness), and
`FoundationModelsACPAgent`'s golden tests via `ReplayTransport` /
`InMemoryTransport`. This package never names a consumer.

Section-reference note: the spec below is carried verbatim from its previous
homes; `§9.1`/`§10`/`§10.1` references point at the composition and testing
sections now living in `../FoundationModelsACPAgent/plan.md`; `§6` (event
correlation ids) is the harness plan's.

---

## The wire specification

The wire-layer spec — home again after its round trip; the old
bridge/`SessionProvider` sections died in the composition plan's Superseded
note and are not reproduced.

**Provenance.** ACP's **Rust schema crate is the source of truth** — every
official SDK is generated from its emitted JSON Schema. There is **no official
Swift SDK**, and the three community ones (`aptove/swift-sdk`,
`wiedymi/swift-acp`, `rebornix/acp-swift-sdk`) are pre-1.0, hand-typed (so
they lag the schema), and partial — so we build our own, stealing their good
ideas: actor connection, `AsyncStream` for `session/update`, in-memory test
transport. License **Apache-2.0**, matching the spec and every reference SDK.
Data types are **generated** from the published schema
(`schema/v1/schema.json` + `meta.json`, from the `agentclientprotocol` org's
releases); connection, role protocols, and transport are **hand-written**,
porting the classic Rust async-trait design (rust-sdk v0.10.4: symmetric
`*SideConnection`s, oneshot + pending-map JSON-RPC engine), not the heavier
`Role`/`Builder` rewrite in runtime 1.0.0.
**Type-mapping rules (schema → Swift).** Idiomatic, not a transliteration:

- **Tagged unions** (`oneOf` + discriminator) → `enum` with associated values,
  hand-rolled `Codable` keyed on the discriminator.
- **Objects** → `struct` with explicit `CodingKeys` (wire is camelCase).
- **String enums** (`ToolKind`, `ToolCallStatus`, `StopReason`, …) →
  hand-rolled `Codable` routing unknown wire strings to `unknown(String)` — a
  newer peer's value can't crash decoding.
- **ID newtypes** (`SessionId`, `ToolCallId`, …) → distinct `RawRepresentable`
  structs, never bare `String`.
- **`_meta`/free-form fields** (`rawInput`, `rawOutput`, MCP env) →
  `JSONValue`; `_meta` round-trips uninterpreted.
- **Capability-gated optionals** — absence = unsupported. Negotiated surfaces
  decode defaults-on-error (a malformed capability degrades to "unsupported",
  never fails `initialize`); on encode, omit `nil`, never emit `null`.
- **`protocolVersion` is a wire integer**: a `UInt16` newtype encoding bare
  `1` (`.v1 = 1`, `.latest = .v1`), rejecting `"v1"`/`"1.0.0"`.
- **Versioning**: target v1; growth via capabilities + `_meta`; generated code
  checked in, regenerated on schema bump only.

**Core type analogs** (representative; the generator emits the full set):

```swift
public struct SessionId: RawRepresentable, Codable, Hashable, Sendable { public let rawValue: String }
public struct ToolCallId: RawRepresentable, Codable, Hashable, Sendable { public let rawValue: String }

// The streaming notification payload (discriminator: `sessionUpdate`)
public enum SessionUpdate: Codable, Sendable {
    case userMessageChunk(ContentBlock)
    case agentMessageChunk(ContentBlock)
    case agentThoughtChunk(ContentBlock)
    case toolCall(ToolCall)
    case toolCallUpdate(ToolCallUpdate)
    case plan(Plan)
    case availableCommandsUpdate([AvailableCommand])
    case usageUpdate(UsageUpdate)
    case currentModeUpdate(SessionModeId)
}

public enum ToolCallStatus: Codable, Sendable, Hashable {
    case pending, inProgress, completed, failed
    case unknown(String)                    // forward-compat; hand-rolled Codable
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

public enum StopReason: Codable, Sendable { case endTurn, maxTokens, refusal, cancelled; case unknown(String) }

// JSON-RPC errors: standard codes + ACP's -32000 authRequired / -32002 resourceNotFound,
// structured `data`, never JSON smuggled through the message string.
public struct RequestError: Error, Codable, Sendable { public var code: Int; public var message: String; public var data: JSONValue? }

public enum JSONValue: Codable, Sendable {
    case null, bool(Bool), number(Double), string(String), array([JSONValue]), object([String: JSONValue])
}
```

**Role protocols** (hand-written; implement `Agent` to be driven by an editor,
`Client` to drive an agent):

```swift
public protocol Agent: Sendable {
    func initialize(_ p: InitializeRequest) async throws -> InitializeResponse
    func newSession(_ p: NewSessionRequest) async throws -> NewSessionResponse
    func loadSession(_ p: LoadSessionRequest) async throws -> LoadSessionResponse   // optional cap
    func prompt(_ p: PromptRequest) async throws -> PromptResponse                  // returns StopReason
    func cancel(_ p: CancelNotification) async                                       // notification
    func authenticate(_ p: AuthenticateRequest) async throws -> AuthenticateResponse // optional
    func setSessionConfigOption(_ p: SetSessionConfigOptionRequest) async throws -> SetSessionConfigOptionResponse
    @available(*, deprecated, message: "Use setSessionConfigOption")
    func setSessionMode(_ p: SetSessionModeRequest) async throws -> SetSessionModeResponse
    // Session management — stabilized in the current schema
    func listSessions(_ p: ListSessionsRequest) async throws -> ListSessionsResponse   // optional
    func resumeSession(_ p: ResumeSessionRequest) async throws -> ResumeSessionResponse // optional
    func deleteSession(_ p: DeleteSessionRequest) async throws                          // optional
    func closeSession(_ p: CloseSessionRequest) async throws                            // optional
    func logout(_ p: LogoutRequest) async throws                                        // optional
}

public protocol Client: Sendable {
    func sessionUpdate(_ n: SessionNotification) async               // notification; the dominant traffic
    func requestPermission(_ p: RequestPermissionRequest) async throws -> RequestPermissionResponse
    func readTextFile(_ p: ReadTextFileRequest) async throws -> ReadTextFileResponse
    func writeTextFile(_ p: WriteTextFileRequest) async throws
    // Terminals — the client owns them; the agent drives them. Capability-gated.
    func createTerminal(_ p: CreateTerminalRequest) async throws -> CreateTerminalResponse
    func terminalOutput(_ p: TerminalOutputRequest) async throws -> TerminalOutputResponse
    func waitForTerminalExit(_ p: WaitForExitRequest) async throws -> WaitForExitResponse
    func killTerminal(_ p: KillTerminalRequest) async throws
    func releaseTerminal(_ p: ReleaseTerminalRequest) async throws
}
```

Method-name mapping is internal (`session/new` → `newSession`); optional
methods are capability-gated, unsupported calls return JSON-RPC
method-not-found. **Connections** are two symmetric objects over one byte
stream, each taking a **factory closure** so the handler can capture its own
connection for reverse calls:
`AgentSideConnection(stream:) { conn in HarnessACPAgent(conn, harness) }` /
`ClientSideConnection(stream:) { agent in MyClient(agent) }`. **Wire
invariants at the type boundary**: paths absolute, line numbers 1-based (an
`AbsolutePath` newtype makes violations decode-time errors); chunks correlate
by message id, tool calls by `toolCallId`
(`pending → in_progress → completed/failed`), and the API surfaces those ids —
consumers never infer ordering.

**Connection model — two concurrent streams, not request/response.** ACP is
full-duplex and notification-first: either peer sends requests and
notifications at any time, many in flight both directions. `session/prompt`
stays pending the whole turn while the agent fires `session/update`
notifications and issues reverse-direction requests concurrently; it resolves
only at turn end with a `StopReason` — the turn's content is the notification
stream, the response just the terminator. The client side surfaces per-session
`session/update` as an `AsyncStream<SessionUpdate>`; the agent side fires and
forgets. Implementation: one read loop per connection; correlation via
monotonic id + `[RequestID: CheckedContinuation]` inside the connection actor
(which also serializes writes); **each inbound request dispatches as its own
`Task`** — why a slow `session/prompt` can't head-of-line-block a
`session/cancel` or callback; long-lived requests are suspended continuations
that must never block the read loop. **Fail loud on disconnect** (a real
TS-SDK gap): on EOF/error, reject every pending continuation and finish the
streams; per-request timeouts; honor `Task` cancellation. **Tolerate
late/out-of-order notifications**: a `tool_call_update` may arrive after the
prompt response or a cancel — correlate to turn/session, drop or attribute
deliberately. **Framing**: ndJSON — one UTF-8 JSON object per line, **no
`Content-Length` headers** (not LSP; we own the codec); buffer partial lines,
tolerate escaped slashes, log-and-skip bad lines. **stdout is sacred — the #1
field failure**: nothing but ACP messages on stdout, logs to stderr; the
target exposes a logger and never prints (tested, §9.1/§10).

**Codegen — build-time, incremental, checked in.**

- **Vendored schema + routing manifest**: `schema/v1/schema.json` AND
  `meta.json` (canonical artifacts on the `agentclientprotocol` org's
  `schema-v*` releases) in `Schema/`; bumping ACP = dropping in a new pair.
- **Routing table generated from `meta.json`** (`x-side`/`x-method`), never
  hand-wired — structurally avoids the TS-SDK bug class (`setSessionModel`
  wired to `session/set_mode`). Unstable methods generate from
  `meta.unstable.json` into an `Unstable` namespace.
- **No-op unless the schema changed** (content-hash stamp in the output).
- **Generated code checked in** — consumers just compile source.
- **A SwiftPM command plugin** (`swift package generate-acp`) writes the
  files (command plugins may write to the package dir; build-tool plugins
  can't); CI runs it and **fails on any diff**.

Hand-written, never generated: transport, connections, role protocols,
`JSONValue`, the `unknown` fallbacks.

**Vendor schema v1.19.x** (checked 2026-07-14): request cancellation (v1.17)
and boolean session config options (v1.18) stable; ID naming unified
(regenerate, don't patch); elicitation still unstable. Keep the pipeline ready
to vendor a v2 schema behind a labeled unstable namespace when the RFDs
publish (§9.1 tailwind) — don't chase v2 into the stable surface.

**Wire-layer testing** (`FoundationModelsACPTests`, §10): ndJSON makes a
session trivially recordable — tee the byte stream and you have a replayable
script. `ReplayTransport` replays a recorded client→agent script against
golden `session/update` fixtures (framing, ordering, tool-call pairing, late
updates, `StopReason` — deterministic, no model); `InMemoryTransport` (paired
in-process `AsyncStream`s) wires a `Client` and `Agent` back-to-back with no
pipes. A captured run doubles as an eval case (§10.1).

**Open questions**: generator choice (custom SwiftSyntax vs off-the-shelf —
the checked-in pipeline tilts custom); which stable methods surface
first-class vs `Unstable` (terminals, `set_config_option`, `logout`, session
management are stable as of v1.19); how aggressively to track point releases.

