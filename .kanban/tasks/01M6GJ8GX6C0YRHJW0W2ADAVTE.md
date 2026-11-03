---
comments:
- actor: claude-code
  id: 01m6gp04g6rb3g09rfc3cwpnb2
  text: |-
    Breaks that the dependent packages (FoundationModelsACPAgent, FoundationModelsACPClient, AgentViewKit) will see after the re-vendor to schema-v2.0.0-alpha.13:

    1. RequestPermissionOutcome.cancelled now holds a value. Write `.cancelled(CancelledPermissionOutcome())`, not `.cancelled`. This is for every place that makes or matches the outcome.
    2. AvailableCommand is now a union with a `type` discriminator. It was a struct. Write `AvailableCommand.command(Command(description:name:))`. A command with no `type` is skipped when decoded. A command with an unknown `type` is kept as `.unknown`.
    3. ElicitationSchema now needs `properties` and `type` (`.object`). The `ElicitationSchema()` initializer with no arguments is gone. Use `ElicitationSchema(properties: .object([:]), type: .object)`.
    4. ClientCapabilities.auth has the type ClientAuthCapabilities. The old name AuthCapabilities is gone. There is also a new AgentAuthCapabilities.
    5. ToolCallStatus has a new case `.paused`. A switch with no default must handle it. In this package, `paused` is not a terminal status.
    6. ToolCallLocation.line has the type `LineNumber?` (new type in Core, 1-based, UInt32). It was `Int?`. The value `0` on the wire now gives `nil` for the line, and the message still decodes.
    7. UsageUpdate.cost has the type `PatchField<Cost>`. It was `Cost?`. Omitted leaves the last cost unchanged, `null` clears it, a value replaces it. SessionMergeEngine.usage keeps the merged cost (`.value`, or `.unchanged` if no cost is known).
    8. Cost.currency accepts any string (for example `credits`). The send rule that needed three upper-case letters is removed from SessionUpdateSendRules.swift.
    9. Agent protocol has two new requests with default implementations that throw method-not-found: `cancelToolCall(CancelToolCallRequest)` for `tool_call/cancel` and `cancelTerminal(CancelTerminalRequest)` for `terminal/cancel`. ClientSideConnection has the two matching calls. An Agent that advertises the cancel capability on a tool call or terminal must override them.
    10. MethodSide has a new case `.proxy`. A switch with no default over MethodSide must handle it. Only the unstable table has proxy entries (proxy/initialize, proxy/successor).
    11. The Unstable method table changed: document/* and nes/* are gone. New entries are auth/status, auth/status_update, session/archive, session/unarchive, session/status, session/set_title and the proxy methods.
    12. A request that has `"id": null` now gets an invalid-request error with `"id": null`. An error response with a null id is dropped and the read loop continues.
    13. New generated types: ErrorData stays untyped (JSONValue seam), BackgroundWork (terminal, toolCall), ElicitationFormMode now has a scope union. Generated file shards changed (Models10, Models11 added).

    Not done in this card: JSON-RPC batch support is removed from ACP v2 in alpha.11, but Connection.swift still reads and answers batches (and ConnectionTests still test it). That needs its own card.

    Answers for the other session:
    (1) Yes. IdleStateUpdate, RequiresActionStateUpdate and RunningStateUpdate each have `background: [BackgroundWork]?`. In the stable schema BackgroundWork has the cases `.terminal` and `.toolCall` (plus `.unknown`). The `subagent` variant is not in the stable schema.
    (2) No. The generator does not emit subagent_update, session_message or session_message_chunk. They are in Schema/acp-v2.unstable.json only, and no schema set reads that file. They still need the second card.
  timestamp: 2026-11-03T12:26:30.278967+00:00
position_column: done
position_ordinal: bb80
title: Re-vendor the ACP v2 schema to schema-v2.0.0-alpha.13 and fix what breaks
---
## What
Move the vendored schema from `schema-v2.0.0-alpha.8` to `schema-v2.0.0-alpha.13` (released 2026-11-02), the same way the earlier re-vendor commits did (see `git log -- Schema`, for example `dc336cb`). Files: `Schema/acp-v2.json`, `Schema/acp-v2.unstable.json`, `Schema/acp-v2.meta.json`, `Schema/acp-v2.meta.unstable.json`, `Schema/README.md` (the pin text). Then run `swift package generate-acp` and fix every compile error and test failure. Per `ARCHITECTURE.md` there is no backward compatibility: change all callers at once and keep no shims. Packages that depend on this one (FoundationModelsACPAgent, FoundationModelsACPClient, AgentViewKit) get their own cards for what breaks in them; list the breaks in a task comment.

Changes in alpha.9 to alpha.13 to check (from the release notes):
- alpha.9: a concrete `_meta` object patches by top-level key (upsert); the client system prompt schema (unstable).
- alpha.10: `terminal_update` has an optional terminal size; `ResourceLink.size` is unsigned; unknown tool kinds are defined; `_meta` on `DiffPatch`, `ToolCallPermissionSubject`, `Icon` and the cancelled outcome; null request ids are not allowed; available commands have a `type` discriminator; version mismatch errors; `session_message` views link to each other and chunks carry no identity; `null` clears `session_message` participant ids and message references; `nextCursor` and listed session directories parse strictly; a malformed replacement list does not clear the list; optional fields of unknown variants stay verbatim; a non-object elicitation schema root is rejected; `ToolCallLocation.line` is 1-based; terminal `exitCode` is signed; exactly one elicitation scope in v2.
- alpha.11: JSON-RPC batching is removed from v2; schema types for defined error data; elicitation content accepts other JSON values; subagent working directories (`cwd`, `additionalDirectories` as `AbsolutePath`); select options need at least one value; `lastModified` is ISO 8601; elicitation `requestedSchema` needs `type` and `properties`; error responses may have a null id; currency units such as credits are allowed (this touches `Cost.currency` and `SessionUpdateSendRules.swift`); `usage_update` `cost` is a patch field; `SessionInfo.additionalDirectories` is default-on-null.
- alpha.12: background work in v2 (the `background` list with `{type: subagent, sessionId}`); unstable methods `session/archive`, `session/unarchive`, `session/status`, `session/set_title`, `auth/status`, `proxy/initialize`, `proxy/successor`.
- alpha.13: spec text only.

Sources: `gh api repos/agentclientprotocol/agent-client-protocol/releases/tags/schema-v2.0.0-alpha.N`.

The card for the subagent session types (id `01M6GJ664BHY454C5NFPFCSP79`) depends on this card, because the `SubagentUpdate` and `session_message` shapes changed after alpha.8.

## Acceptance Criteria
- [ ] `Schema/` holds the alpha.13 documents and `Schema/README.md` names alpha.13.
- [ ] `swift package generate-acp` runs, and a second run gives no diff.
- [ ] `swift build` and `swift test` pass with no warning.
- [ ] A task comment lists each break for the dependent packages (Agent, Client, AgentViewKit).
- [ ] `Cost.currency` accepts a non-ISO unit such as `credits` when sending (`SessionUpdateSendRules.swift` follows the new rule).

## Tests
- [ ] Update or add tests in `Tests/FoundationModelsACPTests` for: the available command `type` discriminator, signed `exitCode`, 1-based `line`, `usage_update` cost as a patch field, a null response id, and the non-ISO currency.
- [ ] Run `swift test`. All pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #subagents