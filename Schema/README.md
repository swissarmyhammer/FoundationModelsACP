# Vendored ACP Schema Artifacts

This directory holds the canonical Agent Client Protocol (ACP) schema artifacts,
vendored byte-identical from upstream.

## Vendored version

- **Source:** the upstream tag `schema-v2.0.0-alpha.3`, released 2026-08-20. A
  tag does not move. Thus you can get the same bytes again from the release
  assets at
  `https://github.com/agentclientprotocol/agent-client-protocol/releases/tag/schema-v2.0.0-alpha.3`.

| Vendored file | Upstream release asset | SHA-256 |
|---|---|---|
| `acp-v2.json` | `schema.json` | `36e8270fb12d4d067005cc02f729f5433930e6834ab4a72260838ee096d62378` |
| `acp-v2.meta.json` | `meta.json` | `ad94c01f2736416776fd53d66e3aaf89242ab72d99832664f39d6ab41e049736` |
| `acp-v2.meta.unstable.json` | `meta.unstable.json` | `2c274308d2a773628bf6316b7f6c535cf87d2c1ceb495d02be9ee899dce0f0bc` |

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
