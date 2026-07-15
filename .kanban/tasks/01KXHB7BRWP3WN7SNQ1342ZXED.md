---
comments:
- actor: wballard
  id: 01kxhkf6dajfnene9rfnptzas3
  text: 'Picked up by driver loop. Plan: TDD the four core types (JSONValue, ProtocolVersion, AbsolutePath, LineNumber) in Sources/FoundationModelsACP/Core/ with tests JSONValueTests.swift, ProtocolVersionTests.swift, WireInvariantTests.swift; then test → commit → review.'
  timestamp: 2026-07-15T00:40:16.042668+00:00
- actor: wballard
  id: 01kxhkvc6s1wha9k936ph8789f
  text: 'Implementation landed (TDD red→green). New files: Sources/FoundationModelsACP/Core/{JSONValue,ProtocolVersion,AbsolutePath,LineNumber}.swift and Tests/FoundationModelsACPTests/{JSONValueTests,ProtocolVersionTests,WireInvariantTests}.swift (Swift Testing). swift test: 23/23 pass; swift build: zero warnings. really-done adversarial double-check: PASS. Notes from double-check (non-blocking, by design): ProtocolVersion accepts bare number 1.0 (criteria only require rejecting string forms); JSONValue .number(Double) loses precision above 2^53 — intrinsic to the task-mandated Double case.'
  timestamp: 2026-07-15T00:46:55.193908+00:00
- actor: wballard
  id: 01kxhkwq65y048kmcfb43yqj8p
  text: 'Checkpoint committed locally: d0ff989 "feat(core): add hand-written wire types JSONValue, ProtocolVersion, AbsolutePath, LineNumber" (11 files, 409 insertions; includes kanban state). Proceeding to task-mode review of HEAD~1..HEAD.'
  timestamp: 2026-07-15T00:47:39.205036+00:00
- actor: wballard
  id: 01kxhm5jc7bvp38q3wp4mwqfzk
  text: 'Review verdict (iteration 1, scope HEAD~1..HEAD): 5 findings, all duplication — the three RawRepresentable newtypes (AbsolutePath, LineNumber, ProtocolVersion) share verbatim encode(to:) and near-verbatim decode-and-validate init(from:). Fix: unify Codable via a shared protocol (e.g. a wire-newtype protocol with a protocol extension providing single-value encode + decode-then-validate). Task stays in review; looping back to implement.'
  timestamp: 2026-07-15T00:52:29.191560+00:00
- actor: wballard
  id: 01kxhmeb15hgd163yww2j127p1
  text: 'Iteration 2 implementation landed: extracted WireRawValueCodable protocol (Core/WireRawValueCodable.swift) providing shared single-value decode-and-validate init(from:) and bare-raw-value encode(to:); AbsolutePath/LineNumber/ProtocolVersion now conform with zero Codable boilerplate. Note: protocol and witnesses must be public — internal protocol-extension witnesses cannot satisfy a public Codable conformance (compiler error confirmed). All 5 review findings flipped to [x]. swift test 23/23 green; double-check re-verdict PASS.'
  timestamp: 2026-07-15T00:57:16.581895+00:00
depends_on:
- 01KXHB6V536ZBBFC24M9WQXWMM
position_column: doing
position_ordinal: '80'
title: 'Hand-written core types: JSONValue, ProtocolVersion, AbsolutePath'
---
## What
Implement the hand-written primitive types the generated code and connection layer build on (spec §2, §3, §4), in `Sources/FoundationModelsACP/Core/`:

- `JSONValue.swift` — enum over arbitrary JSON: `.null, .bool, .number(Double), .string, .array([JSONValue]), .object([String: JSONValue])`; `Codable`, `Sendable`, `Hashable`. Used for `_meta`, `rawInput`, `rawOutput`, MCP env; preserved round-trip, never interpreted.
- `ProtocolVersion.swift` — `RawRepresentable` over `UInt16`; `static let v1 = 1`, `static let latest = v1`. Encodes/decodes as the **bare integer** `1`; decoding MUST reject strings like `"v1"` or `"1.0.0"` with a decoding error.
- `AbsolutePath.swift` — newtype over `String` enforcing the wire invariant (spec §4): initializer/decoder rejects relative paths.
- `LineNumber.swift` — newtype enforcing the other §4 wire invariant: ACP line numbers are **1-based**; initializer/decoder rejects `0` (and negatives). Both invariants are compile- or decode-time errors, not silent interop bugs — the generator (separate task) maps schema path/location fields onto these types.

## Acceptance Criteria
- [x] `JSONValue` round-trips arbitrary JSON (including nested objects/arrays and `null`) byte-equivalently modulo key order
- [x] `ProtocolVersion(rawValue: 1)` encodes to `1` (bare integer); decoding `"v1"` and `"1.0.0"` throws
- [x] `AbsolutePath` decode of `"relative/path"` throws; `"/abs/path"` succeeds
- [x] `LineNumber` decode of `0` throws; `1` succeeds and encodes as the bare integer
- [x] All four are `Sendable` and compile under Swift 6 strict concurrency

## Tests
- [x] `Tests/FoundationModelsACPTests/JSONValueTests.swift` — round-trip of nested fixtures, `_meta` preservation
- [x] `Tests/FoundationModelsACPTests/ProtocolVersionTests.swift` — bare-int encode, string rejection
- [x] `Tests/FoundationModelsACPTests/WireInvariantTests.swift` — AbsolutePath relative rejection / absolute accept; LineNumber zero rejection / 1-based accept
- [x] Run `swift test` — exits 0

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.

## Review Findings (2026-07-14 19:47)

- [x] `Sources/FoundationModelsACP/Core/AbsolutePath.swift:25` — init(from:) method is near-verbatim duplicate of LineNumber.swift:26-36 — both decode a value and validate through optional init?(rawValue:), differing only in the decoded type (String vs Int) and error message literal. Extract a generic decode-and-validate helper parameterized on the Decodable type to eliminate the duplication.
- [x] `Sources/FoundationModelsACP/Core/AbsolutePath.swift:41` — encode(to:) method is verbatim duplicate across AbsolutePath, LineNumber, and ProtocolVersion — three types with identical encoding logic should be unified to avoid keeping copies in sync. Extract encode(to:) into a protocol extension on RawRepresentable or a generic implementation to eliminate the duplication.
- [x] `Sources/FoundationModelsACP/Core/LineNumber.swift:26` — init(from:) method is near-verbatim duplicate of AbsolutePath.swift:25-35 — both decode a value and validate through optional init?(rawValue:), differing only in the decoded type (Int vs String) and error message literal. Extract a generic decode-and-validate helper parameterized on the Decodable type to eliminate the duplication.
- [x] `Sources/FoundationModelsACP/Core/LineNumber.swift:42` — encode(to:) method is verbatim duplicate across AbsolutePath, LineNumber, and ProtocolVersion — three types with identical encoding logic should be unified to avoid keeping copies in sync. Extract encode(to:) into a protocol extension on RawRepresentable or a generic implementation to eliminate the duplication.
- [x] `Sources/FoundationModelsACP/Core/ProtocolVersion.swift:38` — encode(to:) method is verbatim duplicate across AbsolutePath, LineNumber, and ProtocolVersion — three types with identical encoding logic should be unified to avoid keeping copies in sync. Extract encode(to:) into a protocol extension on RawRepresentable or a generic implementation to eliminate the duplication.

Resolution (2026-07-14): all five findings addressed by extracting `Sources/FoundationModelsACP/Core/WireRawValueCodable.swift` — a public `WireRawValueCodable` protocol (RawRepresentable + Codable) whose extension provides the single shared decode-and-validate `init(from:)` and bare-raw-value `encode(to:)`. AbsolutePath, LineNumber, and ProtocolVersion now conform and contain no Codable boilerplate; invariant types override `invalidWireValueDescription(_:)` for their error messages.