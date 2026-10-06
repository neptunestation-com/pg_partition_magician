# pg_partition_magician: adversarial review methodology

How pgpm is subjected to a deliberate, antagonistic search for defects, and when to stop. This is the
process document for a **review pass**: a bounded, adversarial-but-friendly hunt over a pinned commit,
with an independent check on every claim, a measured sensitivity, and a written record. For the
day-to-day testing discipline see the root `CLAUDE.md`; for the guards and their mutations see `bench/`
and `bench/mutations/`.

## Contents

- [Premise](#premise)
- [Definitions](#definitions)
- [Roles and separation](#roles-and-separation)
- [A pass, step by step](#a-pass-step-by-step)
- [Seeding](#seeding)
- [Metrics](#metrics)
- [Stopping criteria](#stopping-criteria)
- [Between passes](#between-passes)
- [Fix phase](#fix-phase)
- [Lenses](#lenses)
- [Pass record](#pass-record)
- [Pass history](#pass-history)

## Premise

Three things are taken as given.

1. **The floor is not zero.** Each successful pass should lower the number and the severity of what the
   next one finds, but testing shows the presence of defects, never their absence. The goal of a pass is
   not to reach zero; it is to lower the expected cost of the defects that remain, and to know when the
   deep-hunt mode has stopped paying.
2. **A method's blind spots are stable.** A second pass with the same method finds fewer defects partly
   because the code improved and partly because the method could never see the rest. A falling yield is
   therefore only evidence about the code when the pass has also shown it could still find defects
   (see [Seeding](#seeding)). Passes rotate their [lenses](#lenses) for the same reason.
3. **A reviewer pushed to find defects will find some that are not there.** This applies to people and
   to models alike, and it gets worse as the real yield falls. The remedy is structural, not
   exhortation: a claim counts only when an executable reproduction survives an independent attempt to
   knock it down, and the reviewer's precision is measured and watched.

These are the same principles the repository already applies to its own tests. A guard must be paired
with a liveness witness that proves the conditions for the defect were present; a pass must be paired
with seeds that prove the conditions for a discovery were present. `./test.sh discriminate` proves a
guard fails against its mutation; the [verifier](#roles-and-separation) proves a finding fails against
the pinned commit and not against a fixed one.

## Definitions

- **Pinned commit.** The `main` SHA a pass reviews. Everything in the pass is stated against it.
- **Claim.** A defect as first reported by a finder. Every claim carries a one-line scenario, the file
  and line it points at, a severity tier, and a reproduction.
- **Reproduction.** An executable script (SQL file, shell script, or pgTAP file) that FAILS against the
  review tree and would PASS once the defect is fixed. A claim without one is a **hypothesis**, kept in
  the record but never counted as a finding and never filed as an issue.
- **Finding.** A claim whose reproduction the verifier has run, confirmed against the pinned commit, and
  failed to explain away. Only findings are filed and counted.
- **Seed.** A known defect the coordinator plants in the review tree before the pass, unknown to the
  finders. Seeds measure the pass's sensitivity; they are never real findings.
- **Review tree.** The pinned commit plus the seeds, delivered to finders as a single commit with no
  history, so that the seeds cannot be read off a diff.
- **Lens.** A named way of looking (concurrency, upgrade paths, time zones, ...). A pass declares its
  lenses up front; the next pass changes them.
- **Tier.** Severity, decided by a rubric before anything is counted:
  - **Tier 1**: data loss, or a silently wrong result (rows dropped, routed to the wrong partition,
    archived incompletely, reported as migrated when they were not).
  - **Tier 2**: a wedge or outage (a table that can no longer be maintained, a lock held for the length
    of a scan, a procedure that cannot make progress).
  - **Tier 3**: acts when it should refuse, or a documented contract not kept, without loss.
  - **Tier 4**: documentation that changes what an operator types, and is wrong.
  - **Tier 5**: a test or guard that passes for the wrong reason.

## Roles and separation

Four roles, and the separations between them are the substance of the method.

| role | does | may not |
|---|---|---|
| coordinator | pins the commit, picks lenses, plants seeds, sets the budget, assembles the record | review code for defects, fix anything |
| finder | reviews one slice of the review tree under the declared lenses, writes claims with reproductions, records what it probed and found sound | edit any file under review beyond adding instrumentation; read `bench/mutations/`, the upstream repository, or any diff of the review tree; see another finder's claims |
| verifier | re-runs every reproduction against the review tree AND the pristine pinned commit, classifies each claim, and tries to disprove the survivors | see the finder's reasoning, only the claim and its reproduction; fix anything |
| fixer | fixes a filed finding in its own PR with a guard and a mutation, per `CLAUDE.md` | be the finder or verifier of that finding |

A finder who needs to change pgpm to make a reproduction fail has not found a pgpm defect. A verifier
who cannot make the reproduction fail on the pristine commit has found a seed, a test artifact, or
nothing; none of the three is filed.

## A pass, step by step

1. **Pin.** Record the `main` SHA, the release it corresponds to, and the date.
2. **Set the budget.** Agent-hours or tokens per finder, number of finders, and a wall-clock limit. The
   budget is fixed before the pass so cost per finding is comparable across passes.
3. **Declare lenses.** Choose from the [catalog](#lenses), at least half of them different from the
   previous pass. The freshly merged surface since the last pass is always one lens: hand-resolved
   merge regions and interactions between recent fixes are where new defects concentrate.
4. **Seed.** Plant `K` seeds (see [Seeding](#seeding)); record which, where and their tiers in a sealed
   file the finders cannot read. Build the review tree as one history-less commit.
5. **Hunt.** Finders work their slices in parallel, in isolated worktrees on the review tree. Each
   produces a claims file and a null-results file (what was probed, how, and found sound).
6. **Verify.** For every claim the verifier runs the reproduction twice:
   - fails on the review tree, passes on the pristine commit: a **seed hit**;
   - fails on both: a **candidate**; the verifier then tries to disprove it (is the behaviour
     documented and intended, is the reproduction exercising a test artifact, does it need a state pgpm
     refuses to enter) and either confirms it as a finding or records why it fell;
   - fails on neither, or needs the finder's environment: **not reproduced**, dropped;
   - fails on both and matches an issue still open from an earlier pass: **known and open**, recorded
     against that issue and not counted as a new finding. The verifier alone holds the open-issue list
     (see [Between passes](#between-passes)).
7. **Triage.** Tier every finding by the rubric. Group findings that share a root cause and a fix.
8. **Measure.** Fill in the [metrics](#metrics). Compute precision and seed recall before anyone looks at
   the count of findings, so the count is read in light of them.
9. **File and fix.** One issue per finding or group; one PR per issue, each with a guard and a mutation,
   merged in a dependency-aware order with a rebase and a fresh CI run before each merge.
10. **Record.** Commit the [pass record](#pass-record). The raw claims and reproductions can stay in a
    local `notes/` file; the record is what the next pass reads first.

## Seeding

Seeds make a quiet pass meaningful. Without them, "found nothing" and "could not have found anything"
look the same.

- **Source.** Start from `bench/mutations/mutate.py`, which already holds one exact, reviewed defect per
  guard. Because finders may have seen that file in earlier sessions, at least a third of the seeds in
  every pass are **novel**: written for the pass, in the style of the catalogue, and added to it only
  after the pass so the next one cannot reuse them.
- **Placement.** Seeds cover the declared lenses and span tiers 1 to 3. A seed should be as quiet as the
  real defects the pass is hunting: a dropped re-check under a lock, an off-by-one at a grid boundary, a
  `%I` where a `_q` fragment is spliced. Loud seeds (a raise in a hot path) measure nothing.
- **Count.** `K` between 6 and 10 for a pass of six to eight finders. Fewer gives recall too coarse to
  read; more starts to shape what finders look at.
- **Suite check.** Before the hunt, every seed is planted alone and the tree's own pgTAP suite run against
  it (`plant_seeds.py --suite`); the files that catch it are sealed with the seed. A seed the suite catches
  measures that a finder ran the tests, not that a lens saw the defect: in pass 4 every seed had a
  test-file guard, and one finder found all nine by running the suite before reading a line. Plant most
  seeds where no test catches them, and read recall by its read-caught half.
- **Blindness.** Finders never see the seed list, `bench/mutations/`, or any diff. The review tree has one
  commit and no remote. Novel seeds are kept in a sealed file the coordinator alone reads until the pass
  closes.
- **After the pass.** Every seed that no finder reported is a blind spot. Record it against the lens
  that should have caught it, and carry that lens into the next pass.

## Metrics

Recorded per pass, in this order, so the count of findings is never read alone.

| metric | definition |
|---|---|
| budget | finders, agent-hours or tokens per finder, wall-clock |
| seeds `K`, recall | seeds planted; fraction reported by at least one finder; from pass 5 also split into suite-caught (the pgTAP suite run on the seeded tree fails, so a finder that ran the tests found it) and read-caught (it does not, so only reading finds it), each as hits over count |
| claims | total claims across finders |
| findings | claims that survived verification |
| per finder | claims, precision and coverage for each finder, with the model it ran on when the pass split model tiers |
| slice coverage | units of a finder's slice (functions and procedures of an install.sql slice, files of a tests, bench, docs or scripts slice) its coverage ledger marks read, over units in the slice, scored by `scripts/review/coverage.py` before classification; a slice below 0.9 is re-run or split first. From pass 8. A missed seed is then either read-and-missed (a reading blind spot) or unread (a budget or slicing fault), and only the first kind says anything about the lenses |
| precision | (findings + seed hits + verified known-and-open re-finds) / claims that had a reproduction; a correctly reported seed is a true report, and so is a reproduced defect an earlier pass's issue already names; a hypothesis is not a claim. Reported with the **strict** figure, (findings + seed hits) / claims, beside it: the share of true reports that were new |
| fell rate | claims that fell in verification / claims that had a reproduction: the reaching alarm. A claim that falls is the one shape a reviewer pushed for defects produces when there are none; a re-find is not |
| findings by tier | Tier 1 through Tier 5 |
| root causes | distinct root causes behind the findings, and how many the fix phase closed as a class rather than an instance |
| known and open | re-found findings from earlier passes still unfixed |
| cost per finding | budget / findings, and budget / Tier 1 findings |
| null results | slices probed and found sound, by lens |
| capture-recapture estimate | when two independent hunts run on the same commit: `n1 * n2 / overlap` for Tier 1, minus what was found |
| blind spots | seeds missed, by lens |

The curve the metrics are meant to draw across passes: findings and Tier 1 findings falling, cost per
finding rising, recall staying high, precision staying high, the fell rate staying low. The fell rate
rising while yield falls is the signature of a reviewer reaching; it means change the method, not push
harder. The strict figure falling on its own is a different signal, the size of the backlog finders
cannot see (pass 7: 23 of 69 claims re-found nine open issues, 19 of them for the first time with a
reproduction, while 2 claims fell), and its remedy is the "backlog verified before the pin" rule below.

## Stopping criteria

The deep-hunt mode ends when ALL of the following hold, judged on the two most recent passes:

1. **Zero Tier 1 findings** in each of two consecutive passes, and
2. **seed recall of at least 0.8** in each of those passes (so the zero was earned); from pass 5, the
   read-caught recall when the suite check measured the split; from pass 8, with every slice's coverage
   at 0.9 or above before classification (passes 6 and 7 read 0.56 twice with the missed seeds in
   units no finder had opened, which is a budget fault, not a reading result), and
3. **precision of at least 0.7** in each, counting verified known-and-open re-finds as true reports, and
   **a fell rate of at most 0.3** (so the passes were not reaching), and
4. **the capture-recapture estimate for Tier 1 rounds to zero**, when two independent hunts were run, or
   the estimate was not attempted and criteria 1 to 3 hold for three passes instead of two.

Stopping does not mean no scrutiny. It means the standing mode changes to:

- **per-PR adversarial verification**: every PR touching `pgpm_core/install.sql` or `pgpm_archive/`
  gets a verifier pass on its claims (the CHANGELOG bullet, the guard, the mutation) with the same
  fail-then-pass rule;
- **a full pass after any release, and after any merge batch of more than five PRs**, since a batch of
  fixes is new surface with new interactions.

A pass is also **abandoned early**, and the method revised, if the fell rate exceeds 0.5 mid-pass.

## Between passes

A pass has a counterpart, the fix phase, and the next pass stands on it. A pass whose findings were
not fixed re-finds them, its yield does not fall because nothing changed, and the curve the metrics are
meant to draw says nothing. The rules that keep the loop honest:

- **Pin on the fixes.** Pass N+1 pins a commit that contains the fixes for every Tier 1 and Tier 2
  finding of pass N. Lower tiers may be deferred, but each deferred finding stays open as an issue.
- **Known and open is a class, not a finding.** The verifier, and only the verifier, holds the list of
  issues still open from earlier passes. A re-found one is classified **known and open** and recorded
  against its issue, with its reproduction (for most of the backlog's bullets, the first one). Finders
  never see the list, so it cannot steer what they look at. It is a true report for precision, since it
  is a reproduced defect; it is not a finding, since it is not new. An open issue that gained a
  reproduction this way joins the next fix phase's list beside the pass's own issues: the reproduction
  is its acceptance test now.
- **The backlog is verified before the pin.** A fix phase ends with the fixers' adjacent observations,
  filed as issues marked unverified. Before the next pass is pinned, each bullet of those issues gets a
  verifier (one `verifier` agent per bullet, against `main`, about 40k tokens): a bullet that reproduces
  gets its reproduction and a tier on the issue, one that does not is struck out, and an issue with
  nothing left is closed. Left unverified at the pin, those bullets become the next pass's re-finds
  (pass 7's 23 came almost entirely from #766 to #775 and #813 to #819, filed one to three days before),
  which costs a verifier run each to re-discover and leaves Tier-1-shaped mechanisms sitting unmeasured
  in the tree that the finders are reviewing.
- **A fix is a guard and a mutation, or it is a patch.** Per `CLAUDE.md`, every fix PR carries a guard
  that would fail with the defect present and a mutation in `bench/mutations/` that puts the defect
  back, proven by `./test.sh discriminate`. The guard keeps the fix honest now; the mutation keeps a
  later refactor from quietly undoing it. Without both, the floor can sink back and the next pass
  cannot tell a new defect from a resurrected one.
- **The reproduction is the acceptance test.** A finding is closed when its original reproduction
  passes against the fixed `main`. That is the verifier's last act for each finding, and it makes the
  reproduction a regression test rather than a one-off.
- **Fixed defects become seeds.** Every real defect this codebase produced is the best possible seed
  for a later pass, because it is quiet in exactly the way its siblings are. After the fix phase, add
  each fixed defect's mutation to the catalogue if the fix PR did not already.
- **Judge the fix phase on classes.** Pass 1's 25 issues came from about seven root causes. A fix that
  removes the cause removes a class; one that patches the symptom leaves siblings for the next pass to
  find. Record root causes closed alongside findings fixed.
- **Fixes are new surface.** A batch of fix PRs, and the hand-resolved merge regions between them, is
  where the next pass's defects concentrate. The floor rises as a ratchet with a small backlash, not
  monotonically, which is why the fresh-surface lens is mandatory and why a full pass follows any large
  merge batch. Finding a defect that a fix introduced is the process working.

The loop, in full: pin, hunt, verify, file, fix with guard and mutation, close each finding by its own
reproduction, merge the batch with a rebase and a fresh CI run per PR, pin again.

## Fix phase

The fix phase is the pass's counterpart and it is run with the same separation of roles. The
**coordinator** (`/fix-phase`) assigns, spawns, lands and closes; it fixes nothing. One **fixer**
agent per issue, or per group of issues that share a mechanism, works in its own worktree under
`CLAUDE.md`'s rules and opens one PR. The issue's verified reproductions are that PR's acceptance
test. Pass 2's fix phase (27 issues, 24 PRs, 2026-09-25 to 2026-09-26) is the measured baseline for
what follows.

- **Assign before spawning.** Parallel fixers collide on test file numbers, guard database names and
  scratch space unless the coordinator hands them out first. Pass 2 ended with seven test files
  numbered 124 because each fixer took "the next free" one. Numbers are assigned in the brief.
- **Gate locally, then let the queue test the tree.** Every PR passes `./test.sh 15 --channel=psql` on
  its own head before it is landed; the merge queue then runs every track on the exact tree it merges,
  which is what catches a pair of fixes that were each green alone.
- **Land in order, one at a time, with `scripts/review/land.sh`.** Under a squash queue this cannot be
  pipelined: a squash commit has no ancestry link to its branch, so once PR k-1 lands, PR k conflicts
  with `main` in the three list files every fix appends to and must be rebased and re-checked before
  it can be queued. Stacking PRs on each other does not help; the queue's own merge sees the same
  conflict. Measured: about 24 minutes per PR, a 10-hour landing for 24 PRs. The alternative is a
  merge-commit queue, which preserves ancestry and allows groups of five, at the cost of merge commits
  and the fixers' individual commits in `main`'s history. That is a ruleset decision (the merge queue
  rule's `merge_method`), made by the maintainer, not by the tooling. Pass 3's fix phase (39 issues,
  24 PRs, 2026-09-28 to 2026-09-29) measured a 28-minute median per PR and 17.8 hours end to end under
  squash, with nine stops for a hand; the maintainer switched the queue to merge commits on 2026-09-29,
  after its last PR merged. `land.sh --batch` (up to five PRs stacked, checked in parallel, enqueued in
  turn as each predecessor merges) and `landq.sh --batch 5` are the tooling for it; pass 4 measures what
  it saves.
- **Retry only a known flake, once.** `flake_check.sh` matches a failed run against narrow signatures
  (the failing assertion, its liveness witness green, nothing else red); anything else stops the
  landing for a human. A signature nobody can point at an issue for is a way of hiding a regression.
- **When two fixes interact, the guard stays.** A fix that changes what a configuration can be will
  meet another fix's guard that depends on that configuration; the guard's `LIVENESS:` witness is what
  makes the meeting legible. The guard is not retired until someone shows the state is unreachable on
  upgraded installs too, not merely through the API. Precedent: #504 made a naive column's grid UTC
  by construction, and #501's guard now rebuilds the pre-#504 legacy grid by hand, still discriminated.
- **Pace the pushes.** A batch of heads pushed at once is a CI storm: pass 2's seventeen heads queued
  45 runs against a limit of 20 concurrent jobs and exhausted a registry's anonymous pull quota. Third-
  party images are cached in the workflows; heads are pushed as the queue reaches them. Pass 3's
  twenty-one heads queued about 90 runs, and the cache never reached `main` (a merge group reads only
  its own ref's caches and `main`'s, and `main`'s runs had met the quota): seed `main` deliberately, and
  give the PR workflows a `concurrency` group so a rebase cancels the superseded head's runs.
- **Close by re-running the reproductions.** `closure.sh` re-runs every reproduction of the pass against
  the fixed `main`, using the verifier's rebuilt version where one exists; `close_comments.py` posts
  the evidence on each issue and reopens one whose sound reproduction still fails. Every reproduction
  that still fails is either explained in a caveat that says why it is unsound, or it is a reopen.
- **Record it.** The pass record gets a fix-phase section: PRs, landing measurements, hand-resolved
  conflicts, flakes and their signatures, interactions, the closure table and the explained failures,
  root causes closed. The fixers' adjacent observations are filed as issues, marked unverified, and
  verified bullet by bullet before the next pass is pinned ("The backlog is verified before the pin",
  above).

## Lenses

The catalogue to rotate through. Each pass names the ones it uses and states, in the record, which were
used last time.

- **Fresh surface** (always): regions merged since the last pass, hand-resolved conflict hunks first,
  then interactions between the recent fixes.
- **Concurrency and locks**: check-then-act across a lock, what a second session sees between commits,
  triggers under `session_replication_role`, advisory-lock reaping.
- **Time and zones**: session `TimeZone`, DST, `now()` versus data frontier, naive versus aware types,
  clock skew.
- **Boundary arithmetic and types**: grid floors and steps at partition edges, integer versus numeric
  division, `name` truncation, text collation versus bytewise order, `uuid` and `text_time` encodings.
- **Upgrade and install paths**: every released version to `main`, stale overloads, backfilled columns,
  `uninstall.sql` residue, bundles versus `install.sql`.
- **Identity and names**: `search_path`, same-named relations, oid anchors versus rendered names.
- **Operator error**: negative or zero knobs, wrong-type arguments, re-running a step, hand edits to
  `pgpm.config`.
- **Failure injection**: a crash or cancel between a procedure's commits, a failed archive upload, an
  archive_fn that lies about `covered_hi`.
- **Contracts versus documentation**: what the reference promises against what the code does, and what
  the runbook tells an operator to type.
- **Tests that pass for the wrong reason**: `count = count` assertions, `throws_ok(NULL)`, probes that
  starve what they measure, guards without a discriminating mutation.
- **Resource cliffs**: memory in the encoders, unbounded loops, statement timeouts that accumulate
  across internal commits.

## Pass record

One file per pass, committed under `docs/reviews/` as `YYYY-MM-DD.md`, in this shape:

```markdown
# Review pass N: YYYY-MM-DD

pinned: <sha> (<release>) | budget: <finders> x <hours or tokens>, <wall-clock>
lenses: <list> | previous pass lenses: <list>
seeds K=<n>, recall <r> (suite-caught <a>/<b>, read-caught <c>/<d>); claims <c>; findings <f>; precision <p> (strict <s>, fell rate <e>)
findings by tier: T1 <n> T2 <n> T3 <n> T4 <n> T5 <n>
cost per finding: <x>; per Tier 1 finding: <y>
root causes: <n> behind the findings, <m> closed as a class by the fix phase
known and open (re-found, unfixed from earlier passes): <n>
capture-recapture (T1): <estimate or "not attempted">
blind spots (seeds missed, by lens): <list>

## Findings
| tier | finding | issue | fix PR |

## Null results (by lens)

## Hypotheses (not counted)

## Stopping criteria status
```

## Pass history

| pass | date | pinned | findings (T1) | claims | precision | seeds / recall | notes |
|---|---|---|---|---|---|---|---|
| 1 | 2026-09-24 | `a72c5bf` (0.6.0) | 76 (25 filed as T1: #441 to #465) | ~106 | not measured | none | eight finders plus a coordinator; no independent verifier; the 76 each had a reproduction but at least one premise (#441's version range) was later corrected, so precision is unknown. Fixed by #466 to #490, merged 2026-09-25. Baseline only. |
| 2 | 2026-09-25 | `581e87a` (0.6.0 + 30) | 49 (7 T1; 44 distinct defects in 27 root-cause groups: #496 to #522) | 73 | 1.00 | 9 / 1.00 | ten finders (eight slices, two duplicated on a second model), one verifier per candidate, planted seeds, all under the method; five reproductions rebuilt by verifiers; five tooling defects found and fixed while running; fix phase closed all 27 root-cause groups by 2026-09-26 (PRs #525 to #549; 62 of 73 reproductions pass on `56b3b40`, the eleven others explained), follow-ups #550 to #558; see [the record](reviews/2026-09-25.md). |
| 3 | 2026-09-28 | `db64096` (0.6.0 + 64) | 55 (9 T1; 46 distinct defects in 39 root-cause groups: #563 to #601) | 73 | 0.92 | 9 / 1.00 | ten finders (eight slices, S3 and S8 duplicated: opus primary, fable duplicate), one verifier per candidate plus one tie-breaker, three reproductions rebuilt and stored, four known-and-open re-finds recorded on their issues, two fell; 4.44M agent tokens, 1 h 35 min hunt to last verdict; fix phase closed all 39 root-cause groups by 2026-09-29 (PRs #603 to #626, 23 fixers, 28-minute median landing under squash, nine hand interventions; 65 of 73 reproductions pass on `46e1d45`, the eight others explained), follow-ups #627 to #644; the merge queue was switched to merge commits after its last PR; see [the record](reviews/2026-09-28.md). |
| 4 | 2026-09-29 | `b52a0d9` (0.6.0 + 97) | 32 (7 T1; 28 root-cause groups: #649 to #676) | 69 | 0.86 | 9 / 1.00 | ten finders (eight slices, S3 and S8 duplicated: opus primary, fable duplicate), one verifier per candidate; the eight lenses were pass 3's, unchanged, by the maintainer's decision to measure the fixes under a fixed method (a recorded deviation from the rotation rule); one reproduction rebuilt; ten claims re-found eight open issues and are recorded on them with reproductions; nothing fell; 3.68M agent tokens, 32 min from hunt start to last verdict; every seed had a test-file guard, so the finder that ran the suite found all nine before reading; fix phase closed all 28 root-cause groups and the eight open issues that completed their classes by 2026-09-30 (PRs #680 to #704, 24 fixers, batches of up to five under the merge-commit queue; 127-minute median per PR that is mostly queue position, 39 minutes per PR of wall clock against pass 3's 27; nine hand-resolved conflicts, two code interactions, three instrument defects fixed as #714, #716 and #717; 66 of 69 reproductions pass on `ff01584`, the three others explained), follow-ups #705 to #713; see [the record](reviews/2026-09-29.md). |
| 5 | 2026-10-01 | `47a293a` (0.6.0 + 173) | 27 (2 T1; 22 root-cause groups: #723 to #744) | 59 | 0.80 | 9 / 0.89 (suite-caught 2/2, read-caught 6/7) | ten finders (eight slices, S1 and S8 duplicated: opus primary, fable duplicate), one verifier per candidate; six lenses, three of them new (identity and names, contracts versus documentation, tests that pass for the wrong reason) beside fresh surface, upgrade and install paths, concurrency and locks; seven of nine seeds novel and planted where the pgTAP suite does not look, measured by the new suite check before the hunt; the one miss was a bench guard's assertion weakened to a count, under the lens that owned it, whose finder ran out of budget before the guards; one reproduction rebuilt (a seed found through an unsound script); twelve claims re-found eight open issues (#634, #635, #640, #706, #707, #708, #710, #711) and are recorded on them with built reproductions, five of those issues' first; nothing fell; on the duplicated slices the fable finder found six new Tier 3 defects and no seed on S1 while the opus finder found four seeds and no new defect; 3.88M agent tokens, 26 min from hunt start to last verdict; fix phase closed all 22 root-cause groups and the eight open issues that completed their classes on 2026-10-01 (PRs #746 to #763 and the workflow PR #764, 18 fixers, batches of up to five under the merge-commit queue; 99-minute median per PR that is mostly queue position and restarted head-check rounds, 39 minutes per PR of wall clock as in pass 4; three hand-resolved conflicts in one paragraph of the reference, one real CI failure repaired at landing, a GitHub-side push-event stall; 58 of 59 reproductions pass on `d2faa7d`, the one other explained), follow-ups #766 to #775, the novel seeds catalogued in #776; see [the record](reviews/2026-10-01.md). |
| 6 | 2026-10-01 | `ae5dddc` (0.6.0 + 220) | 23 (5 T1 claims in 4 groups; 19 root-cause groups: #778 to #796) | 41 | 0.78 | 9 / 0.56 (suite-caught 2/2, read-caught 3/7) | ten finders (eight slices, S7 and S8 duplicated: opus primary, fable duplicate), one verifier per candidate; six lenses, four rotated back in after two passes out (time and zones, boundary arithmetic and types, operator error, failure injection) beside fresh surface and the carried tests-that-pass-for-the-wrong-reason; the bench guards got a slice of their own, duplicated across both models; all nine seeds novel and seven planted where the suite does not look; the first pass whose recall is below the criteria's 0.8: three of the four missed seeds were noticed by a finder and written up as hypotheses rather than built, one (a count where identity was the claim, in tests/194) was read by three finders and judged sound; one reproduction rebuilt (a tick count too short); nine claims re-found seven open issues (#712, #713, #766, #767, #768, #769, #773) and are recorded on them with built reproductions, five of them first ones; nothing fell; on the duplicated fresh-surface slice both models found the same Tier 1 (RC1) and nothing else at that tier, so the capture-recapture estimate is zero there while three Tier 1 groups came from single-finder slices; 3.31M agent tokens, 35 min from hunt start to last verdict; the archive harness came up without its MinIO bucket and the suite check's archive control failed 19 of 27 files before the bucket was created by hand (two tooling lessons in the record); fix phase closed all 19 root-cause groups on 2026-10-02 (PRs #799 to #812, 14 fixers in one wave, 58 minutes to the last PR; batches of up to five under the merge-commit queue; 93-minute median per PR from landing start to merge, 42 minutes per PR of wall clock, 9.7 h for 14; one hand-resolved conflict in the reference's transmute entry, two real CI failures repaired at landing (a `throws_like` pattern `bench/throws_pinned.sh` could not probe, and the two timescale wrappers #806 added without #807's shared verdict block: a fix-fix interaction the new guard caught), one known flake, two false stops from check runs shared across two PRs' SHAs; 33 of 41 reproductions pass on `107da01`, every finding's among them, the eight others the re-finds of open issues this phase did not take), follow-ups #813 to #819; see [the record](reviews/2026-10-01-pass6.md). |
| 7 | 2026-10-02 | `4060f6b` (0.6.0 + 254) | 35 (6 T1 claims in 5 groups; 28 root-cause groups: #821 to #848) | 69 | 0.97 (strict 0.64; fell rate 0.03) | 9 / 0.56 (suite-caught 0/0, read-caught 5/9) | ten finders (eight slices, S7 and S8 duplicated: opus primary, fable duplicate), one verifier per candidate; six lenses, three rotated back in (identity and names, concurrency and locks, resource cliffs) beside fresh surface and the two carried blind-spot lenses; nine seeds all planted where the suite does not look: four of them pass 6's missed novel patches re-planted verbatim, and all four were missed again (two not reached, two read and judged sound), while every novel seed written for this pass was found; one method addition, a bounded round 2 in which each finder built its own hypotheses (24 claims, 14 findings of which 3 Tier 1, 8 re-finds, 2 fell, 0 seeds, about 1.05M tokens); 23 claims re-found nine open issues (#555, #632, #768, #769, #814, #815, #816, #817, #819) and are recorded on them with built reproductions, 19 of them the issue's first, which is why strict precision reads 0.64 against 0.97 counting them; three claims fell, one of them a seed whose unsound pristine assertion a verifier rebuilt (then a hit); five reproductions rebuilt; 4.96M agent tokens, 51 min from hunt start to last verdict; a fleet-image segfault on `grant ... to current_user` restarted the timescale harness once; method lessons #849; fix phase closed all 28 root-cause groups and 19 reproduced bullets of nine older issues on 2026-10-03 (PRs #852 to #870, 19 fixers in two waves, 86 minutes to the last PR, 4.09M fixer tokens; batches of up to five under the merge-commit queue, 23-minute median per PR in the queue, 12.9 h for 19 of which 2.9 h were #852's three enqueues while the queue's 60-minute check timeout dropped it twice behind the fixers' CI storm; three hand-resolved conflicts, every one two fixes composing; no real CI failure; one known flake, the runner-dependent `regrain_perf.sh` discrimination now #871 with a `flake_check.sh` signature; 59 of 69 reproductions pass on `9f2efa6`, every finding's among them but #837's #709-blocked assertion, the others #817's stated one-tick window, two spelling-pinned reproductions and the two claims that fell), 42 adjacent observations filed as #872 to #881 and verified before the pass-8 pin (29 of 29 bullets verified by one verifier agent each: 23 confirmed with a reproduction and a tier, five of them Tier 1, 6 struck, #880 closed), method lessons #882; on the convergence assessment (Tier 1 at 2, 4, 5 across passes 5 to 7 plus five more from the verification, nearly all in four classes fixed site by site) a lever phase preceded pass 8 (#884): four class levers with exhaustiveness checks landed as #885 to #888 on 2026-10-03 (recorded identity with a moved-parent conformance suite, reads under RLS with a catalog-enumerating conformance suite at 19 sites, one archive key function with a static single-assembly check, the null regrain mark with an in-flight upgrade stage), the five open Tier 1 closed through them (#872, #873, #878), their uncovered sites in #890, and the finder coverage ledger (#889) for pass 8's recall; see [the record](reviews/2026-10-02-pass7.md). |
| 8 | 2026-10-04 | `ddf130c` (0.6.0 + 311) | 37 (4 T1 claims in 3 groups; 28 root-cause groups: #892 to #919) | 72 | 0.92 (strict 0.78; fell rate 0.08) | 9 / 0.89 (suite-caught 1/1, read-caught 7/8) | thirteen finders on eleven slices plus a re-run finder (S5 and S8 duplicated: opus primary, fable duplicate; the bench guards and the tests each split in two so the new coverage ledger could gate every slice at 0.9), one verifier per candidate; six lenses, three rotated in (upgrade and install paths, operator error, contracts versus documentation) beside fresh surface and the two carried blind-spot lenses; nine seeds, three of them pass 7's missed patches carried a second time: two found (tests/194's count through the mechanical pre-pass written into the brief, the janitor's isolation in round 2) and the bench sum-only one missed a third time by a finder who read the guard, wrote the hypothesis and did not build it; the first pass whose coverage was measured: thirteen slices at 1.00, the fresh-surface slice at 0.62 then completed by a fresh finder on its 37 unread units, which found a Tier 1 there; four Tier 1 claims in three groups (the capture trigger judged by existence rather than ENABLE ALWAYS, with its upgrade sibling rebuilt by a verifier from a real v0.6.0 install; forget_missing leaving the detach job armed; the hypertable drains' unqualified scratch-table drops), the null-argument class in transmute and extend_to as one Tier 2 group of six claims; ten claims re-found five open issues (#773, #875, #877, #881, #890) and are recorded on them with reproductions; six fell (two of them on states no release or no real run reaches); three reproductions rebuilt; 7.49M agent tokens, 17:28Z to about 19:10Z on 2026-10-04 after a 21-hour suite-check hang on a seed that removed a lock_timeout (withdrawn and replaced); fix phase closed all 28 root-cause groups and 10 reproduced bullets of five older issues on 2026-10-05 (PRs #922 to #948, 27 fixers in two waves, 158 minutes to the last PR, 4.36M fixer tokens; batches of up to five under the merge-commit queue, 29-minute median per PR from its last enqueue to its merge, 18.9 h for 27 with no group dropped by the queue's check timeout; two hand-resolved conflicts, both two fixes composing in one file, one of them also dropping a stray duplicate guard entry a previous landing had left on main; two real CI failures, both a new check meeting the merged main (a drift arm that starved an old mutation's path to its guard, which had also been passing on a setup failure; a docs guard that read a neighbouring PR's new prose as its symptom), both repaired on their branches by their fixers; one known flake; closure 65 of 72 reproductions passing on `e19b362`, the rest the six fell claims and one reproduction unsound after the fix; 41 adjacent bullets filed as #949 to #963 and verified before the pass-9 pin: 24 confirmed (one Tier 1, three Tier 2, eleven Tier 3, nine Tier 5), 17 struck, #953 and #960 closed; method lessons #964); a lever phase followed on 2026-10-05 (#966): two levers, #967 one preflight every converting entry point inherits (null arguments at every public routine from a pg_proc sweep, one control-type contract that also judges a resumed bound, one key gate shared with from_hypertable) and #968 scratch relations minted owner-only and resolved by record with ownership following the table's owner, closing the Tier 1 and three Tier 2 of the verified backlog and a Tier 1 found on the way; landed through a GitHub runner incident with a new `runner_not_acquired` flake signature; residue #969 verified before the pin (six confirmed, among them a Tier 1 on the upgrade path inside the scratch lever's stated gap, five struck) and closed by #971 and #972; pass 9 pinned on #972's merge; see [the record](reviews/2026-10-04-pass8.md). |
| 9 | 2026-10-06 | `06643c8` (0.6.0 + 389) | 44 (5 T1 claims in 4 groups; 31 root-cause groups: #974 to #1004) | 80 | 0.96 (strict 0.90; fell rate 0.04) | 9 / 0.89 (suite-caught 3/3, read-caught 5/6) | fifteen finders on eleven slices plus two coverage re-runs (S6 and S8 duplicated: opus primary, fable duplicate), one verifier per candidate; six lenses, three rotated in (identity and names, concurrency and locks, boundary arithmetic and types) beside fresh surface, upgrade and install paths and the carried tests-that-pass-for-the-wrong-reason lens, in its fourth pass; nine seeds, one carried (the bench sum-only seed, found in round 1 on its fourth planting, through the brief's rule that every pre-pass line marked claimed is built first), five novel on the two levers' surface, three from the catalogue's pass-8 fix mutations; the one miss (the anchor half of `_id_step_contract`) was a planting error: `_control_bound_contract` refuses the bound downstream, so two finders read the site and judged the consequence a wrong remedy only; two catalogue seeds were loud (`-- MUTANT` markers in the replacement text) and one had drifted to removing untransmute's whole lock-and-capture block (twenty pgTAP files, five claims, three attributed by the coordinator); coverage gated two slices and both re-runs found what the first read missed (F10r three Tier 5, F6r two Tier 3 and a Tier 4); five Tier 1 claims in four groups (the scratch mint leaving the delta's identity sequence at default privileges, so a stranger's `setval` makes the swap drop rows; the archive strategies' direct-call guard checking the range's shape and never the ledger's chunk, so a direct call after retire or with a shorter range overwrites the only copy; the export claim keyed by the parent alone; the ledger storing a strategy's offset-less bound, read past hi in another zone), 2 Tier 2, 16 Tier 3, 3 Tier 4 and 18 Tier 5, nine of them count-for-identity assertions in test files the fix phases wrote; five claims re-found four open issues (#639, #713, #766, #956) and are recorded on them with reproductions; three fell; eleven reproductions rebuilt; 7.97M agent tokens, 14:49Z to 15:57Z on 2026-10-06; method lessons #1005; see [the record](reviews/2026-10-06-pass9.md). |

From pass 7 the precision column counts verified re-finds of open issues as true reports and gives the
strict figure beside it. Passes 2 to 6 recorded the strict figure; recomputed under the current definition
from their records (findings, seed-hit claims, re-finds and fallen claims over claims) they read 1.00,
0.97, 1.00, 1.00 and 1.00, with fell rates of 0, 0.03, 0, 0 and 0: the slide from 1.00 to 0.78 was the
known-and-open share of claims rising from 0 to 22 percent, not reaching.

Pass 1 predates this document and is recorded as the baseline it is: a high yield with no measured
sensitivity or precision. Pass 2 was the first to run under the method above; its record is the first
under `docs/reviews/`.
