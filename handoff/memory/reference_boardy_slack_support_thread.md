---
name: boardy-slack-support-thread
description: Boardy.ai production support happens in a Slack thread David has direct read access to via MCP Slack tools -- check it for live status before assuming context is stale
metadata: 
  node_type: memory
  type: reference
  originSessionId: 76528814-f267-4a80-9071-366cc19f87fe
  modified: 2026-09-10T17:30:34.339Z
---

Live, ongoing support conversation with Indranil (Boardy.ai, see [[project_boardy_pilot]]) happens
in a Slack thread in workspace `supabase.slack.com`, channel `C0BRQJML6P3`, parent message ts
`1788804509.909519` (started 2026-09-07, "the regraining is complete but the final atomic
partition attach is timing out"). As of this memory it has 110 messages and counting -- it is the
live record of the v0.4.0 rollout, the `archive_batch`/`archive_byte_budget`/`statement_timeout`
tuning saga, and the discovery that led to [[project_lz77_memory_blowup_fix]] (issue #366).

**How to read it directly:** `mcp__claude_ai_Slack__slack_read_thread` with
`channel_id: "C0BRQJML6P3"` and `message_ts: "1788804509.909519"` (a Slack `p<digits>` URL segment
converts to ts by inserting a decimal point six digits from the end, e.g.
`p1788804509909519` -> `1788804509.909519`). The tool's default page did not return the thread from
the start -- it returned the most recent ~100 replies first; a second call with the `cursor` from
`pagination_info` returned the earliest replies instead. Fetch both directions before assuming
completeness, don't rely on total counts in the header text.

**How to apply:** before assuming any Boardy-related project memory is current, check this thread
for anything newer -- it moves fast (multiple exchanges per day during active incidents), and
David's own summaries to Claude in chat may lag what's actually in Slack by hours.
