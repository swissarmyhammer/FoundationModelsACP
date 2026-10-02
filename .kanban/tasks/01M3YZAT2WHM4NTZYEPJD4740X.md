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
- actor: claude-code
  id: 01m3z043c29kkqbsvjd7ngcc92
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD (edacf69); 1 finding (1 confirmed, 0 refuted) — Tests/FoundationModelsACPTests/ResponseHooksTests.swift:56 code-hygiene/magic-numbers-swift
    - next: implement the open finding. Replace each magic number in ResponseHooksTests.swift with a named constant, then run test, commit and review again.
  timestamp: 2026-10-02T19:05:42.530618+00:00
- actor: claude-code
  id: 01m3z04bqv0fajx8nkb71jqjc9
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 3 files, runAll take-and-clear, discardAll, late append dropped with warning, 6 weak-reference tests
    - test: green — swift build --build-tests 0 warnings; swift test 372+110 passed; IntegrationTests 7 passed
    - commit: edacf69
    - review: findings — Tests/FoundationModelsACPTests/ResponseHooksTests.swift:56
  timestamp: 2026-10-02T19:05:51.099103+00:00
- actor: claude-code
  id: 01m3z0bn80tpm6ar5fadfaw8z8
  text: |-
    Finding code-hygiene/magic-numbers-swift corrected in the whole of ResponseHooksTests.swift. swiftlint no_magic_numbers (allowed_numbers [0, 1, -1, 100]) flagged only `.seconds(5)` in `releaseTimeout`. The integer now has its own constant `releaseTimeoutSeconds`, and `releaseTimeout` is `.seconds(releaseTimeoutSeconds)`. The two `log.messages.count == 1` checks now use the named constant `dropWarningCount`. The other literals were already in named constants (`unitRequestId`, `hooksTestTimeout`). swiftlint with the rule config now reports 0 findings for the file.

    Discovery: the `.build` folder of the workspace is in a bad state. `.build/workspace-state.json` does not list `swift-docc-plugin`, so `swift build` tries to remove `.build/checkouts/swift-docc-plugin` and clone it again. The sandbox stops the removal (EPERM, NSCocoaErrorDomain 513), and the build fails before it compiles. `--skip-update` does not help. `swift package reset` was not run (forbidden). The build and the tests ran with `--scratch-path` in the session scratchpad. A person must remove `.build/checkouts/swift-docc-plugin` (or the full `.build`) outside the sandbox before the next build in `.build`.
  timestamp: 2026-10-02T19:09:50.208486+00:00
- actor: claude-code
  id: 01m3z0bqxjgec905ngq6tjtgey
  text: |-
    ### implement — changed
    - evidence: 1 file — Tests/FoundationModelsACPTests/ResponseHooksTests.swift. swiftlint no_magic_numbers: 0 findings. `swift build --build-tests --scratch-path <scratchpad>/build`: Build complete, 0 warnings. `swift test --filter "ResponseHooksTests|DeferredWorkLifetimeTests"`: 6 tests in 2 suites passed, 0 failures. Finding flipped to [x].
    - next: /test (use a clean scratch path, or remove .build/checkouts/swift-docc-plugin outside the sandbox first), then /commit, then /review.
  timestamp: 2026-10-02T19:09:52.946626+00:00
- actor: claude-code
  id: 01m3z0m7cg9kc8tfgyfk91f7mc
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (21974c5): 0 findings, 0 confirmed, 0 refuted. The rule code-hygiene/dead-code-swift failed in the first run because of a permission error on .build/checkouts/swift-docc-plugin. A second run of the code-hygiene validator completed with 0 findings and 0 failed rules. The prior finding at Tests/FoundationModelsACPTests/ResponseHooksTests.swift:56 is checked.
    - next: Task moved to done. Send the pushed commit to the session foundationmodelsacpagent-bb, as the acceptance criteria tell.
  timestamp: 2026-10-02T19:14:30.928341+00:00
- actor: claude-code
  id: 01m3z0mhp3rq4rc4s6a0k8d799
  text: |-
    ### finish iteration 2 — clean
    - implement: changed — named constants in ResponseHooksTests.swift
    - test: green — scratch-path build 0 warnings; swift test 372+110 passed; IntegrationTests 7 passed
    - commit: 21974c5
    - review: clean — 0 findings; task moved to done
  timestamp: 2026-10-02T19:14:41.475949+00:00
position_column: done
position_ordinal: a180
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

## Review Findings (2026-10-02 14:02)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 3 file(s) reviewed, 2 not reviewed.

> 2 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 2 file(s)

- [x] `Tests/FoundationModelsACPTests/ResponseHooksTests.swift:56` `code-hygiene/magic-numbers-swift` — Magic numbers should be replaced by named constants.
