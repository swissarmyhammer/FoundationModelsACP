---
comments:
- actor: wballard
  id: 01kxjvqbwv4ev5p4qccccmg1v9
  text: |-
    Picked up; research complete. Confirming the ^zwttegj discovery and adapting the card:

    DATA SOURCES (all vendored, nothing hand-wired)
    - Schema/acp-v1.meta.json + acp-v1.meta.unstable.json: version:1 + three routing groups agentMethods/clientMethods/protocolMethods, each a map of snake_case routing key → wire method name. Stable: 13 agent + 9 client + 1 protocol ($/cancel_request). Unstable manifest is a superset; mcp/message appears in BOTH agentMethods and clientMethods, so entries must be keyed (side, wire), not wire alone.
    - Schema/acp-v1.json: 43 defs carry x-side/x-method — every stable method has either a Request+Response def pair (kind=request) or a single *Notification def (kind=notification: SessionNotification=session/update client, CancelNotification=session/cancel agent, CancelRequestNotification=$/cancel_request protocol). NO deprecated keyword anywhere in schema or manifests — the session/set_mode marker must be config-carried (GeneratorConfig gains deprecatedMethods, validated against the built table so a stale entry fails generation — same pattern as typeRenames/wireInvariantFields).

    DESIGN
    - Builder cross-validates manifest ↔ schema x-annotations both directions: manifest method with no schema defs → GeneratorError; schema (side,wire) not routed by manifest → GeneratorError; Request-without-Response etc. → GeneratorError. This double-entry check is the structural anti-miswiring guarantee (TS setSessionModel bug class).
    - Handler names, fully derived: requests = lowerFirst(RequestDefName minus "Request") — gives the card's newSession/readTextFile/createTerminal; notifications + all unstable entries = camelCase of the manifest routing key (session_update → sessionUpdate, document_did_open → documentDidOpen) since unstable methods have no defs in the vendored stable schema (schema.unstable.json was not vendored, per ^zwttegj).
    - Runtime support hand-written in Core/MethodInfo.swift: MethodSide (agent/client/protocolLevel="protocol" — backticked `protocol` case avoided), MethodKind (request/notification), MethodInfo (wireMethod, handlerName, side, kind, paramsTypeName, resultTypeName?, deprecationMessage?), UnstableMethodInfo (wireMethod, handlerName, side — manifests carry no kind/types for unstable-only methods, so the unstable entry type honestly omits them).
    - New emitted file MethodTable.generated.swift (keeps out of the 262144-byte review cap): `public enum ACPMethodTable { static let methods: [MethodInfo] }` sorted (side, wire), plus `public enum Unstable { public enum MethodTable { static let methods: [UnstableMethodInfo] } }` holding ONLY the unstable-minus-stable set per side. Deprecation emitted as data (deprecationMessage), not @available, to keep the zero-warnings build.
    - generate() gains optional metaJSON/unstableMetaJSON params (nil → no table file, existing tests untouched); acp-generate CLI derives Schema/acp-v1.meta.json + .meta.unstable.json from the schema path convention.

    Proceeding TDD: RoutingTableTests + UnstableNamespaceTests RED first.
  timestamp: 2026-07-15T12:23:46.843842+00:00
- actor: wballard
  id: 01kxjwp59fzn22cp7x0wefg32a
  text: |-
    Implementation landed (TDD RED→GREEN: 21 new tests watched fail with 20 issues — missing MethodTable file + no-throw validation paths — then implemented to green). Summary for the plugin (^2em38ty) and role-protocols (^k0n872z) threads:

    EMITTED SHAPE (Sources/FoundationModelsACP/Generated/MethodTable.generated.swift, ~12 KB, well under the review cap)
    - `public enum ACPMethodTable { public static let methods: [MethodInfo] }` — all 23 stable v1.19 methods (13 agent / 9 client / 1 protocol), ordered agent→client→protocol then by wire name. MethodInfo carries wireMethod, handlerName, side, kind, paramsTypeName, resultTypeName? (nil for the 3 notifications), deprecationMessage?. session/set_mode carries "Deprecated upstream in favor of session/set_config_option." as DATA (no @available — keeps the zero-warnings build; role-protocols task can emit @available from the same generator model if desired).
    - `public enum Unstable { public enum MethodTable { public static let methods: [UnstableMethodInfo] } }` — exactly the unstable-minus-stable set per side (15 agent + 5 client, incl. mcp/message on BOTH sides), name+side only, documented unsettled/capability-gated. Future stages (v2 vendoring per plan §risks) can `extension Unstable`.
    - Support types hand-written in Sources/FoundationModelsACP/Core/MethodInfo.swift: MethodSide (agent/client/protocolLevel="protocol" — avoids a backticked `protocol` case), MethodKind, MethodInfo, UnstableMethodInfo.

    DERIVATION (Sources/ACPGenerateCore/MethodTable.swift)
    - Manifest parse validates version==1, exactly the three known groups, string values, no duplicate wires per group.
    - Cross-validation BOTH directions vs the schema's x-side/x-method annotations (the anti-TS-miswiring double-entry check): manifest route without schema defs → error; schema-annotated (side,wire) unrouted by manifest → error; defs must form exactly a Request/Response pair (kind=request) or single Notification (kind=notification) → else error.
    - Handler names fully derived: requests = lowerFirst(def base) → newSession/readTextFile/createTerminal (card-mandated); notifications + unstable = camelized manifest key → sessionUpdate/sessionCancel/cancelRequest, sessionFork/documentDidOpen. All validated via the existing swiftCaseName identifier/keyword gate; per-side handler uniqueness enforced.
    - Deprecations are GeneratorConfig-carried (deprecatedMethods: wire → message) because NEITHER schema nor manifests carry a deprecated marker anywhere (grepped); stale config entries fail generation, same pattern as typeRenames/wireInvariantFields.
    - generate() gained optional metaJSON/unstableMetaJSON (nil → old 4-file behavior, existing tests untouched); unstable-without-stable → error. acp-generate CLI derives <base>.meta.json/.meta.unstable.json from the schema path convention and now requires a .json schema path.
    - Access relaxations: SchemaGenerator.emittedName/swiftCaseName and Emitter.stringLiteral went private→internal for the extension file; every schema-derived string still routes through stringLiteral.

    TESTS: RoutingTableTests.swift (emission samples across both sides/kinds incl. session/prompt + session/update, data-driven every-manifest-method-exactly-once, deprecation marker, 8 fail-loud validation cases, checked-in-artifact-matches-fresh-generation sync test, compiled-table runtime acceptance) + UnstableNamespaceTests.swift (namespace-only emission both directions data-driven from the manifest diff, both-sides mcp/message, unsettled docs). Suite now 167/167 green (70 + 97), zero warnings, regeneration byte-idempotent. Double-check verdict: PASS (independently re-derived the 23-method table and 20-entry unstable diff from the vendored files).
  timestamp: 2026-07-15T12:40:35.887077+00:00
depends_on:
- 01KXHB88Q1GSGHMPXHNSMKM2XF
position_column: doing
position_ordinal: '80'
title: 'Codegen: method-routing table from meta.json + Unstable namespace'
---
## What
Extend `acp-generate` to derive method routing from the vendored manifests, never hand-wired (spec §6 — this structurally avoids the TS-SDK bug where `setSessionModel` was wired to `session/set_mode`):

- Parse `Schema/acp-v1.meta.json`'s per-method `x-side` / `x-method` entries and emit a routing table: wire method name (`session/new`, `fs/read_text_file`, `terminal/create`, …) ↔ Swift handler name (`newSession`, `readTextFile`, `createTerminal`) ↔ side (agent/client) ↔ kind (request/notification) ↔ param/result types.
- Emit the **stable** set including `session/set_config_option`, `logout`, `session/list`, `session/resume`, `session/delete`, `session/close`, request cancellation, boolean session config options (spec §10 stable list at v1.19). Mark `session/set_mode` deprecated in the emitted table.
- Parse `Schema/acp-v1.meta.unstable.json` and emit those methods (`elicitation/*`, `providers/*`, `session/fork`, `nes/*`, `mcp/*`, `document/did*`) into a clearly separated `Unstable` namespace, capability-gated and documented as unsettled.

NOTE (adapted per ^zwttegj discovery): the vendored manifests use `agentMethods`/`clientMethods`/`protocolMethods` routing tables, not per-method `x-side`/`x-method`; the schema's `x-side`/`x-method` def annotations supply kind and param/result types, and the two sources are cross-validated in both directions.

## Acceptance Criteria
- [x] Routing table is generated purely from meta.json — no hand-typed method-name strings in dispatch code
- [x] Every stable v1.19 method appears with correct side/kind; `session/set_mode` carries a deprecation marker
- [x] Unstable methods live only under the `Unstable` namespace

## Tests
- [x] `Tests/ACPGenerateTests/RoutingTableTests.swift` — assert generated table entries for a sample of methods across both sides and both kinds (request vs notification), including `session/prompt` (agent, request) and `session/update` (client, notification)
- [x] `Tests/ACPGenerateTests/UnstableNamespaceTests.swift` — assert unstable methods are emitted only in the Unstable namespace
- [x] Run `swift test` — exits 0

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.