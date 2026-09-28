---
comments:
- actor: claude-code
  id: 01m3mp1s90hjry0cqtcdak5d20
  text: |-
    Research done.
    - `JSONValue` has no string accessor. The codec uses pattern matching on `.object` and `.string`.
    - `PromptRequest(prompt:sessionId:meta:)` takes `meta: JSONValue?` with coding key `_meta`. A JSON `null` `_meta` decodes to `nil` on this type.
    - Test style: `@Suite struct X`, swift-testing, helper `WireRoundTrip.encode` gives a `JSONValue` tree. `SessionId(rawValue:)` is not failable.
    - The swift validators include swiftlint `no_magic_numbers` (allowed 0, 1, -1, 100) and swiftformat test rules (no force unwrap or force try in tests, no `test` prefix on test names). So the codec names each length as a constant, and the tests derive long values from the public constant.
    - Decisions: a non-object `_meta` (string, array, number, bool) comes back unchanged from `inject`. A JSON `null` `_meta` is the same as `nil`: start from an empty object. When `tracestate` is `nil`, `inject` removes a stale `tracestate` member so that it does not pair with a new `traceparent`. A version above `00` is accepted when the first 55 characters are a valid version-00 layout and the next character (if any) is `-` (W3C forward compatibility rule).
  timestamp: 2026-09-28T18:57:16.576209+00:00
- actor: claude-code
  id: 01m3mp9jaxeqz9qmh31x1ewh9n
  text: |-
    Implementation landed (TDD).
    - RED: the tests ran against a stub that always returned `nil`. 14 of 16 tests failed. The two reject tests passed on the stub, as expected.
    - GREEN: `TraceContextMeta` is a public struct with `traceparentKey`, `tracestateKey`, `maximumTracestateLength`, a failable `init?(traceparent:tracestate:)`, `extract(from:)` and `inject(into:)`. A private `TraceparentLayout` does the W3C checks on UTF-8 bytes. It names each field length as a constant and derives the length 55.
    - The layout does not keep the `flags` field, because no check reads it. A stored `flags` property would be an assign-only property, which periphery reports.
    - Environment note: each `swift test` run prints SwiftPM warnings "failed loading cached manifest ... disk I/O error" for `foundationmodelsacp`, `swift-docc-plugin` and `swift-docc-symbolkit`. They come from the SwiftPM manifest cache, not from the code. The compiler gave no warning for the new files.

    ### implement — changed
    - evidence: 2 new files: Sources/FoundationModelsACP/Core/TraceContextMeta.swift, Tests/FoundationModelsACPTests/TraceContextMetaTests.swift. `swift test --filter 'FoundationModelsACPTests.TraceContextMetaTests'`: 16 tests in 1 suite passed. `swift test --parallel`: 282 tests in 26 suites passed, and 107 tests in 14 suites passed, 0 failures. No `Package.swift` change, no generated-file change, no `Tracing` or `Instrumentation` import in Sources/FoundationModelsACP.
    - next: review
  timestamp: 2026-09-28T19:01:31.613860+00:00
- actor: claude-code
  id: 01m3mpbgn9vamdz6scxn9n4ewf
  text: |-
    ### test — green
    - evidence: swift test --parallel — 282 tests in 26 suites passed, 107 tests in 14 suites passed, 0 failed, 0 skipped. I touched TraceContextMeta.swift and TraceContextMetaTests.swift and rebuilt: zero compiler warnings from the code.
    - note: SwiftPM prints 6 "disk I/O error" warnings about its manifest cache. They come from the environment, not from the code.
    - next: review
  timestamp: 2026-09-28T19:02:35.433428+00:00
position_column: doing
position_ordinal: '80'
title: 'OTel: add a codec that reads and writes W3C traceparent and tracestate in an ACP _meta object'
---
## What

Part of the OpenTelemetry design that the user approved on 2026-09-28 (copy: /private/tmp/claude-501/-Users-wballard-github-swissarmyhammer/9f4fa2e8-6833-46c6-bb95-5091ae3613fa/scratchpad/otel-design.md). Rule 7: trace context crosses the process boundary as W3C `traceparent` and `tracestate` in the ACP `_meta` object. ACPClient injects the context. ACPAgent extracts it. Those two packages do the tracing work. This package is the wire layer and supplies only a small codec.

Add a codec that reads and writes the W3C `traceparent` and `tracestate` members of an ACP `_meta` value.

Research:
- Every generated request and notification type models `_meta` as `public var meta: JSONValue?` with the coding key `_meta` (for example `PromptRequest` in `Sources/FoundationModelsACP/Generated/Models6.generated.swift:280`, `NewSessionRequest` in `Models5.generated.swift:533`, `InitializeRequest` in `Models4.generated.swift:581`).
- `JSONValue` is in `Sources/FoundationModelsACP/Core/JSONValue.swift`. It has the cases `null`, `bool`, `number`, `string`, `array` and `object([String: JSONValue])`.
- `Tests/FoundationModelsACPTests/MetaFieldTests.swift` already tests that `_meta` round-trips verbatim.
- The package has no runtime dependency now (only the `swift-docc-plugin` plugin). Keep it so.

Do this:
- [x] Add a new file `Sources/FoundationModelsACP/Core/TraceContextMeta.swift` (the name is a proposal). Put in it a public `struct TraceContextMeta: Sendable, Hashable` (or an equivalent `enum` with static functions) with:
  - [x] The key constants as plain strings: `traceparent` and `tracestate`. Put them at the top level of `_meta` (`_meta.traceparent`, `_meta.tracestate`), as the ACP extensibility text and the MCP `_meta` convention do. Document this choice.
  - [x] `static func extract(from meta: JSONValue?) -> TraceContextMeta?`: return `nil` when `meta` is `nil`, is not an object, has no `traceparent` string, or has a `traceparent` that is not valid. Return `tracestate` only when it is a string.
  - [x] `func inject(into meta: JSONValue?) -> JSONValue`: return an object that keeps every other member of `meta` and sets `traceparent` (and `tracestate` when it is not `nil`). When `meta` is `nil`, start from an empty object. When `meta` is not an object, do not destroy it silently: decide the behavior (for example return `meta` unchanged) and document it.
  - [x] A failable initializer or a static validator for the `traceparent` string. Validate the W3C format `version-traceid-parentid-flags`: exactly 55 characters for version `00`, 4 fields separated by `-`, lowercase hexadecimal only, `version` is 2 characters and not `ff`, `trace-id` is 32 characters and not all zeros, `parent-id` is 16 characters and not all zeros, `flags` is 2 characters. For a version above `00`, accept a longer value only when it starts with a valid version-00 prefix followed by `-` (W3C forward compatibility rule), or reject it; decide and document.
  - [x] A `tracestate` value is opaque to this codec. Do not parse it. Drop it when it is longer than 512 characters (W3C limit), and document this.
- [x] Do NOT import `Tracing`, `Instrumentation` or `ServiceContextModule`. Do NOT add a package dependency. ACPAgent and ACPClient will adapt this codec to an `Extractor` and an `Injector` of swift-distributed-tracing on their side.
- [x] Doc comments in ASD-STE100 Simplified Technical English. Tell in the doc comment that the codec carries only ids and flags, never content.

## Files to change
- New: `Sources/FoundationModelsACP/Core/TraceContextMeta.swift`
- New: `Tests/FoundationModelsACPTests/TraceContextMetaTests.swift`
- No change to `Package.swift`. No change to the generated files.

## Acceptance Criteria
- [x] `extract` reads a valid `traceparent` and `tracestate` from a `_meta` object, and returns `nil` for a missing, non-string or malformed `traceparent`.
- [x] `inject` then `extract` gives the same value (round trip), and `inject` keeps all other `_meta` members.
- [x] A request type with the injected `_meta` (for example `PromptRequest`) encodes to JSON with `_meta.traceparent` and decodes back to an equal value.
- [x] `Package.swift` has no new dependency, and no file in `Sources/FoundationModelsACP` imports `Tracing` or `Instrumentation`.

## Tests
- [x] New `Tests/FoundationModelsACPTests/TraceContextMetaTests.swift` (swift-testing `@Suite`/`@Test`):
  - [x] valid: `00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01` is accepted, with and without `tracestate`.
  - [x] invalid, one test per rule (use parameterized `@Test(arguments:)`): wrong length, uppercase hex, non-hex character, all-zero trace id, all-zero parent id, version `ff`, missing field, extra separator.
  - [x] `_meta` is `nil`, is a string, is an array, and has `traceparent` as a number: `extract` returns `nil`.
  - [x] `inject` into `nil`, into an object with other members (they stay), and into a non-object (the documented behavior).
  - [x] a `tracestate` longer than 512 characters is dropped.
  - [x] a `PromptRequest` wire round trip with the injected `_meta`.
- [x] `swift test --parallel` passes. With `swift test --filter`, use a regex with the target name and check that the count of tests that ran is not zero.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.
- Do not run `swift format`.