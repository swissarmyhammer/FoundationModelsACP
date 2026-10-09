---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m4hbhxwg8p3z77fhzx0epaw2
  text: |-
    Research (alpha.8 names and locations):
    - `StopReason` is now the property enum of `IdleStateUpdate.stopReason`. It is in `Generated/Unions2.generated.swift` (`case unknown(String)`, `wireValue`, `init(wireValue:)`). `IdleStateUpdate` is in `Generated/Models4.generated.swift`.
    - `UsageUpdate` (`size: Int`, `used: Int`) is in `Generated/Models9.generated.swift`. `Cost` (`currency: String`) is in `Generated/Models2.generated.swift`.
    - The only typed outbound path for these values is `AgentSideConnection.sessionUpdate(_:)`. The client side does not send `session/update`.

    Decisions:
    - No generator change. A check in the generated `encode(to:)` would also refuse a re-encode of a received value (a proxy, `SessionMergeEngine`, and the unknown-value round-trip tests re-encode received values). Thus the check is in the send path only, and decoding stays forgiving.
    - The error is `EncodingError.invalidValue`. This follows `JSONValue.encodeMembers(to:reserving:)`, which already refuses an outbound value with this error. No new public error type.
    - A `StopReason.unknown` that holds an ACP value (for example `"end_turn"`) is sent, because its wire value is an ACP value. The rule reads the wire value.
    - Currency check reads UTF-8 bytes: exactly 3 bytes, each `A`..`Z`. This is the schema pattern `^[A-Z]{3}$` exactly; a non-ASCII letter such as `Ä` is refused.

    Implementation:
    - New `Sources/FoundationModelsACP/Session/SessionUpdateSendRules.swift`: internal `validateForSending()` on `SessionUpdate`, `StopReason`, `UsageUpdate`, `Cost`.
    - `AgentSideConnection.sessionUpdate(_:)` calls `notification.update.validateForSending()` before it writes. Doc comment states the rules and the error.
    - `insertUserMessage` and the `ResponseHooks` success-only hooks are not changed.
    - New tests: `Tests/FoundationModelsACPTests/OutboundSessionUpdateRuleTests.swift`. Each refusal test also sends a correct update and expects it as the next frame, so the refused update did not reach the wire.
  timestamp: 2026-10-09T22:11:49.776249+00:00
- actor: claude-code
  id: 01m4hbj0t7fvbmbe7wwq7vz1x5
  text: |-
    ### implement — changed
    - evidence: 3 files — Sources/FoundationModelsACP/Session/SessionUpdateSendRules.swift (new), Sources/FoundationModelsACP/Connection/AgentSideConnection.swift, Tests/FoundationModelsACPTests/OutboundSessionUpdateRuleTests.swift (new). RED: `swift test --filter 'Outbound(StopReason|Usage)RuleTests'` failed on each refusal test (no error thrown). GREEN: same filter, 8 tests in 2 suites pass. Full `swift test`: 474 tests in 49 suites and 135 tests in 17 suites pass, 0 failures, 0 warnings.
    - next: /review
  timestamp: 2026-10-09T22:11:52.775549+00:00
- actor: claude-code
  id: 01m4hbnx8fyfc58bjndjdtp823
  text: |-
    ### test — green
    - evidence: swift test (root) 474 tests in 49 suites + 135 tests in 17 suites passed; IntegrationTests 7 passed; forced rebuild 0 warnings; OutboundSessionUpdateRuleTests 5 runs, 8/8 passed each run.
    - next: commit, then review.
  timestamp: 2026-10-09T22:14:00.207756+00:00
position_column: doing
position_ordinal: '8180'
title: Validate stop reasons and usage values before they are sent
---
## Problem

These values go on the wire without a check:

- A custom stop reason must start with `_`. Unknown values without `_` are reserved for future ACP use. Now `.unknown("foo")` is sent (`Generated/Unions2.generated.swift:722,755`).
- `usage_update.used` and `size` are `uint64` with minimum 0 in the schema. They are a signed `Int` in Swift (`Generated/Models9.generated.swift:264-313`).
- `cost.currency` must agree with `^[A-Z]{3}$` (ISO 4217) (`Generated/Models2.generated.swift:738-793`).

## Work

1. Find the correct location for outbound checks (for example, the agent-side send of `session/update`). Do not change generated files by hand. If a generator change is necessary, change the generator.
2. Refuse an outbound update that breaks a rule above with a clear error. Keep decoding forgiving: inbound values are not refused.
3. Add tests for each rule: a correct value is sent, and an incorrect value gives the error.

## Acceptance

- The tests pass, and all other tests pass.

#acp-lifecycle