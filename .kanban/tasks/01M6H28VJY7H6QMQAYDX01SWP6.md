---
assignees:
- claude-code
position_column: done
position_ordinal: c280
title: One connection-wide ordered update stream with wire sequence numbers
---
Gap found by the client package. The router puts each session update into its session buffer in wire order. Each session has its own subscription, and the consumers run apart. So there is no order guarantee across sessions. Two cases fail in a nested resume replay (root, child, grandchild):
1. A session/request_permission for the grandchild arrives after the resume response. The grandchild announcement is a subagent_update in the child stream. The child consumer may not have read it, so the client has no model for the grandchild.
2. The resume response marker is read in the root stream only. The child streams do not get it, so the child models cannot end their replay at the right place.

Options the client named:
(a) Deliver the requestFinished marker of a resume into every open subscription. This fixes case 2 only. It does not fix case 1, because the handler can still run before a consumer reads an earlier update.
(b) A drain call, for example updatesDelivered(before:). The library cannot know when a consumer applied an element, and one consumer that stops reading blocks the drain. Not recommended.
(c) Recommended: one connection-wide stream of all session events in wire order. Each element has the session id, the event, and a wire sequence number. The sequence shares the counter with Connection.currentRequestArrival, so an inbound request has a number that is comparable with the numbers of the events. The client then uses one consumer task. It applies all events in total order. It sees the resume marker once, and ends the replay of every model itself. A handler waits until the consumer applied sequence >= its own arrival number. The wait is on the client side.

Design points to decide in the work:
- Today only inbound requests get an arrival number. Notifications need numbers from the same counter.
- The per-session subscription stays. It is not removed unless the client wants that (ARCHITECTURE.md: no shims).
- Kept updates for sessions with no subscriber: the all-sessions stream must not lose them (buffer limits apply).

Acceptance (draft): test with a nested replay, a resume response and an immediate inbound request. The stream shows the order. The request arrival number is greater than the number of every earlier update and less than the number of every later update.