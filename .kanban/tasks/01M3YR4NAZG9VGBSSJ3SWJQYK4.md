---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m3z0tn7vnsehwe60rttbgc4h
  text: 'Research: `Connection.request` makes the id and puts it in the private `pending` map. Entries leave the map at three places: `resolve` (success or error response), `fail` (timeout, write failure, cancel, wrong-version response), and `shutDown` (connection close). Plan: an internal `OutgoingRequestTracker` (Mutex-guarded, Sendable, same pattern as `SessionUpdateRouter`) that `Connection` owns as a `let`. `Connection` records the start after it registers the continuation and before it writes the frame, and records the finish before it resumes the continuation. `ClientSideConnection` exposes it through `RoleConnectionCore`. The agent API does not expose the inbound request id, so the elicitation-match test uses a raw wire peer (WireReader) that reads the `auth/login` id and sends `elicitation/create` with that id.'
  timestamp: 2026-10-02T19:18:01.723207+00:00
- actor: claude-code
  id: 01m3z13x9ts62cntyascxz6238
  text: |-
    Implementation landed (not committed). Final public API:
    - `public enum OutgoingRequestEvent: Hashable, Sendable { case started(id: RequestId, method: String); case finished(id: RequestId) }` (Sources/FoundationModelsACP/Connection/OutgoingRequestEvent.swift)
    - `ClientSideConnection.subscribeToOutgoingRequests() -> AsyncStream<OutgoingRequestEvent>`: a new subscriber first gets `started` for each in-flight request (start order), then live events; every subscriber gets every event; stream finishes on connection close after `finished` for each in-flight request; subscribe after close gives a finished stream.
    - `ClientSideConnection.inFlightMethod(for requestId: RequestId) -> String?`: synchronous wire-method lookup.
    Ordering guarantees: `started` is recorded before the frame is written (so any peer message naming the id comes after it); `finished` is recorded before the caller resumes (result, error, cancel, timeout, write failure, close).
    Internal: `OutgoingRequestTracker` (Mutex-guarded, Sendable) owned by `Connection` as `nonisolated let outgoingRequests`; `Connection.removePending(id:)` is now the single removal path used by `resolve` and `fail`; `shutDown` calls `finishAll()`. `RoleConnectionCore.outgoingRequests` forwards it. AgentSideConnection does not expose it (not asked for).
    TDD: RED was a compile failure on the missing API only. GREEN: `swift test --filter OutgoingRequestEventTests` 11 tests / 45 cases passed. Full `swift test` (scratch path build): 383 + 110 tests passed. `swift build --build-tests -Xswiftc -warnings-as-errors` (scratch build-warn): Build complete, zero warnings.
  timestamp: 2026-10-02T19:23:04.890975+00:00
- actor: claude-code
  id: 01m3z140s1wqj2kx39hs0s0rfx
  text: |-
    ### implement — changed
    - evidence: 6 files — Sources/FoundationModelsACP/Connection/OutgoingRequestEvent.swift (new), Sources/FoundationModelsACP/Connection/OutgoingRequestTracker.swift (new), Sources/FoundationModelsACP/Connection/Connection.swift, Sources/FoundationModelsACP/Connection/RoleConnectionCore.swift, Sources/FoundationModelsACP/Connection/ClientSideConnection.swift, Tests/FoundationModelsACPTests/OutgoingRequestEventTests.swift (new); swift test 383 + 110 passed; warnings-as-errors build clean
    - next: /review
  timestamp: 2026-10-02T19:23:08.449002+00:00
- actor: claude-code
  id: 01m3z1fwn2kneysekd0m0v9t31
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD (98a17be); 1 finding (1 confirmed, 0 refuted, 0 validators failed) — Sources/FoundationModelsACP/Connection/OutgoingRequestTracker.swift:16 (reuse/reuse)
    - next: Extract a generic async event broadcaster that SessionUpdateRouter and OutgoingRequestTracker both use. Then run the review again.
  timestamp: 2026-10-02T19:29:37.442862+00:00
- actor: claude-code
  id: 01m3z1g5gt25taf1xm20kap8eb
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 6 files, OutgoingRequestEvent, subscribeToOutgoingRequests, inFlightMethod(for:), OutgoingRequestTracker
    - test: green — scratch-path build 0 warnings; swift test 383+110 passed; IntegrationTests 7 passed
    - commit: 98a17be
    - review: findings — Sources/FoundationModelsACP/Connection/OutgoingRequestTracker.swift:16
  timestamp: 2026-10-02T19:29:46.522874+00:00
- actor: claude-code
  id: 01m3z1sd5vbhfabbb7907cc3gm
  text: |-
    Finding reuse/reuse (OutgoingRequestTracker.swift:16) is now fixed. New internal generic `EventBroadcaster<Topic, Event, Context>` (Sources/FoundationModelsACP/Connection/EventBroadcaster.swift) is the one implementation of the Mutex-guarded subscriber map, the AsyncStream subscription, the replay under the lock, the detach on termination, and finishAll (continuations finished outside the lock). The owner keeps its own data in `Context`, under the same lock: `withState(_:)` gives `inout State` with `context`, `isFinished`, `publish(_:to:) -> Bool` (one topic) and `broadcast(_:)` (all topics). `subscribe(to:replay:)` takes a replay step that returns the replay events and an attachment value (nil when finished). `finishAll(_:)` runs a final step, then finishes the streams.
    - SessionUpdateRouter: Topic = SessionId, Context = PendingSessionUpdates. deliver = publish, else keep in the buffer; subscribe replay = pending.take(for:) with hasMissedUpdates as the attachment; finishAll final step = pending.removeAll(). PendingSessionUpdates is not changed.
    - OutgoingRequestTracker: one private topic, Context = InFlightRequests (requests + sequence); start/finish use broadcast; finishAll final step broadcasts `finished` for each in-flight request in start order; subscribe replay = start events.
    No public API change. Internal API of both types is not changed, so Connection, ClientSideConnection and RoleConnectionCore are not changed.
    TDD: new EventBroadcasterTests (7 tests). RED: compile failure, `cannot find type 'EventBroadcaster' in scope`. GREEN: 7 passed. Then both types were moved onto it.
    Note: a cancelled consumer task is a reliable way to test the detach — the iterator's cancellation handler runs onTermination before `await task.value` returns.
  timestamp: 2026-10-02T19:34:49.275204+00:00
- actor: claude-code
  id: 01m3z1sfs4f8yj2esd1vwsrvye
  text: |-
    ### implement — changed
    - evidence: 4 files — Sources/FoundationModelsACP/Connection/EventBroadcaster.swift (new), Sources/FoundationModelsACP/Connection/SessionUpdateRouter.swift, Sources/FoundationModelsACP/Connection/OutgoingRequestTracker.swift, Tests/FoundationModelsACPTests/EventBroadcasterTests.swift (new); `swift build --build-tests` (scratch build) Build complete, 0 warnings; `swift test` 390 + 110 passed; IntegrationTests (scratch build-it) 7 passed; finding reuse/reuse flipped to [x]
    - next: /review
  timestamp: 2026-10-02T19:34:51.940512+00:00
depends_on:
- 01M3YQYR2Y867FQBAZJG2MKX79
position_column: doing
position_ordinal: '80'
title: Expose outgoing request IDs and their completion on ClientSideConnection
---
## Problem

A request-scoped elicitation (`ElicitationRequestScope.requestId`, `Sources/FoundationModelsACP/Generated/Models3.generated.swift:616`) names the JSON-RPC ID of a request that the CLIENT sent, for example `auth/login`. The schema does not limit which methods can cause one ("e.g., during auth/configuration phases before any session is started"). The connection creates the request IDs privately (`Connection.swift:289`), so a client cannot know which of its requests an elicitation belongs to, or when that request ends.

FoundationModelsACPClient's `ConnectionModel` needs this to show request-scoped elicitations and to remove them when their request completes or fails.

## What

Add a public way on `ClientSideConnection` to observe outgoing requests. Proposed: a stream of events `.started(id: RequestId, method: String)` and `.finished(id: RequestId)` (finished covers success, error, cancel and connection close), plus a synchronous lookup of the method name of an in-flight request ID. Choose the final shape and document it.

## Acceptance criteria

- Tests: each typed client call produces `started` with the correct method and ID, then `finished`, for success, error, cancel and connection close.
- Test: an elicitation request with a request scope can be matched to the in-flight `auth/login`.
- DocC. `swift test` passes with no warnings.

## Review Findings (2026-10-02 14:24)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 6 file(s) reviewed, 2 not reviewed.

> 2 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 2 file(s)

- [x] `Sources/FoundationModelsACP/Connection/OutgoingRequestTracker.swift:16` `reuse/reuse` — OutgoingRequestTracker reimplements the async subscription-and-broadcast infrastructure that SessionUpdateRouter already provides. Both classes implement Mutex-protected subscription state, AsyncStream subscriptions with replay of pending items, broadcast to all subscribers, and finishAll lifecycle management using identical patterns. Extract a generic async event broadcaster class that both SessionUpdateRouter and OutgoingRequestTracker can instantiate, rather than duplicating the subscription infrastructure. This ensures one canonical implementation of the subscription logic that both per-session updates and per-connection request tracking can reuse.
