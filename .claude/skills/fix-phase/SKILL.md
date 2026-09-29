---
name: fix-phase
description: Run the fix phase that follows an adversarial review pass, as its coordinator. Assigns non-colliding test numbers, guard databases and scratch to one fixer agent per issue, lands the PRs through the merge queue with scripts/review/landq.sh (one at a time, or stacked batches under a merge-commit queue), re-runs every reproduction against the fixed main, posts the closure evidence, and files the fixers' adjacent observations.
argument-hint: "[issue ...] (default: every open issue from the latest pass record)"
disable-model-invocation: true
allowed-tools: Bash Read Write Agent
---

You are the **coordinator** of a fix phase. You do not fix anything yourself. Read
`docs/adversarial-review.md` (the "Between passes" and "Fix phase" sections) and `scripts/review/README.md`
("Fix phase tooling") before step 1. Arguments: `$ARGUMENTS`, the issues to fix; default to every open
issue the latest `docs/reviews/*.md` filed. Work in a scratch directory outside the repository (the
session scratchpad, `$WORK`), and keep the PR table there (`$WORK/prs.tsv`, columns
`issue pr test guard mutation`, tab-separated, header first).

## 1. Assign before anyone starts

Parallel fixers collide on three things unless you hand them out:

- **Test file numbers.** `ls tests/ | grep -oE '^[0-9]+' | sort -n | tail -1` gives the highest; assign
  the next N, one per issue (two for an issue that needs a core and an archive file; archive tests
  number separately under `tests/archive/db/`). Write them down before spawning.
- **Guard database names.** `grep -oE 'pgpm_perf[0-9]+' test.sh | sort -t f -k3 -n | tail -1` gives the
  highest `pgpm_perfNN`; assign one per GUARD the fixer will write, not one per issue (#601 needed five
  for four issues and fell back to a scratch name), and say in the brief which is for which.
- **Scratch.** `$WORK/fix/<issue>/` per fixer; nothing shared.

Group issues that share a mechanism into one fixer when fixing them apart would mean the same conflict
four times (pass 2's zone class, #503 to #506, was one PR). Record the grouping in `$WORK/plan.md`.

## 2. Spawn the fixers

One `fixer` agent per issue (or group), `isolation: worktree`, at most as many at once as the concurrency
cap allows. The brief carries: the issue number and body, the assigned numbers, the scratch path, and
the reminder that the issue's reproductions are the acceptance test unless they prove unsound. Record
each PR the fixers report in `$WORK/prs.tsv` with its test, guard and mutation names.

## 3. Gate, then land in order

- Before landing, every PR must have passed `./test.sh 15 --channel=psql` on its own head (the fixer's
  report says so; spot-check one), run through `scripts/review/gate.sh $WORK/gate.lock -- ./test.sh 15
  --channel=psql` so parallel fixers do not fail each other at `compose up`. The merge queue runs every
  track on the exact tree it merges.
- Land them with `scripts/review/landq.sh $WORK --batch 5` reading `$WORK/landq.txt` (`<tier> <pr>` lines,
  appended as the fixers report), or by hand with `scripts/review/land.sh [--batch] <pr> ...`, Tier 1
  first. `land.sh` rebases each PR onto the
  current main, resolves the three list files, verifies what CI would fail on, waits for the head
  checks, enqueues, and waits for the merge; it retries only the flakes `flake_check.sh` knows and
  stops on anything else. Under a squash queue (passes 2 and 3) expect 25 to 30 minutes per PR, one at
  a time (the script's header says why); since 2026-09-29 the queue takes merge commits, which keep a
  stacked PR's ancestry and allow groups of up to five once `land.sh` has a batch mode.
- Before the first landing, make sure `main` holds the third-party image cache: a merge group can read
  only its own ref's caches and `main`'s, and a `main` push run that met the registry quota saved
  nothing. `gh workflow run timescale.yml --ref main` once seeds it. The fixers' pushes are a CI storm
  (pass 3: 21 heads, about 90 queued runs, the first landing's checks still queued when `land.sh`'s
  60-minute wait expired); a wait timeout is a restart, not a failure.
- When it stops: read why. A non-list-file conflict is resolved by hand in the worktree it names, then
  pushed; a CI failure that is not a known flake is a real failure, so read the job log before doing
  anything. Never rebase-and-rerun a batch by hand; that is the queue's job.
- When two fixes interact (one changes what a configuration can be, another's guard depends on that
  configuration), the guard is not retired until someone shows the state is unreachable on upgraded
  installs too. Pass 2's #501/#504 case is the precedent (modelled the legacy state in the fixture).

## 4. Close by re-running the reproductions

- `scripts/review/closure.sh --claims $WORK/../pass/claims --out $WORK/closure.json --wait-fix-prs`
  waits until no `fix/*` PR is open, pulls main, brings up the harness (PG15 and the archive service),
  and re-runs every reproduction of the pass against it. It uses a verifier's `repro.verified.sql`
  where one exists.
- Write `$WORK/caveats.json` from the verdicts and the fixers' reports: every reproduction known to be
  unsound, with the reason (the verifiers' rebuilt repros should make this list short).
- `scripts/review/close_comments.py --closure $WORK/closure.json --filed <pass>/filed.json --prs $WORK/prs.tsv
  --sha <main sha> --caveats $WORK/caveats.json --out $WORK/comments` and read the verdicts. A `REOPEN`
  means a sound reproduction still fails: look before posting. Then rerun with `--post`.

## 5. Record and file

- Append a "Fix phase" section to the pass record (`docs/reviews/<date>.md`) and extend its row in the
  pass history table: PRs, landing measurements, hand-resolved conflicts, flakes, interactions, the
  closure table and the explained failures, root causes closed. Open it as a docs PR.
- File the fixers' adjacent observations as issues, grouped by mechanism, marked as unverified; method
  lessons go in one methodology follow-up issue. Add the fixed defects' mutations to the next pass's
  seed pool (they are already in `bench/mutations/`; the record just needs to say so).
- Remove the fixers' worktrees and their merged local branches; leave the record pointing at the PRs.
