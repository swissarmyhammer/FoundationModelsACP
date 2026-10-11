---
assignees:
- claude-code
position_column: done
position_ordinal: b380
title: 'Fix ABBA deadlock: EventBroadcaster yields under its Mutex'
---
Request from AgentViewKit (card ^06hz99g in AgentViewKit).

## Problem
`EventBroadcaster` calls `continuation.yield` while it holds its `Mutex<State>` (in `State.publish(_:to:)`, `State.broadcast(_:)`, and the replay in `attach`). A yield resumes a waiting consumer and needs the status record lock of that task. On a different thread, `Task.cancel()` holds that task lock and runs the cancel handler of `AsyncStream.next()`. That handler runs `onTermination`, which calls `detach(token:from:)`, which waits for the same `Mutex`. Each thread holds the lock that the other thread needs. Both threads stop permanently.

## Fix
- Do not yield under the state lock. In the lock, change the state and collect the yields. Do the yields after the state lock is released.
- Use a second lock (the delivery lock) around "state step + yields", so that the event order stays the same and no live event comes before a replayed event. `detach` takes only the state lock, thus it never waits for a yield.

## Acceptance criteria
- [ ] A test that cancels a consumer while events are delivered on a different thread. It stops in the deadlock before the fix, and passes after the fix.
- [ ] All tests pass.
- [ ] Commit is pushed, and AgentViewKit gets the commit hash. #bug