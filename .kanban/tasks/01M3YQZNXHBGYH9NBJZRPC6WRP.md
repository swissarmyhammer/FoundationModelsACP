---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m3yysmr6qx3e5xej9d4qpjy5
  text: |-
    Research done.
    - acp-test-agent makes a MessageId by hand and sends the user_message echo through `afterRespondingToCurrentRequest`, so the response goes out first. The integration test LiveAgentPromptEchoTests expects the echo as the first session/update after the response.
    - `SessionMergeEngine` is a value type. An `inout` engine argument to an `async` function cannot be actor-isolated state, so the agent helper is synchronous: it applies the echo to the engine at once and defers the send with the per-request response hooks (`Connection.currentResponseHooks`). With no current request, the echo cannot follow a response: the helper calls `assertionFailure` and logs.
    - AgentSideConnection had no logger reference. The helper keeps the init logger to log a failed deferred echo (only `ConnectionError.closed` is possible), instead of a silent `try?`.
    - Client side: a generic `Sendable` value correlator keyed by the local id of the client. It keeps echoes that arrive before the response only while a prompt waits for its response, so the memory stays bounded.
  timestamp: 2026-10-02T18:42:31.302817+00:00
- actor: claude-code
  id: 01m3yz4y8wb7y71r45h06s1103
  text: |-
    Implementation landed (not committed).

    Public API added:
    - `AgentSideConnection.insertUserMessage(_ request: PromptRequest, messageId: MessageId? = nil) -> MessageId` (@discardableResult)
    - `AgentSideConnection.insertUserMessage(_ request: PromptRequest, messageId: MessageId? = nil, into history: inout SessionMergeEngine) -> MessageId` (@discardableResult)
    - `public struct PendingPromptCorrelator<LocalID: Hashable & Sendable>: Hashable, Sendable` with `init()`, `mutating func addPendingPrompt(_ localID: LocalID)`, `@discardableResult mutating func resolve(_ localID: LocalID, with response: PromptResponse) -> Link?`, `@discardableResult mutating func observe(_ update: SessionUpdate) -> Link?`, `mutating func removePendingPrompt(_ localID: LocalID)`, and nested `public struct Link: Hashable, Sendable { let localID: LocalID; let messageId: MessageId; var entryID: SessionEntry.ID }`.

    Behavior: the agent helper is synchronous. It makes the ID (or uses the caller ID), applies the echo to the optional engine at once, and sends the `user_message` echo after the response through the per-request response hooks. Outside a request handler it calls `assertionFailure`, logs, and sends nothing. A failed deferred echo is logged through the logger that `AgentSideConnection.init` now keeps.

    Other changes: acp-test-agent and the README example use the helper. `EventLog` and `LoggingTransport` moved from PromptLifecycleTests.swift to the new shared WireOrderTestSupport.swift, so that the new ordering test reuses them.

    Downstream note: the FoundationModelsACPAgent session (foundationmodelsacpagent-bb) needs the head commit and these signatures after the commit step.
  timestamp: 2026-10-02T18:48:41.500478+00:00
- actor: claude-code
  id: 01m3yz51dd0sf32yp2swbjaezr
  text: |-
    ### implement — changed
    - evidence: 8 files — Sources/FoundationModelsACP/Connection/AgentSideConnection.swift, Sources/FoundationModelsACP/Session/PendingPromptCorrelator.swift (new), Sources/acp-test-agent/main.swift, README.md, Tests/FoundationModelsACPTests/PendingPromptCorrelatorTests.swift (new), Tests/FoundationModelsACPTests/UserMessageInsertionTests.swift (new), Tests/FoundationModelsACPTests/WireOrderTestSupport.swift (new), Tests/FoundationModelsACPTests/PromptLifecycleTests.swift. `swift build --build-tests`: 0 warnings. `swift test`: 366 + 110 tests passed. `swift test --package-path IntegrationTests`: 7 passed. DocC `--warnings-as-errors` for FoundationModelsACP: built.
    - next: /review
  timestamp: 2026-10-02T18:48:44.717603+00:00
depends_on:
- 01M3YQYR2Y867FQBAZJG2MKX79
- 01M3YQZE249S3VCDBHV2NPY0DA
position_column: doing
position_ordinal: '80'
title: Add the shared prompt messageId helper for agent and client
---
## What

ACP alpha.5 makes `PromptResponse.messageId` REQUIRED. The agent adds the user message to the conversation, echoes it as a `user_message` session/update with an ID, and returns the same ID in the response. The echo can arrive at the client before or after the response. Add one shared helper in this package for both sides.

## Agent side

A helper on `AgentSideConnection` (or a free function that takes the connection) that does "add, echo, return the ID" as one step:
1. Create a new `MessageId` (or take one from the caller).
2. Send `session/update` with `user_message` (the prompt content and that ID).
3. Return the ID, so that the handler returns `PromptResponse(messageId:)`.
It can also apply the echo to a merge engine (the engine task), so that the agent's retained history has the message with the same ID.

FoundationModelsACPAgent (session `foundationmodelsacpagent-bb`) waits for this helper. It will also use it for slash-command responses. When the helper is pushed, send that session the head commit and the final name and signature.

## Client side

A small `Sendable` correlation type: the client records a local pending prompt, then gives it the `messageId` from the response and the `user_message` echoes from the stream, in any order. It reports when the pending prompt and the echo are linked. FoundationModelsACPClient's `SessionModel` uses it to replace its local pending entry with the wire entry.

## Acceptance criteria

- Tests for both orders: echo before response, and response before echo.
- The test agent (`Sources/acp-test-agent/main.swift`) uses the agent helper.
- DocC for the public API. `swift test` passes with no warnings.