---
assignees:
- claude-code
position_column: todo
position_ordinal: '8580'
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