---
name: casing
description: UpperCamelCase types, lowerCamelCase members, uniform acronym casing, no Hungarian/k-prefix
---

# Swift Casing

- **Types and protocols are `UpperCamelCase`; everything else is `lowerCamelCase`** — properties, variables, functions, parameters, enum cases, and constants (including `static let`). DON'T: `struct graphicsContext`, `let MaxRetries`. DO: `struct GraphicsContext`, `let maxRetries`.
- **Enum cases are `lowerCamelCase`.** DON'T: `case NotFound`, `case JSON_error`. DO: `case notFound`, `case jsonError`.
- **Acronyms and initialisms are cased uniformly — all-upper or all-lower as one unit — per the position's convention.** A common acronym is never mixed-case (`Url`, `Json`, `Http`, `deviceId` are all wrong). 
  - Down-case it when it leads a `lowerCamelCase` name; up-case it when interior or leading an `UpperCamelCase` name.
  - `ID` and `IDs` are acronyms and follow this rule. DON'T: `entryId`, `generatedTokenIds`, `schemaJson`. DO: `entryID`, `generatedTokenIDs`, `schemaJSON` (matching Apple's own `entryID:`/`objectID` API labels).
  - This rule wins over local file prevalence: when surrounding code already uses the mixed-case form (`entryId`), flag toward the uniform form (`entryID`) — never flag correct uniform casing toward a nearby mixed-case majority. Renaming back and forth between the two forms across review rounds is always a validator error, and this rule is the tiebreaker.
  - A term that is NOT commonly all-caps in English is an ordinary word: `radarDetector`, `scubaDiving` — not `RADARDetector`.
  - **PROJECT EXCEPTION (FoundationModelsACP).** This package deliberately mirrors the ACP wire schema's identifier naming, and the package spec (`plan.md` §2/§3) writes the ID newtypes with an `Id` suffix. The generated ID newtypes — `SessionId`, `ToolCallId`, `TerminalId`, `PermissionOptionId`, `SessionModeId`, and any future ACP `…Id` type — and their corresponding `…Id` properties, parameters, and argument labels (`sessionId`, `toolCallId`, `terminalId`, …) are an intentional, documented exception: do **NOT** flag them toward `-ID`/`sessionID`, and do not treat their uniform `Id` casing as a finding. These types are machine-generated from the vendored schema and are never hand-patched (§6). This exception is scoped to the `Id`/`ID` initialism on ACP identifiers only — every other acronym and initialism (`URL`, `JSON`, `HTTP`, and any non-ACP `ID` usage) still follows the uniform-casing rule above.
- **No `SCREAMING_SNAKE_CASE` and no `k`-prefixed constants.** Swift has neither convention. DON'T: `MAX_RETRY_COUNT`, `kMaximumRetries`. DO: `maximumRetryCount`.
- **No Hungarian notation or type-encoding affixes.** DON'T: `strName`, `bIsValid`, `intCount`, `m_count`, or Objective-C-style class prefixes (`NSFoo`, `MYView`) on new Swift types. Swift namespaces by module, so type prefixes are non-idiomatic. (A deliberate leading underscore on a `@usableFromInline`/underscored internal is a separate, sanctioned convention — not Hungarian notation.)
