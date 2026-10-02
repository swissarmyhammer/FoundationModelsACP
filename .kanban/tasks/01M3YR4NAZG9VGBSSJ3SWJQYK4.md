---
assignees:
- claude-code
depends_on:
- 01M3YQYR2Y867FQBAZJG2MKX79
position_column: todo
position_ordinal: '8480'
title: Expose outgoing request IDs and their completion on ClientSideConnection
---
## Problem

A request-scoped elicitation (`ElicitationRequestScope.requestId`, `Sources/FoundationModelsACP/Generated/Models3.generated.swift:616`) names the JSON-RPC ID of a request that the CLIENT sent, for example `auth/login`. The schema does not limit which methods can cause one ("e.g., during auth/configuration phases before any session is started"). The connection creates the request IDs privately (`Connection.swift:289`), so a client cannot know which of its requests an elicitation belongs to, or when that request ends.

FoundationModelsACPClient's `ConnectionModel` needs this to show request-scoped elicitations and to remove them when their request completes or fails.

## What

Add a public way on `ClientSideConnection` to observe outgoing requests. Proposed: a stream of events `.started(id: RequestId, method: String)` and `.finished(id: RequestId)` (finished covers success, error, cancel and connection close), plus a synchronous lookup of the method name of an in-flight request ID. Choose the final shape and document it.

## Acceptance criteria

- Tests: each typed client call produces `started` with the correct method and ID, then `finished`, for success, error, cancel and connection close.
- Test: an elicitation request with a request scope can be matched to the in-flight `auth/login`.
- DocC. `swift test` passes with no warnings.