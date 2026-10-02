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