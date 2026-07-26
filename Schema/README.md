# Vendored ACP Schema Artifacts

This directory holds the canonical Agent Client Protocol (ACP) schema artifacts,
vendored byte-identical from upstream.

## Status: not yet vendored

**This directory is empty pending milestone M0.** The v1 artifacts
(`acp-v1.json` and its meta manifests, pinned to `schema-v1.19.0`) were removed
when the package was reset to target v2 only; they remain in git history. The v2
artifacts have not been vendored yet.

Until M0 lands, the codegen pipeline has no input: `swift package generate-acp`
and the CI codegen diff gate cannot succeed.

## Vendoring v2 (milestone M0)

1. Fetch the v2 schema and its routing manifest(s) from
   <https://agentclientprotocol.com/protocol/v2/schema>, or the matching
   `schema-v2*` release at
   <https://github.com/agentclientprotocol/agent-client-protocol/releases>.
2. Save them as `acp-v2.json` and `acp-v2.meta.json` (plus
   `acp-v2.meta.unstable.json` **only if v2 publishes one** — v2 may not have an
   unstable namespace at all; confirm before assuming it does).
3. Record each file's SHA-256 and its upstream source in the table below.
4. Re-point `SchemaSet.acpV1` and `GeneratorConfig.acpV1` in
   `Sources/ACPGenerateCore/` at the v2 artifacts. Both still carry v1 names and
   v1-specific field mappings (`ReadTextFileRequest.path`,
   `CreateTerminalRequest.cwd`, `LoadSessionRequest.*`, …) — types v2 deletes.
5. Run `swift package generate-acp`, then `swift test`.

| Vendored file | Upstream source | SHA-256 |
|---|---|---|
| _(none yet)_ | | |

The schema is JSON Schema (draft 2020-12) with all protocol types under `$defs`.
The meta manifest maps method identifiers to wire method names in
`agentMethods` / `clientMethods` / `protocolMethods` routing tables.

## Bumping the ACP version thereafter

Bumping ACP = dropping in the new artifact set, then `swift package generate-acp`
— nothing else changes by hand. Verify each file's SHA-256 against the upstream
digest, update the table above, regenerate, and run `swift test`.
