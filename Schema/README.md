# Vendored ACP Schema Artifacts

This directory holds the canonical Agent Client Protocol (ACP) schema artifacts,
vendored byte-identical from upstream.

## Vendored version

- **Tag:** `schema-v2.0.0-alpha.2` (a pre-release; ACP v2 is draft)
- **Release:** <https://github.com/agentclientprotocol/agent-client-protocol/releases/tag/schema-v2.0.0-alpha.2>

| Vendored file | Upstream release asset | SHA-256 |
|---|---|---|
| `acp-v2.json` | `schema.json` | `bfc3e499aadf5f8b88d1b11dfd3b4ea446f1fa8751f1c3c9fcdbc372265348cd` |
| `acp-v2.meta.json` | `meta.json` | `2e642a11c41d99c0a19b1c8c596ea0e02dbeaa14a303bee345c5e1465b072d8c` |
| `acp-v2.meta.unstable.json` | `meta.unstable.json` | `2c274308d2a773628bf6316b7f6c535cf87d2c1ceb495d02be9ee899dce0f0bc` |

`acp-v2.json` is the JSON Schema (draft 2020-12) with all protocol types under
`$defs`. The meta manifests map method identifiers to wire method names in
`agentMethods` / `clientMethods` / `protocolMethods` routing tables;
`acp-v2.meta.unstable.json` additionally includes unstable methods, which the
generator emits into the `Unstable` namespace as names and sides only.

### Two upstream files deliberately not vendored

- **`schema.unstable.json`** — the release also publishes a full schema document
  for the unstable surface (`e1ef10a309878485fc3be76e64334ba638c6da4517ed585987368f7f8012bc03`).
  The generator has no input slot for a second schema document, and this package
  serves the stable v2 surface only, so vendoring it would add 400 KB of bytes
  nothing reads. The unstable *manifest* is vendored because the routing table
  consumes it.
- Anything from upstream `main`. The docs site renders `schema/v2/schema.json`
  on `main`, which is **already ahead of `schema-v2.0.0-alpha.2`**: it promotes
  elicitation (`elicitation/create`, `elicitation/complete`, and roughly twenty
  `Elicitation*` / `*PropertySchema` definitions) from unstable to stable. We
  track tagged releases, which carry a digest and can be re-fetched byte for
  byte; `main` is a moving target. Expect elicitation to arrive on the next
  re-vendor.

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
