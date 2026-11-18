---
assignees:
- claude-code
position_column: done
position_ordinal: c780
title: 'New ACPMarkdown target: SessionMarkdown renderer with golden tests'
---
D202 (TestudoApp/features/decisions.md). Brief: ../.briefs/export-markdown/acp-brief.md. That brief has the full rules of the document and the list of tests.

## Work
- A new library target and product `ACPMarkdown`, path `Sources/ACPMarkdown`, that depends only on `FoundationModelsACP`.
- `public enum SessionMarkdown` with `render(updates:options:)` and `render(entries:sessionInfo:options:)`.
- `public struct Options` (`includeThoughts`, `title`, `agentName`, `labels`) and `public struct Labels` with `.english`.
- A test target `ACPMarkdownTests` with golden pairs in `Tests/ACPMarkdownTests/Golden/<name>.ndjson` and `<name>.md`, and a rewrite mode through an environment variable.

## Acceptance
- [ ] One golden pair for each kind in the brief (messages, thoughts off and on, tool calls, diffs with and with no patch, terminals, plan that changes three times, session messages received and sent, `_meta.sah.message`, compaction, unknown update, unknown content block, four backticks).
- [ ] A golden file for `Tests/FoundationModelsACPTests/Fixtures/full-session-agent.ndjson`.
- [ ] Stability: two renders are the same; the render of `engine.transcriptUpdates` is the same as the first render.
- [ ] `render(updates:)` and `render(entries:)` give the same text.
- [ ] Labels that are not English change only the fixed words.
- [ ] `swift build` and `swift test` are green.

#export-markdown