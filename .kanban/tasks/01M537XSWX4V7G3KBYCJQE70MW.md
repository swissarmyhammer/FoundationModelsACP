---
assignees:
- claude-code
position_column: todo
position_ordinal: '8280'
title: 'Test rule T1: remove every .timeLimit and Task.sleep from the tests'
---
Elicitation plan section 10, test rule T1.

- Remove each .timeLimit trait and each Task.sleep from the tests. Get the counts from the code before and after.
- Each wait in a test must also end on the failure event (stream end, connection close, peer gone), or the test must fail before it waits.
- Each fixture closes its connections also when the test body throws.
- One full run. No repeated runs to find flakes.

#elicitation