---
assignees:
- claude-code
position_column: done
position_ordinal: c680
title: Move SessionMergeEngine.init(replaying:) into the core target as public
---
D202 (TestudoApp/features/decisions.md). Brief: ../.briefs/export-markdown/acp-brief.md, item 3 of "Proposed API".

FoundationModelsACPAgent has `SessionMergeEngine.init(replaying:)` as an internal extension (FoundationModelsACPAgent/Sources/FoundationModelsACPAgent/Agent/SessionHistory.swift:136-146). Add it to the core target `FoundationModelsACP` as a `public` initializer with the same body. The ACPAgent session then removes its copy.

## Acceptance
- [ ] `public init(replaying updates: some Sequence<SessionUpdate>)` (or the same signature as the ACPAgent copy) on `SessionMergeEngine`, with documentation.
- [ ] A test: the engine from `init(replaying:)` equals an engine that applies the same updates one by one.
- [ ] `swift build` and `swift test` are green.

#export-markdown