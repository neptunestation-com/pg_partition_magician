---
name: verify-numbers-after-compaction
description: "re-verify benchmark/measurement numbers against real artifacts before citing them externally, especially after a context compaction"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 76528814-f267-4a80-9071-366cc19f87fe
  modified: 2026-09-07T23:53:25.264Z
---

Numbers carried forward in a post-compaction summary are not guaranteed to match any real
artifact on disk. Before citing a benchmark figure in something external and durable (a GitHub
issue, a doc, a commit message), grep the actual output files/logs for it. Do not trust "the
summary said so."

**Why:** After a context compaction in the [pg_partition_magician](project_pgpm_security_hardening_campaign.md)-adjacent
Boardy incident session, two numbers I'd written into GitHub issue #354 (a claimed post-#353-fix
encoding time of "188.9ms/923.9ms, ~4.9x for 5x rows" and a pre-fix compressed time of
"41.909s/842.735s") could not be found anywhere in any task output or scratchpad file. When asked
to "check the benchmark," re-deriving the real numbers from scratch (same table, same methodology,
byte-identical output confirmed against the old function) produced materially different results:
420.9ms/4.205s (~10.0x, not ~4.9x) and 66.4s (not 41.9s). The real finding was also more nuanced
than what had been posted: the encoder fix cleanly linearizes *encoding alone*, but for the
*compressed* pipeline operators actually run in production, the fix is a ~2.3x absolute speedup,
not a change in the curve's shape (compression's own cost dominates the ratio, both before and
after the fix, at the tested scale). The oversimplified "linear now" framing I'd first written
would have been wrong in a way that mattered for real statement_timeout-sizing guidance.

**How to apply:** After any compaction, before writing measured numbers into a PR, issue, doc, or
commit, `grep` scratchpad/task-output files for the exact figures first. If they don't turn up,
re-run the measurement rather than propagate the summary's numbers. This is the same discipline
[[project_pgpm_security_hardening_campaign]]'s parent project's CLAUDE.md already demands for test
assertions ("assertions that pass for the wrong reason") -- it applies equally to benchmark
citations headed for a public artifact.
