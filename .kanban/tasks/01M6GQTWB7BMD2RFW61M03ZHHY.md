---
assignees:
- claude-code
position_column: done
position_ordinal: bf80
title: Remove JSON-RPC batching from Connection (ACP v2 removed it in alpha.11)
---
## What
ACP v2 removed JSON-RPC batching (release notes of schema-v2.0.0-alpha.11). `Sources/FoundationModelsACP/Connection/Connection.swift` still reads a batch (a JSON array frame), answers it with a batch response (`batchToken`), and `Tests/FoundationModelsACPTests/ConnectionTests.swift` and `NDJSONCodec` tests still test it. Per `ARCHITECTURE.md` there is no backward compatibility: remove the batch code and its tests in one change.

Decide the behavior for an array frame: answer with an invalid-request error with a null id, and keep the read loop alive.

## Acceptance Criteria
- [ ] No `batchToken` or batch-response code remains in `Connection.swift`.
- [ ] An array frame gets an invalid-request error with `"id": null`; the read loop continues.
- [ ] Batch tests are removed or changed to the new rule.

## Tests
- [ ] Add a test for the array frame refusal.
- [ ] Run `swift test`. All pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #subagents