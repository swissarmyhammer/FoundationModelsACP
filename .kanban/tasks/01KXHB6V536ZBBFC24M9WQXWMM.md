---
comments:
- actor: wballard
  id: 01kxhhfcejqh927m3cm5sek845
  text: 'Picked up by driver loop. Plan: scaffold Swift 6 package (Package.swift, target layout Core/Generated/Transport/Connection/Bridge, Schema/, LICENSE Apache-2.0, .gitignore, placeholder `public enum ACP {}`), Swift Testing smoke test, then swift build/test.'
  timestamp: 2026-07-15T00:05:25.074762+00:00
- actor: wballard
  id: 01kxhhs10xebvajtcr0a5sttsb
  text: 'Implementation landed (TDD). RED: swift test failed with "target ''FoundationModelsACP'' is empty" before the placeholder existed. GREEN: Package.swift (swift-tools-version 6.4 — note: .macOS(.v27) requires PackageDescription 6.4, 6.0 rejects it), Sources/FoundationModelsACP/{Core,Generated,Transport,Connection,Bridge}/ with .gitkeep placeholders excluded in the manifest, Core/ACP.swift `public enum ACP {}`, Schema/.gitkeep, canonical Apache-2.0 LICENSE from apache.org, DerivedData/ added to .gitignore (.build/ and .swiftpm/ were already present). PackageSmokeTests.swift uses Swift Testing (import Testing, @Test, #expect) with a plain `import FoundationModelsACP` to exercise the public surface. swift build exit 0, swift test exit 0 (1 test passed). really-done verification green; double-check agent verdict PASS.'
  timestamp: 2026-07-15T00:10:41.053348+00:00
position_column: doing
position_ordinal: '80'
title: Scaffold the FoundationModelsACP Swift package
---
## What
Create the package skeleton per spec §1: a standalone Swift 6 package, single library target `FoundationModelsACP`, platform macOS 27, Apple Silicon, Apache-2.0.

- `Package.swift` — swift-tools-version 6.x; one library target `FoundationModelsACP`; one test target `FoundationModelsACPTests` using **Swift Testing** (not XCTest, per spec §8).
- Directory layout: `Sources/FoundationModelsACP/{Core,Generated,Transport,Connection,Bridge}/`, `Tests/FoundationModelsACPTests/`, `Schema/` (empty for now).
- `LICENSE` — Apache-2.0 (matches spec and all reference SDKs).
- Update `.gitignore` for SwiftPM (`.build/`, `.swiftpm/`, `DerivedData/`).
- A placeholder public symbol (e.g. `public enum ACP {}`) so the package compiles.

## Acceptance Criteria
- [ ] `swift build` succeeds on macOS 27 / Apple Silicon
- [ ] `swift test` runs the Swift Testing suite and passes
- [ ] `LICENSE` is Apache-2.0; target layout matches above

## Tests
- [ ] `Tests/FoundationModelsACPTests/PackageSmokeTests.swift` — a Swift Testing `@Test` that imports `FoundationModelsACP` and references the placeholder symbol
- [ ] Run `swift test` — exits 0

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.