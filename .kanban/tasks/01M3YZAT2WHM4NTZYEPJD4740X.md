---
assignees:
- claude-code
position_column: todo
position_ordinal: '8680'
title: ResponseHooks keeps deferred closures after they run; child tasks keep them alive
---
## Defect

`ResponseHooks.runAll()` (`Sources/FoundationModelsACP/Connection/Connection.swift:28`) copies the closures with `hooks.withLock { $0 }` and does NOT clear the array. `Connection.dispatchRequest` (`Connection.swift:577`) binds the `ResponseHooks` object into the task-local `Connection.currentResponseHooks` around the handler. Each unstructured `Task {}` that a handler starts inherits that task-local. So the task keeps the `ResponseHooks` object, and the object keeps every closure and every captured value, for the full life of that task.

Second problem, same cause: when such a task calls `AgentSideConnection.afterRespondingToCurrentRequest(_:)` after `runAll()` ran, `append` records the closure, and nothing runs it. The work is lost and no error is reported.

## Evidence (reported by foundationmodelsacpagent-bb, FoundationModelsACPAgent ^173qn8n and ^w93shct, 2026-10-02)

`session/new` in that agent starts a long-lived watcher task. `leaks --traceTree` showed: `CommandRegistry` <- hook closure <- `ResponseHooks` <- task <- `EventBroadcaster` continuation. This kept a closed session and its three resident models in memory, so a later live test got a 176359-byte budget, and the CI Integration job of that package was red from 2026-09-29.

`insertUserMessage` (^rpc6wrp) also uses these hooks and captures the prompt content, so it has the same exposure.

## Fix

1. `runAll()` takes the closures and clears the array in the same lock:
   ```swift
   func runAll() async {
       let work = hooks.withLock { hooks in
           let taken = hooks
           hooks = []
           return taken
       }
       for item in work { await item() }
   }
   ```
2. After `runAll()` starts, `append` must not record the closure. No response follows, so the closure can never run. Choose one behavior and document it on `afterRespondingToCurrentRequest(_:)`: run the closure at once, or drop it and log a warning with the connection logger. Do not keep it.

## Acceptance criteria

- Test: a closure registered with `afterRespondingToCurrentRequest` is released after it runs (check with a weak reference to a captured object), also while a task that the handler started is still alive.
- Test: a closure registered from a child task after the response follows the documented behavior (runs, or is dropped with a warning), and is not kept.
- `swift build --build-tests` has 0 warnings. `swift test` passes.
- When pushed, send the commit to the session `foundationmodelsacpagent-bb`.