---
assignees:
- claude-code
position_column: todo
position_ordinal: '8180'
title: 'Group D: currentInboundCancellation is inherited by tasks that a handler starts'
---
Elicitation plan section 10, group D.

Defect: the task-local Connection.currentInboundCancellation is bound around the handler of an inbound request. An unstructured Task that the handler starts inherits the task-local. Example: the projector consumer task of ACPAgent starts in the session/new handler and keeps the box of session/new. The doc in CancelRequestMeta.swift says that the value is nil when the current task handles no inbound request. That is false for those tasks. Nothing reads it wrongly today.

Fix: change the behavior if it is simple and safe; else change the doc so that it is true. Record the decision in a comment.

#elicitation