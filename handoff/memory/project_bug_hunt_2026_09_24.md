---
name: project-bug-hunt-2026-09-24
description: "Adversarial review of pgpm 0.6.0 on 2026-09-24 found 76 confirmed defects; the 25 data-loss-tier fixes (#441-#465, PRs #466-#490) are ALL MERGED as of 2026-09-25 (main 31f6140); tiers 2-5 unfiled; merge-chain lessons"
metadata:
  node_type: memory
  type: project
  originSessionId: e3676f1f-5dd0-49b1-884e-c5176eaa0ec4
  modified: 2026-09-25T14:40:00.000Z
---

On 2026-09-24 the user asked for an adversarial bug hunt of pgpm at main `a72c5bf` (v0.6.0). Eight
slice reviewers plus a coordinator pass found 76 confirmed, reproduced defects and ~30 plausible ones.
The full ranked report is `notes/2026-09-24-bug-hunt.md` in the repo (written uncommitted; user decides
whether to commit or file issues). Filed 2026-09-24: #441 (U1 stale overloads on upgrade) and #442 (U2 uninstall residue), then the WHOLE data-loss
tier as #443 to #465 (23 issues; the report's "Issues filed" table maps item to number). Tiers 2 to 5 (wedges,
contract violations, doc contradictions, blind tests) remain unfiled.

FIX PRs (2026-09-24/25): one per issue, #466 to #490 (all 25), each opened after a green local `./test.sh 15
--channel=psql` gate. ALL 25 MERGED on 2026-09-25 (05:38 to ~14:30 UTC), squash, in PR-number order with #483
(TimeZone) last; final main 31f6140. Worktrees, batch branches, containers and the pgpm_test_net network were
cleaned up the same day at the user's request. Eleven older local fix/* branches predate the batch and were left.

Merge-chain lessons (scratchpad scripts are gone with the session; the lessons are what matter):

- Cost was ~19 min per PR, almost all CI wall-clock: each merge moves main, the next PR is rebased onto it and
  needs a fresh full run. Nearly all touched install.sql, so no parallelism was possible. Say so up front.
- GitHub Actions `pull_request` workflows do NOT run on a CONFLICTING PR (no merge ref); a PR with "no CI" is
  usually just conflicting with a moved main. Rebase first, then look for checks.
- Hand-resolve install.sql conflicts by CONTENT rules in a re-runnable script, and dry-run the rebase in a
  throwaway worktree, then run the local PG15 gate on the dry-run tree BEFORE the real rebase. That is what
  found the tests written against a dropped function arity (#483 dropped the old _grid_floor/_grid_next/
  _part_name signatures; tests 108/120/123 from #451/#484/#486 called them). A regex pass that inserts an
  argument into calls must apply insertions from the END of the file (nested calls: positions shift).
- Never edit a running bash script (bash reads incrementally; a mid-run edit produced a syntax error).
- The classifier blocks unattended `gh pr merge` until Bash(gh pr merge:*) plus an autoMode.allow entry are in
  .claude/settings.local.json; I cannot edit settings myself, the user has to.
- Flakes seen: TimescaleDB track pulls supabase/postgres from ECR Public and hit "toomanyrequests: Data limit
  exceeded" (all 5 built-in retries); `gh run rerun <id> --failed` after the run completes fixed it.
- Old test databases named in bench harnesses collide across PRs (pgpm_perf15 used twice); pick a fresh name.

Headline classes (each is a root cause behind several findings):

- Grid arithmetic runs in the caller's session TimeZone (`_grid_floor`/`_grid_next`/`_part_name`); JDBC
  operator + pg_cron UTC leaves a permanent grid hole; day steps drift across DST.
- `max(uuid)` in `regrain_step:2595` and `_next_archive_chunk:1810`: uuidv7 regrain and archive do not
  work at all on PG 15 to 17 (PG18 added max(uuid)); no test drives that path.
- `untransmute` check-then-act race loses committed rows; regrain swap reconcile capped at 100 loops;
  reconcile mis-derives the first child name when target step does not divide `lo`.
- Negative `p_retain` accepted: first tick drops the live table.
- `from_hypertable`: integer-time or non-dimension `p_control` migrates to ZERO rows and reports success.
- Parquet `_pq_plain_decimal` corrupts negatives at precision >= 17 (inexact numeric `/`, use `div()`).
- Upgrade from <= 0.4.0 (NOT 0.3.0: local dist/ artifacts were mislabeled builds; tag sources are ground truth) leaves stale overloads: `pgpm.schedule()` and `restore_incoming_fks(regclass)`
  become "not unique"; `uninstall.sql` leaves the regrain capture trigger + delta table behind.
- Tests 11/12 (`count = count`), 47 (reads after prepare tick), 72/90 (`throws_ok(NULL)`) proved blind.

**Why:** the user's stated mode is hardening; these are the next several weeks of fix PRs.

**How to apply:** when the user picks up any pgpm fix, read the report's tier and "suggested fix order"
first; repro scripts were in the session scratchpad (ephemeral) but every finding lists install.sql
line numbers and a one-line scenario sufficient to rebuild the repro. Tiers 2 to 5 are the remaining work; file from the report when the user asks. Related: [[project-next-issue-421]], [[project-release-v0-5-0]].
