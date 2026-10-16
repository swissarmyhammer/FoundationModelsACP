---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m5386gc4ekrwqz7cjpvs1s78
  text: |-
    ### implement and test, green
    - Decision: a behavior fix, because it is simple and safe. The box now has an "ended" flag. dispatchRequest calls endHandler() right after the handler returns, before the response is written. An ended box gives nil for cancelRequestMeta and false for cancelledByPeer. A task that the handler starts still inherits the box, but it reads no cancel after the handler returned. Structured child tasks end before the handler returns, so they see no change.
    - Docs: CancelRequestMeta.swift now tells that a started task inherits the value while the handler runs, and gets nil or false after the handler returns. The doc of currentRequestArrival had the same false sentence. Its value cannot change, so only its doc changed: a started task inherits the number, also after the handler returns.
    - Test: InboundCancellationScopeTests. Before the fix, the started task read the meta and true after the response was on the wire. After the fix, it reads nil and false.
    - Filtered run: 28 tests in 6 suites passed (cancel meta, permission and the new test). The full run comes before the push.
  timestamp: 2026-10-16T20:59:29.540082+00:00
- actor: claude-code
  id: 01m539d6k1wr7msar84201egqw
  text: |-
    ### commit, changed
    - evidence: 2ea94f1 fix(connection): end the inbound cancel box when the handler returns
    - Full run before the push: 510 tests in 56 suites and 135 tests in 17 suites passed. Integration: 7 tests passed. DocC: clean.
  timestamp: 2026-10-16T21:20:37.473589+00:00
position_column: done
position_ordinal: b780
title: 'Group D: currentInboundCancellation is inherited by tasks that a handler starts'
---
Elicitation plan section 10, group D.

Defect: the task-local Connection.currentInboundCancellation is bound around the handler of an inbound request. An unstructured Task that the handler starts inherits the task-local. Example: the projector consumer task of ACPAgent starts in the session/new handler and keeps the box of session/new. The doc in CancelRequestMeta.swift says that the value is nil when the current task handles no inbound request. That is false for those tasks. Nothing reads it wrongly today.

Fix: change the behavior if it is simple and safe; else change the doc so that it is true. Record the decision in a comment.

#elicitation