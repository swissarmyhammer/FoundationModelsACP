---
assignees:
- claude-code
position_column: done
position_ordinal: c180
title: SAH.RestoreFailure meta payload at _meta.sah.restoreFailure
---
Add SAH.RestoreFailure in the pattern of SAH.AgentRun. It lives at _meta.sah.restoreFailure and has one required member, reason (String). It has extract(from:) and inject(into:). Extract returns nil when the payload is absent or malformed. Inject keeps other _meta keys and other _meta.sah members. A _meta patches by top-level key, so a sah object must carry all members that must stay. Document that.

An agent sends it on a subagent_update of a child that failed to restore (state unknown) and of each descendant of such a child (reason: an ancestor was not restored). A later current subagent_update with a state clears it on the client side. That is a client rule, not a wire rule.