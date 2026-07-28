---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01kykgqmwm71h8jgygcehdd29j
  text: |-
    Implementation landed. Summary:

    Verified counts against Schema/acp-v2.json directly (not trusting either the task description's stated numbers or the pre-existing test doc comment): 90 total _meta fragments, 6 say "explicit clear signal" (ToolCallUpdate, UserMessage, AgentMessage, AgentThought, TerminalUpdate, SessionInfoUpdate), 5 say "equivalent" (Terminal, CommandPermissionSubject, TerminalOutput, TerminalExitStatus, TerminalOutputChunk), 79 say nothing. This matches the pre-existing MetaFieldTests doc comment exactly (5/79/6) -- the task description's own numbers (4 equivalent / 80 nothing) were the wrong ones this time, confirming the "verify yourself" warning was warranted.

    What was built:
    - New hand-written Sources/FoundationModelsACP/Core/PatchField.swift: public enum PatchField<Wrapped: Codable & Hashable & Sendable> with cases unchanged/cleared/value(Wrapped). Does NOT conform to Codable itself -- the omit-the-key-on-unchanged behavior can only be expressed by the containing KeyedEncodingContainer deciding whether to call encode/encodeNil/nothing, not by the value's own encode(to:). Added container extensions: decodePatchField (strict), forgivingDecodePatchField, forgivingDecodePatchArray, and encodePatch.
    - GeneratorConfig.patchSemanticsFields: Set<String> keyed "Definition.field" (same shape as wireInvariantFields), populated in .acpV2 with 22 entries: UserMessage/AgentMessage/AgentThought (content, _meta each), SessionInfoUpdate (title, updatedAt, _meta), TerminalUpdate (command, cwd, output, exitStatus, _meta), ToolCallUpdate (title, kind, status, content, locations, rawInput, rawOutput, _meta). Derived directly from each definition's own description prose, not by sniffing per-field text.
    - SchemaGenerator: propertyModel() sets PropertyModel.hasPatchSemantics from the config; new validatePatchSemanticsFields(definitions:) runs at the top of generate() and throws GeneratorError.invalidSchema for any config entry whose "Definition.field" doesn't resolve to a real property -- same discipline as deprecatedMethods' stale-entry guard.
    - Emitter: renderedType/initParameter/decodeLine/encodeCall all branch on hasPatchSemantics to emit PatchField<Wrapped> (default .unchanged), decode via the three patch helpers per strategy (strict/forgivingScalar/forgivingArray all supported), encode via encodePatch.
    - Regenerated Models.generated.swift via swift run acp-generate (after rm .schema-hash).

    Non-obvious wrinkle found: Swift's "synthesized memberwise-init gets a default value from a property's own initializer" trick only works for `var` stored properties, not `let` -- confirmed empirically with throwaway repros. Since PropertyModel is all `let` (matches codebase convention), hasPatchSemantics has no default; the one pre-existing PropertyModel(...) call site in GeneratorCoreTests.swift now passes it explicitly.

    Second wrinkle: SchemaGenerator's default config parameter is .acpV2, and the new patchSemanticsFields table is validated unconditionally against whatever schema is passed to generate(). ~15 pre-existing tests across GeneratorErrorDetailTests/AnyOfUnionTests/UnknownFallbackTests/TaggedUnionTests/RoutingTableTests/GeneratorCoreTests called bare SchemaGenerator() with small synthetic schemas that don't declare AgentMessage etc., and started failing once .acpV2 carried real patch-semantics entries. Fixed by passing an explicit empty GeneratorConfig() at those call sites (verified none of those synthetic schemas depend on .acpV2-specific typeRenames/knownAcronyms/handwrittenDefinitions), with an explanatory doc comment added per affected suite.

    Tests: replaced MetaFieldTests.upsertMetaCannotYetDistinguishOmittedFromNull with its inverse (upsertMetaDistinguishesOmittedFromNullFromAValue), added sessionInfoUpdateTitleDistinguishesOmittedFromNullFromAValue (same proof for a non-_meta patch field) and nonPatchNullableFieldStillCollapsesOmittedAndNullAndStillOmitsOnEncode (proves patch semantics did NOT become the default for every nullable field, using ToolCallLocation.line). New PatchFieldTests.swift (11 tests, Core type + container helpers in isolation) and PatchSemanticsTests.swift (9 tests, generator emission via miniature schema, including two stale-config-entry-fails-generation tests). Fixed one broken runtime call site (TaggedUnionRoundTripTests: toolCall.status == .completed -> .value(.completed)) and updated VendoredSchemaTests' pinned AbsolutePath-properties list for TerminalUpdate.cwd's new PatchField<AbsolutePath> shape.

    Final state: swift build --build-tests clean (0 errors, 0 warnings); swift test all green -- 198 tests/16 suites (FoundationModelsACPTests) + 93 tests/12 suites (ACPGenerateTests) = 291 tests/28 suites total, 0 failures (up from the stated 269/26 baseline by the 22 new tests + 2 net new MetaFieldTests + 2 new suites, per Package.swift's two test targets).

    Adversarial double-check review is in flight; will report its verdict before handoff. Task left in `doing` per /implement convention.
  timestamp: 2026-07-28T04:46:37.972151+00:00
- actor: claude-code
  id: 01kykh4cspsqe2xd3ddvy0mg82
  text: |-
    Adversarial double-check (via really-done) returned PASS. It independently re-derived the 22-entry patchSemanticsFields table against Schema/acp-v2.json (confirmed complete/correct, nothing missing or extraneous), verified decode/encode symmetry and forgiving-degradation policy in PatchField.swift and the Emitter's patch branches, confirmed validatePatchSemanticsFields is well-scoped and not trivially bypassable, confirmed the GeneratorConfig() swap in six test files was the right call (not a workaround), and independently reran the build/test suite -- got the same 291 tests/28 suites, 0 failures. One noted non-issue: SourceKit's LSP index (not installed in this environment per the sah MCP setup status) threw stale false-positive "cannot find PatchField" diagnostics against the real swiftc build/test success -- a known index-lag artifact, not a real defect; no action needed since the authoritative swiftc build is what's green.

    Final fresh verification re-run just now: swift build --build-tests clean (0 errors), swift test all green (198 tests/16 suites + 93 tests/12 suites = 291/28, 0 failures).

    Leaving in `doing` per /implement convention -- ready for /review.
  timestamp: 2026-07-28T04:53:35.670706+00:00
- actor: claude-code
  id: 01kykjznjenmbk95kr51m04mby
  text: |-
    Pulled back to doing to work the 5 review findings.

    1. Emitter.swift: added a new `indent2 = indentUnit + indentUnit` constant beside the existing `indentUnit`. Swept every hardcoded one/two-level indent literal used as an indentation parameter (docLines `indent:` args, tagEnumDeclaration/valueUnionTagDeclaration `baseIndent:` args, and the "        " + line concatenations in memberwiseInit/codingKeys/decoderInit/encodeMethod/unionStructDecoder/unionStructEncoder) to use indentUnit/indent2, plus one embedded case inside tagEnumDeclaration ("\(baseIndent)    case" -> "\(baseIndent)\(indentUnit)case"). Left the many literal template strings that mix code content with baked-in indentation (e.g. "    public var \(name): ...") untouched -- those aren't standalone "indentation," they're specific source-line templates at a fixed nesting depth, and rewriting them would be a much larger, out-of-scope restructuring not what the finding asked for.

    2. PatchField.swift: extracted a private `forgivingDecodePatch<Value>(forKey:decodeValue:)` helper running the shared contains/decodeNil/nil-check guard sequence, parameterized over a `() -> Value?` closure for the final decode+transform step. `forgivingDecodePatchField` and `forgivingDecodePatchArray` now both call it with their own closure.

    3,4,5. Root cause: GeneratorConfig.swift's `.acpV2` config had an explicit `typeRenames: ["RequestId": "RequestID"]` entry (comment claimed "Swift API Design Guidelines cased acronym" justification) that deliberately overrode the schema's own `RequestId` definition name to the wrong casing -- confirmed via Schema/acp-v2.json (definition is literally named "RequestId" already). Deleted that typeRenames entry entirely; no replacement entry needed since removing the override lets the normal pipeline emit "RequestId" directly. Regenerated Models.generated.swift and Unresolved.generated.swift via `swift run acp-generate` (had to delete the checked-in Generated/.schema-hash stamp first, since the schema bytes didn't change -- only the generator config did -- so the hash-based skip would otherwise have no-op'd). Verified via grep that RequestID was the ONLY generated identifier type with the uppercase-ID inconsistency: grepped Models.generated.swift for `\b[A-Za-z]*ID\b` and every other hit was doc-comment prose ("The ID of the request"), never a type declaration; grepped for `(struct|enum|typealias) [A-Za-z]*ID\b` across Generated/ and got zero matches after the fix. Updated hand-written RequestID type references (NOT the unrelated nextRequestId variable) in Connection.swift (9 sites) and VendoredSchemaTests.swift (2 sites: a doc comment plus the pinned onlyTheDeliberatelyFreeFormDefinitionsStayUntyped type list).

    Verification: `swift build --build-tests` clean (0 errors, 0 warnings). `swift test` fresh run: 198 tests/16 suites (FoundationModelsACPTests) + 93 tests/12 suites (ACPGenerateTests) = 291 tests/28 suites, 0 failures, 0 warnings -- matches baseline exactly, no regression or unexpected growth. `git diff --stat -- Sources/FoundationModelsACP/Generated/` shows exactly the expected scope: 18 changed lines in Models.generated.swift, 2 in Unresolved.generated.swift, all RequestID->RequestId. VendoredSchemaTests.checkedInOutputMatchesAFreshRun and declarationsAreEmittedInSortedSchemaNameOrder (the codegen diff/order gates) both pass, confirming the regenerated output is deterministic and the checked-in files match a fresh run byte-for-byte.

    Adversarial double-check dispatched via really-done; verdict pending -- will follow up with result before final handoff. Left in `doing` per /implement convention.
  timestamp: 2026-07-28T05:25:57.966158+00:00
- actor: claude-code
  id: 01kykk4js75wqbdysczbezgh11
  text: |-
    Adversarial double-check (via really-done) returned PASS. Independently verified (not just trusting the claims above):

    - Emitter.swift: confirmed via diff that every indent-parameter hardcode (`indent:`, `baseIndent:`, and the "        " + line concatenations) was replaced with indentUnit/indent2, including the embedded `"\(baseIndent)    case ..."` fix; grepped for any remaining hardcoded indent-parameter patterns and found none; confirmed the scoping judgment (leaving content templates like "    public var \(name): ..." untouched) is reasonable, not a half-measure.
    - PatchField.swift: diffed old vs new and confirmed the extracted forgivingDecodePatch helper reproduces the original four-guard sequence byte-for-byte in control flow, with forgivingDecodePatchField/forgivingDecodePatchArray differing only in their closures (which match their original final-step logic exactly, including the array case's `.map { $0.compactMap(\.value) }`).
    - RequestID->RequestId: confirmed the schema names the definition "RequestId" already (Schema/acp-v2.json), the typeRenames override was fully removed, Models.generated.swift shows exactly 9 renamed occurrences, Unresolved.generated.swift shows the 1 typealias rename, Connection.swift shows 9 renamed sites with nextRequestId correctly untouched, VendoredSchemaTests.swift shows both claimed sites updated. Independently grepped all of Sources/ and Tests/ for RequestID (zero hits) and for any other ...ID-suffix generated type name (zero found) -- confirming RequestID was the only such inconsistency.
    - Independently re-ran swift build (clean) and swift test (198+93=291 tests/28 suites, 0 failures) plus checkedInOutputMatchesAFreshRun and declarationsAreEmittedInSortedSchemaNameOrder (both pass), confirming deterministic byte-identical regeneration.
    - Confirmed the ~100 stale SourceKit diagnostics on Models.generated.swift are the documented missing-sourcekit-lsp false positives, correctly disregarded.

    No scope drift, no debug artifacts, no TODOs/stubs introduced.

    Final fresh verification (this agent, just now): swift build --build-tests clean (0 errors, 0 warnings); swift test 198 tests/16 suites + 93 tests/12 suites = 291/28, 0 failures, 0 warnings -- matches the pre-existing 291/28/0/0 baseline exactly.

    All 5 review findings closed. Leaving in `doing` per /implement convention -- ready for /review.
  timestamp: 2026-07-28T05:28:38.951702+00:00
- actor: claude-code
  id: 01kykna69pk50e1nk6w3s2wm8z
  text: |-
    Pulled back to doing again to close the round-2 review findings (44 cited "hardcoded indentation literal" items in Emitter.swift, plus the "1/48 sub-tasks failed — INCOMPLETE" warning implying more exist beyond the 44).

    Did a fully exhaustive pass rather than patching the 44 cited lines: wrote a Python script that scans every string literal in Emitter.swift for content starting with a run of leading spaces in a multiple of 4 (4/8/12/16), and mechanically rewrites each as `indentUnit + "..."` / `indent2 + "..."` / `indent3 + "..."` / `indent4 + "..."`, extracting just the leading-space run and leaving the rest of the string's content untouched. Added two new constants following the existing `indent2 = indentUnit + indentUnit` pattern: `indent3 = indentUnit + indent2` and `indent4 = indent2 + indent2` (8 occurrences needed 4-level/16-space indentation, inside nested switch-case bodies in the value-union decoder/encoder).

    Scope decision: this round supersedes the previous round's narrower judgment call (which left "content templates" like `"    public let rawValue: String"` untouched as out-of-scope restructuring) — round 2's checklist explicitly asked for exactly those lines to change, and doing a partial sweep is what produced two consecutive "incomplete" findings. Every leading-whitespace-only prefix on every string literal is now expressed via the indent constants; the only literal `"    "`-style content left untouched is the `header` triple-quoted banner constant (real file-banner text, not a reusable per-declaration indentation level) and the `indentUnit`/`indent2` constant definitions themselves.

    Result: 236 lines changed, one mechanical script pass. Verified via Python regex sweep of the final file: zero remaining string literals anywhere in Emitter.swift start with a 4-space-multiple leading run (excluding the indentUnit definition and header banner).

    Verification: `swift build --build-tests` clean (0 errors, 0 warnings). `swift test`: 198 tests/16 suites + 93 tests/12 suites = 291/28, 0 failures, 0 warnings — matches baseline exactly. Codegen diff gate: deleted `.schema-hash`, ran `swift run acp-generate`, `git diff --stat -- Sources/FoundationModelsACP/Generated/` is empty — byte-for-byte no-op confirmed (expected, since indentUnit/indent2/indent3/indent4 still literally equal the same space strings).

    Noted but explicitly out of scope: a fresh review pass on this diff surfaced a *different* duplication category — repeated non-indentation content string literals (e.g. `"public init(from decoder: any Decoder) throws {"` appearing verbatim in 4 functions). That's not an indentation-literal issue and isn't part of this task's checklist, so I filed it separately as ^hpcfzdb rather than scope-creeping into it here.

    Adversarial double-check dispatched via really-done; verdict pending. Will follow up before final handoff. Left in `doing` per /implement convention.
  timestamp: 2026-07-28T06:06:39.926431+00:00
- actor: claude-code
  id: 01kyknfeg3hqq4e4f8bpbjdqnm
  text: |-
    Adversarial double-check (via really-done) returned PASS. Independently verified: only Emitter.swift modified under Sources/ (no scope creep, no Tests/ changes); walked the full 826-line diff end to end covering every function named in the review checklist plus the value-union decoder/encoder helpers, confirming every replacement's indent depth matches the original literal's space count (indentUnit=4, indent2=8, indent3=12, indent4=16) with byte-identical trailing content — no corruption, merges, or splits; grepped for any remaining hardcoded indentation literal and found only the indentUnit constant's own definition line; independently ran a fresh clean build (rm -rf .build && swift build --build-tests) — 0 errors, 0 warnings; independently ran swift test — 198 tests/16 suites + 93 tests/12 suites = 291/28, 0 failures; independently regenerated codegen output (rm .schema-hash && swift run acp-generate) and confirmed git diff on Generated/ is empty — byte-for-byte no-op. No TODO/debug artifacts. No findings.

    Final tally: 236 hardcoded indentation-literal instances fixed in this pass (the 44 cited by round 2's checklist plus the additional ones its own "1/48 sub-tasks failed — INCOMPLETE" warning implied were still out there). Final grep-verification: zero remaining reusable-indentation literals in Emitter.swift.

    All review findings from both rounds closed. Leaving in `doing` per /implement convention — ready for /review.
  timestamp: 2026-07-28T06:09:32.163114+00:00
position_column: doing
position_ordinal: '80'
title: 'Three-state patch semantics for upsert fields: omitted, null-clears, value-replaces'
---
## What

v2 gives upsert fields **three** wire states, and the generated Swift types have two.

The schema says it in two places. On the six upsert `_meta` fields — `UserMessage`, `AgentMessage`, `AgentThought`, `SessionInfoUpdate`, `TerminalUpdate`, `ToolCallUpdate` — the description reads:

> Omitted means no metadata update; `null` is an explicit clear signal.

And on the definitions themselves, for their other fields:

> Other fields have patch semantics: omitted fields leave the stored value unchanged, `null` clears it, and concrete values replace it. When the terminal ID is new, omitted fields start unset.

`UserMessage`, `AgentMessage`, and `AgentThought` say the same of `content` specifically ("an omitted field leaves existing message content unchanged, `null` clears the value, and a concrete array replaces the previous value").

Every one of those fields generates today as a Swift `Optional`, decoded with `decodeIfPresent`/`forgivingDecodeIfPresent` and encoded with `encodeIfPresent`. Omitted and `null` both decode to `nil`, and `nil` encodes as an omitted key. **A client that means "clear this" sends "leave it unchanged".**

## Why it was not fixed in M1

M1 owned the type system, and this is a type-system gap, so the boundary is worth stating: M1 closed the *placeholder* seam — the definitions that were raw `JSONValue` — and typed these payloads for the first time. Expressing the third state is a different change, it lands entirely inside the `session/update` surface, and M7 is the milestone that owns those variants end to end.

It is also not a small change. It needs a tri-state wrapper (`case unchanged` / `case cleared` / `case value(Wrapped)`) with hand-rolled `Codable`, *and* a way for the generator to know which fields have patch semantics. The schema states the rule in **prose only** — there is no keyword to read — which is exactly the case `GeneratorConfig`'s override mechanism documents itself as existing for ("The override mechanism stays for schema revisions that describe an invariant in prose alone"). Sniffing the description text would be brittle; a config table is the honest option, and it needs the same "every entry must name a real field or generation fails" guard `deprecatedMethods` has, so a stale entry cannot linger past a re-vendor.

## Where the gap is pinned today

`Tests/FoundationModelsACPTests/MetaFieldTests.swift` →
`upsertMetaCannotYetDistinguishOmittedFromNull`. It asserts the *current*
behaviour — that omitted and `null` are indistinguishable — so the failing
assertion is the reminder when this task lands. The suite's doc comment carries
the counts: of the 90 `_meta` fragments in the vendored document, 6 say `null`
clears, 4 say omitted and `null` are equivalent, and 80 say nothing either way.

## Acceptance Criteria

- [ ] A field with patch semantics distinguishes omitted, `null`, and a value, in both directions.
- [ ] Which fields have patch semantics is configuration or a schema-read, not a heuristic over description prose.
- [ ] A stale configuration entry — a field the schema no longer has — fails generation rather than being ignored.
- [ ] Fields *without* patch semantics keep the plain `Optional` shape; this must not become the default for every nullable field.
- [ ] `MetaFieldTests.upsertMetaCannotYetDistinguishOmittedFromNull` is replaced by its inverse.

## Tests

- [ ] Omitted, `null`, and a concrete value decode to three distinct states and re-encode to three distinct documents.
- [ ] `null` survives a decode/encode round trip as `null`, not as an omitted key.
- [ ] A non-patch nullable field still collapses omitted and `null`, and still omits on encode.

## Review Findings (2026-07-27 23:58)

- [ ] `Sources/ACPGenerateCore/Emitter.swift:85` — The `indentUnit` constant defined at line 14 is barely used; hardcoded indentation strings like `"    "` and `"        "` appear throughout the file instead, violating the repeated-literals rule. Use `indentUnit` instead of hardcoded indentation strings. Either use `"\(indentUnit)"` directly, or create level-specific constants: `let indent1 = indentUnit`, `let indent2 = indentUnit + indentUnit`, `let indent3 = indentUnit + indentUnit + indentUnit`. This enables single-point maintenance if indentation width ever changes.
- [ ] `Sources/FoundationModelsACP/Core/PatchField.swift:52` — forgivingDecodePatchField and forgivingDecodePatchArray share verbatim control flow: both open with three identical guard statements (contains, decodeNil, nil check) before diverging only in the final value decode and transformation. This shared pattern could drift independently in each copy. Extract a shared helper that handles the common key-presence-and-nil-checking logic, parameterized over how the value is decoded and transformed. For example: a helper that takes a closure for the decode+transform step, so both functions reuse the guard structure and only pass different decode strategies.
- [ ] `Sources/FoundationModelsACP/Generated/Models.generated.swift:560` — `RequestID` type uses uppercase `ID` suffix, inconsistent with other generated ACP identifier types; see also line 1360 and line 1755 for identical violations. Rename RequestID to RequestId to match the `…Id` pattern for ACP-generated identifier types.
- [ ] `Sources/FoundationModelsACP/Generated/Models.generated.swift:1360` — `RequestID` type uses uppercase `ID` suffix, inconsistent with other generated ACP identifier types; see also line 560 and line 1755 for identical violations. Rename RequestID to RequestId to match the `…Id` pattern for ACP-generated identifier types.
- [ ] `Sources/FoundationModelsACP/Generated/Models.generated.swift:1755` — Type name `RequestID` uses uppercase `ID` suffix while all other generated ACP identifier types in this file use `Id` suffix (SessionId, MessageId, ToolCallId, TerminalId, PermissionOptionId, AuthMethodId, SessionConfigId, etc.). This violates uniform acronym casing per the project exception that establishes the `…Id` pattern for generated identifier types. Rename RequestID type to RequestId to match the documented `…Id` pattern for ACP-generated identifier types in the project exception.

Note: two engine findings on `Tests/ACPGenerateTests/UnknownFallbackTests.swift` (dead/duplicate local `decode` helpers at lines 140 and 205) were dropped from this checklist per the review skill's blanket exception — their subject is refactoring already-existing test code, which is out of scope regardless of validator flags.

## Review Findings (2026-07-28 00:32)

> ⚠️ 1/48 review tasks failed — results are INCOMPLETE.

- [ ] `Sources/ACPGenerateCore/Emitter.swift:117` — Hardcoded 4-space indentation literal '    ' in `identifierNewtype()` should use `indentUnit` constant. This pattern repeats throughout the function (lines 117–127) rather than using the configurable constant defined at line 13. Replace each `"    ` string prefix with `indentUnit + "` and each `"        ` with `indent2 + "`.
- [ ] `Sources/ACPGenerateCore/Emitter.swift:118` — Hardcoded 4-space indentation in `identifierNewtype()` should use `indentUnit`. Part of the same pattern as line 117 in this function. Replace `"    public let rawValue: String"` with `indentUnit + "public let rawValue: String"`.
- [ ] `Sources/ACPGenerateCore/Emitter.swift:122` — Hardcoded 4-space indentation in `identifierNewtype()` should use `indentUnit`. Replace with `indentUnit + "public init(rawValue: String) {"`.
- [ ] `Sources/ACPGenerateCore/Emitter.swift:123` — Hardcoded 8-space (double) indentation in `identifierNewtype()` should use `indent2`. Replace with `indent2 + "self.rawValue = rawValue"`.
- [ ] `Sources/ACPGenerateCore/Emitter.swift:161` — Hardcoded 4-space indentation in `structDeclaration()` should use `indentUnit`. Replace with `indentUnit + "/// Creates"`.
- [ ] `Sources/ACPGenerateCore/Emitter.swift:162` — Hardcoded 4-space indentation in `structDeclaration()` should use `indentUnit`. Replace with `indentUnit + "public init() {}"`.
- [ ] `Sources/ACPGenerateCore/Emitter.swift:198` — Hardcoded 4-space indentation in `memberwiseInit()` should use `indentUnit`. First of multiple hardcoded indents in this function. Replace string literals with `indentUnit + "..."` to use the configurable constant.
- [ ] `Sources/ACPGenerateCore/Emitter.swift:199` — Hardcoded 4-space indentation in `memberwiseInit()` array literal should use `indentUnit`. Replace with `indentUnit + "public init("` within the array literal.
- [ ] `Sources/ACPGenerateCore/Emitter.swift:201` — Hardcoded 4-space indentation in `memberwiseInit()` should use `indentUnit`. Replace with `indentUnit + ") {"` for consistency.
- [ ] `Sources/ACPGenerateCore/Emitter.swift:204` — Hardcoded 4-space indentation in `memberwiseInit()` should use `indentUnit`. Replace with `indentUnit + "}"` to centralize indent-width configuration.
- [ ] `Sources/ACPGenerateCore/Emitter.swift:263` — Hardcoded indentation literal '    ' should use the `indentUnit` constant defined at line 13. This same function uses `indent2` on line 265, showing inconsistent maintenance of indent width — a single point of control is needed. Replace `"    private enum CodingKeys: String, CodingKey {"` with `indentUnit + "private enum CodingKeys: String, CodingKey {"` to use the configurable constant.
- [ ] `Sources/ACPGenerateCore/Emitter.swift:267` — Hardcoded indentation literal '    ' should use the `indentUnit` constant. The closing brace of `codingKeys()` repeats what line 263 should already express via the constant. Replace `"    }"` with `indentUnit + "}"` for consistency with the constant-based indentation already used in the function.
- [ ] `Sources/ACPGenerateCore/Emitter.swift:275` — Hardcoded 4-space indentation in `decoderInit()` doc-comment lines should use `indentUnit`. Multiple doc lines (275–279) hardcode indentation. Apply `indentUnit` to each doc line, e.g., `indentUnit + "/// Decodes..."`, rather than hardcoding.
- [ ] `Sources/ACPGenerateCore/Emitter.swift:280` — Hardcoded indentation in `decoderInit()` should use constants. The function uses `indent2` on line 284 but hardcodes 4-space and 8-space indents throughout lines 275–287, violating the single-point-of-maintenance principle. Replace hardcoded indentation strings with `indentUnit` and `indent2` throughout the function, matching the pattern already used on line 284.
- [ ] `Sources/ACPGenerateCore/Emitter.swift:282` — Hardcoded 4-space indentation in `decoderInit()` should use `indentUnit`. Replace with `indentUnit + "public init(from decoder..."` to use the configurable constant.
- [ ] `Sources/ACPGenerateCore/Emitter.swift:283` — Hardcoded 8-space (double) indentation in `decoderInit()` should use `indent2`. Replace with `indent2 + "let container..."` for consistency.
- [ ] `Sources/ACPGenerateCore/Emitter.swift:286` — Hardcoded 4-space indentation in `decoderInit()` should use `indentUnit`. Replace with `indentUnit + "}"` to maintain a single indent-width constant.
- [ ] `Sources/ACPGenerateCore/Emitter.swift:322` — Hardcoded 4-space indentation in `encodeMethod()` doc-comment array should use `indentUnit`. Multiple doc lines (322–328) hardcode indents. Apply `indentUnit` to each doc line rather than hardcoding the indentation.
- [ ] `Sources/ACPGenerateCore/Emitter.swift:331` — Hardcoded 4-space indentation in `encodeMethod()` should use `indentUnit`. Replace with `indentUnit + "public func encode..."` to use the configurable constant.
- [ ] `Sources/ACPGenerateCore/Emitter.swift:332` — Hardcoded 8-space (double) indentation in `encodeMethod()` should use `indent2`. Replace with `indent2 + "var container..."` for consistency.
- [ ] `Sources/ACPGenerateCore/Emitter.swift:340` — Hardcoded 4-space indentation in `encodeMethod()` should use `indentUnit`. Replace with `indentUnit + "}"` to centralize indent-width maintenance.
- [ ] `Sources/ACPGenerateCore/Emitter.swift:409` — Hardcoded 4-space indentation in `unknownCaseDoc()` should use `indentUnit`. The entire function hardcodes doc-comment indents. Replace each doc-comment line with `indentUnit + "/// ..."`.
- [ ] `Sources/ACPGenerateCore/Emitter.swift:410` — Hardcoded 4-space indentation in `unknownCaseDoc()` doc-comment lines should use `indentUnit`. Lines 410–416 all hardcode indentation. Apply `indentUnit` to each doc line, e.g., `indentUnit + "/// of the object..."`, rather than hardcoding.
- [ ] `Sources/ACPGenerateCore/Emitter.swift:411` — Hardcoded 4-space indentation in `unknownCaseDoc()` should use `indentUnit`. This function has multiple consecutive doc-comment lines with hardcoded indents (lines 411–416). Apply `indentUnit` to each doc-comment line instead of hardcoding indentation throughout the function.
- [ ] `Sources/ACPGenerateCore/Emitter.swift:412` — Hardcoded 4-space indentation in `unknownCaseDoc()` should use `indentUnit`. Replace with `indentUnit + "///"` to use the configurable constant.
- [ ] `Sources/ACPGenerateCore/Emitter.swift:413` — Hardcoded 4-space indentation in `unknownCaseDoc()` should use `indentUnit`. Apply `indentUnit` instead of hardcoding the indentation.
- [ ] `Sources/ACPGenerateCore/Emitter.swift:414` — Hardcoded 4-space indentation in `unknownCaseDoc()` should use `indentUnit`. Replace with `indentUnit + "/// beside this union..."` to use the configurable constant.
- [ ] `Sources/ACPGenerateCore/Emitter.swift:415` — Hardcoded 4-space indentation in `unknownCaseDoc()` should use `indentUnit`. Apply `indentUnit` instead of hardcoding the indentation.
- [ ] `Sources/ACPGenerateCore/Emitter.swift:416` — Hardcoded 4-space indentation in `unknownCaseDoc()` should use `indentUnit`. Replace with `indentUnit + "/// an `EncodingError`"` to centralize indent-width maintenance.
- [ ] `Sources/ACPGenerateCore/Emitter.swift:436` — Hardcoded 8-space (double) indentation in `unknownDecodeArm()` should use `indent2`. Replace with `indent2 + "\(pattern)"` to use the configurable constant.
- [ ] `Sources/ACPGenerateCore/Emitter.swift:437` — Hardcoded 12-space (triple) indentation in `unknownDecodeArm()` should use a constant or computed value. Use a named constant or compute `indent2 + indentUnit` rather than hardcoding 12 spaces.
- [ ] `Sources/ACPGenerateCore/Emitter.swift:449` — Hardcoded 4-space indentation in `excludedMembersDeclaration()` should use `indentUnit`. Replace with `indentUnit + "private static let excludedMembers..."` to centralize indent-width maintenance.
- [ ] `Sources/ACPGenerateCore/Emitter.swift:517` — Hardcoded 8-space (double) indentation in `unknownEncodeArm()` should use `indent2`. Replace with `indent2 + "case .unknown..."` to use the configurable constant.
- [ ] `Sources/ACPGenerateCore/Emitter.swift:518` — Hardcoded 12-space (triple) indentation in `unknownEncodeArm()` should use a constant or computed value. Use `indent2 + indentUnit` rather than hardcoding 12 spaces.
- [ ] `Sources/ACPGenerateCore/Emitter.swift:559` — Hardcoded 4-space indentation in `scalarEnumDeclaration()` should use `indentUnit`. This large function has many hardcoded indents throughout. Apply `indentUnit` and `indent2` throughout this function for consistency with other emitter functions and to maintain a single indent-width constant.
- [ ] `Sources/ACPGenerateCore/Emitter.swift:560` — Hardcoded 4-space indentation in `scalarEnumDeclaration()` should use `indentUnit`. This large function has many hardcoded indents throughout. Apply `indentUnit` consistently throughout this function instead of hardcoding indentation.
- [ ] `Sources/ACPGenerateCore/Emitter.swift:572` — Hardcoded 4-space indentation in `scalarEnumDeclaration()` should use `indentUnit`. Replace with `indentUnit + "public var wireValue..."` to use the configurable constant.
- [ ] `Sources/ACPGenerateCore/Emitter.swift:573` — Hardcoded 8-space (double) indentation in `scalarEnumDeclaration()` should use `indent2`. Replace with `indent2 + "switch self..."` for consistency.
- [ ] `Sources/ACPGenerateCore/Emitter.swift:691` — Hardcoded 4-space indentation in `taggedUnionDeclaration()` should use `indentUnit`. This large function has many hardcoded indents throughout. Apply `indentUnit` consistently throughout this function instead of hardcoding indentation.
- [ ] `Sources/ACPGenerateCore/Emitter.swift:697` — Hardcoded 4-space indentation in `taggedUnionDeclaration()` should use `indentUnit`. Replace with `indentUnit + "case unknown(String, JSONValue)"` to use the configurable constant.
- [ ] `Sources/ACPGenerateCore/Emitter.swift:708` — Hardcoded indentation in `taggedUnionDeclaration()` should use `indentUnit` or `indent2`. This large function has numerous hardcoded indent strings. Systematically replace hardcoded indentation strings with `indentUnit` and `indent2` throughout this function to maintain a single point of indent-width configuration.
- [ ] `Sources/ACPGenerateCore/Emitter.swift:823` — Hardcoded 4-space indentation in `discriminatedUnionDeclaration()` should use `indentUnit`. Replace with `indentUnit + "case unknown(String, JSONValue)"` to use the configurable constant.
- [ ] `Sources/ACPGenerateCore/Emitter.swift:1027` — Hardcoded 4-space indentation in `valueUnionEnum()` should use `indentUnit`. Apply `indentUnit` consistently throughout this function instead of hardcoding indentation.
- [ ] `Sources/ACPGenerateCore/Emitter.swift:1028` — Hardcoded 4-space indentation in `valueUnionEnum()` should use `indentUnit`. Replace with `indentUnit + "public enum"` to use the configurable constant.
- [ ] `Sources/ACPGenerateCore/Emitter.swift:1080` — Hardcoded 4-space indentation in `unionStructInit()` should use `indentUnit`. This function has hardcoded indents for its doc comment and declarations. Apply `indentUnit` consistently throughout this function instead of hardcoding indentation.
- [ ] `Sources/ACPGenerateCore/Emitter.swift:1081` — Hardcoded 4-space indentation in `unionStructInit()` should use `indentUnit`. Replace with `indentUnit + "public init"` to use the configurable constant.
- [ ] `Sources/ACPGenerateCore/Emitter.swift:1111` — Hardcoded 4-space indentation in `unionStructDecoder()` should use `indentUnit`. This large function has hardcoded indents throughout. Apply `indentUnit` consistently throughout this function instead of hardcoding indentation.
- [ ] `Sources/ACPGenerateCore/Emitter.swift:1136` — Hardcoded 4-space indentation in `unionStructEncoder()` should use `indentUnit`. This function has hardcoded indents for its doc comment and method declaration. Apply `indentUnit` consistently throughout this function instead of hardcoding indentation.
