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
