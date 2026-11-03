# ``acp_conformance``

@Metadata {
  @DisplayName("acp-conformance")
}

Run any ACP agent binary through scripted client scenarios and check the wire trace.

## Overview

`acp-conformance` starts the agent over stdio, plays client scenarios, and checks the
messages on the wire. Each check has a stable id. The output is a pass, fail or skip
line for each check, with the position of the first event that breaks it.

    acp-conformance [--json] [--script FILE] [--env KEY=VALUE]... [--cwd PATH] \
                    [--quiet SECONDS] [--timeout SECONDS] -- AGENT [ARGUMENT]...

`--cwd` sets the working directory of the sessions. The default is a new empty folder,
because a cwd such as `/` makes some agents index the whole disk. `--trace` prints the
numbered wire trace of each scenario to stderr; the positions in the report are these numbers.

The exit code is 0 when no check failed, 1 when a check failed, and 2 for a usage error.
A skipped check does not fail the run. `--json` prints an object with `passed` and
`results`.

### The scenarios

Each scenario starts its own agent process.

1. **Handshake and turn.** `initialize`, `session/new`, and one prompt turn.
   - `handshake.initialize`, `handshake.new-session`.
   - `turn.response`: `session/prompt` is answered.
   - `turn.states`: the turn reports `running` and then one final `idle`.
2. **Cancel.** A prompt that asks the agent to keep working, then `session/cancel`.
   - `cancel.ends-turn`: the last `state_update` is `idle`.
3. **Resume.** `session/resume` of the created session, with `replayFrom: start` and without it.
   - `resume.accepted`.
   - `resume.no-history-without-replay-from`: no conversation history before the response when the request had no `replayFrom`.
4. **The ten rules** of `SubagentWireTraceValidator`, checked on every recorded trace:
   `rule.1` to `rule.10`. The order of a resume (replay, background item updates, one
   current `state_update`, `session_info_update`, the response), no historical state
   as current, no replayed request, and the rules for nested sub-agents.

The runner answers each permission request and each elicitation with a cancel.

### The script for nested sub-agents

The default resumes use the session that `session/new` made. To check an agent that
announces children, give the runner a script. Each step is a resume of one session in a
new agent process.

    { "resumes": [ { "sessionId": "root", "replayFrom": true, "untilToolCall": "call-child-1" } ] }

- `sessionId`: the session to resume. Absent means the created session.
- `replayFrom`: send `replayFrom: start`. The default is true.
- `untilToolCall`: end the recording after the final status of this tool call. Absent
  means the recording ends when the wire is quiet after the response.

### Use in CI

Build the product `acp-conformance` from this package, and run it with the agent after `--`.
Use `--json` when a job reads the result. Use `--quiet` to set how long the wire must be
quiet before the runner decides that the agent sends nothing more.

    swift run acp-conformance --json -- .build/debug/acp-agent --stub-model

`acp-test-agent --scenario conformant` passes every check. Add
`--scenario nested-subagents` and the script above to check the nested rules.
