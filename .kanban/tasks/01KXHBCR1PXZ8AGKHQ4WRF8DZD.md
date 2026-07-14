---
depends_on:
- 01KXHBBA1PN5PQJVEVHCQTBQ9T
- 01KXHBBTQ24BC8586M5K0N872Z
position_column: todo
position_ordinal: 8d80
title: Stdio transport, stderr-only logging, and child-process management
---
## What
Implement the production transport (spec §5) in `Sources/FoundationModelsACP/Transport/`:

- `.stdio` transport: async reads from stdin, writes to stdout, satisfying the transport abstraction — usable as `AgentSideConnection(stream: .stdio)`.
- **stdout is sacred — the field failure:** the package must write nothing to stdout except valid ACP frames. Expose a logger/delegate seam; every internal log (skipped bad line, dispatch error, etc.) goes to **stderr** or the delegate, never stdout. Add loud documentation for agent authors (a stray `print`, banner, or progress bar corrupts framing).
- Client-side subprocess transport for driving an external agent (e.g. `gemini --experimental-acp`, spec §9): spawn via `Process`, wire its stdio to a connection, forward the child's stderr, and **reap the child** on connection close/deinit — no zombies; also terminate on parent cancellation.

## Acceptance Criteria
- [ ] An agent over `.stdio` completes an initialize handshake with a client on the other end of real pipes
- [ ] Nothing but ACP frames appears on the agent's stdout during a session that logs internally (assert stdout capture is pure ndJSON)
- [ ] Killing/closing the connection to a spawned child agent reaps the process (no zombie; exit observed)

## Tests
- [ ] `Tests/FoundationModelsACPTests/StdioTransportTests.swift` — spawn a tiny helper agent executable (test-only target) over pipes; handshake; assert stdout purity while the agent emits stderr logs
- [ ] `Tests/FoundationModelsACPTests/SubprocessReapTests.swift` — spawn, close, assert child exit is collected
- [ ] Run `swift test` — exits 0

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.