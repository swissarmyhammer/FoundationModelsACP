---
assignees:
- claude-code
depends_on:
- 01M112K7M506DDHQ3SN6QDCGGY
position_column: todo
position_ordinal: '8180'
title: Add round-trip tests for terminal auth method and client auth capabilities
---
## What
Pin the wire shape of the new terminal-authentication types with hand-written fixtures. The exhaustive-over-tags test only checks that the `terminal` tag selects a modeled case; it does not check field round trips or the omit-when-nil rules.

Note on types: `AuthMethodTerminal.args` is `[String]?` and `.env` is `[EnvVariable]?` (not required in the schema, so the generator emits optionals decoded with `forgivingDecodeArrayIfPresent`, which returns `nil` when the key is absent).

- [ ] In `Tests/FoundationModelsACPTests/TaggedUnionRoundTripTests.swift`, add a hand-written fixture for `AuthMethod.terminal`: decode `{"type":"terminal","methodId":"login","name":"Log in","description":"Run login","args":["auth","login"],"env":[{"name":"FOO","value":"bar"}],"_meta":{"k":1}}` with `WireRoundTrip.expectLossless`, assert `case .terminal(let payload)` with `payload.methodId == AuthMethodId(rawValue: "login")`, `payload.args == ["auth","login"]`, and `payload.env?.count == 1`. Assert the re-encoded JSON keeps `"type":"terminal"`.
- [ ] In the same file, assert: an omitted `args`/`env` decodes to `nil` and re-encodes with the keys absent; `{"args":["a",1,"b"]}` gives `["a","b"]` (`x-deserialize-skip-invalid-items`); `{"args":"notanarray"}` gives `nil` (`x-deserialize-default-on-error`).
- [ ] In the same file, update the doc comment on `everyDeclaredTagSelectsAModeledCase`: "37 of these 44 tags" becomes "38 of these 45 tags" (the `terminal` payload requires `methodId` and `name`, so it reaches the probe by a thrown payload error too). Verify the numbers against the fresh schema before you write them.
- [ ] In `Tests/FoundationModelsACPTests/InitializeNegotiationTests.swift` (or a new `AuthCapabilitiesRoundTripTests.swift`), add tests for `ClientCapabilities.auth`: `ClientCapabilities()` encodes with no `auth` key; `ClientCapabilities(auth: AuthCapabilities(terminal: TerminalAuthCapabilities()))` encodes `"auth":{"terminal":{}}`; decoding `{"auth":{"terminal":{}}}` gives non-nil `auth?.terminal`; decoding `{"auth":null}` gives `auth == nil`; decoding `{"auth":{"terminal":null}}` gives `auth != nil` and `auth?.terminal == nil`; decoding `{"auth":"garbage"}` gives `auth == nil` (no decode error).
- [ ] Add an `InitializeResponse` fixture with `authMethods: [.terminal(...), .agent(...)]` and assert lossless round trip through `WireRoundTrip.expectLossless`.

Context: generated types live in `Sources/FoundationModelsACP/Generated/Models*.generated.swift` and `Unions.generated.swift`. `WireRoundTrip.expectLossless` is in `Tests/FoundationModelsACPTests/WireRoundTrip.swift`. Check the exact initializer signatures in the generated files after the schema task regenerates them.

## Acceptance Criteria
- [ ] The new tests exist and pass.
- [ ] `AuthMethod.terminal` round-trips losslessly with `args`, `env`, `description`, and `_meta`.
- [ ] `ClientCapabilities.auth` is omitted from JSON when nil and encodes `{"terminal":{}}` when set.
- [ ] The "N of M tags" comment in `TaggedUnionRoundTripTests` matches the fresh schema.

## Tests
- [ ] `swift test --filter TaggedUnionRoundTripTests` passes.
- [ ] `swift test --filter InitializeNegotiationTests` (or the new suite) passes.
- [ ] `swift test` passes in full.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #schema-alpha3