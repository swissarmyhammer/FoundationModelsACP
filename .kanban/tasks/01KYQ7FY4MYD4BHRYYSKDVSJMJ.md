---
comments:
- actor: claude-code
  id: 01kyq9pgnt4anqcrtq6tjnfszz
  text: 'Checked before starting: `mcp/*` methods appear only in `Schema/acp-v2.meta.unstable.json`, not the stable manifest — confirms the task''s own "BLOCKED EXTERNALLY" note is still accurate. Same upstream precondition as ^7kgq5dw (no newer schema-v2 tag exists past schema-v2.0.0-alpha.2; the mcp/* promotion to stable hasn''t happened). Leaving in `todo`, not moving to `doing`.'
  timestamp: 2026-07-29T16:00:38.586218+00:00
- actor: claude-code
  id: 01kyqakfxzj6bx403fdwpdz1t5
  text: 'Closed as done per user decision, not because the mcp/* payload types were actually generated. Confirmed mcp/* methods exist only in Schema/acp-v2.meta.unstable.json (routing names only), not in the stable manifest or in acp-v2.json''s $defs. Same root cause as ^7kgq5dw/^enzjy0q: no schema-v2 tag past alpha.2 exists upstream yet. No code was written. If/when upstream stabilizes mcp/*, this should be re-opened (or a fresh task filed) to actually generate and wire up the payload types.'
  timestamp: 2026-07-29T16:16:28.095825+00:00
position_column: done
position_ordinal: '9580'
title: Generate mcp/connect, mcp/message, mcp/disconnect payload types for the ACP tunnel
---
The three mcp/* methods exist only as routing names in the unstable manifest. The consumer (FoundationModelsACPAgent plan sections 11.5 and 21) needs generated payload types before it can build ACPTunnelTransport. BLOCKED EXTERNALLY: upstream must graduate the mcp/* methods to the stable schema first. Do not build against the unstable schema. Keep this task until upstream stabilizes, then re-vendor and generate.