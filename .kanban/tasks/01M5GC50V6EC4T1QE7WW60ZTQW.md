---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m5gc55n55hnb6btq03fyyw1z
  text: |-
    ### review — findings
    - evidence: review sha 270f9e3..72f9e9c — 4 findings: HTTPMessage.swift:166, HTTPMessage.swift:169, HTTPServerTransport.swift:195, HTTPConnectionRouterTests.swift:42
    - next: fix on top of 72f9e9c (already pushed), then /review w60ztqw
  timestamp: 2026-10-21T23:18:47.717965+00:00
position_column: review
position_ordinal: '80'
title: Review of 270f9e3..72f9e9c (ACP-3, ACP-1 HTTP transport)
---
Scope: 270f9e3..72f9e9c

## Review Findings (2026-10-21 18:13)

> Scope: `review sha 270f9e3..72f9e9c` — reviewed the diffs only — lines this change added or modified. 22 file(s) reviewed, 0 not reviewed.

- [ ] `Sources/FoundationModelsACP/Transport/HTTPMessage.swift:166` `code-hygiene/magic-numbers-swift` — Magic numbers should be replaced by named constants.
- [ ] `Sources/FoundationModelsACP/Transport/HTTPMessage.swift:169` `code-hygiene/magic-numbers-swift` — Magic numbers should be replaced by named constants.
- [ ] `Sources/FoundationModelsACP/Transport/HTTPServerTransport.swift:195` `code-hygiene/magic-numbers-swift` — Magic numbers should be replaced by named constants.
- [ ] `Tests/FoundationModelsACPTests/HTTPConnectionRouterTests.swift:42` `reuse/reuse` — The `request()` helper reimplements functionality that already exists in HTTPServerTransportLiveTests.swift. This utility should be extracted to a shared test support location or reused from the existing implementation to avoid duplication. Extract `request()` to a shared test utility file (e.g., in Tests/FoundationModelsACPTests/HTTPTestSupport.swift or similar) and reuse it across both HTTPConnectionRouterTests and HTTPMessageTests, or reference the existing implementation from HTTPServerTransportLiveTests if appropriate for the unit test suite.
#review