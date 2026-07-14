---
position_column: todo
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