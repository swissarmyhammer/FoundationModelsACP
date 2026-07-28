---
assignees:
- claude-code
position_column: todo
position_ordinal: '8e80'
title: 'Emitter.swift: extract repeated non-indentation string-literal fragments into named constants'
---
A review pass (2026-07-28 00:58) on ^1pfngj1's indentation sweep surfaced a separate, unrelated duplication category in Sources/ACPGenerateCore/Emitter.swift: several full-line string literals repeat verbatim across functions (not indentation, actual content), e.g. `"public init(from decoder: any Decoder) throws {"` (decoderInit, scalarEnumDeclaration, taggedUnionDeclaration, discriminatedUnionDeclaration), `"public func encode(to encoder: any Encoder) throws {"`, `"var container = encoder.container(keyedBy: CodingKeys.self)"`, `"case unknown(String, JSONValue)"`, and `"try payload.encode(to: encoder)"`.

Out of scope for ^1pfngj1 (which is specifically about hardcoded indentation-prefix literals, now fully swept — 236 instances closed, verified by grep and byte-for-byte codegen diff gate). This is a distinct dedup opportunity: extract these repeated content fragments into named `private static let` constants the same way `indentUnit`/`indent2`/`indent3`/`indent4` centralize indentation width, so the literal text lives in one place per fragment.

Verify no other content-fragment duplicates exist beyond the 5 the review pass reported before declaring this done — that review's own report should be treated as a lead, not an exhaustive list.