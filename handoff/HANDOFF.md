# Handoff: pass-12 fix phase, interrupted 2026-10-12 21:53Z

The coordinator session (`/fix-phase` for review pass 12) died with its machine at 21:53Z on
2026-10-12, with every subagent, watcher and the landing loop. This branch carries everything the
next session needs that is not already on GitHub. Nothing here is meant to merge: delete the branch
once the fix phase is recorded.

- `handoff/fix12/`: the fix-phase scratch (`plan.md`, `groups.json`, `briefs/G*.md`, `issues/`,
  `prs.tsv`, `pv.tsv`, `fixers.tsv`, `landq.txt`, `notes.md` (timeline), `adjacent.md` (the fixers'
  and verifiers' adjacent observations, to file at the end), `acc_extra/` (round-2 and round-3
  acceptance claims), `pv/<pr>[_rN]/pr/` without the four trees (claims, verdicts, briefs, the posted
  comment, `pr_classified.json`, surface), and the helper scripts).
- `handoff/pass12/`: the pass-12 scratch the fix phase reads (`claims/` for `closure.sh`, `issues/`,
  `issues/filed.json`, `groups.json`, `known_open/`, `classified.json`, `sealed.json`, `notes.md`,
  `tools/`, `seeds/`).
- `handoff/memory/`: the coordinator's memory directory
  (`~/.claude/projects/-Users-davida-ventimiglia-Work-pg-partition-magician/memory/`), with
  `MEMORY.md` as the index. `project_fix12_phase.md` is the one-page state; the standing orders, the
  landing feedback and every earlier pass are the other files.

## Where things stand (assessed 2026-10-13 17:30Z)

`main` is b76002e6 (the pass-12 record merge, the pin's successor). **Nothing has merged.** Fourteen
fix PRs are open. Per-PR verification ran in rounds; "clear" means the posted verification comment
says `Landing: clear` on that head.

| PR | group | issue | head | state | next action |
|---|---|---|---|---|---|
| #1298 | G3 | #1260 T1 | 8f77fc00 | clear r1 | land (tier 1, first) |
| #1294 | G4 | #1261 T2 | f96b180a | clear r1 | land; dropped from the merge queue twice with `checks_timed_out` (see Landing) |
| #1293 | G8 | #1265 T3 | cf9bc477 | clear r1 | land |
| #1297 | G10 | #1267 T3 | ba30f7a1 | clear r1 | land |
| #1300 | G13 | #1270 T3 | 2a721d22 | clear r1 on an earlier sha | re-run acceptance F1-06 on this head (`pv_setup.sh 1300 ...` again), then land |
| #1296 | G6 | #1263 T3 | 15110fd5 | clear r2 | land |
| #1302 | G11 | #1268 + #1232 | e1989695 | clear r2 | land |
| #1305 | G7 | #1264 T3 | e79fa9cb | clear r2 | land |
| #1299 | G2 | #1259 T1 (+ Addresses #705) | db2596ba | round 3 pushed | round-3 verification (`ROUND=3`): acceptance F14-01 + `acc_extra/V-01-1299` (r1, rebuilt in `pv/1299_r2/.../ACC/ACC-02/repro.verified.sql`) + `acc_extra/V-01-1299r2` (the unanchored null-oid row); P1 + V live |
| #1301 | G12 | #1269 T3 | 33a65bfc | round 3 pushed (LAST round) | round-3 verification: F19-02 rebuilt + V-01/V-02 (r1) + `acc_extra/V-01-1301r2` (default port); the body must state the refusal list as the limit; any further spelling is filed, not chased |
| #1295 | G5 | #1262 T3 | 346fe8ab | round 3 pushed 2026-10-13 (the fixer's unpushed commit) | round-3 verification: ACC-01..03 of r2 (rebuilt) + `acc_extra/V-01-1295r2` (ALTER SCHEMA swap) + P1-02 r2 (42P01 on a plain rename); check the pg_locks witness; last round |
| #1304 | G30 | #814 archive bullet (Addresses) | 341b9c87 (= r2) | round 3 NOT started (fixer died) | spawn a fixer on the branch with the round-3 request: ONE read of the bounds under the grid's clock feeding the empty-range check, the range read, the recorded-chunk check and the key, in both encoders; date grid keys the cell; claims `acc_extra/V-01-1304r2` (regression: `_refuse_empty_range` in the session zone), `V-02-1304r2` (date grid, explicit offset), `P1-02-1304r2` (DST gap); last round |
| #1303 | G15 | #1272 T4 | ae02189d | r2: P1 done (seed caught), V died | re-run the r2 claims verifier (`pv/1303_r2/pr/brief_claims_verifier.md`; the regression-shaped ACC-02 passes on the base by definition), classify, report |
| #1306 | G1 | #1258 T1 | 26770663 | r1 prepared (both ACC fixed), P1 and V died | re-run P1 and V from `pv/1306/pr/brief_*.md` (V must run live: default_transaction_isolation = repeatable read under maintain's tick), classify, report |

Fixer branches pushed to origin **without a PR** (the fixers died at the gated-run stage; each
carries CHANGELOG, test, guard, mutation and docs changes): spawn a `fixer` per branch with its
brief plus "continue from the branch's commit: verify what is there, finish the proof list, open the
PR"; do not restart from main.

| group | branch | issue |
|---|---|---|
| G9 | `fix/hypertable-copy-key-constraint-by-conrelid` | #1266 (timescale) |
| G14 | `fix/regrain-capture-function-by-oid-any-schema` | #1271 |
| G29 | `fix/transmute-refuses-negative-infinity-oldest` | #769 bullet 2 (Addresses) |
| G16 | `fix/staging-squatter-remedy-by-relkind` | #1273 |
| G17 | `fix/child-holders-label-rule-by-grid` | #1274 + Addresses #1216 |
| G19 | `fix/time-unit-breach-month-step-date-anchor` | #1276 |
| G20 | `fix/quoted-splices-lint-reads-every-body-and-assignment` | #1278 + Addresses #1236 (REPO-WIDE RULE: lands first in its batch, `rule` in landq.txt) |

Not started: G18 (#1275 + #1277, docs + CHANGELOG lint), G21 (#1279, rule), G22 (#1287, rule, with
Addresses #1180), G23 (#1280), G24 (#1281 + #1282), G25 (#1283, timescale tests; appends under
G27's dispatch), G26 (#1284, archive tests; same), G27 (#1285 + #1286, OWNS
`bench/tests_fail_on_defect.sh`'s dispatch, lands before G25 and G26), G28 (#1288 + #1289 + #1290,
review tooling). Briefs are in
`handoff/fix12/briefs/`.

## Landing

`landq.txt` holds the clear PRs in `<tier> <pr>` form. `scripts/review/landq.sh $W --batch 5`
enqueued #1294 at 20:48Z and again at 21:52Z; GitHub removed it both times with
`checks_timed_out`: the org's Actions ran about two jobs at a time all evening (38 runs queued from
thirteen fixer heads), so the merge group's checks outran the queue's status-check timeout. Before
landing again: check `gh run list --limit 60 --json status` is quiet, re-run any cancelled runs on
the CURRENT heads (`gh run list --branch <br> --status cancelled --json databaseId,headSha`, re-run
only runs whose sha is the PR head), and if the queue times out once more, raising the merge queue's
status-check timeout in ruleset 24013010 is a user decision. Verify every enqueue by GraphQL
(`isInMergeQueue mergeQueueEntry{state position}`) and put a dead-man on the next state.

## Resuming on the new computer

1. Clone the repository anywhere, `gh auth login`, install Docker.
2. From inside the clone, run the restore script straight out of this branch (no worktree needed):

   ```bash
   git fetch origin chore/fix12-handoff
   git show origin/chore/fix12-handoff:handoff/restore.sh > /tmp/restore.sh
   bash /tmp/restore.sh            # optional argument: the work directory, default ~/.claude/handoff-fix12
   ```

   It restores the memory directory into the place Claude Code reads for this checkout (named after
   the checkout path; it prints the path, and says what to do if Claude Code picks another name),
   copies `fix12/` and `pass12/` under the work directory, and re-points every absolute path the
   scripts and briefs carry from the old machine.
3. Images and harnesses: `./test.sh 15` builds `pgpm_test:15` (16, 17, 18 and `pgpm_test:17-archive`
   likewise through compose); the timescale fleet image is
   `public.ecr.aws/supabase/postgres:15.14.1.127`; MinIO is
   `bitnamilegacy/minio:2025.7.23-debian-12-r5@sha256:6dabb4a2088c9a79908de3bc05f4586c23ad2182c8908e7e3acbf61c1467fb20`
   (pull it by digest; Docker Hub and quay denials are in memory). `scripts/review/pr_verify.sh harness
   up [--archive] [--timescale]` brings up the private verification containers. Seed `main`'s image
   cache before the first landing: `gh workflow run timescale.yml --ref main` and `gh workflow run
   test.yml --ref main`.
4. Start Claude Code in the checkout (the restored `MEMORY.md` loads on its own) and say: "resume the
   pass-12 fix phase per `<work dir>/HANDOFF.md`, continuing `/fix-phase` at step 2 with its per-PR
   table". Step 1 (numbers and briefs) is done. The helpers, with `$W` = `<work dir>/fix12`:
   `pv_setup.sh <pr> <issue> "<acc label>" "<lens2>" "<note>" <mutation> <claim-ids>
   [--archive|--timescale]` (set `ROUND=N ROUND_SUFFIX=_rN` for a later round; claim ids resolve to
   `pass12/claims/<finder>/<id>` or `fix12/acc_extra/<id>`), `pv_finish.sh <pr> classify|report
   "<budget>" [--post]|cleanup` (same `ROUND`), `mkcand_brief.py <pr> <claim-id> "<note>"` (needs
   `pv/<pr>/pr/verify/<claim-id>.json`, written from `pr_classified.json`), `r2_setup.sh` as the
   shape for a round's batch setup. Launch finders and verifiers with the `finder` and `verifier`
   agent types from `pv/<pr>[_rN]/pr/brief_finder.md` and `brief_claims_verifier.md`; a candidate
   verifier from `pv/<pr>/pr/briefs/<claim>.md`.
5. Then the rest of the skill: closure (`closure.sh --claims <work dir>/pass12/claims --out
   $W/closure.json --wait-fix-prs`), `caveats.json` from the rebuilt reproductions (every
   `repro.verified.*` in `pv/`), `close_comments.py`, the "Fix phase" section of
   `docs/reviews/2026-10-12-pass12.md` plus its history row, the adjacent observations in
   `adjacent.md` filed and verified, the method lessons issue, the record PR landed with `land.sh`,
   and the loop summary plus convergence report the user asks for after every loop (see memory
   `feedback_loop_summary_and_convergence.md`).

Not carried: the old machine's durable scratch under `~/.claude/projects/<slug>/scratch/` (454 MB,
mostly pass-11 trees). Memory files that name it are history; everything the fix phase reads is in
`pass12/` here.

## Rules that bit this phase (put them in the lessons issue)

- A Tier 1 PR's claims verifier must run its states live; the read-only first verdict on #1299 said
  "holds" and the live re-run found a second Tier 1 (the recorded-detach hand-off).
- Tell fixers not to wait for CI before reporting; eight of them held agent slots for an hour
  watching `gh pr checks`.
- Cancel superseded CI runs by SHA, never by branch: the branch-wide cancel at 21:29Z also hit the
  already-pushed round-2 heads, which then had to be re-run.
- Verifiers sharing `pgpm_prv-15` must prefix their scratch databases (one dropped another's).
- The gate (one fixed-name compose stack) is the fix phase's throughput limit: 24 queued runs, waits
  up to 1 h 42 min. Giving each fixer its own compose project name would remove it.
- Declare the last round at round 2 for a Tier 3 whose follow-ups are the same mechanism from
  another angle (#1295, #1301, #1304 each took three), and have the PR state its limit.
- A CI throughput collapse (two jobs org-wide) needs a dead-man on the merge group's checks and the
  queue timeout raised before the next fix phase; the storm itself comes from thirteen heads each
  running seven workflows.

## Numbers so far

Per-PR finders caught 20 of 20 planted mutations. 13 first-round PRs: 5 clear in round 1, 8 sent
back; 4 clear after round 2; 4 in round 3. Agent tokens roughly 8M through the interruption (fixers
about 190k each, verifiers 50k to 150k; count exactly from the transcripts if the ~27M loop ceiling
matters). Timeline in `handoff/fix12/notes.md` (its 20:24Z to 20:36Z entries run about 30 minutes
fast; the clock was corrected at 20:27Z).
