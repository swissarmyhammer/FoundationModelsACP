---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01ky3fjnc5h7dhc75z9mse9mry
  text: 'Picked up. Research done: verified shared swift-ci.yaml@main declares integration-gate-env and integration-xctest-glob as required:false default:"" (fetched from raw.githubusercontent.com), so removing them from ci.yml is safe. Remaining bridge/eval references confirmed in: Sources Bridge/ (6 files), Tests Bridge/ (12 files), Tests/FoundationModelsACPEvals/ (6 files + Fixtures), Package.swift, ci.yml, CONTRIBUTING.md, ACP.swift doc comment, plus a word-match ''bridge'' in RoleDispatch.swift MARK comment (''Typed coding bridge'') that trips the grep -riw acceptance criterion and needs rewording. Plan: TDD — wire-purity guard test first (RED while Bridge exists), then delete/update until green.'
  timestamp: 2026-07-21T23:18:35.141094+00:00
- actor: claude-code
  id: 01ky3kmh46b6hvmyc8pq8vx5tx
  text: 'Implementation landed via TDD. RED: added wireTargetImportsNoModelFramework guard to PackageSmokeTests.swift (walks Sources/FoundationModelsACP via #filePath, regex \bimport\s+FoundationModels\b, plus a swiftFilesSeen>0 anti-vacuous check) — watched it fail with 5 issues naming the 5 Bridge files importing FoundationModels. GREEN: git rm''d Sources Bridge/ (incl .gitkeep), Tests Bridge/, Tests/FoundationModelsACPEvals/ (incl Fixtures); Package.swift dropped Bridge/.gitkeep exclude + Evals target (fixturesExclude kept for FoundationModelsACPTests, comment updated to singular); ci.yml dropped integration-gate-env/integration-xctest-glob (verified optional with default \"\" in shared swift-ci.yaml@main) and rewrote the stale eval comment; CONTRIBUTING.md Tests section now wire-only; ACP.swift doc comment describes the wire-only layout; RoleDispatch.swift MARK reworded ''Typed coding bridge'' -> ''Typed coding helpers'' to satisfy the grep -riw criterion. Discovery: RoleTestSupport.swift used the Bridge-owned typealias MCPServerConfig (= McpServer, defined in deleted SessionProvider.swift) — switched it to the generated wire type McpServer directly rather than resurrecting the alias. Evidence: swift test exit=0 (123 tests/3 suites + 116 tests/14 suites, zero failures/warnings); swift build exit=0; all four acceptance greps return nothing; codegen gate: generate-acp reports ''up to date, nothing regenerated'', git diff --exit-code on Generated/ clean; ci.yml parses as YAML. Note for reviewer: the previously flagged RUN_EVALS-gated skipped test lived in the deleted Evals target and is gone with it.'
  timestamp: 2026-07-22T00:29:30.630492+00:00
- actor: claude-code
  id: 01ky3kywx0wg91q38q1015kdxn
  text: 'really-done: verification commands green (swift build exit 0, swift test exit 0, acceptance greps empty, codegen gate no drift). Adversarial double-check returned REVISE with one low-severity finding: the guard regex \bimport\s+FoundationModels\b missed submodule imports (import FoundationModels.X — Swift Regex default Unicode word boundary treats ''.'' between letters as non-breaking) and scoped imports (import struct FoundationModels.X). Fixed as suggested: regex is now \bimport\s+(?:\w+\s+)?FoundationModels(?![A-Za-z0-9_]) with an explanatory doc comment. Empirically probed via a scratchpad swift script: matches plain/@testable/submodule/scoped FoundationModels imports; does NOT match import Foundation, import FoundationModelsACP, or scoped FoundationModelsACP imports (ALL PROBES PASS). Full suite re-run after the fix: 123 tests/3 suites + 116 tests/14 suites, exit 0. All other double-check findings: none — deletions, Package.swift, ci.yml semantics (integration job gated on inputs.integration-gate-env != ''''), docs, and codegen gate all confirmed. Not re-spawning double-check: the sole finding was fixed exactly per its suggested regex and verified empirically. Task left in doing for /review; no commit made (orchestrator handles checkpoints).'
  timestamp: 2026-07-22T00:35:10.368516+00:00
- actor: claude-code
  id: 01ky3mh16zz8dr562fz1cc21mh
  text: 'Picked back up from review for the 2026-07-21 19:38 findings (serveEmpty/serveResult and callResult/callEmpty duplication in RoleDispatch.swift). Research: callers are ClientSideConnection.swift, AgentSideConnection.swift, RoleConnectionCore.swift, and DeprecatedRouter in RoleDispatch.swift itself — all through the existing four signatures, so those stay unchanged. Plan: consolidate serveResult/serveEmpty onto one private `serve` core (single decode-then-invoke path, entry points supply only the response encoding) and callResult/callEmpty onto one private `call` core returning the raw JSONValue (entry points decode or discard). notify stays separate: it uses connection.notify vs connection.request — a real transport-verb axis, not response-handling duplication. Pure refactor, no behavior change; existing suite is the gate.'
  timestamp: 2026-07-22T00:45:04.607600+00:00
- actor: claude-code
  id: 01ky3mm8jfrk6ehfwm1rzpsv5e
  text: 'Refactor landed in Sources/FoundationModelsACP/Connection/RoleDispatch.swift. serveResult/serveEmpty now delegate to a new private `serve(_:as:_:)` core — the single decode-then-invoke path; each entry point supplies only its response encoding (encode typed result vs return emptyResult). callResult/callEmpty now delegate to a new private `call(_:handler:on:_:)` core returning the raw JSONValue result; entry points decode-or-discard in one line each. All four public helper signatures unchanged, so ClientSideConnection/AgentSideConnection/RoleConnectionCore/DeprecatedRouter call sites compile unmodified. notify intentionally not folded into `call`: it uses connection.notify (no response) vs connection.request — a transport-verb axis, not the response-handling duplication the findings cite. Evidence: swift build exit 0; swift test exit 0, zero ''warning'' lines in the captured log, 123 tests/3 suites + 116 tests/14 suites passed. Both Review Findings checkboxes flipped to [x]. Adversarial double-check spawned per really-done.'
  timestamp: 2026-07-22T00:46:50.447623+00:00
- actor: claude-code
  id: 01ky3msnsxg5kxbfaddv3fp4sy
  text: 'really-done complete for the review findings: verification commands green first-hand (swift build exit 0; swift test exit 0 with zero warning lines — 123 tests/3 suites + 116 tests/14 suites passed), then adversarial double-check returned PASS with zero findings. Double-check independently confirmed: no behavior drift (decode-then-invoke order, invalidParams mapping, emptyResult semantics, and encode/wire evaluation order all identical to HEAD); DeprecatedRouter byte-identical so the warning-free deprecation construction holds; only RoleDispatch.swift changed under Sources and all 23 RoleDispatch call sites compile unmodified; duplicate scan shows no remaining serveResult/serveEmpty or callResult/callEmpty pairing intra-file — the cited duplications are gone at the root. Both findings checkboxes are [x]. Task left in doing per instructions; no commit made.'
  timestamp: 2026-07-22T00:49:47.837522+00:00
depends_on:
- 01KY370D05M3MMACAN2FVA8ECQ
- 01KY370WD1N9HSYKNG480ETHT1
position_column: doing
position_ordinal: '80'
title: Delete the superseded Bridge, its tests, and the model-driven Evals target; enforce wire purity
---
## What
Execute plan.md §9.1's Superseded note: remove every remnant of the `SessionProvider` bridge design and the model coupling it drags in, leaving the package pure wire with (near-)zero dependencies.

Delete:
- `Sources/FoundationModelsACP/Bridge/` — `FoundationModelsAgent.swift`, `SessionProvider.swift`, `ClientEnvironment.swift`, `TranscriptMapper.swift`, `TranscriptBuilder.swift`, `PromptInputMapper.swift`, and the `.gitkeep` (git history preserves them for the future composition package)
- `Tests/FoundationModelsACPTests/Bridge/` — all files
- `Tests/FoundationModelsACPEvals/` — the whole target (drives the live on-device `SystemLanguageModel` through the bridge; plan.md §10.1 replaces it with `PythonCLIEvaluation` in the composition package)

Update:
- `Package.swift`: drop the `Bridge/.gitkeep` exclude on the wire target and remove the `FoundationModelsACPEvals` test target (and the now-unneeded `fixturesExclude` use for it)
- `.github/workflows/ci.yml`: remove `integration-gate-env: RUN_EVALS` and `integration-xctest-glob` inputs and the stale eval comment. First confirm the shared `swissarmyhammer/workflows/.github/workflows/swift-ci.yaml@main` treats these inputs as optional (check that workflow's `inputs:` declarations); if they are required, pass empty/neutral values instead of removing.
- `CONTRIBUTING.md`: remove the `FoundationModelsACPEvals`/`RUN_EVALS=1` section (around line 13) describing the deleted target.
- `Sources/FoundationModelsACP/Core/ACP.swift`: fix the stale doc comment (lines ~3–5) saying the "FoundationModels bridge land[s] in sibling directories in subsequent tasks" — describe the wire-only layout instead.
- Add a wire-purity guard test (e.g. in `Tests/FoundationModelsACPTests/PackageSmokeTests.swift`): walk `Sources/FoundationModelsACP` via `#filePath` and assert no source line matches `import FoundationModels\b` (allow `import Foundation`, `Synchronization`) — the zero-model-dependency invariant becomes machine-checked.

Depends on the test-port task (end-to-end/golden tests must no longer reference the bridge, including `BridgeTestSupport.swift` helpers) and the docs task (README/GUIDE/ReadmeExampleTests must no longer show it) so the suite stays green through the deletion.

## Acceptance Criteria
- [x] `grep -r 'import FoundationModels$' Sources Tests` returns nothing (only `FoundationModelsACP` imports remain)
- [x] `grep -riw 'bridge' Sources/FoundationModelsACP --include='*.swift'` returns nothing outside `Generated/` (stale prose gone)
- [x] `grep -ri 'RUN_EVALS\|FoundationModelsACPEvals\|SystemLanguageModel' README.md docs/ CONTRIBUTING.md .github/` returns nothing
- [x] `Package.swift` declares no Evals target and no Bridge exclude; `swift build` succeeds
- [x] Full suite green: `swift test` exits 0

## Tests
- [x] New wire-purity guard test in `Tests/FoundationModelsACPTests/PackageSmokeTests.swift` fails if a model-framework import reappears in the wire target
- [x] `swift test` exits 0 after deletion
- [x] Codegen gate unaffected: `swift package --allow-writing-to-package-directory generate-acp` then `git diff --exit-code` shows no drift

## Workflow
- Use `/tdd` — add the wire-purity guard test first (it should fail while Bridge exists), then delete until it and the suite are green.

## Review Findings (2026-07-21 19:38)

- [x] `Sources/FoundationModelsACP/Connection/RoleDispatch.swift:139` — The `serveEmpty` method is a near-duplicate of `serveResult` (lines 120-128) — both perform identical parameter decoding and body invocation, differing only in response handling. This is one function with an argument: the response handler. Consolidate into a single parameterized function that handles both typed and empty responses via a callback.
- [x] `Sources/FoundationModelsACP/Connection/RoleDispatch.swift:160` — The `callResult` method contains nearly identical code to `callEmpty` (lines 183-193) — both make the same `connection.request()` call with identical arguments, differing only in how they handle the response (decode vs discard). This is one function with an argument: the response handler. Extract a shared `callGeneric` function that takes an optional response decoder, eliminating the code duplication in the wire call setup.