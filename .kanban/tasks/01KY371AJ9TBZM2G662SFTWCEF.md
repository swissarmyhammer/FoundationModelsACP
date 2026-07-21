---
assignees:
- claude-code
depends_on:
- 01KY370D05M3MMACAN2FVA8ECQ
- 01KY370WD1N9HSYKNG480ETHT1
position_column: todo
position_ordinal: '8280'
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
- [ ] `grep -r 'import FoundationModels$' Sources Tests` returns nothing (only `FoundationModelsACP` imports remain)
- [ ] `grep -riw 'bridge' Sources/FoundationModelsACP --include='*.swift'` returns nothing outside `Generated/` (stale prose gone)
- [ ] `grep -ri 'RUN_EVALS\|FoundationModelsACPEvals\|SystemLanguageModel' README.md docs/ CONTRIBUTING.md .github/` returns nothing
- [ ] `Package.swift` declares no Evals target and no Bridge exclude; `swift build` succeeds
- [ ] Full suite green: `swift test` exits 0

## Tests
- [ ] New wire-purity guard test in `Tests/FoundationModelsACPTests/PackageSmokeTests.swift` fails if a model-framework import reappears in the wire target
- [ ] `swift test` exits 0 after deletion
- [ ] Codegen gate unaffected: `swift package --allow-writing-to-package-directory generate-acp` then `git diff --exit-code` shows no drift

## Workflow
- Use `/tdd` — add the wire-purity guard test first (it should fail while Bridge exists), then delete until it and the suite are green.