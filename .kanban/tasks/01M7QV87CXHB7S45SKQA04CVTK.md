---
assignees:
- claude-code
position_column: done
position_ordinal: c980
title: 'Route session/fork: Agent.forkSession handler and ClientSideConnection.forkSession'
---
D205. Brief: ../.briefs/fork/acp-brief.md, item 2.

After the generator routes `session/fork` with types, add:
- `Agent.forkSession(_:)` with a default that throws method-not-found, and its dispatch arm in `AgentSideConnection.serve`.
- `ClientSideConnection.forkSession(_:)`.

## Acceptance
- [ ] An agent with a `forkSession` handler gets the request and its response comes back.
- [ ] An agent with no handler answers method-not-found.
- [ ] The routing coverage tests know the new method.
- [ ] `swift test` is green.

#fork