---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m53g4j9h375jje85sexqfdcr
  text: |-
    ### test, green
    - evidence: swift build --build-tests (0 warnings); swift test: 510 tests in 56 suites and 135 tests in 17 suites passed; IntegrationTests: 7 tests passed; DocC with warnings-as-errors is clean. One full run.
    - change 1: RequestCancelOrderTests takes the cancel work at once after caller.cancel(), with no wait. When onCancel schedules no work, take() gives nil and the test fails.
    - change 2: Connection gets an internal RequestTimeoutScheduler seam (default: Task.sleep). ClientSideConnection and RoleConnectionCore pass it through. The expire closure returns true when it failed a waiting request. ManualRequestTimeouts keeps each timeout. The five timeout tests make it fire by hand and require the list of failed requests before they wait for the caller. Thus a broken timeout fails the test at once.
    - next: commit, push, watch CI.
  timestamp: 2026-10-16T23:18:14.577274+00:00
position_column: done
position_ordinal: b980
title: 'Rule T1: remove the two remaining waits that can hang'
---
A double check found two test items that break rule T1.

1. RequestCancelOrderTests: the second arrivals.next() waits for the cancel work after caller.cancel(). The onCancel handler runs synchronously inside caller.cancel(). Thus the test must take the work at once, with no wait (for example, require that work.take() is not nil).
2. The timeout tests use a real clock of 30 to 50 ms and a peer that never answers. If the timeout breaks, the tests wait forever. Add an internal clock seam to makeTimeoutTask, and drive the clock by hand in these tests:
   - DisconnectTests: perRequestTimeoutFiresWhenPeerNeverAnswers, connectionDefaultTimeoutApplies, lateResponseAfterTimeoutIsIgnored.
   - The OutgoingRequestEventTests timeout test.
   - The SessionUpdateStreamTests timeout test.

Push when green. Report only the commits and the CI result.