---
assignees:
- claude-code
position_column: todo
position_ordinal: 8b80
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
