---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m0d1dpv0js7mkds5jdn93rcb
  text: |-
    Research is complete. Facts found:
    - The generated method table gives the handler names "createElicitation" (wire elicitation/create, request) and "elicitationComplete" (wire elicitation/complete, notification). The card text used the name "elicitationCreate". That name is not correct. The generated table is the authority, so the protocol members get the generated names.
    - CreateElicitationResponse is a typealias for JSONValue (Generated/Unresolved.generated.swift). The schema gives it an anyOf with actions accept, decline, cancel, other.
    - CreateElicitationRequest has a Payload enum with cases form(ElicitationFormMode), url(ElicitationUrlMode) and unknown. Each mode holds a Scope enum with cases session(ElicitationSessionScope) and request(ElicitationRequestScope). The scope keys sit flat at the top level of the wire object. RequestId is a typealias for JSONValue.
    - Suite state: only RoutingCoverageTests.everyClientMethodReachesExactlyItsOwnHandlerAndNoOther is red. VendoredSchemaTests already holds the new stable mappings.
    - Test conformers of Client that get the two new members: StubClient (ClientProtocolTests), RecordingClient (RoutingCoverageTests), GatedPermissionClient (PermissionRequestTests), PassiveClient (SessionLifecycleTests), PassiveClient and PermissionAnsweringClient (PromptLifecycleTests), PermittingClient and ReactiveClient (FactoryClosureTests), GoldenSessionClient (GoldenSessionEndToEndTests), MinimalClient (SessionUpdateStreamTests), HandshakeClient (TransportProcessSupport).
    - Stale text to correct: Client.swift header doc, AgentSideConnection.swift header doc, ClientProtocolTests comments ("two entry points"), AgentProtocolTests comment near line 202, PermissionRequestTests comment near line 97, plan.md near lines 194-204, 323-326 and 430-435 (plan.md line 194 also claims ClientCapabilities carries only _meta; that claim is now false).
    Plan: write ElicitationLifecycleTests first (red), then add the two protocol members, the dispatch cases and the outbound calls, then update the conformers, the stale comments and plan.md, then run the full suite.
  timestamp: 2026-08-19T12:55:00.704892+00:00
- actor: claude-code
  id: 01m0d1thac1k82escktkhtxefj
  text: |-
    Implementation is complete. What happened, in order:
    1. TDD red: ElicitationLifecycleTests was written first. The build failed with "AgentSideConnection has no member createElicitation" and "no member elicitationComplete". That is the correct failure for a missing feature. The suite was also red at RoutingCoverageTests.everyClientMethodReachesExactlyItsOwnHandlerAndNoOther before this work.
    2. TDD green: the Client protocol got the two members createElicitation (request) and elicitationComplete (notification), with a rewritten header doc (four stable entry points; ClientCapabilities gates elicitation). ClientSideConnection got the two dispatch cases with the handler strings "createElicitation" and "elicitationComplete" — the exact generated names. AgentSideConnection got the outbound createElicitation via core.call (no timeout; it waits on a human) and elicitationComplete via core.notify, plus header and requestTimeout doc updates.
    3. Every test conformer of Client got the two members: StubClient, RecordingClient, GatedPermissionClient, two PassiveClient types, PermissionAnsweringClient, PermittingClient, ReactiveClient, GoldenSessionClient, MinimalClient, HandshakeClient.
    4. RoutingCoverageTests: the client driver got cases for createElicitation and elicitationComplete; the expected-calls rule now keys on entry.kind == .notification; the shared permissionProbe fixture removed a copied request literal.
    5. Stale text was corrected: ClientProtocolTests (four entry points, new capability test in the stub check), AgentProtocolTests comment, PermissionRequestTests suite doc and comment, plan.md near lines 190-205, 322-326 and the M8 milestone note (elicitation is now stable and implemented). A new test pins that ClientCapabilities decodes an omitted and a null elicitation field as no support.
    6. Verification: swift test — 253 tests in 24 suites and 101 tests in 13 suites, all passed, zero failures. swift build --build-tests shows zero warnings. swift package --allow-writing-to-package-directory generate-acp reports "up to date, nothing regenerated" — the generator runs clean and is idempotent.
    Open item: the first acceptance box stays open because the Generated/ diff is not committed. The orchestrator said: do not commit in this step. The commit step closes that box.
    Discovery for the next agent: CreateElicitationResponse is a typealias for JSONValue (a deferred anyOf union), so client conformers return raw JSON action objects such as {"action":"accept","content":{...}}.
  timestamp: 2026-08-19T13:02:01.036228+00:00
- actor: claude-code
  id: 01m0d1tr16cjt9zs78bra3rhbt
  text: |-
    ### implement — changed
    - evidence: 13 files — Sources/FoundationModelsACP/Connection/Client.swift, ClientSideConnection.swift, AgentSideConnection.swift; Tests/FoundationModelsACPTests/ElicitationLifecycleTests.swift (new), RoutingCoverageTests.swift, ClientProtocolTests.swift, AgentProtocolTests.swift, PermissionRequestTests.swift, SessionLifecycleTests.swift, PromptLifecycleTests.swift, FactoryClosureTests.swift, GoldenSessionEndToEndTests.swift, SessionUpdateStreamTests.swift, TransportProcessSupport.swift; plan.md. swift test: 253 tests in 24 suites passed and 101 tests in 13 suites passed, zero failures, zero warnings.
    - next: /review; the commit step commits the working tree, Generated/ diff included.
  timestamp: 2026-08-19T13:02:07.910202+00:00
depends_on:
- 01M0CZFHF71TFK46JGFWW8HHFM
position_column: doing
position_ordinal: '8180'
title: Regenerate from pinned schema and wire stable elicitation client surface
---
# Regenerate from pinned schema and wire stable elicitation client surface

## What

After the generator supports the flattened scope union (task ^ww8hhfm), regenerate from the vendored `Schema/acp-v2.json` (pinned upstream commit `7a13081`) and catch the hand-written stable surface up to it. The stable `clientMethods` now include `elicitation/create` (request) and `elicitation/complete` (notification), and `ClientCapabilities` gains the generated `elicitation` field.

Modify:

- `Sources/FoundationModelsACP/Connection/Client.swift` — add to the `Client` protocol: `func elicitationCreate(_ params: CreateElicitationRequest) async throws -> CreateElicitationResponse` and `func elicitationComplete(_ notification: CompleteElicitationNotification) async`. Rewrite the header doc comment: it currently says elicitation is unstable-only and that stable v2 has no client capability fields. Both statements are now false.
- `Sources/FoundationModelsACP/Connection/ClientSideConnection.swift` — dispatch incoming handler `"elicitationCreate"` through `RoleDispatch.serveResult` (like `"requestPermission"`, line 97) and handler `"elicitationComplete"` in the notification switch (like `"sessionUpdate"`, line 125).
- `Sources/FoundationModelsACP/Connection/AgentSideConnection.swift` — add outbound `elicitationCreate` via `core.call` (like `requestPermission`, line 142; it waits on a human, so no timeout) and `elicitationComplete` via `core.notify` (like `sessionUpdate`, line 127). Update the header doc comment list of outbound calls.
- Tests that pin the old deferral: `Tests/ACPGenerateTests/VendoredSchemaTests.swift` (expected mapping list near line 413), `Tests/FoundationModelsACPTests/ClientProtocolTests.swift` (near line 44), `Tests/FoundationModelsACPTests/AgentProtocolTests.swift` (near line 202), `Tests/FoundationModelsACPTests/PermissionRequestTests.swift` (comment near line 97), `Tests/FoundationModelsACPTests/RoutingCoverageTests.swift` (handler enumeration). Update `plan.md` (elicitation out-of-scope notes near lines 197, 323, 431).

All test conformers of `Client` gain the two new members.

Note: the generated method table names the request handler `createElicitation`, not `elicitationCreate`. The generated table is the authority, so the protocol member and the dispatch case use `createElicitation`.

## Acceptance Criteria

- [ ] `swift package --allow-writing-to-package-directory generate-acp` runs clean and the diff of `Sources/FoundationModelsACP/Generated/` is committed.
- [x] `ClientCapabilities` has the `elicitation: ElicitationCapabilities?` field, and omitted and `null` both decode as no support.
- [x] `Client` protocol exposes `createElicitation` and `elicitationComplete`; the generated stable routing table and the dispatch switches agree on the handler names.
- [x] An agent-side `createElicitation` call round-trips to the client conformer and back with the correct wire method `elicitation/create`.
- [x] `elicitation/complete` arrives at the client conformer as a notification (no response on the wire).
- [x] `swift test` passes with zero failures.

## Tests

- [x] New `Tests/FoundationModelsACPTests/ElicitationLifecycleTests.swift`: over `InMemoryTransport.pair()`, an agent calls `createElicitation` with a form mode (session scope) and a url mode (request scope); assert the client receives them, the response round-trips, and the wire JSON flattens scope keys at the top level. Add a `elicitation/complete` notification delivery case.
- [x] Update `Tests/ACPGenerateTests/VendoredSchemaTests.swift` expected mappings: `elicitation/create` and `elicitation/complete` appear as stable client methods.
- [x] Run `swift test` — full suite green.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.

#elicitation