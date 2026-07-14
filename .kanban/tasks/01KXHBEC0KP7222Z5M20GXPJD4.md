---
depends_on:
- 01KXHBDW50GFJS4TH0HGS0D3KP
position_column: todo
position_ordinal: '9080'
title: Bridge FM tools → reverse ACP requests (fs/*, terminal/*, permission)
---
## What
Bridge FoundationModels `Tool`s to the client's environment (spec §7): an FM tool runs in-process, but when its work needs the *client's* environment it must issue reverse-direction ACP requests rather than touch the host directly, so an FM tool transparently uses the editor's filesystem and consent.

- Provide a client-environment handle the bridge exposes to tools (injected per session/turn), offering: `readTextFile`/`writeTextFile` (→ `fs/*`), `requestPermission` (→ `session/request_permission` with `PermissionOption`s, mapping `RequestPermissionOutcome.selected/cancelled`), and terminals (`createTerminal`, poll `terminalOutput` bounded by `outputByteLimit`+`truncated`, `waitForTerminalExit`, `killTerminal`, `releaseTerminal`).
- Gate on negotiated `clientCapabilities` (`fileSystem`, `terminal`) — a tool asking for an un-advertised capability gets a typed error, not a wire call.
- When a tool runs a command, embed the `terminalId` in the emitted `tool_call` content (`ToolCallContent.terminal`) so the client renders live output (spec §9).
- Permission denial (`rejectOnce`/`rejectAlways`/`cancelled`) surfaces to the tool as a typed error it can convert into a tool failure (`tool_call_update` status `failed`).

## Acceptance Criteria
- [ ] An FM tool reading a file over the bridge produces an `fs/read_text_file` request on the wire and receives the client's content
- [ ] A command-running tool produces `terminal/create` → embeds `terminalId` in its `tool_call` → `wait_for_exit` → `release`, in order
- [ ] Permission flow round-trips: request → client selects option → outcome delivered; denial becomes a failed tool_call_update
- [ ] Un-advertised capability use fails locally with a typed error and no wire traffic

## Tests
- [ ] `Tests/FoundationModelsACPTests/Bridge/ToolBridgeTests.swift` — fake `Client` over InMemoryTransport asserting the wire sequences above
- [ ] `Tests/FoundationModelsACPTests/Bridge/PermissionFlowTests.swift` — grant, deny, cancel outcomes
- [ ] Run `swift test` — exits 0

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.