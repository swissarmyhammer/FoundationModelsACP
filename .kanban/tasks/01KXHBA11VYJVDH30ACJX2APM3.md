---
comments:
- actor: wballard
  id: 01kxk70gqjpxp3qq5kdtvqxfmr
  text: |-
    Picked up. Verified the full v1 generated surface is already committed and compiling (Identifiers/Models/Unions/MethodTable/Unresolved .generated.swift); `swift run acp-generate` is a no-op ("v1: up to date … nothing regenerated"), Generated/ byte-identical (git clean). No generator changes needed.

    Implemented the wire-conformance TESTS (the remaining scope of this card), all TDD-clean hand-written to pre-empt the mechanical review findings (period-terminated doc first lines, param labels, private on file-local helpers, data-driven fixtures):

    - Tests/FoundationModelsACPTests/WireFixtureSupport.swift (shared, keeps both files DRY): jsonValue/decoded/encodedValue helpers; expectExactRoundTrip (decode→encode→structural JSONValue equality, order-independent); expectStableRoundTrip (decode→encode→decode equality, for the capability trees whose encoded form always restates defaulted sub-objects); containsNull (deep no-null scan); field accessor.
    - WireConformanceTests.swift (16 tests): initialize req+resp round-trip with protocolVersion asserted as bare integer .number(1); unknown capability field degrades to defaults (ClientCapabilities(terminal:true), unknown key dropped on re-encode); absent optionals omitted (no clientInfo/_meta key, no null anywhere); session/new req+resp; session/prompt req (text + resource_link blocks) + response over all 5 StopReason wire values; session/update every variant (11 cases, data-driven) + a coverage-guard test that the fixture set equals the known discriminator set + SessionNotification wrapper; tool_call lifecycle (pending → in_progress w/ content → completed w/ diff + rawOutput, 3 cases); RequestError over all 7 codes (-32700..-32603, -32000, -32002) with structured data, plus data-not-smuggled-through-message and absent-data-omitted assertions.
    - MetaPreservationTests.swift (4 tests): _meta (rich object incl. a nested null — data, must be preserved) round-trips untouched on request/response/notification via a shared expectMetaPreserved helper; absent _meta omitted (no field, no null).

    swift test: 108 ACPGenerateTests + 90 FoundationModelsACPTests (was 70; +20 new) = 198, exit 0, zero failures, zero warnings.
  timestamp: 2026-07-15T15:41:01.042370+00:00
- actor: wballard
  id: 01kxk79y78b2hdh82p9r7c3e7k
  text: 'really-done: verification green (swift build exit 0; swift run acp-generate no-op, Generated/ byte-identical/git clean; swift test exit 0). Adversarial double-check returned REVISE with 2 findings, both fixed same iteration:\n\n1. (medium) InitializeResponse null-omission was never asserted — expectStableRoundTrip (decode→encode→decode) normalizes null→nil on the second decode, so a spurious `agentInfo`/`_meta` null would have been masked. Added initializeResponseOmitsAbsentOptionalsNotEncodedAsNull (encodes InitializeResponse(protocolVersion:.v1), asserts agentInfo/_meta keys absent + !containsNull), mirroring the request-side test.\n2. (low) sessionUpdateFixturesCoverEveryKnownVariant comment overstated the guarantee (hand-typed literal, not type-anchored; SessionUpdate has associated values so cannot be CaseIterable). Reworded comment to state what it actually enforces and strengthened it to also assert every fixture decodes to a recognized variant (not .unknown).\n\nswift test after fixes: 108 ACPGenerateTests + 91 FoundationModelsACPTests = 199, exit 0, zero failures, zero warnings.'
  timestamp: 2026-07-15T15:46:09.768483+00:00
- actor: wballard
  id: 01kxk7ja8wnevetz6etj32h6nw
  text: 'Review pass 1 (review sha HEAD~1..HEAD): CLEAN — 0 findings, 14 rules attempted, 0 failed. Task moved doing → review → done. Converged in 1 iteration (no code-fix passes needed); the double-check REVISE findings were resolved during implement before the checkpoint commit, so the review engine saw a clean tree.\n\nFINAL STATE:\n- No generator/production changes. Full v1 generated surface was already committed, compiling, and byte-idempotent (swift run acp-generate = no-op, git clean). Acceptance criterion "Generated/ compiles with no hand edits" verified as pre-existing.\n- New tests only, all hand-written clean: Tests/FoundationModelsACPTests/WireFixtureSupport.swift (shared helpers), WireConformanceTests.swift (17 tests), MetaPreservationTests.swift (4 tests).\n- Coverage added: initialize req/resp round-trip + protocolVersion asserted as bare integer .number(1); unknown capability fields degrade to defaults; absent optionals omitted / no null on encode (both request AND response sides); session/new; session/prompt over all 5 StopReason values; session/update every variant (11, data-driven) + recognized-variant guard + SessionNotification wrapper; tool_call lifecycle (pending→in_progress→completed, 3 cases); RequestError over all 7 codes (-32700..-32603, -32000 authRequired, -32002 resourceNotFound) with structured data proven to live in `data` not the message; _meta (incl. nested null) round-trips untouched on request/response/notification.\n- swift test: 108 ACPGenerateTests + 91 FoundationModelsACPTests = 199, exit 0, zero failures, zero warnings.\n- Commit: 625ec20 (local only, not pushed).'
  timestamp: 2026-07-15T15:50:44.252700+00:00
depends_on:
- 01KXHB9KHBC38R4V0C82EM38TY
position_column: done
position_ordinal: 8a80
title: Generate and check in the full v1 type surface + wire-conformance tests
---
## What
Run the finished generator against the vendored v1.19 schema, commit `Sources/FoundationModelsACP/Generated/*.swift`, and prove wire conformance (spec §2, §3, §6):

- Commit the full generated type surface: all request/response/notification payload types, `SessionUpdate`, `ContentBlock`, `ToolCall`/`ToolCallUpdate`, `Plan`, capabilities, permission types, `RequestError` (with codes -32700…-32603 plus ACP's -32000 authRequired and -32002 resourceNotFound, structured `data: JSONValue?` — never smuggle JSON through the message string), ID newtypes, and the Unstable namespace.
- Note (spec §7.2): v1.19 unified ID naming conventions — the generated newtypes come from regeneration, never hand-patched.
- Write wire-conformance tests against real JSON fixtures matching the published protocol docs.

## Acceptance Criteria
- [ ] Generated/ compiles as part of the package with no hand edits (consumers build with zero codegen)
- [ ] `initialize` request/response fixtures round-trip, with `protocolVersion` as bare integer `1`
- [ ] `_meta` on any message survives decode→encode untouched
- [ ] Unknown capability fields degrade to defaults; absent optionals are omitted (no `null`) on encode

## Tests
- [ ] `Tests/FoundationModelsACPTests/WireConformanceTests.swift` — fixture round-trips for `initialize`, `session/new`, `session/prompt`, `session/update` (every variant), `tool_call` lifecycle, `RequestError` with structured data
- [ ] `Tests/FoundationModelsACPTests/MetaPreservationTests.swift` — `_meta` round-trip on requests, responses, and notifications
- [ ] Run `swift test` — exits 0

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.