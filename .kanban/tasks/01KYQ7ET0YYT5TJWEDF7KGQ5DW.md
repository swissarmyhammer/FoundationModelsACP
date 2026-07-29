---
position_column: todo
position_ordinal: '8280'
title: Re-vendor the ACP schema past schema-v2.0.0-alpha.2 to pick up stable elicitation
---
Schema/README.md records that upstream main promotes elicitation/create and elicitation/complete, plus ~20 Elicitation*/PropertySchema definitions, from unstable to stable. Bump the vendored tag, run swift package generate-acp, and update the digest table in Schema/README.md. This is the one prerequisite for the elicitation payload-type task. Consumer: FoundationModelsACPAgent plan section 16.