# Vendored ACP Schema Artifacts

This directory contains the canonical Agent Client Protocol (ACP) schema
artifacts, vendored byte-identical from the upstream GitHub release.

## Pinned release

- **Tag:** `schema-v1.19.0`
- **Release:** <https://github.com/agentclientprotocol/agent-client-protocol/releases/tag/schema-v1.19.0>

| Vendored file | Upstream release asset | SHA-256 |
|---|---|---|
| `acp-v1.json` | `schema.json` | `92c1dfcda10dd47e99127500a3763da2b471f9ac61e12b9bf0430c32cf953796` |
| `acp-v1.meta.json` | `meta.json` | `e0bf36f8123b2544b499174197fdc371ec49a1b4572a35114513d56492741599` |
| `acp-v1.meta.unstable.json` | `meta.unstable.json` | `3026898232badf413624010d1343e20bef853e6705c62d6b56387cf9de6b0543` |

`acp-v1.json` is the JSON Schema (draft 2020-12) with all protocol types under
`$defs`. The meta manifests map method identifiers to wire method names in
`agentMethods` / `clientMethods` / `protocolMethods` routing tables;
`acp-v1.meta.unstable.json` additionally includes unstable methods.

## Bumping the ACP version

Bumping ACP = dropping in the new artifact pair, then
`swift package generate-acp` — nothing else changes by hand.

1. Pick the new `schema-v*` tag from
   <https://github.com/agentclientprotocol/agent-client-protocol/releases>.
2. Download its `schema.json`, `meta.json`, and `meta.unstable.json` assets
   byte-identical (e.g. `gh release download <tag> --repo
   agentclientprotocol/agent-client-protocol --pattern schema.json ...`) and
   replace `acp-v1.json`, `acp-v1.meta.json`, `acp-v1.meta.unstable.json`.
3. Verify the SHA-256 of each file matches the release asset digest
   (`gh api repos/agentclientprotocol/agent-client-protocol/releases/tags/<tag>
   --jq '.assets[] | "\(.name) \(.digest)"'`) and update the table above with
   the new tag, URL, and digests.
4. Run `swift package generate-acp` to regenerate the Swift surface.
5. Run `swift test`.
