---
assignees:
- claude-code
position_column: todo
position_ordinal: '8480'
title: Log a known session/update variant whose payload does not decode
---
## Problem

Unknown `session/update` variants are kept as raw data. But if the payload of a known variant is malformed, the decode of the full notification fails. `ClientSideConnection` then drops it and writes no log (`Connection/ClientSideConnection.swift:214-218`). A schema difference with a peer is then not visible.

## Work

1. When a `session/update` notification does not decode, write a warning to the connection logger. Include the session id (if it decodes), the `sessionUpdate` discriminator, and the decoding error.
2. Do not stop the connection.
3. Add a test: a `tool_call_update` with a bad field type gives one warning, and later updates still arrive.

## Acceptance

- The test passes, and all other tests pass.

#acp-lifecycle