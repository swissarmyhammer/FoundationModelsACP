# Vendored ACP Schema Artifacts

This directory holds the canonical Agent Client Protocol (ACP) schema artifacts,
vendored byte-identical from upstream.

## Vendored version

- **Source:** upstream `main`, pinned to commit
  `7a13081ae8cb2b93d02ea0c8b538c4f3a086768c` (2026-08-19). The newest tag,
  `schema-v2.0.0-alpha.2`, does not contain the promotion of elicitation to
  the stable client surface. This package needs that promotion. A pinned
  commit is immutable: you can get the same bytes again from
  `https://raw.githubusercontent.com/agentclientprotocol/agent-client-protocol/<commit>/schema/v2/<file>`.
  When upstream publishes the next `schema-v*` tag, move back to that tag.

| Vendored file | Upstream file at pinned commit | SHA-256 |
|---|---|---|
| `acp-v2.json` | `schema/v2/schema.json` | `9480f7224002f60725e2bd509725c40cd76bd391627a95d62d08d1b2e948e43c` |
| `acp-v2.meta.json` | `schema/v2/meta.json` | `ad94c01f2736416776fd53d66e3aaf89242ab72d99832664f39d6ab41e049736` |
| `acp-v2.meta.unstable.json` | `schema/v2/meta.unstable.json` | `2c274308d2a773628bf6316b7f6c535cf87d2c1ceb495d02be9ee899dce0f0bc` |

Differences from `schema-v2.0.0-alpha.2`: the pinned commit promotes
elicitation (`elicitation/create`, `elicitation/complete`, the
`ClientCapabilities.elicitation` field, and 26 `Elicitation*` /
`*PropertySchema` definitions) from unstable to stable. All other changes
are documentation strings only. `meta.unstable.json` is byte-identical to
the tagged release.

`acp-v2.json` is the JSON Schema (draft 2020-12) with all protocol types under
`$defs`. The meta manifests map method identifiers to wire method names in
`agentMethods` / `clientMethods` / `protocolMethods` routing tables;
`acp-v2.meta.unstable.json` additionally includes unstable methods, which the
generator emits into the `Unstable` namespace as names and sides only.

### One upstream file deliberately not vendored

- **`schema.unstable.json`** — upstream also publishes a full schema document
  for the unstable surface. The generator has no input slot for a second schema
  document, and this package serves the stable v2 surface only, so vendoring it
  would add 400 KB of bytes nothing reads. The unstable *manifest* is vendored
  because the routing table consumes it.

### Vendoring rule

Prefer a `schema-v*` tag. Vendor from `main` only when the newest tag does not
contain a stable feature that this package needs, and then always pin the exact
commit SHA and record it above — never a branch head, which moves.

## Bumping the ACP version

Bumping ACP = dropping in the new artifact set, then
`swift package generate-acp` — nothing else changes by hand, unless the new
revision introduces a schema construct the generator has not met before.

1. Pick the new `schema-v*` tag from
   <https://github.com/agentclientprotocol/agent-client-protocol/releases>.
2. Download its `schema.json`, `meta.json`, and `meta.unstable.json` assets
   byte-identical (e.g. `gh release download <tag> --repo
   agentclientprotocol/agent-client-protocol --pattern schema.json ...`) and
   replace `acp-v2.json`, `acp-v2.meta.json`, `acp-v2.meta.unstable.json`.
3. Verify the SHA-256 of each file matches the release asset digest
   (`gh api repos/agentclientprotocol/agent-client-protocol/releases/tags/<tag>
   --jq '.assets[] | "\(.name) \(.digest)"'`) and update the table above with
   the new tag, URL, and digests.
4. If the major version moved, update `GeneratorConfig.acpV2.manifestVersion` —
   upstream sets the manifests' `version` to the protocol's major version.
5. Run `swift package generate-acp` to regenerate the Swift surface.
6. Run `swift test`.
