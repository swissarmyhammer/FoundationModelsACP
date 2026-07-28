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
- actor: claude-code
  id: 01kymw2n7eeqm340hf0gy323sa
  text: |-
    Closed all 32 items from the 2026-07-28 11:45 review round, plus additional instances found during the required final consistency read-through.

    Category A (7 items, Emitter.swift) — added explicit labels to the last 7 remaining unlabeled struct/property-model parameters: structDeclaration(model:), decoderInit(model:), decodeLine(property:), patchDecodeLine(property:), encodeCall(property:), scalarEnumDeclaration(model:), valueUnionEncoder(model:). Updated every call site in Emitter.swift, SchemaGenerator.swift, and two test files (GeneratorCoreTests.swift, UnknownFallbackTests.swift).

    Category B (22 items, SchemaGenerator.swift) — fixed every cited doc-comment/argument-label mismatch by correcting the DOC to match the real label (default per the task instructions), reviewed individually rather than blanket-applied. One exception: validateUnclaimed had both a doc mismatch (base: vs by:) and a mixed-labeling-convention issue (first param unlabeled, others labeled) on the same function — fixed the doc AND added an explicit `names:` label to the first parameter for internal consistency, updating both call sites to `validateUnclaimed(names:by:context:)`.

    Category C (3 items, SchemaGenerator.swift) — extracted booleanTypeName/numberTypeName/arrayTypeName constants. Each of the three literals appears only once in this file (unlike the 4+ each for the existing stringTypeName/integerTypeName/objectTypeName/nullTypeName family), but two of the three ("boolean"/"number") sat as raw literals inside the very same `scalarTypes` dictionary literal whose other two entries already used `Self.stringTypeName`/`Self.integerTypeName` — a real internal inconsistency, not just cross-file parity — so extraction was warranted despite the single-occurrence count. Confirmed this doesn't contradict ^1pfngj1's prior single-occurrence non-extraction call in Emitter.swift: different file, different context (no sibling dictionary already mixing constant/literal keys there).

    Final consistency read-through (as required): wrote a small script to parse every `func` declaration in both files, extract its actual argument labels, and diff them against every `/// - Parameter x:` / `///   - x:` doc line, flagging any doc name absent from the real label set (deliberately excluding functions with a genuinely unlabeled `_` first parameter documented by its own internal name, which is correct Swift-doc convention, not a mismatch). This surfaced 11 more instances of the identical mismatch beyond the 32 cited, which were also fixed:
    - SchemaGenerator.swift: orderedEntries(of:), objectMembers(of:...), emissionRank(of:), defaultParts(of:...), decodeStrategy(of:...), rank(of:), orderedByWireMethod(of:) — all doc'd by internal name instead of the real `of:` label.
    - Emitter.swift: renderedType(of:), caseAssociatedValues(of:) — same pattern, in the file Category A already touched.
    Re-ran the script after fixing; zero remaining mismatches (only the 3 legitimately-unlabeled positional-param functions remain, correctly documented by internal name: validateNonEmptyUnion, agreedDiscriminator, discriminatorDisagreement).

    Self-caught and fixed a mid-session regression: an early batched edit call used a fabricated (unread) old_string for the meta-property call sites in unionStructDecoder/unionStructEncoder and silently matched the wrong text, deleting the `self.\(union.wireName) = try ...(from: decoder)` / `try \(union.wireName).encode(to: encoder)` lines and corrupting `if let meta { }` into `if let meta = model.metaProperty {` (no such `model` parameter exists on those functions). Caught immediately via `swift build --build-tests` failing with "cannot find 'model' in scope", restored the two deleted lines and the correct `if let meta {` form from `git diff`, re-verified the diff was then a minimal, correct 2-line-per-function change (only the intended `decodeLine(property)`→`decodeLine(property: property)` labels), and confirmed clean build afterward. Lesson: never fabricate an old_string for an edit without first reading the actual surrounding lines.

    Verification (fresh, this session):
    - `swift build --build-tests`: 0 errors, 0 warnings.
    - `swift test`: 198 tests/16 suites + 95 tests/12 suites = 293 tests/28 suites, 0 failures — matches the stated baseline exactly.
    - `mcp__sah__diagnostics check working`: 0 errors, 0 warnings.
    - Codegen diff gate: `rm -f .schema-hash && swift run acp-generate` → "nothing regenerated"; `git status --short -- Sources/FoundationModelsACP/Generated/` empty — byte-for-byte no-op confirmed.
    - No `swift format` run. No markdown tables in this comment.
    - Adversarial double-check agent: PASS, no findings — independently re-verified every doc fix against the real signature, re-ran build/test/codegen-gate fresh, and re-confirmed the corruption region is now correct.

    Leaving in `doing` for `/review`.
  timestamp: 2026-07-28T17:24:07.534566+00:00
- actor: claude-code
  id: 01kymzktmr8pyqm592kr6ft675
  text: |-
    Implemented the 2026-07-28 13:03 review round: added two shared helpers and swept the whole file for every remaining raw occurrence of each duplicated opening sequence, not just the 4 cited call sites.

    decoderInitSequence(baseIndent: String = indentUnit) -> [String] — the 2-line `init(from:)` opening (signature + keyed-container decl). encoderInitSequence(baseIndent: String = indentUnit) -> [String] — the 4-line `encode(to:)` opening (2 doc lines + signature + keyed-container decl). Both placed near the shared-fragment constants at the top of the enum, taking baseIndent since one call site nests one level deeper than the other four.

    Grepped the whole file for decoderInitOpening / encodeMethodOpening / decoderContainerDeclaration / encoderContainerDeclaration before and after. Found 5 call sites for each helper, not the 4 the review cited:

    decoderInitSequence(): decoderInit, taggedUnionDeclaration, discriminatedUnionDeclaration, unionStructDecoder (the 4 cited across items 1/5), plus valueUnionDecoder (baseIndent: indent2) — a 5th instance the review missed, matching the standing pattern on this file where a review's cited count undercounts by one.

    encoderInitSequence(): encodeMethod, taggedUnionDeclaration, discriminatedUnionDeclaration, unionStructEncoder (the 4 cited across items 3/4/6), plus valueUnionEncoder (baseIndent: indent2) — same 5th-instance miss on the encoder side.

    Deliberately left scalarEnumDeclaration's decoderInitOpening/encodeMethodOpening usages alone — they're followed by a single-value-container decode/encode, not the keyed-container sequence, so they are not duplicates of either helper's body.

    Fixed the doc-comment item (review's :325, now at renderedType(of property:) since line numbers drifted): changed `/// - Parameter of:` to `/// - Parameter property:`. Left the other `/// - Parameter of:` occurrence (caseAssociatedValues(of unionCase:)) alone since its internal parameter name is `unionCase`, not `property` — the review specifically named `property` as the correct fix.

    Verification (fresh, this session): `swift build --build-tests` 0 errors; `swift test` → 198 tests/16 suites + 95 tests/12 suites = 293 tests/28 suites, 0 failures, 0 warnings — matches baseline exactly. `mcp__sah__diagnostics check working`: 0 errors/0 warnings. Codegen gate: `rm -f .schema-hash && swift run acp-generate` then `git status --short -- Sources/FoundationModelsACP/Generated/` — empty, byte-for-byte no-op confirmed. No swift format run.

    Adversarial double-check agent dispatched to independently re-verify the 5+5 call sites, confirm no 6th occurrence exists, re-run build/test/codegen-gate fresh, and confirm the renderedType(of:) doc fix. Awaiting its verdict before final hand-off.
  timestamp: 2026-07-28T18:25:55.864657+00:00
- actor: claude-code
  id: 01kymztnxwy2d5njt11djvsc6z
  text: |-
    Adversarial double-check verdict: PASS, no findings.

    Independently verified: all 10 call sites (5 decoderInitSequence, 5 encoderInitSequence) are byte-identical to the pre-refactor text, including the two baseIndent: indent2 sites (indent2 + indentUnit == indent3 character-for-character since all indent constants are repeats of the same 4-space string); grepped the whole file for decoderInitOpening/encodeMethodOpening/decoderContainerDeclaration/encoderContainerDeclaration and confirmed no 6th occurrence exists beyond the two deliberately-untouched scalarEnumDeclaration single-value-container lines; confirmed the renderedType(of property:) doc fix is correct and that caseAssociatedValues(of unionCase:) was correctly left alone; reran swift build --build-tests (clean) and swift test fresh (198+95 = 293 tests, 16+12 = 28 suites, 0 failures); reran the codegen gate (rm -f Sources/FoundationModelsACP/Generated/.schema-hash && swift run acp-generate) and confirmed git status --short -- Sources/FoundationModelsACP/Generated/ is empty; confirmed the two new private static helpers have no external callers (blast radius clean, touched function signatures unchanged).

    Final call-site counts: decoderInitSequence() — 5 sites (decoderInit, taggedUnionDeclaration, discriminatedUnionDeclaration, unionStructDecoder, valueUnionDecoder). encoderInitSequence() — 5 sites (encodeMethod, taggedUnionDeclaration, discriminatedUnionDeclaration, unionStructEncoder, valueUnionEncoder). Both helpers found a 5th call site (valueUnionDecoder/valueUnionEncoder) beyond the 4 the review round cited — confirming the review's own stated pattern ("finds N, misses N+1") held again this round, and the sweep caught it.

    All 6 checklist items marked [x]. Task is done and green. Leaving in `doing` for `/review`.
  timestamp: 2026-07-28T18:29:40.412573+00:00
position_column: doing
position_ordinal: '80'
title: 'Emitter.swift: extract repeated non-indentation string-literal fragments into named constants'
---
A review pass (2026-07-28 00:58) on ^1pfngj1's indentation sweep surfaced a separate, unrelated duplication category in Sources/ACPGenerateCore/Emitter.swift: several full-line string literals repeat verbatim across functions (not indentation, actual content), e.g. `\"public init(from decoder: any Decoder) throws {\"` (decoderInit, scalarEnumDeclaration, taggedUnionDeclaration, discriminatedUnionDeclaration), `\"public func encode(to encoder: any Encoder) throws {\"`, `\"var container = encoder.container(keyedBy: CodingKeys.self)\"`, `\"case unknown(String, JSONValue)\"`, and `\"try payload.encode(to: encoder)\"`.

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

## Review Findings (2026-07-28 11:45)

- [x] `Sources/ACPGenerateCore/Emitter.swift:286` — Parameter label omitted with `_` while similar functions include the label — inconsistent with `objectValueUnionDeclaration`, `objectTaggedUnionDeclaration`, and other struct-like declaration functions that name their model parameter explicitly. Add explicit parameter label: change `_ model` to `model` to match the convention of similar declaration functions.
- [x] `Sources/ACPGenerateCore/Emitter.swift:397` — Parameter label omitted with `_` while similar initializer/method functions include the label — inconsistent with `memberwiseInit(model:)` at line 352 and `encodeMethod(model:)` at line 478, which also process struct models. Add explicit parameter label: change `_ model` to `model` to match similar struct-processing functions.
- [x] `Sources/ACPGenerateCore/Emitter.swift:413` — Parameter label omitted with `_` while similar property-processing helper `codingKeyCase(property:)` includes the label — inconsistent for functions with related purposes. Add explicit parameter label: change `_ property` to `property` to match similar property-processing functions.
- [x] `Sources/ACPGenerateCore/Emitter.swift:431` — Parameter label omitted with `_` while similar property-processing helper `codingKeyCase(property:)` includes the label — inconsistent for functions with related purposes. Add explicit parameter label: change `_ property` to `property` to match similar property-processing functions.
- [x] `Sources/ACPGenerateCore/Emitter.swift:448` — Parameter label omitted with `_` while similar property-processing helper `codingKeyCase(property:)` includes the label — inconsistent for functions with related purposes. Add explicit parameter label: change `_ property` to `property` to match similar property-processing functions.
- [x] `Sources/ACPGenerateCore/Emitter.swift:505` — Parameter label omitted with `_` while similar functions include the label — inconsistent with `taggedUnionDeclaration`, `discriminatedUnionDeclaration`, and other `*Declaration` functions that name their model parameter explicitly. Add explicit parameter label: change `_ model` to `model` to match the convention of similar declaration functions.
- [x] `Sources/ACPGenerateCore/Emitter.swift:1182` — Parameter label omitted with `_` while similar function `valueUnionDecoder(model:)` at line 1074 includes the label — inconsistent for paired encoder/decoder functions processing the same model. Add explicit parameter label: change `_ model` to `model` to match the paired decoder function.
- [x] `Sources/ACPGenerateCore/SchemaGenerator.swift:283` — Parameter documented as `name:` but argument label is `to:`. Documentation should use argument labels to match what callers see in the signature. Change `- Parameter name:` to `- Parameter to:` to match the argument label in the function signature.
- [x] `Sources/ACPGenerateCore/SchemaGenerator.swift:369` — Parameter documented as `wireName:` but argument label is `forWireName:`. Documentation should use argument labels to match what callers see. Change `- Parameter wireName:` to `- Parameter forWireName:` to match the argument label.
- [x] `Sources/ACPGenerateCore/SchemaGenerator.swift:384` — Parameter documented as `fragment:` but argument label is `of:`. Documentation should use argument labels to match what callers see. Change the documented parameter from `fragment:` to `of:` to match the argument label.
- [x] `Sources/ACPGenerateCore/SchemaGenerator.swift:422` — Parameter documented as `wireValue:` but argument label is `fromWire:`. Documentation should use argument labels for clarity. Change the documented parameter from `wireValue:` to `fromWire:` to match the argument label.
- [x] `Sources/ACPGenerateCore/SchemaGenerator.swift:457` — Parameter documented as `title:` but argument label is `fromTitle:`. Documentation should use argument labels to match the caller's perspective. Change the documented parameter from `title:` to `fromTitle:` to match the argument label.
- [x] `Sources/ACPGenerateCore/SchemaGenerator.swift:462` — Parameter documented as `fragment:` but argument label is `of:`. Documentation should use argument labels for clarity. Change the documented parameter from `fragment:` to `of:` to match the argument label.
- [x] `Sources/ACPGenerateCore/SchemaGenerator.swift:489` — Parameter documented as `fragment:` but argument label is `of:`. Documentation should use argument labels to match the signature. Change the documented parameter from `fragment:` to `of:` to match the argument label.
- [x] `Sources/ACPGenerateCore/SchemaGenerator.swift:575` — Parameter documented as `variants:` but argument label is `of:`. Documentation should use argument labels to match what callers see. Change `- Parameter variants:` to `- Parameter of:` to match the argument label.
- [x] `Sources/ACPGenerateCore/SchemaGenerator.swift:609` — Parameter documented as `variant:` but argument label is `of:`. Documentation should use argument labels to match what callers see. Change the documented parameter from `variant:` to `of:` to match the argument label.
- [x] `Sources/ACPGenerateCore/SchemaGenerator.swift:636` — Parameter documented as `variant:` but argument label is `of:`. Documentation should use argument labels to match the function's signature. Change the documented parameter from `variant:` to `of:` to match the argument label.
- [x] `Sources/ACPGenerateCore/SchemaGenerator.swift:657` — Parameter documented as `variant:` but argument label is `of:`. Documentation should use argument labels for clarity at the call site. Change the documented parameter from `variant:` to `of:` to match the argument label.
- [x] `Sources/ACPGenerateCore/SchemaGenerator.swift:714` — Parameter documented as `variants:` but argument label is `of:`. Documentation should use argument labels to match the caller's signature. Change the documented parameter from `variants:` to `of:` to match the argument label.
- [x] `Sources/ACPGenerateCore/SchemaGenerator.swift:808` — Parameter documented as `base:` but argument label is `by:`. Documentation should use argument labels to match the function signature. Change the documented parameter from `base:` to `by:` to match the argument label.
- [x] `Sources/ACPGenerateCore/SchemaGenerator.swift:820` — Mixed parameter label conventions within the same function — first parameter omits label with `_` while second and third parameters include explicit labels — inconsistent naming pattern. Make parameter labels consistent: either omit the first with `_` or provide explicit labels for all parameters.
- [x] `Sources/ACPGenerateCore/SchemaGenerator.swift:855` — Parameter documented as `variants:` but argument label is `of:`. Documentation should use argument labels for consistency with the call site. Change the documented parameter from `variants:` to `of:` to match the argument label.
- [x] `Sources/ACPGenerateCore/SchemaGenerator.swift:871` — Parameter documented as `properties:` but argument label is `of:`. Documentation should use argument labels to match what callers see. Change the documented parameter from `properties:` to `of:` to match the argument label.
- [x] `Sources/ACPGenerateCore/SchemaGenerator.swift:1123` — Parameter documented as `typeName:` but argument label is `named:`. Documentation should use argument labels to match the call site. Change the documented parameter from `typeName:` to `named:` to match the argument label.
- [x] `Sources/ACPGenerateCore/SchemaGenerator.swift:1212` — Parameter documented as `value:` but argument label is `for:`. Documentation should use argument labels for consistency with the function signature. Change the documented parameter from `value:` to `for:` to match the argument label.
- [x] `Sources/ACPGenerateCore/SchemaGenerator.swift:1387` — JSON Schema type name hardcoded as string; inconsistent with constants defined for other type names (stringTypeName, integerTypeName, objectTypeName, nullTypeName) and harder to maintain. Extract \"boolean\" as a constant booleanTypeName = \"boolean\" (around line 228) and use it at line 1387 for consistency.
- [x] `Sources/ACPGenerateCore/SchemaGenerator.swift:1388` — JSON Schema type name hardcoded as string; inconsistent with constants defined for other type names and makes the mapping less obvious and harder to extend. Extract \"number\" as a constant numberTypeName = \"number\" (around line 228) and use it at line 1388 for consistency with other type names.
- [x] `Sources/ACPGenerateCore/SchemaGenerator.swift:1411` — JSON Schema type name hardcoded as string; inconsistent with constants defined for other type names (stringTypeName, integerTypeName, objectTypeName, nullTypeName) at the top of the file. Extract \"array\" as a constant arrayTypeName = \"array\" (around line 228) and use it at line 1411: `guard typeName == Self.arrayTypeName else {`.
- [x] `Sources/ACPGenerateCore/SchemaGenerator.swift:1544` — Parameter documented as `variant:` but argument label is `of:`. Documentation should use argument labels to match what callers see. Change the documented parameter from `variant:` to `of:` to match the argument label.
- [x] `Sources/ACPGenerateCore/SchemaGenerator.swift:1813` — Parameter documented as `variant:` but argument label is `of:`. Documentation should use argument labels to match the function signature. Change the documented parameter from `variant:` to `of:` to match the argument label.
- [x] `Sources/ACPGenerateCore/SchemaGenerator.swift:2192` — Parameter documented as `definitions:` but argument label is `from:`. Documentation should use argument labels to match the function signature. Change `- Parameter definitions:` to `- Parameter from:` to match the argument label.
- [x] `Sources/ACPGenerateCore/SchemaGenerator.swift:2462` — Parameter documented as `seen:` but argument label is `in:`. Documentation should use argument labels to match what callers see. Change the documented parameter from `seen:` to `in:` to match the argument label.

## Review Findings (2026-07-28 13:03)

Scope: `3598af9..bacd605` (the checkpoint commit for this task; `HEAD~1..HEAD` at review time landed on `f3b1388`, an unrelated kanban-bookkeeping commit for a different task, so the range was resolved to the commit that actually touches `Emitter.swift`/`SchemaGenerator.swift`/tests).

- [x] `Sources/ACPGenerateCore/Emitter.swift:276` — Identical 2-line decoder method opening appears twice without extraction. The sequence `indentUnit + decoderInitOpening,` followed by `indent2 + decoderContainerDeclaration,` is duplicated in both `decoderInit(model:)` and `unionStructDecoder(...)`. This pattern can drift if a fix is applied to one location but not the other. Extract a `decoderInitSequence()` helper function that returns these two lines, then call it from both locations to ensure they stay synchronized. — Done: added `decoderInitSequence(baseIndent:)`; applied at all 5 actual call sites found by a whole-file sweep (decoderInit, taggedUnionDeclaration, discriminatedUnionDeclaration, unionStructDecoder, and valueUnionDecoder — a 5th instance this review round didn't cite).
- [x] `Sources/ACPGenerateCore/Emitter.swift:325` — Parameter documentation references external label `of` instead of internal parameter name `property`, inconsistent with established convention throughout the file. Change `/// - Parameter of:` to `/// - Parameter property:`. — Done: fixed on `renderedType(of property:)` (line numbers had drifted since the review). Confirmed the file's other `/// - Parameter of:` occurrence, on `caseAssociatedValues(of unionCase:)`, was correctly left alone since its internal name is `unionCase`, not `property`.
- [x] `Sources/ACPGenerateCore/Emitter.swift:413` — Identical 4-line encoder method opening appears twice without extraction. The sequence appending `encoderParameterDoc`, `encoderThrowsDoc`, `encodeMethodOpening`, and `encoderContainerDeclaration` is duplicated in both `encodeMethod(model:)` and `unionStructEncoder(...)`. This pattern can drift if a fix is applied to one location but not the other. Extract an `encoderInitSequence()` helper function that returns these four lines, then call it from both locations to ensure they stay synchronized. — Done: added `encoderInitSequence(baseIndent:)`; applied at all 5 actual call sites (encodeMethod, taggedUnionDeclaration, discriminatedUnionDeclaration, unionStructEncoder, and valueUnionEncoder — the encoder-side 5th instance).
- [x] `Sources/ACPGenerateCore/Emitter.swift:994` — Identical 4-line encoder method opening appears in `taggedUnionDeclaration`. The sequence appending `encoderParameterDoc`, `encoderThrowsDoc`, `encodeMethodOpening`, and `encoderContainerDeclaration` matches the pattern already flagged in `encodeMethod` and `unionStructEncoder`. This is a third instance of the same duplication. Use the same extracted `encoderInitSequence()` helper function mentioned in the second finding instead of duplicating these lines a third time. — Done: taggedUnionDeclaration now calls `encoderInitSequence()`.
- [x] `Sources/ACPGenerateCore/Emitter.swift:1123` — Identical 2-line decoder method opening appears in `discriminatedUnionDeclaration`. The sequence `indentUnit + decoderInitOpening,` followed by `indent2 + decoderContainerDeclaration,` matches the pattern already flagged in `decoderInit`, `unionStructDecoder`, and `taggedUnionDeclaration`. This is a fourth instance of the same duplication. Use the same extracted `decoderInitSequence()` helper function instead of duplicating these lines a fourth time. — Done: discriminatedUnionDeclaration now calls `decoderInitSequence()`.
- [x] `Sources/ACPGenerateCore/Emitter.swift:1133` — Identical 4-line encoder method opening appears in `discriminatedUnionDeclaration`. The sequence appending `encoderParameterDoc`, `encoderThrowsDoc`, `encodeMethodOpening`, and `encoderContainerDeclaration` matches the pattern already flagged in `encodeMethod`, `unionStructEncoder`, and `taggedUnionDeclaration`. This is a fourth instance of the same duplication. Use the same extracted `encoderInitSequence()` helper function instead of duplicating these lines a fourth time. — Done: discriminatedUnionDeclaration now calls `encoderInitSequence()`.

Note: the engine also flagged `Tests/ACPGenerateTests/UnknownFallbackTests.swift` (an orphaned `encode` doc comment with no implementing function) — dropped per the standing rule against asking to refactor pre-existing test code. Confirmed via `git blame` that comment predates this commit (2026-07-15, commit 49450737); this commit only touched one unrelated line in that file (the `scalarEnumDeclaration` call-site relabel).
