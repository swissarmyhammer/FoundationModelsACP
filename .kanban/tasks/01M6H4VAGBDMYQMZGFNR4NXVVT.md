---
assignees:
- claude-code
position_column: todo
position_ordinal: '8180'
title: 'DocC: sub-agent sessions, SAH.AgentRun, SAH.RestoreFailure, markReplayBoundary, subscribeToAllSessions, resume order'
---
Document in the package DocC, in simple technical English: the sub-agent session updates (subagent_update, session_message, session_message_chunk), SAH.AgentRun, SAH.RestoreFailure, SessionMergeEngine.markReplayBoundary(), ClientSideConnection.subscribeToAllSessions() with latestEventSequence and currentRequestArrival, and the resume order (history before the response, current snapshots after it). Keep the doc comments and add a DocC article. The DocC build gate in CI must stay green.