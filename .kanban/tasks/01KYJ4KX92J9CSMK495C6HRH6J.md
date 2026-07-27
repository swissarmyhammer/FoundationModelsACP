---
assignees:
- claude-code
position_column: todo
position_ordinal: 8c80
title: VendoredSchemaTests sort-order check doesn't account for knownAcronyms renames
---
`declarationsAreEmittedInSortedSchemaNameOrder` in `Tests/ACPGenerateTests/VendoredSchemaTests.swift` reconstructs each emitted declaration's "original schema spelling" via a reverse map built only from `config.typeRenames` (`Dictionary(uniqueKeysWithValues: Self.set.config.typeRenames.map { ($1, $0) })`). It has no knowledge of `GeneratorConfig.knownAcronyms` / `SchemaGenerator.applyKnownAcronymCasing(to:)`, added on `^qzht036` to uniformly uppercase acronym words (e.g. `McpServer` -> `MCPServer`) in emitted type names.

For the six names affected only by `knownAcronyms` (not also in `typeRenames`) — `MCPCapabilities`, `MCPHTTPCapabilities`, `MCPServerHTTP`, `MCPServerStdio`, `MCPStdioCapabilities`, `HTTPHeader` — the reverse map misses, so `schemaNames[$0] ?? $0` falls back to the *emitted* spelling instead of the true original schema spelling when checking sort order.

Verified by hand this currently still passes for a real structural reason: `applyKnownAcronymCasing` only changes the case of letters *inside* a word, never a word's initial capital, and every first-differing character between these six names and their sorted neighbors in the vendored schema sits at a word boundary — so substituting the emitted spelling for the original doesn't change relative order today. But the test's own logic doesn't guarantee that invariant; a future acronym addition or schema change could make it pass coincidentally-sorted-but-wrong, or fail without explaining why (comparing the wrong strings).

Fix: extend the test's reverse-map construction to also invert `knownAcronyms` casing (or otherwise recover true original schema spelling for every emitted name), so the check is correct by construction rather than by accident.

Found during the adversarial `double-check` review of ^qzht036's 2026-07-27 review-findings round (non-blocking there; the change under review didn't introduce a regression, it just exposed the gap).