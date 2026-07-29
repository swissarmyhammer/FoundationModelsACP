# Wire fixtures

Recorded ndJSON byte streams that pin wire behavior against ACP v2. They are
loaded via `#filePath` (see `GoldenFixtureSupport.swift`) and excluded from
the test target in `Package.swift`, so they are plain data, never compiled
resources.

Every v1 transcript this repo once carried was deleted on the `v2-reset`
branch: `session/prompt` no longer completes, `fs/*` and `terminal/*` frames
are gone, and `messageId` is now required, so none of it decodes against the
current generated types. These are fresh v2 recordings, not migrations.

## Files

- `replay-script.ndjson` / `replay-golden.ndjson` — the codec-level
  `ReplayTransport` round trip used by `ReplayTransportTests`: a toy scripted
  request stream and the deterministic echo responses it produces. Proves the
  transport primitive itself (framing, capture, replay) independent of any
  real `Agent`/`Client`.
- `unknown-values-transcript.ndjson` — a multi-frame `session/update`
  transcript mixing known variants with unrecognized enum values and
  `_`-prefixed extensions, proving losslessness at the transcript level
  rather than one decoded value at a time. Built and captured by
  `ReplayTransportTests`.
- `full-session-agent.ndjson` — the agent's emitted byte stream for the
  representative full session: `initialize`, `session/new`, `session/prompt`,
  a streamed turn (thought/message chunks, a tool call with a content chunk
  and a display terminal reference, the terminal's own upserts), a
  `session/request_permission` round trip, and the closing `idle`. Captured
  from a live `InMemoryTransport` pair by `GoldenSessionEndToEndTests` — not
  `ReplayTransport`, because the permission round trip needs a live,
  reactive peer (see `ReplayTransport`'s own doc comment for why a
  statically-scripted replay cannot answer its own outbound request safely).

`OutOfOrderConvergenceTests` builds its scrambled `session/update` transcript
(a patch before its own creation, a chunk before any upsert names the id, and
a straggler after the closing `idle`) in code rather than from a checked-in
file — the interesting content is the *order*, spelled out once at the call
site, not bytes worth diffing against a golden copy.

## Capturing or re-recording a fixture

Every fixture here is produced by running its owning test with `RECORD_GOLDEN`
set, so "capture once, replay forever" — the same convention used throughout
this suite:

```sh
RECORD_GOLDEN=1 swift test --filter ReplayTransportTests
RECORD_GOLDEN=1 swift test --filter GoldenSessionEndToEndTests
```

Review the diff, then commit. Without `RECORD_GOLDEN`, the same tests assert
the committed bytes byte-for-byte and fail with the first differing line on
drift.
