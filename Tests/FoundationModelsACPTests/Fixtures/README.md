# Wire fixtures

Recorded ndJSON byte streams that pin the agent's wire behavior. They are loaded
via `#filePath` (see `EndToEndSupport.swift`) and excluded from the test target
in `Package.swift`, so they are plain data, never compiled resources.

## Files

- `golden-session-script.ndjson` — a full client→agent session (initialize,
  `session/new`, `session/prompt`) with **string** JSON-RPC ids, so responses
  echo readable ids instead of the encoder's `Double` formatting.
- `golden-session-agent.ndjson` — the agent→client byte stream the session
  above produces: the `session/update` notifications and the responses,
  frame for frame. `GoldenReplayTests` asserts the live capture equals this
  file byte-for-byte and fails with the first differing line on drift.
- `replay-script.ndjson` / `replay-golden.ndjson` — the `ReplayTransport`
  codec-level round-trip fixtures used by `ReplayTransportTests`.

## Capturing a new fixture (tee the stream)

Golden replay is deterministic because the turn is scripted (no live model) and
the driver awaits each response in order. `GoldenReplayTests` captures both the
client→agent script it sends and the agent→client bytes it receives; the
`expectGolden` helper writes them to `Fixtures/` when the fixture is absent, and
otherwise asserts against it.

To (re)record after an intended change to the wire shape:

```sh
RECORD_GOLDEN=1 swift test --filter GoldenReplayTests
```

That rewrites `golden-session-script.ndjson` and `golden-session-agent.ndjson`
from the live run. Review the diff, then commit — "capture once, replay
forever". Without `RECORD_GOLDEN`, the same test asserts the committed bytes.

To capture a brand-new scenario, add a scripted turn and a `driver.request(...)`
sequence in `GoldenReplayTests`, name a new fixture in the `expectGolden(...)`
calls, and run the command above once to record it.
