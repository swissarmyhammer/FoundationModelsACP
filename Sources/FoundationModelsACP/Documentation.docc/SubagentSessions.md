# Sub-agent sessions

Show a tree of child sessions, resume it in the right order, and read it in one
order on the client.

## Overview

An agent can run a child session for a tool call. A child can have children.
ACP v2 calls this the unstable "Subagent Sessions" feature. It needs no client
capability. Each child is a session with its own `sessionId`.

### The updates

The agent tells the client about a child with three session updates:

- ``SubagentUpdate`` (`subagent_update`) announces a child, and later changes
  it. It is a patch. A field that the update omits stays as it was. `null`
  clears a field. It goes in the stream of the parent of the child. An agent
  announces a child before the first update that names the child.
- ``SessionMessage`` (`session_message`) and ``SessionMessageChunk``
  (`session_message_chunk`) carry a message from one session to another.

The `capabilities` of a ``SubagentUpdate`` tell what the client can do with the
child, for example cancel it. A tool call and a terminal have the same kind of
`capabilities` field.

### Link a tool call to its child

ACP does not link the tool call that started a child to the child. The SAH
extension ``SAH/AgentRun`` does it, in `_meta.sah.agentRun`:

- The `subagent_update` of the child has `toolCallId`: the tool call that
  started the child.
- The `tool_call_update` of that tool call has `sessionId`: the child.

The agent sends the final `tool_call_update` after the last update of the
child. A client removes the child at that update.

ACP patches `_meta` by top-level key. A new `sah` object replaces the whole
earlier `sah` object. Thus an update that sends one SAH member must send every
other SAH member that must stay.

### A child that failed to restore

When a child fails to restore, the agent sends a `subagent_update` without a
`state`. A missing state means that the state is unknown. The update carries
``SAH/RestoreFailure`` in `_meta.sah.restoreFailure`, with a short `reason`.
The agent sends the same object with the reason that an ancestor was not
restored on each descendant of that child. A later current `subagent_update`
with a `state` clears the failure. That is a rule of the client. It is not a
message on the wire.

### The order of a resume

The client resumes a session with `session/resume`. The agent sends the
updates in this order:

1. The history (the replay) of the session and of its children. These
   updates are history. They confirm nothing about the state now.
2. A `subagent_update` for each child that the `background` list names, if
   the replay did not give it.
3. The current `state_update` of the session, with the `background` list.
4. A `session_info_update`.
5. The `session/resume` response.
6. The current snapshot of each child, as a `subagent_update`. A snapshot
   replaces the state of its child. A snapshot without a `state` means that the
   state is unknown.

The `acp-test-agent` tool plays this order with `--scenario nested-subagents`.
It is the reference script for a correct agent.

### Build the state on the client

``SessionMergeEngine`` folds each `subagent_update` onto the earlier value of
the same child. A snapshot before the response is history, so it must not
fill a field that the current snapshot omits. Call
``SessionMergeEngine/markReplayBoundary()`` when the `session/resume` response
arrives. The first `subagent_update` of each known child after the call then
starts from an empty value. A field that it omits stays unset, and it does not
keep the history value. A child with no current update keeps its history value.

### Read all sessions in one order

``ClientSideConnection/subscribe(to:)`` gives the events of one session. The
streams of different sessions have no order between them. A child
announcement can be in the stream of the parent while a request for the child
already runs.

Use ``ClientSideConnection/subscribeToAllSessions()`` to read the events of all
sessions in one stream, in wire order. Each element has a
``SequencedSessionEvent/sequence``. The sequence comes from the same counter
as ``ClientSideConnection/currentRequestArrival``, the number of an inbound
request. A handler of a request, for example for a permission or an
elicitation, does this:

1. As its first statement, it reads ``ClientSideConnection/currentRequestArrival``
   and ``ClientSideConnection/latestEventSequence``.
2. It waits until the one task that reads the stream has applied that
   sequence. When ``ClientSideConnection/latestEventSequence`` is `nil`, it
   does not wait.

Then the client has applied everything that the agent sent before the request.
The `session/resume` marker is in the same stream, at the position of the
response. Thus one reader ends the replay of all sessions at the same place.

Call ``ClientSideConnection/subscribeToAllSessions()`` as soon as the
connection exists. The connection keeps the events before the first
subscription, up to a limit.
