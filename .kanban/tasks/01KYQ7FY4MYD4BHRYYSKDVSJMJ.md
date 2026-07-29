---
position_column: todo
position_ordinal: '8580'
title: Generate mcp/connect, mcp/message, mcp/disconnect payload types for the ACP tunnel
---
The three mcp/* methods exist only as routing names in the unstable manifest. The consumer (FoundationModelsACPAgent plan sections 11.5 and 21) needs generated payload types before it can build ACPTunnelTransport. BLOCKED EXTERNALLY: upstream must graduate the mcp/* methods to the stable schema first. Do not build against the unstable schema. Keep this task until upstream stabilizes, then re-vendor and generate.