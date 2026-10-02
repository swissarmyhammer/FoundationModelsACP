---
assignees:
- claude-code
depends_on:
- 01M3YQYR2Y867FQBAZJG2MKX79
- 01M3YQZE249S3VCDBHV2NPY0DA
position_column: todo
position_ordinal: '8380'
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