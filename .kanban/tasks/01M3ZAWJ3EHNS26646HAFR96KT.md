---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m40r396gknczsyqpsygy3xjg
  text: |-
    Research done.
    - `Connection.shutDown()` is synchronous on the actor. It cancels the inbound tasks but does not wait. `completeInbound` removes the task from `inboundTasks` before the response and the response hooks run, so `inboundTasks` alone does not show all running handler tasks. Plan: a separate set of live inbound tasks, keyed by a local token, that each task removes at its end. shutDown keeps the old order (read task cancel, outgoingRequests.finishAll, reject pending, cancel inbound, drop batches, internal onClose), then starts one task that waits for each live inbound task and for the read task (notification handlers run inline on the read task), then fires the public signal.
    - Write failures do not close the connection today (they fail only the one request or are logged). So `transportFailed` is for a failure of the input stream only. I do not change write behavior.
    - `dispatchRequest` can still run after close (a batch that is mid-dispatch). Add a guard so no new handler task starts after close; otherwise the signal could fire while a new handler runs.
    - Waiting on `closed` inside an inbound handler would wait for itself. Document this.
  timestamp: 2026-10-03T11:23:55.984609+00:00
- actor: claude-code
  id: 01m40s0w75v645wxy9v87vvmqq
  text: |-
    Implementation landed (not committed).

    Final public API:
    - `public enum ConnectionCloseReason: Sendable { case endOfInput; case transportFailed(any Error); case closedLocally }`
    - `public var closed: ConnectionCloseReason { get async }` on `AgentSideConnection` and `ClientSideConnection`, and `public nonisolated var closed: ConnectionCloseReason { get async }` on `Connection`.
    - No `onClose(_:)` closure API: `closed` covers it.

    How it works:
    - `Connection.isClosed` is now computed from `closeReason: ConnectionCloseReason?`. `shutDown(reason:)` sets the first reason only and returns the reason in effect. The old order stays the same: cancel the read task, `outgoingRequests.finishAll()`, reject pending requests, cancel inbound tasks, drop batches, internal `onClose` (router `finishAll`). ResponseHooks `discardAll` still runs in each inbound task when `completeInbound` returns false.
    - The read loop fires the signal: after `readFrames()` ends (EOF, error, or the cancel from `close()`), it calls `shutDown(reason:)`, waits for each live inbound task, then calls `ConnectionCloseSignal.fire`. Notification handlers run on the read loop, so they ended too. No new unstructured task.
    - New `liveInboundTasks` (token-keyed) keeps each inbound task until its last step, also while it writes its response and runs the deferred hooks (`inboundTasks` drops the task before that).
    - New guard: `dispatchRequest` drops a request after close (a batch can still dispatch items after `close()` from a notification handler).

    Discoveries:
    - A write failure does not close the connection today; `transportFailed` therefore means a failure of the input stream only. Documented on the enum case.
    - `ScriptedTransport` moved from `DisconnectTests.swift` (private) to `WireTestSupport.swift` (internal) so that the new tests can use it.
    - Each RED was seen: compile failure first; then the handler test failed with the signal fired at shutdown; then the deferred-work test failed with the live-task tracking removed; then the batch-after-close test failed with the guard removed.

    Still open from the card (after push, not part of this step): send the commit and the final names to `foundationmodelsacpagent-bb` and `foundationmodelsacpclient-ae`.
  timestamp: 2026-10-03T11:40:05.733307+00:00
- actor: claude-code
  id: 01m40s100jfqz0zzwp92gnkyxm
  text: |-
    ### implement — changed
    - evidence: 9 files — Sources/FoundationModelsACP/Connection/{ConnectionCloseReason.swift (new), ConnectionCloseSignal.swift (new), Connection.swift, RoleConnectionCore.swift, AgentSideConnection.swift, ClientSideConnection.swift}, Tests/FoundationModelsACPTests/{ConnectionClosedSignalTests.swift (new), WireTestSupport.swift, DisconnectTests.swift}. `swift build --build-tests`: 0 warnings. `swift test`: 399 + 110 tests passed. `swift package generate-documentation --target FoundationModelsACP --warnings-as-errors`: passed. `swift test --package-path IntegrationTests`: 7 tests passed.
    - next: /review
  timestamp: 2026-10-03T11:40:09.618639+00:00
position_column: doing
position_ordinal: '80'
title: Public connection-closed signal with a reason on both connection sides
---
## Problem

An agent cannot know when the client drops the connection without `session/close`. `Connection.shutDown()` (`Sources/FoundationModelsACP/Connection/Connection.swift:959`) runs on end of input, on a transport error and on an explicit `close()`, and calls an internal `onClose` handler. `AgentSideConnection` does not expose this to its owner. Also, `shutDown` cancels the in-flight inbound handler tasks but does not wait for them to end before it calls `onClose`.

Evidence (reported by foundationmodelsacpagent-bb, FoundationModelsACPAgent ^56jbp35, 2026-10-02): the agent holds the connection weakly (required to fix its model leak ^173qn8n). When the client drops stdin or the transport fails, the agent and its sessions are released with no close path: its shell stream is not finished, its MCP pool is not shut down, session-history.json is not written, and a session with an MCP server trips a debug assertion (Multitool SurfaceRefresher.swift:136), which stops the process.

FoundationModelsACPClient's `ConnectionModel.state` (connecting / connected / disconnected / failed(Error)) needs the same signal on `ClientSideConnection`, with the reason.

## What

Add ONE public signal, the same on `AgentSideConnection` and `ClientSideConnection`. Proposed shape (choose the final names, document them):

```swift
public enum ConnectionCloseReason: Sendable {
    case endOfInput                 // the peer closed its side
    case transportFailed(any Error) // read or write error
    case closedLocally              // close() was called
}
public var closed: ConnectionCloseReason { get async }   // returns when the connection is closed; at once if it is already closed
```

Optionally also `onClose(_ body: @escaping @Sendable (ConnectionCloseReason) async -> Void)` if that is simpler for owners; it runs one time.

Rules:
- The signal fires for all three paths, exactly ONE time, and every waiter (also a late one) gets the same reason.
- The signal fires only AFTER every inbound handler task has ended (finished or cancelled), so an owner can release state without a race with a running handler.
- The existing internal `onClose` users (router `finishAll`, outgoing request `finishAll`) keep their order and behavior.

## Acceptance criteria

- Tests for each of the three paths: the signal fires one time with the correct reason; a second `close()` does not fire it again; a waiter that starts after close gets the reason at once.
- Test: a handler that is still running when the connection closes has ended before the signal fires.
- `swift build --build-tests` has 0 warnings; `swift test` passes; DocC with `--warnings-as-errors` passes.
- When pushed, send the commit and the final names to `foundationmodelsacpagent-bb` and `foundationmodelsacpclient-ae`.