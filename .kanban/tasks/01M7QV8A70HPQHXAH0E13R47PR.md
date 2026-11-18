---
assignees:
- claude-code
position_column: done
position_ordinal: ca80
title: SAH.ForkCut in _meta.sah.forkCut of ForkSessionRequest, and the forkCut capability flag
---
D205. Brief: ../.briefs/fork/acp-brief.md, item 3.

- `SAH.ForkCut { messageId: MessageId; side: before | after }` with `extract(from:)` and `inject(into:)` at `_meta.sah.forkCut` of `ForkSessionRequest`.
- The flag `_meta.sah.forkCut = true` on `SessionForkCapabilities`, with a write and a read.
- No cut means "the last completed turn" (document it).

## Acceptance
- [ ] Round trip of `ForkSessionRequest` with and without `_meta.sah.forkCut`.
- [ ] `SessionCapabilities` decodes `fork: {"_meta": {"sah": {"forkCut": true}}}` and the read gives `true`.
- [ ] An unknown `side` decodes with its raw text.
- [ ] `swift test` is green.

#fork