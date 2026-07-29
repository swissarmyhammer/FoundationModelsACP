---
depends_on:
- 01KYQ7ET0YYT5TJWEDF7KGQ5DW
position_column: todo
position_ordinal: '8480'
title: Generate elicitation/* payload types and add Client handler entry points
---
Today elicitation/create and elicitation/complete exist only as UnstableMethodInfo rows in MethodTable.generated.swift. After the re-vendor, generate the request/response structs, add the two Client protocol methods in Connection/Client.swift, and add the outbound senders on AgentSideConnection. Consumer ask: FoundationModelsACPAgent plan section 16 (ACPElicitationCoordinator).