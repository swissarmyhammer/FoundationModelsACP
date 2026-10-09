---
assignees:
- claude-code
position_column: todo
position_ordinal: '8980'
title: Log the other inbound notifications whose payload does not decode
---
## Problem

Task ^66t4ttv added a warning for a `session/update` notification that does not decode. Two other inbound notifications still use `try?` and drop a payload that does not decode with no log:

- `elicitation/complete` in `ClientSideConnection.serveNotification` (`Connection/ClientSideConnection.swift`).
- `session/cancel` in `AgentSideConnection` (`Connection/AgentSideConnection.swift`).

A schema difference with a peer is then not visible for these two methods.

## Work

1. For each of the two notifications, decode with `JSONValue.decodeParamsKeepingCause` and, on failure, write one warning to the connection logger. Include the wire method (from `RoleRouting.wireMethod`), the session id when `SessionId(namedIn:)` reads it, and the decoding error.
2. Do not stop the connection.
3. Add one test for each: a payload with a bad field type gives one warning, and a later notification still arrives.

## Acceptance

- The new tests pass, and all other tests pass.

#acp-lifecycle