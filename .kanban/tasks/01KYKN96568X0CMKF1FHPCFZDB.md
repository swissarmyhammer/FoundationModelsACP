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
- actor: claude-code
  id: 01kymkene1z3hdte8w6nqe4fkt
  text: |-
    Implemented all 17 parameter-label renames from the 2026-07-28 09:34 review checklist.

    Went beyond the review's cited call-site count as instructed: grepped each of the 17 function names across Sources/ and Tests/ (not just Emitter.swift) before editing. Found call sites in three files, not just Emitter.swift:
    - Sources/ACPGenerateCore/Emitter.swift — declarations + internal call sites
    - Sources/ACPGenerateCore/SchemaGenerator.swift — an `extension Emitter { ... }` block plus direct `Emitter.xxx(...)` calls from the generator driver
    - Tests/ACPGenerateTests/TaggedUnionTests.swift — one direct call, `Emitter.taggedUnionDeclaration(model)`

    Total: 66 line-level edits (17 declaration signatures + 49 call-site updates), applied via a line-verified Python script rather than the MCP files-edit tool (its `replace_all` doesn't actually replace all occurrences in this environment per the prior implementation's note — verified independently: each edit checked the exact expected substring was present on the target line before writing, so no ambiguous/ wrong-line replacements were possible even with many duplicate-looking lines like the five `docLines(unionCase.documentation, indent: indentUnit)` call sites).

    Deliberately left three call sites unchanged, correctly: `stringLiteral`, `initParameter` are each referenced bare as function values in three places (`.map(stringLiteral)` x2 in SchemaGenerator.swift, `.map(stringLiteral)` in Emitter.swift:476, `leading.map(initParameter)` and `render: initParameter` in Emitter.swift) — Swift function-value types don't carry argument labels, so these compile unchanged after the rename. Confirmed by the clean build.

    Verification:
    - `swift build --build-tests`: clean, 0 errors.
    - `swift test`: 198 tests/16 suites + 95 tests/12 suites = 293 tests/28 suites total, 0 failures, 0 warnings — matches stated baseline exactly.
    - Regenerated codegen (`rm .schema-hash && swift run acp-generate`): `git status --short -- Sources/FoundationModelsACP/Generated/` shows zero diff, confirming the byte-for-byte no-op (parameter labels are call-site syntax only, no effect on emitted string content).
    - `mcp__sah__diagnostics check working`: 0 errors, 0 warnings.

    No swift format run. No markdown tables in this comment.
  timestamp: 2026-07-28T14:53:23.777944+00:00
- actor: claude-code
  id: 01kymm66ezcmvdh2cfg3a2vn32
  text: |-
    Adversarial double-check verdict: PASS, no findings.

    Independently confirmed by the double-check agent: all 66 changed lines match the spec exactly (17 signatures + 49 call sites); whole-repo grep for every old bare function name found matches only in the three edited files (plus one unrelated test-name substring, not a call); the 3 bare function-value references (`.map(stringLiteral)` x3-equivalent sites, `leading.map(initParameter)`, `render: initParameter`) are genuinely unapplied function references and compile correctly since Swift erases argument labels from function-value types; a forced fresh recompile gave 0 errors/0 warnings; a fresh `swift test` run gave 198 tests/16 suites + 95 tests/12 suites = 293 tests/28 suites, 0 failures; a fresh, independent codegen regeneration showed zero diff on Generated/; and the one pre-existing doc-comment reference to the old `codingKeys(_:)` signature was already updated to `codingKeys(model:)`.

    All 17 checklist items marked [x] in the task description. Task is done and green. Leaving in `doing` for `/review`.
  timestamp: 2026-07-28T15:06:14.879810+00:00
position_column: doing
position_ordinal: '80'
title: 'Emitter.swift: extract repeated non-indentation string-literal fragments into named constants'
---
A review pass (2026-07-28 00:58) on ^1pfngj1's indentation sweep surfaced a separate, unrelated duplication category in Sources/ACPGenerateCore/Emitter.swift: several full-line string literals repeat verbatim across functions (not indentation, actual content), e.g. `"public init(from decoder: any Decoder) throws {"` (decoderInit, scalarEnumDeclaration, taggedUnionDeclaration, discriminatedUnionDeclaration), `"public func encode(to encoder: any Encoder) throws {"`, `"var container = encoder.container(keyedBy: CodingKeys.self)"`, `"case unknown(String, JSONValue)"`, and `"try payload.encode(to: encoder)"`.

Out of scope for ^1pfngj1 (which is specifically about hardcoded indentation-prefix literals, now fully swept — 236 instances closed, verified by grep and byte-for-byte codegen diff gate). This is a distinct dedup opportunity: extract these repeated content fragments into named `private static let` constants the same way `indentUnit`/`indent2`/`indent3`/`indent4` centralize indentation width, so the literal text lives in one place per fragment.

Verify no other content-fragment duplicates exist beyond the 5 the review pass reported before declaring this done — that review's own report should be treated as a lead, not an exhaustive list.

## Review Findings (2026-07-28 09:34)

- [x] `Sources/ACPGenerateCore/Emitter.swift:264` — Parameter label omitted for non-value-preserving transformation — `stringLiteral(_:)` transforms a plain string to an escaped, quoted literal, which is not value-preserving. Omit labels only for value-preserving conversions like `Int64(someUInt32)`. Add parameter label: `static func stringLiteral(text: String) -> String`. Call sites change from `stringLiteral(property.wireName)` to `stringLiteral(text: property.wireName)`.
- [x] `Sources/ACPGenerateCore/Emitter.swift:457` — Parameter label omitted for non-value-preserving transformation — `memberwiseInit(_:)` renders an initializer, not a value-preserving conversion. Add parameter label: `private static func memberwiseInit(model: StructModel) -> [String]`.
- [x] `Sources/ACPGenerateCore/Emitter.swift:477` — Parameter label omitted for non-value-preserving transformation — `initParameter(_:)` renders an initializer parameter, not a value-preserving conversion. Add parameter label: `private static func initParameter(property: PropertyModel) -> String`.
- [x] `Sources/ACPGenerateCore/Emitter.swift:520` — Parameter label omitted for non-value-preserving transformation — `codingKeys(_:)` renders a CodingKeys enum, not a value-preserving conversion. Add parameter label: `private static func codingKeys(model: StructModel) -> [String]`.
- [x] `Sources/ACPGenerateCore/Emitter.swift:530` — Parameter label omitted for non-value-preserving transformation — `codingKeyCase(_:)` renders a CodingKeys case, not a value-preserving conversion. Add parameter label: `private static func codingKeyCase(property: PropertyModel) -> String`.
- [x] `Sources/ACPGenerateCore/Emitter.swift:627` — Parameter label omitted for non-value-preserving transformation — `encodeMethod(_:)` renders an `encode(to:)` method, not a value-preserving conversion. Add parameter label: `private static func encodeMethod(model: StructModel) -> [String]`.
- [x] `Sources/ACPGenerateCore/Emitter.swift:742` — Parameter label omitted for non-value-preserving transformation — `wireLiteral(_:kind:)` renders a wire constant as a literal, not a value-preserving conversion. Add parameter label: `private static func wireLiteral(enumCase: EnumCaseModel, kind: EnumRawKind) -> String`.
- [x] `Sources/ACPGenerateCore/Emitter.swift:748` — Parameter label omitted for non-value-preserving transformation — `taggedUnionDeclaration(_:)` renders a model as source code, not a value-preserving conversion. Add parameter label: `static func taggedUnionDeclaration(model: TaggedUnionModel) -> String`.
- [x] `Sources/ACPGenerateCore/Emitter.swift:906` — Parameter label omitted for non-value-preserving transformation — `discriminatedUnionDeclaration(_:)` renders a model as source code, not a value-preserving conversion. Add parameter label: `static func discriminatedUnionDeclaration(model: DiscriminatedUnionModel) -> String`.
- [x] `Sources/ACPGenerateCore/Emitter.swift:1031` — Parameter label omitted for non-value-preserving transformation — `objectValueUnionDeclaration(_:)` renders a model as source code, not a value-preserving conversion. Add parameter label: `static func objectValueUnionDeclaration(model: ObjectValueUnionModel) -> String`.
- [x] `Sources/ACPGenerateCore/Emitter.swift:1039` — Parameter label omitted for non-value-preserving transformation — `valueUnionEnum(_:)` renders a value-union enum declaration, not a value-preserving conversion. Add parameter label: `private static func valueUnionEnum(model: ObjectValueUnionModel) -> [String]`.
- [x] `Sources/ACPGenerateCore/Emitter.swift:1042` — Parameter label omitted for non-value-preserving transformation — `objectTaggedUnionDeclaration(_:)` renders a model as source code, not a value-preserving conversion. Add parameter label: `static func objectTaggedUnionDeclaration(model: ObjectTaggedUnionModel) -> String`.
- [x] `Sources/ACPGenerateCore/Emitter.swift:1061` — Parameter label omitted for non-value-preserving transformation — `valueUnionDecoder(_:)` renders a value-union decoder `init(from:)`, not a value-preserving conversion. Add parameter label: `private static func valueUnionDecoder(model: ObjectValueUnionModel) -> [String]`.
- [x] `Sources/ACPGenerateCore/Emitter.swift:1085` — Parameter label omitted for non-value-preserving transformation — `valueUnionDecoderBody(_:capturesTag:)` renders decoder switch statement, not a value-preserving conversion. Add parameter label: `private static func valueUnionDecoderBody(model: ObjectValueUnionModel, capturesTag: Bool) -> [String]`.
- [x] `Sources/ACPGenerateCore/Emitter.swift:1096` — Parameter labels omitted for non-value-preserving transformation — `valueDecodeCall(_:_:)` renders a decode call, not a value-preserving conversion. Add parameter labels: `private static func valueDecodeCall(unionCase: ValueUnionCaseModel, model: ObjectValueUnionModel) -> String`.
- [x] `Sources/ACPGenerateCore/Emitter.swift:1105` — Parameter label omitted for non-value-preserving transformation — `valueUnionDecoderBodyWithoutTaggedCases(_:capturesTag:)` renders decoder code, not a value-preserving conversion. Add parameter label: `private static func valueUnionDecoderBodyWithoutTaggedCases(model: ObjectValueUnionModel, capturesTag: Bool) -> [String]`.
- [x] `Sources/ACPGenerateCore/Emitter.swift:1331` — Parameter label omitted for non-value-preserving transformation — `docLines(_:indent:)` renders documentation comment lines, not a value-preserving conversion. Add parameter label: `private static func docLines(text: String?, indent: String) -> [String]`.
