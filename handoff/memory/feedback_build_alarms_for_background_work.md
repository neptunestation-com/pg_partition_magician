---
name: build-alarms-for-background-work
description: Every long background job and the landing loop must have an alarm that wakes the coordinator (Monitor or run_in_background), never bare nohup; a CI failure stopping the landing loop must surface
metadata:
  type: feedback
  modified: 2026-10-09T04:10:00Z
---

"You need to build better alarms, if there's risk of CI failures leaving us hanging." (2026-10-09, after the pass-10 fix phase sat idle for three hours: landq.sh had STOPPED on a CI failure at 01:13Z and a nohup'd classification had finished, and nothing woke the coordinator until the user asked.)

**Why:** a background job started with bare `nohup ... &` gives no completion notice, and `scripts/review/landq.sh` exits silently on a CI failure or a hand-resolvable conflict; silence looks identical to "still running".

**How to apply:** start long jobs with Bash `run_in_background: true` (one completion notice) or arm a `Monitor` on their log with a filter that covers every terminal state (`STOPPED|MERGED|ALL LANDED|FAILED|needs a hand|stall`), re-armed on expiry; for the landing loop keep a Monitor on `landq.stdout` for the whole phase; for a CI run you are waiting on, an `until gh run view ... completed` loop in the background. Check the alarm exists before ending a turn that waits on background work. See [[fix10-phase]].
