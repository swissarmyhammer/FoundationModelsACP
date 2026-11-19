---
assignees:
- claude-code
position_column: done
position_ordinal: cb80
title: 'SessionSearchChunker: search chunks from the merged session entries (D207 (a))'
---
D207 (TestudoApp/features/decisions.md), part (a). Brief: ../.briefs/search/acp-brief.md.

## Work
- `public struct SessionSearchChunk` (turn, ordinal, kind, author, date, title, text, entries with their character ranges).
- `public enum SessionSearchChunker` with `chunks(of:)`, a pure function. `maximumChunkLength` = 2,000 characters, `maximumToolTextLength` = 64 KB for each tool call.
- One text form of `SessionEntry.ID` (`searchHitID`) with its parse, here, for the server and FoundationModelsACPClient.

## Acceptance
- [ ] Each kind of entry gives the right kind, author, title and text.
- [ ] Agent messages and thoughts of a turn join; a tool call between them cuts them.
- [ ] Turn index before the first prompt, after a prompt, after a received session message.
- [ ] Cut at 2,000 characters at a line end, with the ranges of the entries.
- [ ] Cut at 64 KB for a tool call with a large terminal output.
- [ ] No chunk for a compaction or an unknown entry.
- [ ] The same entries give the same chunks; the id text form round trips.
- [ ] `swift test` is green.

#search