---
depends_on:
- 01KXHB7BRWP3WN7SNQ1342ZXED
position_column: todo
position_ordinal: '8880'
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
- [ ] A message split across arbitrary chunk boundaries (including mid-UTF-8-codepoint) reassembles correctly
- [ ] Multiple messages in one chunk are all delivered
- [ ] A garbage line between two valid lines is skipped and logged; both valid messages are delivered
- [ ] `session\/update` (escaped slash) parses to method `session/update`

## Tests
- [ ] `Tests/FoundationModelsACPTests/NDJSONCodecTests.swift` — chunk-boundary matrix (split mid-line, mid-codepoint, multiple-per-chunk), garbage-line skip, escaped-slash, trailing-partial retention
- [ ] Run `swift test` — exits 0

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.