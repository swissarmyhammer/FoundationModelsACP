---
assignees:
- claude-code
position_column: done
position_ordinal: cd80
title: 'ACPImport target: Claude Code and Codex session readers (D209)'
---
D209 (TestudoApp/features/decisions.md), parts (b), (c), (d), (m). Brief: ../.briefs/import/acp-brief.md.

## Work
- A new library target and product `ACPImport` that depends only on `FoundationModelsACP`. No file access: each function takes `Data`.
- `ImportSourceAgent`, `ImportedSessionMetadata`, `ImportedSession`, `ImportReadError`.
- `ClaudeCodeSessionReader` and `CodexSessionReader`, each with `read(_:)` and the fast `metadata(_:)` scan.
- The map of D209 (c); stable wire ids from the source ids; unknown records, fields and broken lines skipped and counted.

## Acceptance
- [ ] Golden tests for each reader, with hand-written fixtures and the expected updates as JSON; a second read gives the same updates and ids.
- [ ] The merge engine and the ACPMarkdown renderer take the updates with no unknown update.
- [ ] An unknown record, an unknown block, a broken line, a file with no readable record, a file of the other format.
- [ ] The metadata scan of a large generated file is fast (a measured bound).
- [ ] `swift test` is green.

#import