---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m539d2jhdnj62a5z9krg3400
  text: |-
    ### implement and test, green
    - Counts from the code: 153 .timeLimit traits (all in Tests/), 11 Task.sleep calls in Tests/ and 2 in IntegrationTests/ (13 in total), plus the clock helpers withTimeout and waitUntil. After the work: 0 of each (rg for timeLimit, Task.sleep, ContinuousClock, withTimeout, waitUntil(timeout gives no match).
    - Commit beef086: traits and sleeps removed. Handlers wait for their cancel with waitForTaskCancellation() (CancelGate, now shared). Work after a cancel waits for a release from the test. Reverse-turn gate for out-of-order answers. Process tests read stdout to a line or to the end, and wait for the exit with the new internal SubprocessTransport.waitForExit(). The integration agent reads stdout chunks from a stream that ends at EOF.
    - Second commit: an audit of each wait and each fixture in all test files (four parallel agents, disjoint files). Each fixture closes its connections and raw ends with a defer (defer with await compiles in Swift 6.4). Streams that waited forever now finish on onClose, on connection close, or on producer end. Waits that came after a failed step now use try #require. The hidden 10 s timeout in lateResponseAfterTimeoutIsIgnored is removed.
    - Kept: three tests of the library request timeout feature (requestTimeout, timeout: 30 to 50 ms). They test a feature, not a test limit.
    - Known limits (no event exists without a clock): the EventBroadcaster deadlock test hangs on a deadlock regression. A few waits on a raw peer hang if the code under test never sends the item while the connection stays open. SubprocessReapTests hangs if close does not reap the child.
    - Full run, one time: build with 0 warnings. 510 tests in 56 suites and 135 tests in 17 suites passed. Integration: 7 tests passed. DocC: clean.
  timestamp: 2026-10-16T21:20:33.361608+00:00
position_column: done
position_ordinal: b880
title: 'Test rule T1: remove every .timeLimit and Task.sleep from the tests'
---
Elicitation plan section 10, test rule T1.

- Remove each .timeLimit trait and each Task.sleep from the tests. Get the counts from the code before and after.
- Each wait in a test must also end on the failure event (stream end, connection close, peer gone), or the test must fail before it waits.
- Each fixture closes its connections also when the test body throws.
- One full run. No repeated runs to find flakes.

#elicitation