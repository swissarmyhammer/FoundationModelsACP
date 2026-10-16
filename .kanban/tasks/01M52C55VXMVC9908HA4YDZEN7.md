---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m52cjydf0fnqm2x5kryx6n5h
  text: |-
    ### test — green
    - evidence: one full run. `swift test`: 504 tests in 54 suites passed, and 135 tests in 17 suites passed. `swift test --package-path IntegrationTests`: 7 tests in 3 suites passed. `swift package generate-documentation --target FoundationModelsACP --warnings-as-errors`: exit 0. New suite `CancelRequestMetaTests`: 10 tests (T1 to T5, plus the arrival number). No clock, sleep, poll, retry or time limit.
    - scope added by the peer (ACPClient bug ^s39vtvg): `currentRequestArrival: UInt64?` on `Connection`, `ClientSideConnection` and `AgentSideConnection`. The value is the inbound token, given in read order.
    - next: commit and push in one batch, then watch CI.
  timestamp: 2026-10-16T12:56:57.007412+00:00
- actor: claude-code
  id: 01m52ck9318pa9816dcw5mgf0b
  text: |-
    ### commit — changed
    - evidence: 7d78473 feat(connection): carry _meta on $/cancel_request and give the inbound arrival number
    - next: push in one batch with this kanban record, then watch CI.
  timestamp: 2026-10-16T12:57:07.937766+00:00
- actor: claude-code
  id: 01m52e1k58fc86rvg2wq01v6ht
  text: |-
    ### implement and test — green (follow-up: cancelledByPeer)
    - request from the peer after the ACPClient check of 97a9d5e: a handler could not tell a `$/cancel_request` with no `_meta` from a close, because `cancelRequestMeta` is nil in both cases.
    - change: public static `cancelledByPeer: Bool` on `Connection`, `ClientSideConnection` and `AgentSideConnection`. `handleCancelRequest` sets it in the same receiver box, before it cancels the task, on the connection actor. It is false for a close, a timeout, no cancel, or outside a handler.
    - evidence: one full run. `swift test`: 505 tests in 54 suites passed, and 135 tests in 17 suites passed. IntegrationTests: 7 tests passed. DocC with `--warnings-as-errors`: exit 0. New test `closeWithAnOpenHandlerIsNotACancelOfThePeer`. The other tests now also check the flag: true for a peer cancel with no `_meta` (with a nil meta), false for a handler with no cancel, and false outside a handler.
    - next: commit, push, watch CI.
  timestamp: 2026-10-16T13:22:25.576615+00:00
- actor: claude-code
  id: 01m52e1r7hdk4g77qreza5wyjb
  text: |-
    ### commit — changed
    - evidence: 2c1abde feat(connection): tell a cancel of the peer from a close with cancelledByPeer
    - next: push, watch CI.
  timestamp: 2026-10-16T13:22:30.769901+00:00
- actor: claude-code
  id: 01m52h8ehqzrq805yqaj2ds6av
  text: |-
    ### implement and test — green (follow-up: requestPermission cancellation, from ACPClient card ^zqrpbmg)
    - change: `AgentSideConnection.requestPermission(_:cancellation: OutboundCancellation)`, the same pattern as `createElicitation(_:cancellation:)`. The old signature stays. The client permission handler runs in a child task of the dispatch task, so it gets the same receiver box and sees `cancelRequestMeta` and `cancelledByPeer` with no other change.
    - evidence: one full run. `swift test`: 506 tests in 54 suites passed, and 135 tests in 17 suites passed. IntegrationTests: 7 tests passed. DocC with `--warnings-as-errors`: exit 0. New test `permissionCancelMetaReachesTheClientHandler`: a reason set before the cancel reaches the client handler, with `cancelledByPeer` true.
    - next: commit, push, watch CI.
  timestamp: 2026-10-16T14:18:35.959223+00:00
position_column: done
position_ordinal: b580
title: Carry an optional _meta on $/cancel_request (elicitation plan task 50)
---
## Problem

When ACPAgent ends an open client request (for example an `elicitation/create` whose question Router ended with no answer: run cancel, `cancelAll`, `close`), the relay cancels the task of the call. `Connection.cancelOutbound(id:)` (Connection.swift:1272) then sends `$/cancel_request` with only `requestId`. The reason ("run cancelled", "no user is present") goes only to the agent log. The receiver (`handleCancelRequest`, Connection.swift:938) reads only `requestId`, and the handler sees only a `CancellationError`.

The wire type already has the field: `CancelRequestNotification.meta` (`_meta`, Models2.generated.swift:90). No generated file changes.

## Design (no code yet)

### 1. Sender side (agent side, and the generic connection)

A cancel comes from `Task.cancel()`, which cannot carry data. Thus the caller gives a box before the call, and puts the `_meta` in the box before it cancels the task.

- New public type `OutboundCancellation` (final class, `Sendable`, state in a `Mutex`). API: `init()`, `func setMeta(_ meta: JSONValue?)`, `var meta: JSONValue? { get }`.
- New public overload `Connection.request(method:params:timeout:cancellation:)`. The existing `request(method:params:timeout:)` delegates to it with `nil`.
- `PendingRequest` keeps the box. `cancelOutbound(id:)` reads `meta` from the box when it builds the notification. A `nil` meta gives no `_meta` member, so the frame is the same as today.
- New public overload `AgentSideConnection.createElicitation(_:cancellation:)`. This is the only typed call that ACPAgent ends today. Other typed calls can get the same overload later; the generic `request` overload covers them now.
- Contract (in the doc comment): set the meta before `Task.cancel()`. The box is read one time, when the connection writes the notification. When the response, a timeout or a close comes first, no `$/cancel_request` is sent, as today, and the meta is not used.

### 2. Receiver side (client side, and the generic connection)

- `dispatchRequest` binds a new task-local box for each inbound request (the same pattern as `currentResponseHooks`).
- `handleCancelRequest` stores `fields["_meta"]` in the box of that request, then cancels the task. Both steps run on the connection actor, in this order. Thus the handler always sees the meta when it sees the cancel.
- New public static read `Connection.cancelRequestMeta: JSONValue?`, with the same read on `ClientSideConnection` and `AgentSideConnection`. It gives the `_meta` of the `$/cancel_request` that cancelled the current inbound request. It is `nil` when the request is not cancelled, when the cancel had no `_meta`, or when the code is not in a handler task.
- Contract (in the doc comment): read it in the task of the handler, after the handler sees the cancel (for example after `await` throws `CancellationError`, or after a continuation that `onCancel` resumed). Do not read it in an `onCancel` closure: that closure runs in the task that cancels, so the task-local of the handler is not there.
- The value is the raw `JSONValue`, with no check. A `_meta` that is not an object is given as is.

### 3. Key name

`"reason"`, with a string value: `"_meta": {"reason": "run cancelled"}`. This is the same key as `ACPClient.elicitationReasonMetaKey` (ACPClient task 29, `61876e8`) and `MCPServer.elicitationReasonMetaKey` (Multitool task 25, `f07d7e8`). New public constant `CancelRequestNotification.reasonMetaKey = "reason"` in a hand-written extension (not in a generated file). The connection does not read or write this key; ACPAgent writes it and ACPClient reads it.

### 4. Compatibility

- Additive only. All existing signatures stay. Old callers compile with no change.
- On the wire, a cancel with no meta is the same bytes as today. An old receiver reads only `requestId`, so it ignores `_meta`.

### 5. Out of scope (other repos)

- ACPAgent: create the box for each `elicitation/create` round trip, and in `ElicitationRelay.end(_:)` and `drainOpenRoundTrips()` call `setMeta(["reason": ...])` before `cancel()`.
- ACPClient: in its `createElicitation` handler, read `ClientSideConnection.cancelRequestMeta` after the cancel and give the reason to the model.

## Tests (fixed order; no clock, sleep, poll, retry or time limit)

All tests use an in-memory transport pair. Each step waits on a continuation or a stream element that the step before it gives.

1. Reason goes to the handler: the client handler signals "entered" and waits for its cancel. The test calls `setMeta(["reason": "run cancelled"])`, then cancels the caller task. The handler reads `cancelRequestMeta` and records it. Assert the record is `{"reason": "run cancelled"}`, and the recorded wire frame of `$/cancel_request` has the same `_meta`.
2. No meta: cancel with the old overload. Assert the wire frame has no `_meta` member and the handler reads `nil`.
3. Per request: two concurrent `createElicitation` calls with two boxes and two reasons. Cancel both. Assert each handler reads its own reason.
4. Not cancelled: a handler that completes reads `nil`. Code outside a handler reads `nil`.
5. Raw peer: a raw `$/cancel_request` with a `_meta` that is a string. Assert the handler reads that string as is.

Done when: the tests pass in one full `swift test` run, and CI is green. #elicitation