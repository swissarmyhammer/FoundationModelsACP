---
assignees:
- claude-code
depends_on:
- 01M3YQZE249S3VCDBHV2NPY0DA
- 01M3YQZ0HNG9KMTZKX51HEG5DF
position_column: todo
position_ordinal: '8580'
title: Remove deprecated SessionUpdateAggregator and updates(for:)
---
## What

Delete `SessionUpdateAggregator` and `ClientSideConnection.updates(for:)`. Both are deprecated by ^2npy0da (merge engine) and ^1heg5df (`subscribe(to:)`).

## Wait condition

Do NOT start this task until the session `foundationmodelsacpclient-ae` reports that FoundationModelsACPClient no longer uses them (ACPSessionState is deleted). Until then, this task stays in todo.

## Acceptance criteria

- No code or tests in this package use the two removed APIs; the tests use the engine and `subscribe(to:)`.
- DocC has no links to the removed names.
- `swift test` passes with no warnings.