---
depends_on:
- 01KXHBADH1XF34Q5C911R8GYD6
position_column: todo
position_ordinal: '8980'
title: InMemoryTransport and ReplayTransport test infrastructure
---
## What
Ship the two test transports (spec §8) against the transport abstraction from the ndJSON codec task, in `Sources/FoundationModelsACP/Transport/`:

- `InMemoryTransport` — a pair of in-process `AsyncStream`s (as `rebornix/acp-swift-sdk` does) so a `Client` and `Agent` can be wired back-to-back in one test with no pipes or subprocess. `InMemoryTransport.pair()` returns two connected ends.
- `ReplayTransport` — feeds a recorded client→agent ndJSON script line by line and captures everything the agent emits, so a test can assert the emitted `session/update` sequence against a golden fixture. Recording format = the raw ndJSON byte stream (spec §8: tee the stream while it runs and you have a replayable script).

These live in the main target (they're useful to consumers' tests too), with no test-only dependencies.

## Acceptance Criteria
- [ ] Two codec instances over `InMemoryTransport.pair()` exchange messages in both directions concurrently
- [ ] `ReplayTransport` replays a fixture script and exposes captured output for assertion, deterministically across runs

## Tests
- [ ] `Tests/FoundationModelsACPTests/InMemoryTransportTests.swift` — bidirectional concurrent exchange, stream finish on close
- [ ] `Tests/FoundationModelsACPTests/ReplayTransportTests.swift` — replay a small fixture, assert captured emissions match a golden file
- [ ] Run `swift test` — exits 0

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.