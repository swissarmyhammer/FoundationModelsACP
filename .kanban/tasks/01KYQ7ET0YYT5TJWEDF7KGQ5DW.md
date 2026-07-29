---
comments:
- actor: claude-code
  id: 01kyq9nznz8x0cd2fdag08r2a1
  text: |-
    Investigated before starting implementation. Checked upstream releases: `gh api repos/agentclientprotocol/agent-client-protocol/releases --paginate --jq '.[].tag_name' | grep '^schema-v2'` returns only `schema-v2.0.0-alpha.2` and `schema-v2.0.0-alpha.1` — no newer schema-v2 tag exists yet. `schema-v2.0.0-alpha.2` is exactly what's already vendored (see Schema/README.md).

    This task's premise (a newer tag exists carrying the elicitation promotion) is not yet true. Schema/README.md itself says the elicitation promotion is on upstream `main` only, not any tagged release, and explicitly states the project's policy is to track tagged releases only ("main is a moving target"). Re-vendoring from `main` would violate that stated policy.

    Leaving this in `todo`, not actionable right now — same situation as the earlier ^dsefdb7 task (blocked on an external precondition, not a code/design blocker). Not moving to `doing`. ^enzjy0q remains correctly blocked on this.
  timestamp: 2026-07-29T16:00:21.183091+00:00
- actor: claude-code
  id: 01kyqa7ym2tfydxa5mqmr85qjs
  text: Closed as done per user decision, not because the re-vendor was actually performed. No newer schema-v2 tag exists upstream (confirmed via gh api — only schema-v2.0.0-alpha.1/alpha.2, alpha.2 already vendored). User chose to close this out rather than leave it parked waiting on an upstream release with no ETA. If a new schema-v2 tag carrying the elicitation promotion ships later, this should be re-opened (or a fresh task filed) to actually do the re-vendor.
  timestamp: 2026-07-29T16:10:09.922729+00:00
position_column: done
position_ordinal: '9380'
title: Re-vendor the ACP schema past schema-v2.0.0-alpha.2 to pick up stable elicitation
---
Schema/README.md records that upstream main promotes elicitation/create and elicitation/complete, plus ~20 Elicitation*/PropertySchema definitions, from unstable to stable. Bump the vendored tag, run swift package generate-acp, and update the digest table in Schema/README.md. This is the one prerequisite for the elicitation payload-type task. Consumer: FoundationModelsACPAgent plan section 16.