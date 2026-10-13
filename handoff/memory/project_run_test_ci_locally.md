---
name: project-run-test-ci-locally
description: "Running ./test.sh ci locally from a Claude Code session takes ~8 min on this Mac, close to the 10-minute background cap; launch it detached with nohup and Monitor the log, and rm the stale pgpm_test-NN container after any interrupted run"
metadata:
  node_type: memory
  type: project
  originSessionId: 13a5bedd-84e9-4b84-9a14-1e9f3f661779
  modified: 2026-09-24T22:52:00.134Z
---

`./test.sh ci` took about 8 minutes on this Mac (measured 2026-09-24, PR #435), with `locktrace` and
`lockview` SKIPPED by design on Darwin. That is close to the Bash tool's 10-minute background cap, so
do not run it with `run_in_background`. Launch it detached (macOS has no `setsid`):

```bash
nohup bash -c 'cd <repo> && ./test.sh ci; echo "testci exit=$?"' >> "$LOG" 2>&1 < /dev/null & disown
```

then arm a Monitor that polls `$LOG` for `ci: (PASS|FAIL)|testci exit=|Result: FAIL|not ok` and exits
on `testci exit=`. A single-version run (`./test.sh 17`, all three install channels) takes ~100 s and
is a fast first signal before the full track.

If a run is interrupted (TaskStop, timeout), the compose container `pgpm_test-NN` stays up and the next
run collides on it: check `docker ps` and `docker rm -f pgpm_test-NN` before relaunching. Other
containers on the box (a Supabase local stack) are unrelated; leave them alone.

**Why:** The house rule is `./test.sh ci` before pushing anything that touches `pgpm_core/install.sql`,
comments included. A tool-timeout kill mid-run wastes the whole run and leaves containers behind.

**How to apply:** `./test.sh 17` first for quick feedback, then the detached `ci` with a Monitor; after
any interruption, clear the stale test container before relaunching.
