---
assignees:
- claude-code
position_column: done
position_ordinal: c080
title: 'SessionMergeEngine: replay boundary resets child state and capabilities'
---
Gap found by the client package. foldSubagent folds each subagent_update onto the earlier folded value of the same child. A client that resumes with replayFrom gets history snapshots before the resume response. A current snapshot after the response can omit state. The fold then keeps the history state (for example running). The client cannot see that the current snapshot gave no state.

Rule from the ACP v2 Subagent Sessions RFD: snapshots before the response are history and confirm nothing. The current snapshot after the response replaces the state. A missing state means unknown.

Chosen design (option a): the engine gets a replay boundary. A call such as markReplayBoundary() is made when the resume response arrives. After it, the first subagent_update for each known child folds onto a fresh base. State and capabilities do not carry over from history. The child entry and its other fields stay. Change.subagentChanged then holds a state that is unknown when the update omits it.

Why not option b: a raw patch next to the folded value makes each client repeat the fold rule.

Acceptance:
- Test: history update with state running, boundary, current update without state. Folded state is unknown.
- Test: same for capabilities.
- Test: a child with no update after the boundary keeps its history value until an update arrives, or is marked stale (decide in the test).
- Test: an update before the boundary still folds as it does now.
- Document the call in the SessionMergeEngine doc comment, next to reset().
- No backward compatibility shims. Change all callers at once.