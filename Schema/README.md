# Vendored ACP Schema Artifacts

This directory holds the canonical Agent Client Protocol (ACP) schema artifacts,
vendored byte-identical from upstream.

## Vendored version

- **Source:** the upstream tag `schema-v2.0.0-alpha.7`, released 2026-09-30. A
  tag does not move. Thus you can get the same bytes again from the release
  assets at
  `https://github.com/agentclientprotocol/agent-client-protocol/releases/tag/schema-v2.0.0-alpha.7`.

| Vendored file | Upstream release asset | SHA-256 |
|---|---|---|
| `acp-v2.json` | `schema.json` | `98b51a64b02e757e013948d88b73d990b4ad11b507d8a3dfd6fcd7f9f3b08dee` |
| `acp-v2.meta.json` | `meta.json` | `ad94c01f2736416776fd53d66e3aaf89242ab72d99832664f39d6ab41e049736` |
| `acp-v2.meta.unstable.json` | `meta.unstable.json` | `d9c1d9ab65740e988e4c78abd54bf1b4d60ff3ffd3db1d366c601cd9cc3462a2` |
| `acp-v2.unstable.json` | `schema.unstable.json` | `75b2aa359dd26cd9d0468674be96482b14a2d181bc8e3ea8c91a8e598f63e3b5` |

`acp-v2.json` is the JSON Schema (draft 2020-12) with all protocol types under
`$defs`. The meta manifests map method identifiers to wire method names in
`agentMethods` / `clientMethods` / `protocolMethods` routing tables;
`acp-v2.meta.unstable.json` additionally includes unstable methods, which the
generator emits into the `Unstable` namespace as names and sides only.

### The unstable schema document

`acp-v2.unstable.json` is the full schema document of the unstable surface.
The generator reads it as a second schema set (`SchemaSet.acpV2Unstable`), but
it does not emit the whole document. It emits only the types that these
unstable session updates reach:

- `compaction_update` (`CompactionUpdate`)
- `compaction_summary_chunk` (`CompactionSummaryChunk`)
- `notice` (`Notice`)

The result is six types in the `Unstable` namespace: `CompactionId`,
`CompactionStatus`, `CompactionUpdate`, `CompactionSummaryChunk`, `Notice` and
`NoticeSeverity`. A reference to `ContentBlock` resolves to the stable type,
because the stable set emits it already. A test makes sure that the two
documents give `ContentBlock` and the types it reaches the same shape.

The stable `SessionUpdate` enum gets no new case. These updates decode as
`SessionUpdate.unknown(type, payload)`, and the hand-written
`Unstable.SessionUpdate` reads them from that case. To send one, an agent
makes the stable value with `SessionUpdate(_:)`.

To emit more of the unstable surface, add its root definitions to
`GeneratorConfig.acpV2Unstable.rootDefinitions`.

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
2. Download its `schema.json`, `meta.json`, `meta.unstable.json`, and
   `schema.unstable.json` assets byte-identical (e.g. `gh release download
   <tag> --repo agentclientprotocol/agent-client-protocol --pattern schema.json
   ...`) and replace `acp-v2.json`, `acp-v2.meta.json`,
   `acp-v2.meta.unstable.json`, `acp-v2.unstable.json`.
3. Verify the SHA-256 of each file matches the release asset digest
   (`gh api repos/agentclientprotocol/agent-client-protocol/releases/tags/<tag>
   --jq '.assets[] | "\(.name) \(.digest)"'`) and update the table above with
   the new tag, URL, and digests. Also update the `schema.unstable.json` digest
   in `UnstableVendoredSchemaTests.releaseAssetDigest`, which pins the vendored
   bytes.
4. If the major version moved, update `GeneratorConfig.acpV2.manifestVersion` —
   upstream sets the manifests' `version` to the protocol's major version.
5. Run `swift package generate-acp` to regenerate the Swift surface.
6. Run `swift test`.
