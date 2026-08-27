---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m114rw6e35mg9baxyg7r6bxn
  text: |-
    Research done. Notes for the next agent:

    Generated signatures read from `Sources/FoundationModelsACP/Generated/`:
    - `AuthMethodTerminal` (Models.generated.swift): `init(methodId: AuthMethodId, name: String, args: [String]? = nil, description: String? = nil, env: [EnvVariable]? = nil, meta: JSONValue? = nil)`. `args` and `env` decode with `forgivingDecodeArrayIfPresent`; `description` and `_meta` with `forgivingDecodeIfPresent`. Encode uses `encodeIfPresent` for all four, so nil keys stay absent.
    - `AuthCapabilities` (Models.generated.swift): `terminal: TerminalAuthCapabilities?`, `meta: JSONValue?`, both `forgivingDecodeIfPresent` / `encodeIfPresent`.
    - `TerminalAuthCapabilities` (Models8.generated.swift): only `meta`, so `{}` is its full wire form.
    - `ClientCapabilities` (Models2.generated.swift): `auth: AuthCapabilities?` decoded with `forgivingDecodeIfPresent`, so `{"auth":"garbage"}` degrades to nil without a decode error.
    - `InitializeResponse` (Models4.generated.swift): always encodes `capabilities`, so a lossless fixture must carry `"capabilities":{}`.
    - `AuthMethod` (Unions.generated.swift): `case terminal(AuthMethodTerminal)`, `case agent(AuthMethodAgent)`, `case unknown(String, JSONValue)`, discriminator `type`.

    Tag counts checked against the fresh schema, not copied from the card. A script over `Schema/acp-v2.json` counts the const-pinned discriminator values of the 13 unions in the table, and marks a tag "throwing" when the variant's `allOf` `$ref` payload declares a required member other than the discriminator. Run against the pre-bump schema (`git show cbf541d^:Schema/acp-v2.json`) the script reproduces the comment that stands today — 37 of 44 tags, 9 of 13 unions. Run against the fresh schema it gives 38 of 45 tags, and still 9 of 13 unions. So only the two tag numbers change.
  timestamp: 2026-08-27T08:18:21.006419+00:00
- actor: claude-code
  id: 01m114z9stcxph82ej0h0h9bka
  text: |-
    TDD record, because the code under test already existed and a test written against it would have passed on the first run.

    RED was made real by a perturbation pass: each new test was written first with one expectation set to a value the code cannot produce, and the suite was run. All eleven new tests failed, each on its own perturbed line, and the failure text reported the true value. That is what proves each assertion reaches the generated code rather than sitting inert:

    - `encoded["auth"] → nil` for `ClientCapabilities()`.
    - `encoded["auth"] → .object(["terminal": .object([:])])` for a set terminal marker.
    - `capabilities.auth?.terminal → TerminalAuthCapabilities(meta: nil)` for `{"auth":{"terminal":{}}}`.
    - `payload.args → ["a", "b"]` for `{"args":["a",1,"b"]}`.
    - `payload.args → nil` for `{"args":"notanarray"}` and for an omitted `args`.
    - `methods.count → 2` for the two-method `InitializeResponse`.

    GREEN followed by setting each expectation to the observed value. No source under `Sources/FoundationModelsACP/Generated/` was touched — `git status` shows only the two test files.

    Two decisions a later reader may want:

    - The four terminal fixtures share a `private static func terminalPayload(of:)` helper that returns the `terminal` payload or `nil`, and each test binds it with `try #require`. Four copies of `guard case .terminal ... else { Issue.record; return }` would have been a duplication finding.
    - The `InitializeResponse` fixture asserts `methods.first` is `.terminal` and `methods.last` is `.agent` instead of `methods.count == 2`. `expectLossless` already pins the array length, because it compares the whole re-encoded document with the source. The literal `2` was dropped on purpose: the project ships no `.swiftlint.yml`, so `no_magic_numbers` runs with `allowed_numbers: [0, 1, -1, 100]` and would report it on a changed line.
  timestamp: 2026-08-27T08:21:51.546765+00:00
- actor: claude-code
  id: 01m114zep7ser67mzfey05wp19
  text: |-
    ### implement — changed
    - evidence: 2 files — Tests/FoundationModelsACPTests/TaggedUnionRoundTripTests.swift (4 new tests, 1 new private helper, 1 doc-comment number corrected), Tests/FoundationModelsACPTests/AuthCapabilitiesRoundTripTests.swift (new file, 7 tests). `swift build` clean. `swift test`: 264 tests in 25 suites and 107 tests in 14 suites, 0 failures, 0 warnings, 0 skipped. `swift test --package-path IntegrationTests`: 6 tests in 2 suites, all passed.
    - next: /review
  timestamp: 2026-08-27T08:21:56.551858+00:00
depends_on:
- 01M112K7M506DDHQ3SN6QDCGGY
position_column: doing
position_ordinal: '80'
title: Add round-trip tests for terminal auth method and client auth capabilities
---
## What
Pin the wire shape of the new terminal-authentication types with hand-written fixtures. The exhaustive-over-tags test only checks that the `terminal` tag selects a modeled case; it does not check field round trips or the omit-when-nil rules.

Note on types: `AuthMethodTerminal.args` is `[String]?` and `.env` is `[EnvVariable]?` (not required in the schema, so the generator emits optionals decoded with `forgivingDecodeArrayIfPresent`, which returns `nil` when the key is absent).

- [x] In `Tests/FoundationModelsACPTests/TaggedUnionRoundTripTests.swift`, add a hand-written fixture for `AuthMethod.terminal`: decode `{"type":"terminal","methodId":"login","name":"Log in","description":"Run login","args":["auth","login"],"env":[{"name":"FOO","value":"bar"}],"_meta":{"k":1}}` with `WireRoundTrip.expectLossless`, assert `case .terminal(let payload)` with `payload.methodId == AuthMethodId(rawValue: "login")`, `payload.args == ["auth","login"]`, and `payload.env?.count == 1`. Assert the re-encoded JSON keeps `"type":"terminal"`.
- [x] In the same file, assert: an omitted `args`/`env` decodes to `nil` and re-encodes with the keys absent; `{"args":["a",1,"b"]}` gives `["a","b"]` (`x-deserialize-skip-invalid-items`); `{"args":"notanarray"}` gives `nil` (`x-deserialize-default-on-error`).
- [x] In the same file, update the doc comment on `everyDeclaredTagSelectsAModeledCase`: "37 of these 44 tags" becomes "38 of these 45 tags" (the `terminal` payload requires `methodId` and `name`, so it reaches the probe by a thrown payload error too). Verify the numbers against the fresh schema before you write them.
- [x] In `Tests/FoundationModelsACPTests/InitializeNegotiationTests.swift` (or a new `AuthCapabilitiesRoundTripTests.swift`), add tests for `ClientCapabilities.auth`: `ClientCapabilities()` encodes with no `auth` key; `ClientCapabilities(auth: AuthCapabilities(terminal: TerminalAuthCapabilities()))` encodes `"auth":{"terminal":{}}`; decoding `{"auth":{"terminal":{}}}` gives non-nil `auth?.terminal`; decoding `{"auth":null}` gives `auth == nil`; decoding `{"auth":{"terminal":null}}` gives `auth != nil` and `auth?.terminal == nil`; decoding `{"auth":"garbage"}` gives `auth == nil` (no decode error).
- [x] Add an `InitializeResponse` fixture with `authMethods: [.terminal(...), .agent(...)]` and assert lossless round trip through `WireRoundTrip.expectLossless`.

Context: generated types live in `Sources/FoundationModelsACP/Generated/Models*.generated.swift` and `Unions.generated.swift`. `WireRoundTrip.expectLossless` is in `Tests/FoundationModelsACPTests/WireRoundTrip.swift`. Check the exact initializer signatures in the generated files after the schema task regenerates them.

## Acceptance Criteria
- [x] The new tests exist and pass.
- [x] `AuthMethod.terminal` round-trips losslessly with `args`, `env`, `description`, and `_meta`.
- [x] `ClientCapabilities.auth` is omitted from JSON when nil and encodes `{"terminal":{}}` when set.
- [x] The "N of M tags" comment in `TaggedUnionRoundTripTests` matches the fresh schema.

## Tests
- [x] `swift test --filter TaggedUnionRoundTripTests` passes.
- [x] `swift test --filter InitializeNegotiationTests` (or the new suite) passes.
- [x] `swift test` passes in full.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #schema-alpha3