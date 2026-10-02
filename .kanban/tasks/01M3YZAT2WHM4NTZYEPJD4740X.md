---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m3yzpf7z32k57qcd71w0bbf8
  text: 'Research: ResponseHooks lives in Connection.swift. Connection.dispatchRequest makes one per inbound request, binds it in the task-local Connection.currentResponseHooks, and calls runAll() only when completeInbound wrote a response. Callers of append: AgentSideConnection.afterRespondingToCurrentRequest and AgentSideConnection.sendAfterCurrentResponse (insertUserMessage). Second hole found: when the connection closes during the handler, no response is written, runAll() is not called, and the hooks keep their closures for the life of any child task. Plan: ResponseHooks gets a phase enum (collecting / ran / discarded), init(logger:requestId:), runAll() takes and clears in one lock, new discardAll() for the no-response path, and append() after either drops the closure and logs a warning with the connection logger. Choice: drop with a warning (not run at once), because a closure that runs at once from another task has no order with the hooks that still run.'
  timestamp: 2026-10-02T18:58:15.935723+00:00
- actor: claude-code
  id: 01m3yzvgpnt8ebb9zd4xnrgjzj
  text: 'Implementation landed (TDD). RED: 6 new tests in Tests/FoundationModelsACPTests/ResponseHooksTests.swift failed on the old code (closure kept, weak reference alive, wait timed out, no warning). One test first failed for a wrong reason: its body kept the captured object in a local; changed it to use the helper so that only the closure holds the object. GREEN: ResponseHooks now has Phase { collecting([Work]), closed(ClosingReason) }, runAll() and discardAll() take the closures and close the collector in one Mutex lock, append() after close drops the closure and logs "Connection: dropped work deferred for request <id>: ..." to the connection logger. Connection.dispatchRequest calls discardAll() when completeInbound wrote no response. Connection.logPrefix is now fileprivate so ResponseHooks uses the same prefix. DocC on afterRespondingToCurrentRequest(_:) and insertUserMessage(_:messageId:) records the drop-with-warning choice. Open for the commit step: the card says to send the pushed commit to session foundationmodelsacpagent-bb.'
  timestamp: 2026-10-02T19:01:01.269255+00:00
- actor: claude-code
  id: 01m3yzvjxkwrm4qk22vb45wea2
  text: |-
    ### implement — changed
    - evidence: 3 files — Sources/FoundationModelsACP/Connection/Connection.swift, Sources/FoundationModelsACP/Connection/AgentSideConnection.swift, Tests/FoundationModelsACPTests/ResponseHooksTests.swift (new). `swift build --build-tests`: 0 warnings. `swift test`: 372 tests in 35 suites and 110 tests in 14 suites passed, 0 failures.
    - next: /test, then /review. After push, send the commit to session foundationmodelsacpagent-bb.
  timestamp: 2026-10-02T19:01:03.539806+00:00
position_column: doing
position_ordinal: '80'
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