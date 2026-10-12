---
name: review-loop
description: Drive one whole loop of the adversarial review method without a human, as its driver. Pins the merge of the previous record PR, runs /review-pass and /fix-phase, opens the record PR, posts the loop summary and the convergence report, and asks scripts/review/stop_check.py whether another loop starts. Keeps the loop's state in loop_state.json, queues every default it applies in decisions_queue.md, and stops on a blocking decision or a dead-man timeout.
argument-hint: "<loop number> [<pin>]"
disable-model-invocation: true
allowed-tools: Bash Read Write Agent
---

You are the **driver** of loop N. A loop is: pin, review pass (`/review-pass`), fix phase (`/fix-phase`:
fixers, per-PR verification, landing, closure, comments, adjacent filing and verification), record PR,
the loop summary and the convergence report, then `stop_check`. You run all of it in this one session,
through compaction, and you are the coordinator of each step in turn: you do not review code for defects
and you do not fix anything yourself. Arguments: `$ARGUMENTS`, the loop number (the pass number it
reviews) and optionally the pin.

Keep the loop's files in a durable scratch directory outside the repository that survives compaction and
a restarted session (`$LOOP`): `$LOOP/loop_state.json` (where you are), `$LOOP/decisions_queue.md` (what
you decided on the user's behalf, and what only the user may decide), and the pass's and the fix phase's
own `$WORK` directories under it. After a compaction, `loop_state.py $LOOP/loop_state.json show` is the
first thing you read.

## 0. Read the orders

- `docs/adversarial-review.md`, "Running a loop without a human" (the standing orders: what is
  pre-authorized, the defaults, the blocking decisions, the budget, the dead-man switch, the self-checks),
  then "Stopping criteria" and "Lenses".
- `scripts/review/stop_check.py --help`, `scripts/review/loop_state.py --help` and
  `scripts/review/decisions_queue.py --help`; `scripts/review/README.md`, "Loop tooling".
- Pre-authorized: everything in the loop except, in loop 12, the record PR's merge, which the user does;
  from loop 13 that too. Nothing else is: see "Blocking decisions" below.

## 1. Start the loop

- The pin is the merge commit of the previous loop's record PR (`gh pr view <record pr> --json
  mergeCommit`), unless `$ARGUMENTS` names one. `git rev-parse` it; record the release it corresponds to.
- `scripts/review/loop_state.py $LOOP/loop_state.json init --loop N --pin <sha>` and
  `scripts/review/decisions_queue.py $LOOP/decisions_queue.md init`. An `init` that refuses because the
  state file exists means this loop already started: `show` it and resume from its phase and step.
- Ask the stopping check where the previous loop left off, before choosing anything:
  `scripts/review/stop_check.py --history docs/adversarial-review.md --records docs/reviews
  --decisions $LOOP/decisions_queue.md`. Its exit must be 0 (continue); 1 means the previous loop should
  not have started this one, so stop and report; 2 is a parse error in a record, so fix the record first.
- The lenses by the cycle rule: fresh surface plus the five least recently used catalogue lenses.
  `stop_check.py` prints them ("next pass lenses by the cycle rule") and the lenses the cycle still owes;
  use its line, and state the previous pass's lenses beside it.
- The seeds: K=9, at least a third novel patches written for this pass, three from
  `bench/mutations/mutate.py --late-survivors` (the late-survivor set the record measures separately).
- `loop_state.py ... set --phase review --step "1: pinned <sha>, lenses <list>"`.

## 2. The review pass

Run `/review-pass <pin> 9 <lenses>` with the budget below. At each of its numbered steps,
`loop_state.py ... set --phase review --step "<n>: <what>"` when the step starts, and `loop_state.py ...
progress` whenever a step advances inside it (a finder returns, a verifier's verdict lands). The record it
writes must carry the coverage line (`pass_metrics.py --coverage $WORK/coverage.json`, the final
`coverage.py --out` after any re-runs), the late-survivor figure and the `capture-recapture (T1):` line
(`--capture-recapture`, saying `estimate <x>[, found <y>]`, `not attempted` or `not computable`);
`stop_check.py` reads all three.

## 3. The fix phase

Run `/fix-phase` on the pass's issues and the re-found open ones, the same way: `set --phase fix --step
"<n>: <what>"` at each numbered step, `--pr <n>` as each fixer reports its PR, `progress` as PRs verify and
land. Apply the standing defaults where a recurring trade-off comes up, and queue each one (see below).
A Tier 1 regression that per-PR verification found and the fixer could not clear in three rounds is a
blocking decision.

## 4. Record, summary, convergence

- `set --phase record`. Open the record PR (the pass record, its fix-phase section, the pass history row).
- `set --phase report`. Write the **loop summary** and the **convergence report**, in the shape the user
  asked for: Tier 1 per pass with its provenance (old surface or young, the pass and PR that introduced
  it) and the lens that found it; the precision and recall series, the read-caught and late-survivor
  figures included; closure; Tier 1 injected by the fix phase; per-PR verification's blocked rounds; the
  stopping status with the lenses the cycle owes (`stop_check.py`'s lines); cost against the ceiling; a
  one-paragraph reading. Add `scripts/review/decisions_queue.py $LOOP/decisions_queue.md render --since N`.
  Post both on the record PR (`gh pr comment`) AND in the chat.
- The record's merge: in loop 12 the user merges it. Before the wait, `loop_state.py ... set --phase waiting
  --step "record PR #N awaits the user's merge"`: `check` reads a waiting loop as ok and reports how long it
  has waited, so a wait for the user never reads stale or dead. Once it has merged, `set --phase stop_check
  --step "record PR #N merged"`, which re-arms the switch. From loop 13, merge it when its checks are green
  and the closure gate holds. Its merge commit is the next loop's pin.

## 5. Stop or continue

```bash
scripts/review/stop_check.py --history docs/adversarial-review.md --records docs/reviews \
  --budget-used <this loop's agent tokens> --decisions $LOOP/decisions_queue.md --json $LOOP/stop_check.json
```

`set --phase stop_check`, run it, post its lines with the convergence report, then `set --phase done
--step "stop_check: <verdict>"`. Exit 0 is **continue**: the next loop starts in a NEW session
(`/review-loop N+1`), not this one. Exit 1 is **stop** with its reason (converged, ceiling, budget, or a
blocking decision): report it and end. Exit 2 is a parse error: a record without the shape the script
reads, fixed in the record PR, never worked around.

## The dead-man switch

Every wakeup (`ScheduleWakeup` in a `/loop`-style session, or the cron the harness provides) runs
`scripts/review/loop_state.py $LOOP/loop_state.json check` FIRST, before anything else:

- exit 0: carry on;
- exit 3 (no progress for over two hours with a phase open): push a notification to the user saying where
  the loop is stuck (phase, step, age), and re-arm the wakeup;
- exit 4 (over six hours): stop, report where and why, and do not re-arm.

Re-arm the wakeup yourself at the end of every turn that leaves work running. Call `progress` only when
something actually advanced; a wakeup that found nothing to do is not progress.

## The standing defaults (applied, recorded, queued; never blocking)

Each one is applied at once and written to the queue with `decisions_queue.py $LOOP/decisions_queue.md add
--loop N --kind <kind> --text "<what and why>" [--issue N] [--pr N]`:

- refuse over warn, unless a test's premise breaks (`default`);
- never drop a channel, a documented feature or a supported version's path (`default`);
- a lint beaten by a new spelling is not chased past one round: document the limit, downgrade the PR to
  `Addresses` (`limit`);
- a Tier 2 that needs a design decision is carried open (`carried`); a Tier 1 never is;
- a known-flaky test is filed, never given a `flake_check.sh` signature (`default`, with the issue);
- a scope change the lessons suggest (`scope`).

## Blocking decisions

These stop the loop. Write `decisions_queue.py ... add --kind blocking --text "<the decision needed>"`,
push a notification, and wait (the dead-man switch keeps running; `stop_check.py` and
`decisions_queue.py ... pending` both read an unresolved `BLOCKING` entry as a stop). Only the user resolves
one (`decisions_queue.py ... resolve D<nn> --by <user> --note "<answer>"`).

- a release or a version bump;
- any outward-facing action beyond this repository (a publish, a message, a post anywhere else);
- a budget extension past the ceiling (about 27M agent tokens per loop: 10M review, 17M fix phase; 48 h
  of wall clock; the campaign runs through pass 13 unless the user extends it, `--extended-through`);
- a destructive action outside the method's own cleanup;
- a Tier 1 regression per-PR verification found that the fixer could not clear in three rounds.

## Do not

- Report a number you have not re-read from an artifact (a record, a JSON, a log) in this session; a
  number carried across a compaction is a claim, not a figure.
- Start a background job without a Monitor on it, or with a bare `nohup`; silence is not success.
- Post the loop summary or the convergence report only in the chat: both go on the record PR as well.
- Take a blocking decision, or work around one, because the loop would otherwise stall.
- Start the next loop in this session, or start it at all on a `stop` or a parse error.
- Edit `loop_state.json` or `decisions_queue.md` by hand; the scripts refuse a malformed file, and a hand
  edit is how one gets malformed.
