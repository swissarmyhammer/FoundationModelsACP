---
comments:
- actor: claude-code
  id: 01kyk67jqxtwrpda53p1288w2r
  text: |-
    Implementation landed. Summary:

    - New file Tests/FoundationModelsACPTests/PromptLifecycleTests.swift: a real test-double Agent (PromptLifecycleAgent) implementing the v2 prompt lifecycle end to end over InMemoryTransport — prompt() acknowledges with PromptResponse() (encodes to {}), then a deferred turn reports running, echoes the user's content as user_message_chunk updates sharing one agent-generated messageId, optionally pauses on requires_action and resumes to running once session/request_permission is answered, then reports idle with a stopReason. session/cancel cancels in-flight work and reports idle+cancelled. 8 tests cover every acceptance-criteria bullet and the full test list from the card, including a dedicated StopReason round-trip test (known values derived from the vendored schema, not hardcoded, plus the unknown-value sibling path nested inside IdleStateUpdate).

    - Real concurrency bug found and fixed (not hypothetical): a naive prompt() that spawns a Task to send the "running" state_update before returning PromptResponse() has a genuine race — under load (e.g. full test suite running in parallel) the update's wire frame sometimes gets written before the response frame, ~30-40% of full-suite runs in local stress testing. Caught by repeating swift test (not just the filtered new suite) many times, per the card's own warning about concurrency-heavy M3/M5 precedent.

    - Fix: added a small, deliberately-scoped mechanism to Sources/FoundationModelsACP/Connection/Connection.swift (ResponseHooks class + @TaskLocal static var currentResponseHooks) and Sources/FoundationModelsACP/Connection/AgentSideConnection.swift (public afterRespondingToCurrentRequest(_:)). Connection.dispatchRequest's per-request Task now runs any hooks the handler registered, but only AFTER completeInbound has written the response — making the ordering guarantee provable rather than probabilistic. PromptLifecycleAgent.prompt() uses this instead of spawning the turn's Task directly. This is a small, additive change to shared Connection/AgentSideConnection code (no signature changes to Agent/Client protocols, no change to ClientSideConnection behavior — hooks.runAll() is a no-op empty-array call for every other method).

    - Verified via 500-iteration wire-level ordering test (LoggingTransport wrapper classifying frames by content, not by racing client-side continuations against the update stream — an earlier version of this test using a client-observed race was itself flaky for reasons unrelated to the agent's actual wire order, documented in the test file's LoggingTransport doc comment) plus 25+ full `swift test` runs post-fix with zero failures (vs. reproducible failures pre-fix).

    Final state: swift build --build-tests clean (0 warnings, 0 errors). swift test: 185 tests / 15 suites (FoundationModelsACPTests) + 75 tests / 10 suites (ACPGenerateTests) = 260 tests / 25 suites, all passing, repeated ~30 times total across both filtered and full runs with no flakes observed after the fix. Baseline before this task was 252 tests / 24 suites, so +8 tests / +1 suite, matching the new PromptLifecycleTests suite.

    Adversarial double-check (via really-done) is running in background at time of this comment; will report its verdict once it lands.

    Task left in `doing` per /implement convention — ready for /review.
  timestamp: 2026-07-28T01:43:05.725755+00:00
- actor: claude-code
  id: 01kyk6z465y8kz0z2n2g60vrjt
  text: |-
    Adversarial double-check (via really-done) verdict: REVISE, with 2 findings. Both addressed:

    1. Real gap: Connection.dispatchRequest ran hooks.runAll() unconditionally even when completeInbound skipped writing the response (connection closed mid-handler), contradicting the documented "hooks follow a response that exists" contract. Fixed: completeInbound now returns a Bool (discardable for its other, pre-existing call site) indicating whether it actually wrote, and dispatchRequest only calls hooks.runAll() when it did.

    2. Real gap: LoggingTransport.classify(_:) in the test file classified any frame with a non-nil id as "response", which would misclassify an outbound agent request (e.g. session/request_permission, which also carries id+method) as a response. Currently inert (the ordering test's script never calls requestPermission) but a latent correctness trap for future reuse. Fixed: classify now requires method == nil for the "response" case, matching the same distinction Connection.owesResponse already uses in production code.

    A follow-up automated review pass (mcp__sah__review) then flagged a third item claiming the classifier's method-name check ("session/update") doesn't match what AgentSideConnection.sessionUpdate sends ("sessionUpdate") -- verified this is a false positive: MethodTable.generated.swift confirms the "sessionUpdate" handler's wireMethod is literally "session/update" (RoleDispatch resolves Swift handler names to wire method names via the routing table before writing), and this is empirically confirmed by the ordering test passing reliably across 500 iterations x 10+ full-suite reruns. No change made for that one; the fourth (a magic-number 3600 in Task.sleep) was legitimate and fixed with a named constant (indefiniteForegroundWorkDuration), mirroring the existing precedent in SessionLifecycleTests.swift's SessionManagingAgent.prompt.

    Final re-verification after all fixes: swift build --build-tests clean (0 warnings/errors from a full rm -rf .build). swift test run 10 additional times post-fix, all green (185 tests/15 suites + 75 tests/10 suites = 260 tests/25 suites each time). mcp__sah__diagnostics clean.

    Task remains in `doing`, ready for /review.
  timestamp: 2026-07-28T01:55:57.253390+00:00
- actor: claude-code
  id: 01kyk81px1djnnpstyxaq5y3f1
  text: |-
    Pulled back from review into doing to address the 2026-07-27 21:01 review findings. All 6 addressed:

    1. Renamed `nextRequestID` -> `nextRequestId` throughout Connection.swift (declaration + both usages in `request(method:params:timeout:)`).

    2-5. Extracted the repeated `do { try await transport.write(NDJSONCodec.encode(...)) } catch { log(...) } ` pattern into a new private helper on Connection:
    ```
    private func writeEncoded(_ value: JSONValue, logMessage: String) async {
        do {
            try await transport.write(NDJSONCodec.encode(value))
        } catch {
            log("\(logMessage): \(error)")
        }
    }
    ```
    placed after `log(_:)`. Updated all 4 call sites: `deliver()`'s standalone-response path, `deliver()`'s batch-flush path, `respondParseError()`, and `cancelOutbound()`. Verified these 4 are the only call sites with this exact log-and-swallow semantics -- `notify()` rethrows on failure and `write(_:failing:)` fails a specific pending continuation on failure, so neither was folded into the helper (different error-handling contracts).

    6. In PromptLifecycleTests.swift, added `private let standardTestTimeout = 1  // minute` next to the other fixture constants and replaced the 4 occurrences of `.timeLimit(.minutes(1))` with `.timeLimit(.minutes(standardTestTimeout))`. Left `promptResponseArrivesBeforeTheFirstStateUpdate`'s own `.timeLimit(.minutes(2))` untouched -- it intentionally has a larger budget for its internal 500-iteration loop and is a separate concern from the plain per-test 1-minute constant.

    Verification: `swift build --build-tests` clean (0 errors/0 warnings). `swift test` full suite: 185 tests/15 suites (FoundationModelsACPTests) + 75 tests/10 suites (ACPGenerateTests) = 260/25, all green, matching baseline. `mcp__sah__diagnostics check working`: 0 errors/0 warnings. Re-ran `swift test --filter PromptLifecycleTests` 10 additional times back to back (each run internally repeats the ordering-race check `repetitionsForOrderingRaceDetection` = 500x) -- all 10 runs green, so the response-before-first-state_update ordering guarantee from the M3/M6 concurrency fix still holds after this refactor (5,000 additional ordering-race iterations with zero failures, on top of the ~30 full-suite reruns already logged from the original implementation).

    Adversarial double-check (via really-done) launched; will report its verdict once it lands. Task remains in `doing`.
  timestamp: 2026-07-28T02:14:50.529840+00:00
- actor: claude-code
  id: 01kyk82v7gvy8yc3vj000t07p7
  text: |-
    Adversarial double-check (via really-done) verdict: PASS. Independently confirmed: the `writeEncoded` extraction is semantically identical to the 4 original inline blocks (same encode call, same swallow-and-log behavior, same log message text per site); no remaining references to `nextRequestID` anywhere in the tree; `standardTestTimeout` preserves the 1-minute duration at all 4 sites and the ordering test's separate `.timeLimit(.minutes(2))` was correctly left untouched; `notify()` and `write(_:failing:)` correctly left out of the extraction since they have different error-handling contracts (rethrow / fail-a-specific-continuation vs. log-and-swallow); no unrelated changes in the diff.

    All verification green: `swift build --build-tests` (0 errors/0 warnings), full `swift test` (260 tests/25 suites, matching baseline), `mcp__sah__diagnostics check working` (0/0), and 10 extra back-to-back `swift test --filter PromptLifecycleTests` runs (5,000 total ordering-race iterations) all passing -- the response-before-first-state_update guarantee holds after the refactor.

    All 6 review findings fixed. Task remains in `doing`, ready for `/review`.
  timestamp: 2026-07-28T02:15:27.728255+00:00
- actor: claude-code
  id: 01kyk8xpp04hsrcwadcwyfrnfa
  text: |-
    BLOCKER — validator rule contradiction, not a code defect. Documenting per project process rather than picking a winner or touching the identifier again.

    What happened, in order:

    - Round 1 (2026-07-27 21:01 review): flagged `Connection.swift`'s outbound-request counter, then named `nextRequestID`, and demanded it be renamed to `nextRequestId` — citing "Acronym `ID` in `lowerCamelCase` context should be downcase-first" and stating the project's `...Id` exception (for ACP-generated types like `SessionId`/`ToolCallId`) does not cover this internal counter.
    - That finding was implemented in commit `ab483e6` (see comment `01kyk81px1djnnpstyxaq5y3f1` above): the field is now `nextRequestId` throughout Connection.swift.
    - Round 2 (2026-07-27 21:19 review): re-flagged the SAME identifier, now spelled `nextRequestId`, and demanded the opposite rename — back to `nextRequestID` — citing "uniform-casing rule for acronyms... Non-ACP ID usages must be uniformly cased as either all-uppercase or all-lowercase" and invoking the identical ACP-generated-type-exception rationale to reach the opposite required casing.

    Both rounds cite the same underlying casing rule (the `...Id` exception applies only to ACP-generated `SessionId`/`ToolCallId`-style types, not this counter) but reach opposite required casings for the same identifier. This is a genuine, unresolvable contradiction between two review passes, not a new code defect and not something a "pick one" judgment call can fix, since the next pass could just as easily flip it back.

    Action taken per this project's process for a real contradiction: did NOT touch the identifier's casing again. It remains `nextRequestId` (its state as of commit `ab483e6`, i.e. round 1's answer, left alone rather than re-litigated). No further renames applied.

    What a human needs to do: fix the underlying review-validator rule so it deterministically picks one casing (all-lowercase `Id` or all-uppercase `ID`) for non-ACP-generated identifiers and stops flip-flopping between passes. Once that rule is fixed, a future pass can safely apply whichever casing the corrected rule settles on.

    Separately, the round-2 finding at Connection.swift's `dispatchRequest` (4 levels of nesting: Task -> withValue closure -> do block -> catch clauses) was legitimate and has been fixed: extracted the do/catch outcome computation into a new `private static func outcome(of handler:method:params:) async -> Result<JSONValue, RequestError>`, called from inside the `withValue` closure, removing 2 nesting levels. Verified: `swift build --build-tests` clean (0 errors/0 warnings), full `swift test` 260 tests/25 suites all green (matching baseline), and `swift test --filter PromptLifecycleTests --maximum-repetitions 30` all green — the response-before-first-state_update ordering guarantee holds after this refactor.

    Task left in `review` (not moved to `doing`, not moved to `done`) since it is stuck on the identifier-casing contradiction pending human action on the validator rule.
  timestamp: 2026-07-28T02:30:07.808065+00:00
- actor: claude-code
  id: 01kyk93ay2dzthtaewxbwqk19h
  text: |-
    Marking this task STUCK per the /finish orchestration process, not closing it.

    Reason: the local review engine issued genuinely contradictory findings on the same identifier (Connection.swift's request-id counter) across two consecutive rounds — round 1 (2026-07-27 21:01) demanded nextRequestID -> nextRequestId citing the project's "…Id exception is only for ACP-generated types" rule; round 2 (2026-07-27 21:19) demanded the exact opposite, nextRequestId -> nextRequestID, citing the identical rule. Both cannot be satisfied. Per the finish skill's contradiction-handling rule, the orchestrator does not pick a winner and does not touch the identifier again — a human needs to fix the underlying casing validator rule (settle on one consistent convention for non-ACP identifiers, all-lowercase id or all-uppercase ID) before this identifier is touched again.

    The other legitimate finding from round 2 (dispatchRequest nesting) was fixed, tested, stress-tested for the ordering-race guarantee, and committed (SHA ea1e252).

    Left in review, unresolved, for a human to fix the review-validator casing rule and re-run /review on this task once fixed. This task is being skipped for now in the current /finish batch run.
  timestamp: 2026-07-28T02:33:12.386653+00:00
- actor: claude-code
  id: 01kyn9fz2jpc5tk4n7bdsd2skz
  text: |-
    Blocker resolved — the round-2/round-3 "contradiction" on `nextRequestId`/`nextRequestID` was a mistake by the prior orchestrator, not a genuine validator conflict. Corrected as follows:

    * Read `.validators/swift/rules/casing.md`'s `casing` rule directly (via `git show HEAD:.validators/swift/rules/casing.md`, since the file has since been deleted from disk by unrelated concurrent activity in this repo — see below). The rule is explicit and self-resolving: down-case an acronym when it leads a lowerCamelCase name, up-case it when interior or leading an UpperCamelCase name, and this rule is stated as the deliberate tiebreaker for exactly the back-and-forth-renaming symptom seen here.
    * For `nextRequestId`/`nextRequestID` the leading word is `next`, not `Id`/`ID` — the acronym is interior/trailing, so the rule requires the UP-CASED form, `nextRequestID`.
    * The project's separate `…Id` exception is scoped only to ACP-generated wire-schema identifier types (`SessionId`, `ToolCallId`, `TerminalId`, etc.) and their properties/parameters. It says nothing about internal counters, so it does not cover this identifier. Both prior review rounds invoked that exception's rationale but reached opposite conclusions about which casing it left standing for a non-ACP identifier — that inconsistency was the reviewer's error, not evidence the rule itself was contradictory.
    * Renamed the field back to `nextRequestID` throughout `Sources/FoundationModelsACP/Connection/Connection.swift` (the `private var nextRequestID = 1` declaration and its two usages in `request(method:params:timeout:)`). Confirmed via whole-tree grep that no other `nextRequestId`/`nextRequestID` references exist anywhere in `Sources/` or `Tests/`.
    * No other changes made this round — the M6 prompt-lifecycle behavior (acknowledge-then-`state_update`, `running`/`idle`/`requires_action`, agent-generated `messageId`, cancel-yields-`idle`+`cancelled`, the response-before-first-`state_update` ordering fix) was left untouched, per the task's scope for this round.

    Verification (all fresh, this round):

    * `mcp__sah__diagnostics check working`: 0 errors, 0 warnings.
    * `swift build --build-tests`: clean, 0 errors/0 warnings.
    * Full `swift test`: 293 tests / 28 suites all green — 198 tests/16 suites in `FoundationModelsACPTests`, 95 tests/12 suites in `ACPGenerateTests`. This is a new baseline, not the previously recorded 260/25 — other tasks landed on the board since this card was last touched, exactly as flagged in the task brief; the baseline was re-derived from a fresh run rather than assumed.
    * `swift test --filter PromptLifecycleTests --maximum-repetitions 30`: 8/8 tests green across all 30 repetitions, including the internal 500-iteration ordering-race check inside `promptResponseArrivesBeforeTheFirstStateUpdate` (15,000 ordering-race iterations this round alone) — the rename didn't disturb the response-before-first-`state_update` guarantee from the earlier critical fix.
    * Adversarial double-check (via really-done, `double-check` agent): verdict PASS. Independently re-verified the rename's completeness/scope, re-read the casing rule from git history, and re-ran the build and `PromptLifecycleTests` filter itself.

    Unrelated observation, out of scope for this task: at some point during this session, the entire `.validators/` directory (including `casing.md`) was deleted from disk by what appears to be other concurrent background activity in this repo (visible as pending `D` entries in `git status`, not something this task's changes did). Not touched or reverted here since it's unrelated to the casing fix — flagging in case a human wants to look into it separately.

    Task left in `doing`, ready for `/review`.
  timestamp: 2026-07-28T21:18:35.090292+00:00
- actor: claude-code
  id: 01kynaadvcwddddpfd5nehh0yk
  text: |-
    Pulled back from review into doing to address the 2026-07-28 16:21 review findings. Both addressed:

    1. Extracted `private static let errorKey = "error"` in Connection.swift (placed after `cancelRequestMethod`, alongside the file's other wire-format constants), and replaced all 6 code-site occurrences of the "error" dictionary-key literal with `Self.errorKey`: both reads in `owesResponse`, the two reads in `dispatchSingle` (jsonrpc-version-mismatch branch and response-classification check), the write in `respond`, the write in `respondParseError`, and the read in `resolve`. One remaining literal "error" text is inside a doc comment illustrating `"error": null` peer-tolerance behavior — documentation prose, not a code site, correctly left untouched.

    2. Extracted `private static let requestIdKey = "requestId"` next to `errorKey`, and replaced both occurrences: the read in `handleCancelRequest` (parsing an incoming `$/cancel_request` notification's params) and the write in `cancelOutbound` (constructing an outgoing `$/cancel_request` notification).

    Verified exact occurrence counts and locations via fresh grep before editing rather than trusting the review's cited line numbers, per the task brief's warning that reviews can cite stale/approximate locations.

    Verification (all fresh this round): `swift build --build-tests` clean (0 errors/0 warnings). Full `swift test`: 198 tests/16 suites + 95 tests/12 suites = 293/28, all green, matching baseline exactly (pure refactor, no behavior change). `mcp__sah__diagnostics check working`: 0/0. `swift test --filter PromptLifecycleTests --maximum-repetitions 30`: 8/8 tests green across all 30 repetitions, including the internal 500-iteration ordering-race check in `promptResponseArrivesBeforeTheFirstStateUpdate` — the response-before-first-`state_update` guarantee holds after this refactor.

    Adversarial double-check (via really-done, `double-check` agent) verdict: PASS, no findings. Confirmed the diff is exactly 9 hunks (one adding the two constants, 8 one-line literal-to-constant swaps), all substitutions are semantically identical 1:1 key swaps, no unrelated code touched, and the new constants' placement/doc-comment style matches the surrounding wire-constant conventions.

    Task left in `doing`, ready for `/review`.
  timestamp: 2026-07-28T21:33:02.188669+00:00
- actor: claude-code
  id: 01kyncjm90ay2hq0d7b6p1b57m
  text: |-
    Pulled back from review into doing to address the 2026-07-28 16:36 review findings (3 items). Resolved as follows:

    1. FIXED: Extracted `private static let jsonrpcKey = "jsonrpc"` in Connection.swift, placed immediately after the existing `jsonrpcVersion` constant. Replaced all 6 occurrences of the "jsonrpc" dictionary-key literal with `Self.jsonrpcKey`: both occurrences in `request(method:params:timeout:)` and `notify(method:params:)`'s envelope construction, the guard check in `dispatchSingle`, `respond`'s envelope construction, `respondParseError`'s envelope, and `cancelOutbound`'s notification envelope. Verified exact count/locations via fresh grep before editing (6 occurrences confirmed, matching the finding). The `jsonrpcVersion` constant's own value literal "2.0" was correctly left untouched -- only the dictionary key name changed.

    2. FIXED: Extracted `private static let resultKey = "result"` in Connection.swift, placed between the existing `errorKey` and `requestIdKey` constants (same grouping/doc-comment style as those, added in a prior round). Replaced all 5 occurrences of the "result" dictionary-key literal with `Self.resultKey`: both checks in `owesResponse`, the check in `dispatchSingle`'s jsonrpc-version-mismatch branch, the check further down `dispatchSingle` for response classification, `respond`'s success-case envelope write, and `resolve`'s continuation-resume read. Verified 5 occurrences via fresh grep (matching the finding's "4+" estimate).

    3. DECLINED as validator false-positive -- NOT implemented: "rename `nextRequestID` back to `nextRequestId`". This is the third consecutive round citing the identical rule to demand the opposite casing of the same identifier (round 2026-07-27 21:01 demanded `nextRequestID` -> `nextRequestId`; round 2026-07-27 21:19 demanded the reverse; this round demands the reverse again). Per the project's casing rule (`~/.validators/swift/rules/casing.md`), acronym-spelling conversions between the uniform form (`ID`) and capitalized-word form (`Id`) must NEVER be flagged in either direction on any declaration, new or pre-existing -- "a finding that proposes one is a validator error." `nextRequestID` was already correctly re-settled on this exact spelling in the 2026-07-28 21:18 round specifically because of this rule, after a stale project-local validator copy caused the earlier flip-flop (that root cause -- the stale copy -- is fixed; this appears to be one more instance of the discouraged flip-flop finding from the review engine's judge model). Left `nextRequestID` exactly as-is; no rename applied. Per the task instructions, this checklist item is recorded as declined-as-false-positive rather than checked off as implemented.

    Verification (all fresh, this round): `swift build --build-tests` clean (0 errors/0 warnings). Full `swift test`: 198 tests/16 suites (FoundationModelsACPTests) + 95 tests/12 suites (ACPGenerateTests) = 293/28, all green, matching the current baseline exactly (pure refactor, no test-count change). `mcp__sah__diagnostics check working`: 0 errors/0 warnings. `swift test --filter PromptLifecycleTests --maximum-repetitions 30`: 8/8 tests green across all 30 repetitions, including the internal 500-iteration ordering-race check inside `promptResponseArrivesBeforeTheFirstStateUpdate` -- the response-before-first-state_update ordering guarantee holds after this refactor. Adversarial double-check (via really-done, `double-check` agent, independently re-ran `swift build --build-tests` and `swift test --filter PromptLifecycleTests` itself rather than trusting my numbers): verdict PASS -- confirmed all 11 literal-to-constant substitutions are correct and complete, `jsonrpcVersion`'s value literal untouched, new constants' placement/doc style matches `errorKey`/`requestIdKey` precedent, no unrelated changes, `nextRequestID` correctly left untouched per the out-of-scope instruction.

    Task left in `doing`, ready for `/review`.
  timestamp: 2026-07-28T22:12:28.064180+00:00
- actor: claude-code
  id: 01kyndmsy6nnhgpwqj2s4b593n
  text: |-
    Implemented the 2026-07-28 17:17 review round's methodKey/paramsKey/idKey extraction.

    Verified exact counts via fresh grep before editing (review's cited counts were close but I re-derived them directly rather than trusting the review text): "method" appeared at 4 sites (request, notify, dispatchSingle's method-check guard, cancelOutbound), "params" at 6 sites (request, notify, dispatchSingle x3 for handleCancelRequest/dispatchRequest/notificationHandler calls, cancelOutbound), "id" at 5 sites (request, owesResponse, dispatchSingle's id extraction, respond, respondParseError) -- one more than the review's cited "3 places" for id, since the review undercounted as usual in this repo.

    Added three new constants directly after jsonrpcKey, matching the existing docstring/placement convention (envelope-member-key constants grouped near the top of the type, before logPrefix):
    - private static let idKey = "id"
    - private static let methodKey = "method"
    - private static let paramsKey = "params"

    Replaced all 15 literal call sites with Self.idKey / Self.methodKey / Self.paramsKey. Took care NOT to touch: the existing requestIdKey = "requestId" constant and its two use sites (a distinct field name, not a bare "id"), the Swift argument-label `params:` in handleCancelRequest(params:) call sites (labels aren't string literals), and the doc-comment prose mentioning `id`/`method`/`params` in backticks (documentation, not code).

    Verification (fresh, this round): `swift build --build-tests` clean (0 errors/0 warnings). Full `swift test`: 198 tests/16 suites (FoundationModelsACPTests) + 95 tests/12 suites (ACPGenerateTests) = 293/28, all green, matching baseline exactly. `mcp__sah__diagnostics check working`: 0 errors/0 warnings. `swift test --filter PromptLifecycleTests --maximum-repetitions 30`: 8/8 tests green across all 30 repetitions, including the internal 500-iteration ordering-race check inside promptResponseArrivesBeforeTheFirstStateUpdate -- the response-before-first-state_update guarantee holds after this refactor.

    Adversarial double-check dispatched via really-done; awaiting verdict before final handoff. Task left in doing.
  timestamp: 2026-07-28T22:31:07.974233+00:00
- actor: claude-code
  id: 01kynest882qqaayrgcjxd3d5m
  text: |-
    Pulled back from review into doing to address the 2026-07-28 17:36 review's one open finding: extract a shared envelope-construction helper for request/notify.

    Verified exact current locations via fresh read (request's envelope literal and notify's had both shifted lines across every prior extraction round). Extracted `private static func outboundEnvelope(id: RequestId?, method: String, params: JSONValue?) -> JSONValue`, placed directly above `request` under `// MARK: - Outbound`, reusing the existing jsonrpcKey/methodKey/paramsKey/idKey constants rather than reintroducing literals. `id` is included only `if let id`, so notify (id: nil) omits the member entirely, matching original behavior. `request` and `notify` both now call this helper instead of duplicating the dictionary literal.

    Verification: `swift build --build-tests` clean (0/0). Full `swift test`: 293 tests/28 suites, matching baseline exactly. `mcp__sah__diagnostics check working`: 0/0. `swift test --filter PromptLifecycleTests --maximum-repetitions 30`: 8/8 green across 30 repetitions, ordering guarantee (`promptResponseArrivesBeforeTheFirstStateUpdate`) holds.

    Mutation testing: temporarily broke the helper so every notification would gain an `id: null` member instead of omitting id. Full suite caught it hard -- 40 issues across PromptLifecycleTests/SessionLifecycleTests/ConnectionTests. Reverted; re-verified clean/green. This confirms the suite actually exercises the shared envelope path rather than just looking similar.

    Adversarial double-check (via really-done): verdict PASS -- independently re-ran build, full suite, and the PromptLifecycleTests filter; also noted NDJSONCodec.encode uses sortedKeys output formatting so the helper's field-declaration-order difference from the originals has zero wire-format effect.

    Task left in `doing`, ready for `/review`.
  timestamp: 2026-07-28T22:51:20.712034+00:00
- actor: claude-code
  id: 01kyng3mfstx87tcaaxpjgmqs1
  text: |-
    Pulled back from review into doing to address the 2026-07-28 17:58 review's one remaining root cause (reported as two checklist entries): `cancelOutbound` still manually built its outgoing `$/cancel_request` notification envelope instead of using the `outboundEnvelope` helper extracted in the prior round.

    Verified current implementation via `get symbol` before editing (line numbers in the review findings were stale, as usual for this file after many rounds of edits): `cancelOutbound` was at line 754, manually constructing `JSONValue.object([jsonrpcKey: jsonrpcVersion, methodKey: .string(cancelRequestMethod), paramsKey: .object([requestIdKey: id])])`. Confirmed `RequestId` is `typealias RequestId = JSONValue` (in `Unresolved.generated.swift`), so the `id` parameter needed no wrapping/conversion to be used as a `JSONValue` dictionary value.

    Fix: replaced the manual literal with `Self.outboundEnvelope(id: nil, method: Self.cancelRequestMethod, params: .object([Self.requestIdKey: id]))`. `id: nil` is correct because the original never stamped a top-level envelope `id` for this notification either — the `id` variable was only ever used inside `params`, never as the envelope's own id — and `outboundEnvelope` only adds the `idKey` member `if let id`, so passing `nil` reproduces the original's `{jsonrpc, method, params}` shape exactly (no stray `id: null`).

    Verification (all fresh, this round):
    - `swift build --build-tests`: clean, 0 errors/0 warnings.
    - `mcp__sah__diagnostics check working`: 0 errors/0 warnings.
    - Full `swift test`: 198 tests/16 suites (FoundationModelsACPTests) + 95 tests/12 suites (ACPGenerateTests) = 293/28, all green, matching baseline exactly.
    - `swift test --filter PromptLifecycleTests --maximum-repetitions 30`: 8/8 tests green across all 30 repetitions, including the internal 500-iteration ordering-race check inside `promptResponseArrivesBeforeTheFirstStateUpdate` — the response-before-first-`state_update` guarantee holds after this change.
    - `swift test --filter 'ConnectionTests|SubprocessReapTests|SessionLifecycleTests'`: 46/46 green, explicitly including the cancellation-flow tests `cancelRequestNotificationCancelsRunningHandlerAndAnswersRequestCancelled`, `closingTransportReapsSpawnedChild`, `closingConnectionReapsChildAgent`, and `concurrentBidirectionalRequestsCorrelateToCallers` — confirming `cancelOutbound`'s cancellation behavior (the code path this change directly touches) is unaffected.

    Adversarial double-check (via really-done, `double-check` agent, which independently re-ran `git diff` scope check, `swift build --build-tests`, the full suite, and the `PromptLifecycleTests --maximum-repetitions 30` filter): verdict PASS. It also grepped the file to confirm no other hand-built `jsonrpc`/`method`/`params` envelope literal remains outside `outboundEnvelope` itself (the two response-shaped envelopes in `respond`/`respondParseError` are a different shape — `jsonrpc/id/result|error` — correctly out of scope for this helper).

    Task left in `doing`, ready for `/review`.
  timestamp: 2026-07-28T23:14:11.065089+00:00
depends_on:
- 01KYD58WV07Q982G94JHT1SH5G
position_column: doing
position_ordinal: '80'
title: 'M6 Prompt lifecycle: acknowledge, then report state'
---
## Starting point

**This is a rewrite** — see `plan.md` -> *Starting point*. Of all the milestones, this one has the **least** to salvage: the v1 prompt lifecycle is not a v2 prompt lifecycle with different types, it is a different design. The deleted v1 code held `session/prompt` open for an entire turn and resolved it with a `stopReason`; v2 acknowledges immediately and reports everything through `state_update`. Do not consult the v1 turn code for structure — it will actively mislead you. Its cancellation plumbing is the only part with any carryover.

## What

`plan.md` -> **M6**. The change with the largest blast radius for our agent.

**v1:** `session/prompt` stayed pending for the whole turn and resolved with `stopReason`.
**v2:** it returns **`{}` immediately** to acknowledge acceptance. *\"The `session/prompt` response no longer ends the turn. It acknowledges acceptance. Foreground progress and completion arrive as `state_update` notifications, and the stop reason moved there too.\"*

`state_update` carries three states:

- **`running`** -- foreground work in progress.
- **`idle`** -- ready for the next prompt; carries **`stopReason`** when transitioning from working.
- **`requires_action`** -- foreground work **blocked waiting on the user**. This is a protocol-level state for exactly the permission / elicitation pause, which previously had no representation at all.

Also required: after accepting a prompt the agent must emit a `user_message` or streamed `user_message_chunk` updates carrying an **agent-generated `messageId`** -- the agent owns history, so it owns message identity.

**Cancellation:** `session/cancel` stays a notification, but confirmation now arrives as an `idle` `state_update` with `stopReason: \"cancelled\"` rather than in the prompt response.

## Acceptance Criteria

- [x] `session/prompt` returns `{}` immediately, before any work completes.
- [x] `state_update` emits `running`, `idle` (with `stopReason`), and `requires_action`.
- [x] Accepting a prompt emits a `user_message` / chunks with an agent-generated `messageId`.
- [x] `session/cancel` results in an idle state with `stopReason: \"cancelled\"`.
- [x] `stopReason` values round-trip, unknown ones preserved.

## Tests

- [x] The prompt response arrives before the first `state_update` -- assert ordering, since this is the entire semantic change.
- [x] A full turn produces running -> idle with a `stopReason`.
- [x] A blocked turn reports `requires_action`, then resumes to `running` once answered.
- [x] Cancel mid-turn yields idle + `cancelled`.
- [x] The acknowledged prompt's `messageId` is present and stable across its chunks.

## Review Findings (2026-07-27 21:01)

- [x] `Sources/FoundationModelsACP/Connection/Connection.swift:153` — Acronym `ID` in `lowerCamelCase` context should be downcase-first as `nextRequestId`, not `nextRequestID`. The project exception for `…Id` ACP types applies only to machine-generated types following the `SessionId`/`ToolCallId` pattern; this counter variable is neither ACP-generated nor following that pattern. Rename `nextRequestID` to `nextRequestId` throughout Connection.swift (lines 153, and any usages in the `request` method). **Implemented in commit `ab483e6`. Superseded — see the 2026-07-28 resolution note below: this finding's stated rule was misapplied and the identifier has since been renamed back to `nextRequestID`, which is what the casing rule actually requires.**
- [x] `Sources/FoundationModelsACP/Connection/Connection.swift:288` — The pattern `do { try await transport.write(NDJSONCodec.encode(...)) } catch { log(...) }` is repeated 4 times across the file. Extract a shared helper method: `private func writeEncoded(_ value: JSONValue, logMessage: String) async { do { try await transport.write(NDJSONCodec.encode(value)) } catch { log(logMessage + \": \(error)\") } }` and replace all 4 occurrences.
- [x] `Sources/FoundationModelsACP/Connection/Connection.swift:306` — Second occurrence of write-encode-catch-log pattern in deliver() method (batch response path). Use extracted helper method instead of duplicating the try-catch block.
- [x] `Sources/FoundationModelsACP/Connection/Connection.swift:321` — Third occurrence of write-encode-catch-log pattern in respondParseError() method. Use extracted helper method instead of duplicating the try-catch block.
- [x] `Sources/FoundationModelsACP/Connection/Connection.swift:483` — Fourth occurrence of write-encode-catch-log pattern in cancelOutbound() method. Use extracted helper method instead of duplicating the try-catch block.
- [x] `Tests/FoundationModelsACPTests/PromptLifecycleTests.swift:376` — Hardcoded timeout value 1 (minute) configures test behavior and should be a named constant. Extract to a named constant: `private let standardTestTimeout = 1 // minute` and use `.timeLimit(.minutes(standardTestTimeout))`.

## Review Findings (2026-07-27 21:19)

- [x] **RESOLVED 2026-07-28 — was mistakenly treated as an unresolvable validator contradiction; it was not.** `Sources/FoundationModelsACP/Connection/Connection.swift:143` — This pass's engine flagged `nextRequestId` and demanded renaming it to `nextRequestID`. At the time this looked like the exact opposite of the 2026-07-27 21:01 finding on the same identifier, and a prior agent declared it a genuine, unresolvable validator-rule contradiction, left the identifier untouched, and stuck the task in `review`. That declaration was a mistake: `.validators/swift/rules/casing.md`'s `casing` rule is unambiguous and explicitly self-resolving — \"Down-case it when it leads a lowerCamelCase name; up-case it when interior or leading an UpperCamelCase name... This rule wins over local file prevalence... Renaming back and forth between the two forms across review rounds is always a validator error, and this rule is the tiebreaker.\" For `nextRequestId`/`nextRequestID`, the leading word is `next`, not `Id`/`ID` — the acronym sits in interior/trailing position, so the rule requires the UP-CASED form: `nextRequestID`. The project's separate `…Id` exception is explicitly scoped to ACP-generated wire-schema identifier types (`SessionId`, `ToolCallId`, etc.) and does not cover this plain internal counter. **Renamed `nextRequestId` -> `nextRequestID` throughout Connection.swift (declaration + both usages in `request(method:params:timeout:)`).** No other references existed anywhere in `Sources/`/`Tests/`. Verified: `swift build --build-tests` clean (0 errors/0 warnings); full `swift test` fresh baseline 293 tests/28 suites (198/16 FoundationModelsACPTests + 95/12 ACPGenerateTests), all green — note this baseline has grown from the previously recorded 260/25 since other tasks landed on the board in the interim; `swift test --filter PromptLifecycleTests --maximum-repetitions 30` all green (8/8 tests x 30 repetitions, including the 500-iteration-internal ordering-race test `promptResponseArrivesBeforeTheFirstStateUpdate`), confirming the rename didn't disturb the response-before-first-state_update guarantee. Adversarial double-check (via really-done) verdict: PASS.
- [x] `Sources/FoundationModelsACP/Connection/Connection.swift:480` — `dispatchRequest` has 4 levels of deep nesting (Task → withValue closure → do block → multiple catch clauses), with error handling branches adding cognitive load. Extract the do/catch outcome computation into a separate private helper method that returns `Result<JSONValue, RequestError>`, eliminating 2 nesting levels. **FIXED**: extracted `private static func outcome(of handler:method:params:) async -> Result<JSONValue, RequestError>`, called from the `withValue` closure in `dispatchRequest`. Verified with `swift build --build-tests` (clean) and full `swift test` (260/25, matching baseline) plus `swift test --filter PromptLifecycleTests --maximum-repetitions 30` (ordering guarantee holds).

Note: the engine also returned two findings targeting `Tests/FoundationModelsACPTests/PromptLifecycleTests.swift` (nesting in `runTurn` at line 126, and a hardcoded `.seconds(3600)` literal at line 150) — both outside this commit's diff hunks (pre-existing test code, confirmed via `git show HEAD -- Tests/FoundationModelsACPTests/PromptLifecycleTests.swift`). Per the review skill's blanket \"never ask to refactor existing tests\" exception, these were dropped rather than relayed.

## Review Findings (2026-07-28 16:21)

- [x] `Sources/FoundationModelsACP/Connection/Connection.swift:301` — String literal \"error\" is repeated 6+ times throughout the file (lines 301, 327, 379, 434, 538) and should be extracted as a named constant. Extract as private static let errorKey = \"error\" and use Self.errorKey in place of literal strings. **FIXED**: added `private static let errorKey = \"error\"` alongside the file's other wire constants (after `cancelRequestMethod`), and replaced all 6 code-site occurrences of the `\"error\"` dictionary-key literal with `Self.errorKey`: the two reads in `owesResponse`, the read in the jsonrpc-version-mismatch branch of `dispatchSingle`, the read in the response-classification check further down `dispatchSingle`, the write in `respond`, the write in `respondParseError`, and the read in `resolve`. (The one remaining literal \"error\" text in the file, in a doc comment illustrating `` `\"error\": null` `` peer tolerance, is documentation prose, not a code site, and was correctly left alone.) Verified via whole-file grep before and after.
- [x] `Sources/FoundationModelsACP/Connection/Connection.swift:403` — String literal \"requestId\" is repeated 2 times in different methods (line 403 reads it from incoming cancel requests, line 540 writes it to outgoing cancel requests) and should be extracted as a named constant to keep the protocol field definition in one place. Extract as private static let requestIdKey = \"requestId\" and use Self.requestIdKey in place of literal strings. **FIXED**: added `private static let requestIdKey = \"requestId\"` next to `errorKey`, and replaced both occurrences: the read in `handleCancelRequest` (parsing an incoming `$/cancel_request` notification's params) and the write in `cancelOutbound` (constructing an outgoing `$/cancel_request` notification). Verified via whole-file grep before and after — only the constant's own declaration contains the literal now.

Verification for this round (fresh, 2026-07-28): `swift build --build-tests` clean (0 errors/0 warnings). Full `swift test`: 198 tests/16 suites (FoundationModelsACPTests) + 95 tests/12 suites (ACPGenerateTests) = 293/28, all green, matching the current baseline exactly (pure refactor, no test count change expected or observed). `mcp__sah__diagnostics check working`: 0 errors/0 warnings. `swift test --filter PromptLifecycleTests --maximum-repetitions 30`: 8/8 tests green across all 30 repetitions, including the internal 500-iteration ordering-race check inside `promptResponseArrivesBeforeTheFirstStateUpdate` — the response-before-first-`state_update` guarantee holds after this refactor. Adversarial double-check (via really-done, `double-check` agent): verdict PASS, no findings — confirmed the diff is exactly 9 hunks (one adding the two constants, 8 one-line literal→constant swaps), all substitutions are semantically identical 1:1 key swaps, no unrelated code touched.

Task left in `doing`, ready for `/review`.

## Review Findings (2026-07-28 16:36)

Scope reviewed: `review sha HEAD~1..HEAD` (commit `8bde043`, the errorKey/requestIdKey extraction checkpoint).

- [x] `Sources/FoundationModelsACP/Connection/Connection.swift:151` — \"jsonrpc\" field name is hardcoded 6 times and should be a named constant, matching the pattern established by errorKey and requestIdKey extraction. Extract as: private static let jsonrpcKey = \"jsonrpc\" and replace all occurrences with Self.jsonrpcKey. **FIXED 2026-07-28 22:xx**: added `private static let jsonrpcKey = \"jsonrpc\"` immediately after `jsonrpcVersion`, and replaced all 6 code-site occurrences of the \"jsonrpc\" dictionary-key literal with `Self.jsonrpcKey` (in `request`, `notify`, the version-check guard in `dispatchSingle`, `respond`, `respondParseError`, and `cancelOutbound`). `jsonrpcVersion`'s own value literal \"2.0\" correctly left untouched. Verified via fresh grep before/after; confirmed by adversarial double-check (PASS).
- [x] `Sources/FoundationModelsACP/Connection/Connection.swift:152` — Property name `nextRequestID` uses uppercase acronym ID in camelCase context, inconsistent with strict camelCase used throughout this file. Rename to `nextRequestId` to match Swift naming conventions and consistency with other identifiers in this file. **DECLINED 2026-07-28 22:xx as a validator false-positive — NOT implemented, `nextRequestID` left exactly as-is.** This is the third consecutive review round (after 2026-07-27 21:01 and 2026-07-27 21:19, both resolved above) citing the identical casing rule to demand the opposite casing of this same identifier. The project's casing rule (`~/.validators/swift/rules/casing.md`) explicitly states that acronym-spelling conversions between the uniform form (`ID`) and capitalized-word form (`Id`) must NEVER be flagged in either direction on any declaration, new or pre-existing, and that \"a finding that proposes one is a validator error.\" `nextRequestID` was already correctly re-settled on this exact spelling in the 2026-07-28 21:18 round specifically because of this rule (after a stale, since-deleted project-local validator copy caused the earlier genuine flip-flop — that root cause is fixed). This finding is one more instance of the discouraged flip-flop the rule itself warns against, not a new legitimate signal. No rename applied.
- [x] `Sources/FoundationModelsACP/Connection/Connection.swift:364` — \"result\" field name is hardcoded 4+ times and should be a named constant for consistency. Extract as: private static let resultKey = \"result\" and replace all occurrences. **FIXED 2026-07-28 22:xx**: added `private static let resultKey = \"result\"` between `errorKey` and `requestIdKey` (same grouping/doc-comment style), and replaced all 5 code-site occurrences of the \"result\" dictionary-key literal with `Self.resultKey` (both checks in `owesResponse`, the version-mismatch check and the response-classification check in `dispatchSingle`, `respond`'s success-case write, and `resolve`'s continuation-resume read). Verified via fresh grep before/after; confirmed by adversarial double-check (PASS).

Verification for this round (fresh, 2026-07-28): `swift build --build-tests` clean (0 errors/0 warnings). Full `swift test`: 198 tests/16 suites + 95 tests/12 suites = 293/28, all green, matching baseline exactly. `mcp__sah__diagnostics check working`: 0/0. `swift test --filter PromptLifecycleTests --maximum-repetitions 30`: 8/8 tests green across all 30 repetitions, ordering guarantee holds. Adversarial double-check (via really-done, `double-check` agent, which independently re-ran the build and PromptLifecycleTests filter itself): verdict PASS.

Task left in `doing`, ready for `/review`.

## Review Findings (2026-07-28 17:17)

Scope reviewed: `review sha HEAD~1..HEAD` (commit `2051d99`, the jsonrpcKey/resultKey extraction checkpoint). This commit fixed the two real findings from the 2026-07-28 16:36 round (jsonrpcKey, resultKey) and deliberately left the `nextRequestID` casing finding un-actioned as a documented validator false-positive (see that round's note above). This round's engine did NOT re-flag `nextRequestID`/`nextRequestId` — no 4th flip-flop instance — but it did surface a new, legitimate batch of findings: the same wire-format-constant-extraction pattern still has unextracted literals for `method`, `params`, and `id`.

- [x] `Sources/FoundationModelsACP/Connection/Connection.swift:241` — The literal \"method\" should be extracted as a named constant — it is a JSON-RPC 2.0 wire format field name appearing in 4 places across read and write sites, violating the consistency established by jsonrpcKey, errorKey, resultKey, and requestIdKey constants in this same file. Extract private static let methodKey = \"method\" and use Self.methodKey at all 4 occurrences to match the existing pattern. **FIXED 2026-07-28**: confirmed via fresh grep exactly 4 sites (in `request`, `notify`, the method-string-check guard in `dispatchSingle`, and `cancelOutbound`'s outgoing `$/cancel_request` notification) — matches the review's count exactly. Added `private static let methodKey = \"method\"` and replaced all 4.
- [x] `Sources/FoundationModelsACP/Connection/Connection.swift:244` — The literal \"params\" should be extracted as a named constant — it is a JSON-RPC 2.0 wire format field name appearing in 6+ places across read and write sites, violating the consistency established by jsonrpcKey, errorKey, resultKey, and requestIdKey constants in this same file. Extract private static let paramsKey = \"params\" and use Self.paramsKey at all 6+ occurrences to match the existing pattern. **FIXED 2026-07-28**: confirmed via fresh grep exactly 6 sites (`request`'s envelope write, `notify`'s envelope write, and dispatchSingle's three reads feeding `handleCancelRequest`/`dispatchRequest`/`notificationHandler`, plus `cancelOutbound`'s outgoing notification write). Added `private static let paramsKey = \"params\"` and replaced all 6. Took care to leave the Swift argument label `params:` in call sites like `handleCancelRequest(params: fields[Self.paramsKey])` untouched — only the dictionary-subscript string-literal keys changed, never argument labels.
- [x] `Sources/FoundationModelsACP/Connection/Connection.swift:245` — The literal \"id\" should be extracted as a named constant — it is a JSON-RPC 2.0 wire format field name appearing in 3 places across read and write sites, violating the consistency established by jsonrpcKey, errorKey, resultKey, and requestIdKey constants in this same file. Extract private static let idKey = \"id\" and use Self.idKey at all 3 occurrences to match the existing pattern. **FIXED 2026-07-28 — review undercounted, actual count was 5, not 3** (consistent with this repo's established pattern of review counts running low; verified myself via fresh whole-file grep before editing rather than trusting the cited count): the 5 bare \"id\" dictionary-key sites are `request`'s envelope write, `owesResponse`'s presence check, `dispatchSingle`'s `let id = fields[...]` extraction, `respond`'s envelope write, and `respondParseError`'s `id: .null` write. Added `private static let idKey = \"id\"` and replaced all 5. Verified the existing `requestIdKey = \"requestId\"` constant (a distinct field name, \"requestId\" not bare \"id\") and its two use sites in `handleCancelRequest`/`cancelOutbound` were correctly left untouched and not conflated with the new `idKey`.
- [x] `Sources/FoundationModelsACP/Connection/Connection.swift:247` — Literal \"params\" appears in dispatchSingle's dispatchRequest call — this should use the extracted constant to match the pattern established by other wire format field names. Use Self.paramsKey instead of literal \"params\". **FIXED** — covered by the paramsKey extraction above.
- [x] `Sources/FoundationModelsACP/Connection/Connection.swift:267` — Literal \"id\" appears in respond envelope — this should use the extracted constant to match the pattern established by other wire format field names. Use Self.idKey instead of literal \"id\". **FIXED** — covered by the idKey extraction above.
- [x] `Sources/FoundationModelsACP/Connection/Connection.swift:315` — Literal \"id\" appears in request envelope — this should use the extracted constant to match the pattern established by other wire format field names. Use Self.idKey instead of literal \"id\". **FIXED** — covered by the idKey extraction above.
- [x] `Sources/FoundationModelsACP/Connection/Connection.swift:316` — Literal \"method\" appears in request envelope — this should use the extracted constant to match the pattern established by other wire format field names. Use Self.methodKey instead of literal \"method\". **FIXED** — covered by the methodKey extraction above.
- [x] `Sources/FoundationModelsACP/Connection/Connection.swift:318` — Literal \"params\" appears in request envelope — this should use the extracted constant to match the pattern established by other wire format field names. Use Self.paramsKey instead of literal \"params\". **FIXED** — covered by the paramsKey extraction above.
- [x] `Sources/FoundationModelsACP/Connection/Connection.swift:325` — Literal \"method\" appears in notify envelope — this should use the extracted constant to match the pattern established by other wire format field names. Use Self.methodKey instead of literal \"method\". **FIXED** — covered by the methodKey extraction above.
- [x] `Sources/FoundationModelsACP/Connection/Connection.swift:326` — Literal \"params\" appears in notify envelope — this should use the extracted constant to match the pattern established by other wire format field names. Use Self.paramsKey instead of literal \"params\". **FIXED** — covered by the paramsKey extraction above.
- [x] `Sources/FoundationModelsACP/Connection/Connection.swift:361` — The literal \"id\" appears again in respondParseError — this is an additional write occurrence of the wire format field name that should use the extracted constant for consistency with the pattern. Use Self.idKey instead of literal \"id\" to complete the extraction across all 4 occurrences. **FIXED** — covered by the idKey extraction above.
- [x] `Sources/FoundationModelsACP/Connection/Connection.swift:407` — Literal \"method\" appears in cancelOutbound notification — this should use the extracted constant to match the pattern established by other wire format field names. Use Self.methodKey instead of literal \"method\". **FIXED** — covered by the methodKey extraction above.

Verification for this round (fresh, 2026-07-28): added the three constants (`idKey`, `methodKey`, `paramsKey`) directly after `jsonrpcKey`, matching the file's existing docstring/placement convention for envelope-member-key constants. Replaced all 15 literal call sites (4 `method` + 6 `params` + 5 `id`). Post-edit whole-file grep for `\"method\"|\"params\"|\"id\"` returns exactly 3 lines — the three constant declarations themselves; no stray literals remain anywhere else in the file. `swift build --build-tests` clean (0 errors/0 warnings). Full `swift test`: 198 tests/16 suites (FoundationModelsACPTests) + 95 tests/12 suites (ACPGenerateTests) = 293/28, all green, matching baseline exactly. `mcp__sah__diagnostics check working`: 0 errors/0 warnings. `swift test --filter PromptLifecycleTests --maximum-repetitions 30`: 8/8 tests green across all 30 repetitions, including the internal 500-iteration ordering-race check inside `promptResponseArrivesBeforeTheFirstStateUpdate` — the response-before-first-`state_update` guarantee holds after this refactor. Adversarial double-check (via really-done, `double-check` agent, which independently re-ran the build, full test suite, and the PromptLifecycleTests filter, and confirmed no bare `id`/`method`/`params` literal sites were missed, no argument labels were mistakenly touched, and `requestIdKey` remained distinct from the new `idKey`): verdict PASS.

Task left in `doing`, ready for `/review`.

## Review Findings (2026-07-28 17:36)

Scope reviewed: `review sha HEAD~1..HEAD` (commit `d199cf3`, the methodKey/paramsKey/idKey extraction checkpoint that closed out all 12 findings from the 2026-07-28 17:17 round). This round's engine did NOT re-flag `nextRequestID`/`nextRequestId` casing — no further flip-flop. It surfaced one new, legitimate finding: a structural duplication between `request` and `notify` that predates this task's constant-extraction work but is newly visible now that both envelope-construction sites use the same named constants.

- [x] `Sources/FoundationModelsACP/Connection/Connection.swift:244` — Envelope construction in `notify` (lines 244–249) is near-verbatim with `request` (lines 218–223), differing only by the absence of `idKey`. Changes to method or params encoding must be synchronized across both, creating drift risk. Extract a shared helper to construct request/notification envelopes, parameterized by optional id. **FIXED 2026-07-28**: verified exact current locations via fresh read before editing (this file has shifted line numbers across every prior round) — `request`'s envelope literal at what is now lines 264-269, `notify`'s at lines 307-312. Extracted `private static func outboundEnvelope(id: RequestId?, method: String, params: JSONValue?) -> JSONValue`, placed directly above `request` under `// MARK: - Outbound`, reusing the existing `jsonrpcKey`/`methodKey`/`paramsKey`/`idKey` constants (no literals reintroduced). `id` is included only `if let id`, so a notification (`id: nil`) omits the member entirely rather than encoding `null` — matching the original's behavior exactly, since Swift's dictionary-subscript-assign-nil already made the prior `envelope[paramsKey] = params` omit rather than null-encode. `request` now calls `Self.outboundEnvelope(id: id, method: method, params: params)`; `notify` calls `Self.outboundEnvelope(id: nil, method: method, params: params)`.

Verification (fresh, this round): `swift build --build-tests` clean (0 errors/0 warnings). Full `swift test`: 198 tests/16 suites + 95 tests/12 suites = 293/28, all green, matching baseline exactly (pure refactor, no test-count change). `mcp__sah__diagnostics check working`: 0/0. `swift test --filter PromptLifecycleTests --maximum-repetitions 30`: 8/8 tests green across all 30 repetitions, including the internal 500-iteration ordering-race check inside `promptResponseArrivesBeforeTheFirstStateUpdate` — the response-before-first-`state_update` guarantee holds after this refactor.

**Mutation testing** (per task instructions, to verify behavior-preservation rather than mere visual similarity): temporarily mutated the helper to unconditionally stamp `envelope[Self.idKey] = id ?? .null` (so every notification would gain an `id: null` member instead of omitting `id` entirely). Re-ran the full suite: this single-line mutation was caught hard — 40 issues across `PromptLifecycleTests`, `SessionLifecycleTests`, and `ConnectionTests` (e.g. `notificationsRouteToHandlerInSendOrder`, `outOfOrderNotificationsAreDeliveredWithoutReordering`, `promptResponseArrivesBeforeTheFirstStateUpdate`), confirming the suite actually exercises the shared envelope path and would catch a broken extraction, not just a differently-shaped-but-passing one. Reverted the mutation; re-verified clean build and full green suite (293/28) afterward.

Adversarial double-check (via really-done, `double-check` agent, which independently ran `git diff`, re-ran `swift build --build-tests`, full `swift test`, and the `PromptLifecycleTests --maximum-repetitions 30` filter itself, and additionally confirmed `NDJSONCodec.encode` uses `.sortedKeys` output formatting so the helper's field-declaration-order difference from the original inline blocks has zero effect on wire bytes): verdict PASS, no findings.

Task left in `doing`, ready for `/review`.

## Review Findings (2026-07-28 17:58)

Scope reviewed: `review sha HEAD~1..HEAD` (commit `b417930`, the outboundEnvelope extraction checkpoint that closed out the 2026-07-28 17:36 finding). This round's engine did NOT re-flag `nextRequestID`/`nextRequestId` casing. It surfaced one new, legitimate finding (reported by the engine as two checklist entries against the same root cause): `cancelOutbound` still builds its outgoing `$/cancel_request` notification by hand instead of calling the just-extracted `outboundEnvelope` helper, leaving a second manual envelope-construction call site that the extraction was meant to eliminate.

- [x] `Sources/FoundationModelsACP/Connection/Connection.swift:595` — The cancelOutbound function manually constructs a notification envelope, re-implementing the pattern just extracted into outboundEnvelope. After consolidating envelope building for requests and notifications, this pre-existing code duplicates that shared logic. Replace the manual envelope construction with: let notification = Self.outboundEnvelope(id: nil, method: Self.cancelRequestMethod, params: .object([Self.requestIdKey: id])). **FIXED 2026-07-28**: replaced `cancelOutbound`'s manual `JSONValue.object([...])` literal with `Self.outboundEnvelope(id: nil, method: Self.cancelRequestMethod, params: .object([Self.requestIdKey: id]))`. `RequestId` is `typealias RequestId = JSONValue`, so `id` needed no wrapping to serve as the params dictionary's value. `id: nil` correctly matches the original, which never stamped a top-level envelope id for this notification either.
- [x] `Sources/FoundationModelsACP/Connection/Connection.swift:619` — The diff extracts `outboundEnvelope` to centralize envelope construction and avoid duplication, but `cancelOutbound` still builds a notification envelope inline with the identical structure (jsonrpc, method, params), creating a sibling call site that will diverge if envelope encoding changes and defeating the stated purpose of the extraction ('exactly one call site'). Replace the inline envelope construction with a call to the extracted helper: `Self.outboundEnvelope(id: nil, method: Self.cancelRequestMethod, params: .object([Self.requestIdKey: id]))`. **FIXED** — same root cause as the finding above, covered by the same edit.

Verification (fresh, 2026-07-28): `swift build --build-tests` clean (0 errors/0 warnings). `mcp__sah__diagnostics check working`: 0/0. Full `swift test`: 198 tests/16 suites + 95 tests/12 suites = 293/28, all green, matching baseline exactly. `swift test --filter PromptLifecycleTests --maximum-repetitions 30`: 8/8 tests green across all 30 repetitions, including the internal 500-iteration ordering-race check inside `promptResponseArrivesBeforeTheFirstStateUpdate` — the response-before-first-`state_update` guarantee holds. `swift test --filter 'ConnectionTests|SubprocessReapTests|SessionLifecycleTests'`: 46/46 green, explicitly covering the cancellation-flow tests (`cancelRequestNotificationCancelsRunningHandlerAndAnswersRequestCancelled`, `closingTransportReapsSpawnedChild`, `closingConnectionReapsChildAgent`, `concurrentBidirectionalRequestsCorrelateToCallers`) — `cancelOutbound`'s cancellation behavior is unaffected. Adversarial double-check (via really-done, `double-check` agent, independently re-ran the diff-scope check, build, full suite, and PromptLifecycleTests filter, and confirmed no other hand-built jsonrpc/method/params envelope literal remains outside `outboundEnvelope`): verdict PASS.

Task left in `doing`, ready for `/review`.
