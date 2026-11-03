# ``FoundationModelsACP``

Types and connections for the Agent Client Protocol (ACP) v2, in Swift.

## Overview

The package has the generated ACP types, an agent side and a client side
connection over a transport, a merge engine that builds session state from
`session/update` notifications, and the SwissArmyHammer (SAH) extensions.

## Topics

### Sub-agent sessions

- <doc:SubagentSessions>
- ``SubagentUpdate``
- ``SessionMessage``
- ``SessionMessageChunk``
- ``SAH/AgentRun``
- ``SAH/RestoreFailure``
- ``SubagentWireTraceValidator``
- ``WireTraceEvent``

### Session state

- ``SessionMergeEngine``
- ``ClientSideConnection``
- ``AgentSideConnection``
