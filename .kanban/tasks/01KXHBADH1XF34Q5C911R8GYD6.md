---
comments:
- actor: wballard
  id: 01kxhw06hdhdw5b85khqa1n118
  text: |-
    Implementation landed via TDD (tests written first, watched all 14 fail, then implemented). Full suite green: 73 tests (37 + 36), exit 0, zero warnings. Double-check agent verdict: PASS.

    Decisions later transport/connection tasks should know:

    - Transport abstraction (Sources/FoundationModelsACP/Transport/NDJSONCodec.swift): `protocol ACPTransport: Sendable { var bytes: AsyncThrowingStream<Data, any Error> { get }; func write(_ data: Data) async throws }`. Transports move opaque bytes only; framing is layered on top by NDJSONCodec. Stdio/in-memory/replay transports should construct their `bytes` stream via `AsyncThrowingStream.makeStream()` (see LoopbackTransport in the tests for the in-memory pattern).
    - Logger seam: `ACPLogger` struct-of-closure with `.disabled` and `.standardError` (writes to FileHandle.standardError — never stdout, spec §5).
    - Read pipeline: `NDJSONFramer` (byte-level, mutating `append(Data) -> [Data]` + `finish() -> Data?`) composed by `NDJSONCodec.messages(from:logger:) -> AsyncThrowingStream<JSONValue, any Error>`. Delivery type is `JSONValue` — the connection task gets parsed JSON, not raw Data; envelope (jsonrpc/id/method) validation is deliberately NOT done here.
    - Escaped `session\/update` needs no special handling — JSONDecoder unescapes natively; covered by test anyway.
    - Wire tolerances built in: trailing `\r` stripped (CRLF peers), blank/whitespace-only lines skipped silently (no log noise), unterminated final line at EOF is parsed like any other line, stream errors propagate through the message stream, garbage lines log a 256-byte preview and are skipped.
    - Write side: `NDJSONCodec.encode(some Encodable) -> Data` uses compact JSONEncoder with [.sortedKeys, .withoutEscapingSlashes]; the appended 0x0A is provably the only newline (JSON escapes control chars in strings).
    - Known non-issue (probed by double-check): a peer that never sends `\n` grows the framer buffer unboundedly — standard NDJSON behavior, no cap required by spec.
  timestamp: 2026-07-15T03:09:21.837414+00:00
- actor: wballard
  id: 01kxhw9t9cr07v84e5jyhqhr00
  text: 'Review pass on checkpoint 118e24b (HEAD~1..HEAD) came back clean: 0 findings, 14 checks attempted, 1 candidate refuted. Task moved to done in one implement→test→commit→review iteration. Downstream tasks (stdio/in-memory/replay transports, connection): consume `ACPTransport.bytes` via `NDJSONCodec.messages(from:logger:)` and write with `transport.write(try NDJSONCodec.encode(message))` — see the prior comment for the full decision log.'
  timestamp: 2026-07-15T03:14:36.972900+00:00
depends_on:
- 01KXHB7BRWP3WN7SNQ1342ZXED
position_column: done
position_ordinal: '8480'
title: ndJSON framing codec
---
## What
Implement the wire framing (spec §5 "Framing & errors") in `Sources/FoundationModelsACP/Transport/NDJSONCodec.swift`:

- One JSON object per `\n`-delimited line, UTF-8, no embedded newlines, and **no `Content-Length` headers** — this is not LSP framing; we own the codec rather than reusing an LSP JSONRPC library.
- Read side: buffers incoming byte chunks, retains a trailing partial line across reads, splits on `\n`, tolerates JSON-escaped slashes in method names (`session\/update`).
- A line that fails to parse is logged (to the injected logger, spec §5 stdout discipline) and **skipped**, never fatal.
- Write side: serializes one message per line, guaranteeing no embedded newlines in output.
- Define the transport abstraction here too: a small `ByteStream`/transport pair (async read sequence + write function) that stdio, in-memory, and replay transports all satisfy.

## Acceptance Criteria
- [x] A message split across arbitrary chunk boundaries (including mid-UTF-8-codepoint) reassembles correctly
- [x] Multiple messages in one chunk are all delivered
- [x] A garbage line between two valid lines is skipped and logged; both valid messages are delivered
- [x] `session\/update` (escaped slash) parses to method `session/update`

## Tests
- [x] `Tests/FoundationModelsACPTests/NDJSONCodecTests.swift` — chunk-boundary matrix (split mid-line, mid-codepoint, multiple-per-chunk), garbage-line skip, escaped-slash, trailing-partial retention
- [x] Run `swift test` — exits 0

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.