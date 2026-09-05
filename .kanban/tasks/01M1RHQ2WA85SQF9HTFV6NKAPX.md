---
position_column: todo
position_ordinal: '80'
title: 'AbsolutePath: mirror the schema, and stop refusing relative paths at decode'
---
## What

`Schema/acp-v2.json` gives `AbsolutePath` the type `string`. It states the absolute-path rule in prose only. The definition says "An absolute filesystem path used by the protocol", and `NewSessionRequest.cwd` says "Must be an absolute path." The protocol documentation (https://agentclientprotocol.com/protocol/v2/session-setup#creating-a-session) says the cwd "MUST be an absolute path" and names no validator.

The agent owns the file system, so the agent validates the path and answers JSON-RPC invalid params (-32602). `FoundationModelsACPAgent` already does this in `SessionSetup.validatedWorkingDirectory(path:)`. But today that check can never run, because this package refuses the value at decode first. That is a second validator, and it sits on the wrong side of the wire.

Make `AbsolutePath` mirror the schema: a named string type with no guard.

- [ ] `Sources/FoundationModelsACP/Core/AbsolutePath.swift`: make `init(rawValue:)` non-failable. Delete the `hasPrefix("/")` guard. Delete the `invalidWireValueDescription(of:)` override; the protocol default stays for `ProtocolVersion` and the identifiers. Rewrite the doc comment: this is the schema's `AbsolutePath` `$def`; the protocol says it must be absolute; the agent enforces it.
- [ ] Keep the struct and the `WireRawValueCodable` conformance. The generator lists `AbsolutePath` in `handwrittenDefinitions`, and 14 generated properties use the name.
- [ ] `Sources/ACPGenerateCore/GeneratorConfig.swift:16` and `:39`: replace "rejecting relative paths at decode" with the new meaning.
- [ ] `plan.md:269-271` and `:397-399`: "the invariant rides the `$ref`" becomes "the type rides the `$ref`; the schema states the rule; the agent enforces it".
- [ ] Sweep each site that unwraps `AbsolutePath(rawValue:)` with `guard let`, `if let`, `#require` or `!`. A non-failable init makes each one a compile error. Counts from `rg`: `Tests/FoundationModelsACPTests/SessionLifecycleTests.swift` 14, `SessionUpdateAggregatorTests.swift` 1, `RoutingCoverageTests.swift` 1, `PromptLifecycleTests.swift` 1, `GoldenSessionEndToEndTests.swift` 1, `AgentProtocolTests.swift` 1.

Option not taken: keep `init?` and never return `nil`. Each call site keeps compiling, but a failable initializer that cannot fail is a false statement in the API. Do not do this.

## Acceptance Criteria

- [ ] `WireRoundTrip.decode(NewSessionRequest.self, from: #"{"cwd":"relative/path"}"#)` succeeds, and `cwd.rawValue == "relative/path"`.
- [ ] `AbsolutePath(rawValue: "")` and `AbsolutePath(rawValue: "src")` are values, not `nil`.
- [ ] No source file or document in this package says a relative path is refused at decode.
- [ ] `swift test` is green. `VendoredSchemaTests` (type names) does not change.

## Tests

- [ ] `Tests/FoundationModelsACPTests/WireInvariantTests.swift`: `relativePathFailsDecodingWithAClearError` becomes `relativePathDecodesAsTheSchemaSays` (a bare string, kept as sent). Delete `emptyPathIsRejectedToo`.
- [ ] `SessionLifecycleTests.swift:808`, `:814`, `:820`: the three relative-cwd decodes become round trips.
- [ ] `GeneratorCoreTests.swift:233` and `PermissionRequestTests.swift:81`: correct the comments that say a relative path is a decode error.
- [ ] `swift test`: 0 failures, 0 warnings.

## Downstream

`FoundationModelsACPAgent` and `FoundationModelsACPClient` each hold a card that depends on this one. Neither can start before this card is pushed and the packages re-resolve.

## Workflow

- Use `/tdd`. Write the failing tests first.