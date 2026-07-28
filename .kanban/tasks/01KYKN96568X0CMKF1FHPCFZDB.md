---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01kymgd8js3bxqxegqm1s411qc
  text: |-
    Implementation done, verification green, adversarial double-check in progress.

    Ran a script-based sweep for repeated pure-literal string content (>= 15 chars, excluding interpolated `\(...)` fragments) across the whole file, not just the 5 named examples. Found and fixed 10 distinct fragments (44 total call sites):

    - decoderInitOpening = "public init(from decoder: any Decoder) throws {" — 6 sites (decoderInit, scalarEnumDeclaration, taggedUnionDeclaration, discriminatedUnionDeclaration, valueUnionDecoder, unionStructDecoder). Task description named only 4 of these 6.
    - encodeMethodOpening = "public func encode(to encoder: any Encoder) throws {" — 6 sites (encodeMethod, scalarEnumDeclaration, taggedUnionDeclaration, discriminatedUnionDeclaration, valueUnionEncoder, unionStructEncoder).
    - decoderContainerDeclaration = "let container = try decoder.container(keyedBy: CodingKeys.self)" — 5 sites. Not named in task description; found by the sweep.
    - encoderContainerDeclaration = "var container = encoder.container(keyedBy: CodingKeys.self)" — 5 sites. Matches task's named example.
    - payloadEncodeCall = "try payload.encode(to: encoder)" — 2 sites. Matches task's named example.
    - decoderParameterDoc = "/// - Parameter decoder: The decoder positioned at the object." — 5 sites. Doc-comment duplicate found by the sweep, not named in the task.
    - encoderParameterDoc = "/// - Parameter encoder: The encoder to write the object into." — 5 sites. Same category.
    - encoderThrowsDoc = "/// - Throws: Rethrows any error from the underlying encoder." — 6 sites. Same category.
    - schemaDefaultsDoc = "/// schema defaults instead of failing the message." — 2 sites (decoderInit, unionStructDecoder). Second line of a 2-line doc comment whose first line still varies by interpolated type name.
    - tagSwitchOpening = "switch Tag(rawValue: discriminator) {" — 2 sites (taggedUnionDeclaration, valueUnionDecoderBody's capturesTag branch).

    The task's own named example "case unknown(String, JSONValue)" was already deduped by the prior task (^1pfngj1) via `unknownUnionCaseDeclaration` — confirmed only 1 occurrence remains (the constant's own definition), so no further action needed there.

    Deliberately left alone: literals containing `\(...)` interpolation (e.g. `"case .\(unionCase.swiftName)(let payload):"`, count 4) — these aren't literal-content duplicates in the same sense; extracting them would require parameterized helper functions, a different and larger refactor outside this task's stated scope (plain `private static let` constants mirroring `standardPublicProtocols` etc.).

    Verification: `swift build` clean, `swift build --build-tests` clean, `swift test` → 293 tests / 28 suites / 0 failures / 0 warnings (matches stated baseline exactly). Regenerated codegen (`rm .schema-hash && swift run acp-generate`) — `git diff --stat` on `Sources/FoundationModelsACP/Generated/` shows zero diff, confirming byte-for-byte no-op as required (these are template fragments, not schema-derived content, so no generated-code impact was expected, but verified anyway).

    Note: the `mcp__sah__files edit file` tool's `replace_all: true` parameter did NOT replace all occurrences in a single call — each call only replaced one occurrence regardless of the flag, and parallel/concurrent edit calls on the same file raced and lost updates. Had to issue one edit call per occurrence, sequentially. Worth knowing for future large-scale mechanical edits in this environment.

    Leaving task in `doing` pending double-check agent's adversarial pass (in progress).
  timestamp: 2026-07-28T14:00:12.121025+00:00
- actor: claude-code
  id: 01kymgj81fr6nh8h2jx78qy3ab
  text: |-
    Adversarial double-check verdict: PASS, no findings.

    Independently verified: literal fidelity of all 10 constants against removed lines (character-for-character), correct indent-prefix (indentUnit/indent2/indent3) preserved at every call site including the trickiest nested value-union decoder/encoder cases, no missed inline occurrences of any of the 10 literals (each appears exactly once, on its own constant's definition line), no naming collisions anywhere in the repo, fresh `swift build --build-tests` and `swift test` green, and fresh codegen regeneration (`rm .schema-hash && swift run acp-generate`) showing zero diff on `Sources/FoundationModelsACP/Generated/`.

    Also confirmed the extraction was selective, not a blind find/replace: scalarEnumDeclaration's differently-worded decoder-parameter doc line ("...positioned at the value." vs "...positioned at the object.") was correctly left inline rather than incorrectly merged into `decoderParameterDoc`.

    Task is done and green. Leaving in `doing` for `/review`.
  timestamp: 2026-07-28T14:02:55.407016+00:00
position_column: doing
position_ordinal: '80'
title: 'Emitter.swift: extract repeated non-indentation string-literal fragments into named constants'
---
A review pass (2026-07-28 00:58) on ^1pfngj1's indentation sweep surfaced a separate, unrelated duplication category in Sources/ACPGenerateCore/Emitter.swift: several full-line string literals repeat verbatim across functions (not indentation, actual content), e.g. `"public init(from decoder: any Decoder) throws {"` (decoderInit, scalarEnumDeclaration, taggedUnionDeclaration, discriminatedUnionDeclaration), `"public func encode(to encoder: any Encoder) throws {"`, `"var container = encoder.container(keyedBy: CodingKeys.self)"`, `"case unknown(String, JSONValue)"`, and `"try payload.encode(to: encoder)"`.

Out of scope for ^1pfngj1 (which is specifically about hardcoded indentation-prefix literals, now fully swept — 236 instances closed, verified by grep and byte-for-byte codegen diff gate). This is a distinct dedup opportunity: extract these repeated content fragments into named `private static let` constants the same way `indentUnit`/`indent2`/`indent3`/`indent4` centralize indentation width, so the literal text lives in one place per fragment.

Verify no other content-fragment duplicates exist beyond the 5 the review pass reported before declaring this done — that review's own report should be treated as a lead, not an exhaustive list.