# Vendored ACP Schema Artifacts

This directory holds the canonical Agent Client Protocol (ACP) schema artifacts,
vendored byte-identical from upstream.

## Vendored version

- **Source:** the upstream tag `schema-v2.0.0-alpha.13`, released 2026-11-02. A
  tag does not move. Thus you can get the same bytes again from the release
  assets at
  `https://github.com/agentclientprotocol/agent-client-protocol/releases/tag/schema-v2.0.0-alpha.13`.

| Vendored file | Upstream release asset | SHA-256 |
|---|---|---|
| `acp-v2.json` | `schema.json` | `b6c91055df549d6f1db1d76d692d0561dad433e03d8ed114ea9b5baed9da72c5` |
| `acp-v2.meta.json` | `meta.json` | `5eac58a28615d399af1db8e3d636767a7e404f2df38c9668a1ba00b1989e0714` |
| `acp-v2.meta.unstable.json` | `meta.unstable.json` | `fb2d6096afa466713cdabe3329bebec582e0305012e008006cdb1aedb718d683` |
| `acp-v2.unstable.json` | `schema.unstable.json` | `49e10f8c1935854363ed5b176cc6560d856642ba5020c97d264d34de4b6f1b31` |

`acp-v2.json` is the JSON Schema (draft 2020-12) with all protocol types under
`$defs`. The meta manifests map method identifiers to wire method names in
`agentMethods` / `clientMethods` / `protocolMethods` routing tables;
`acp-v2.meta.unstable.json` additionally includes unstable methods, which the
generator emits into the `Unstable` namespace as names and sides only.

### The unstable schema document

`acp-v2.unstable.json` is the full schema document of the unstable surface.
No schema set reads it now. Until `schema-v2.0.0-alpha.7`, the generator
emitted the `compaction_update`, `compaction_summary_chunk` and `notice`
session updates from it into the `Unstable` namespace. In
`schema-v2.0.0-alpha.8` upstream made these three updates stable, so the
primary set emits them: `SessionUpdate` has the cases `notice`,
`compactionUpdate` and `compactionSummaryChunk`, and their types
(`CompactionId`, `CompactionStatus`, `CompactionUpdate`,
`CompactionSummaryChunk`, `Notice`, `NoticeSeverity`) are top-level types.

The primary set also reads a named part of this document:
`GeneratorConfig.unstableOverlay` lists the definitions and the `SessionUpdate`
and `BackgroundWork` union variants that the stable document lacks. Today they
are the subagent session types (`SubagentUpdate`, `SessionMessage`,
`SessionMessageChunk`, `SubagentSessionCapabilities`,
`SessionCancelCapabilities`, `BackgroundSubagent`), and the variants
`subagent_update`, `session_message`, `session_message_chunk` and `subagent`.
Nothing else of the unstable document is emitted. They are unstable: they may
change or go in a later release.

The document stays vendored beside the other artifacts of the same release.
`UnstableVendoredSchemaTests` pins its digest. To emit a part of the unstable
surface again, add a `SchemaSet` with an output namespace and the root
definitions of that part (`GeneratorConfig.rootDefinitions`).

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
