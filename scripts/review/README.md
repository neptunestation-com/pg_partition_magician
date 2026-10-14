# scripts/review: tooling for an adversarial review pass

The mechanical parts of a review pass as defined in [`docs/adversarial-review.md`](../../docs/adversarial-review.md).
Everything here is a script; nothing here judges a claim. The `/review-pass` skill (`.claude/skills/review-pass/`)
walks a coordinator through them in order, and the `finder` and `verifier` agents (`.claude/agents/`) are
the two model roles.

| script | step | what it does |
|---|---|---|
| `build_review_tree.sh <sha> <dir>` | 4 | the pinned commit as ONE history-less commit in a fresh repo with no remote; `bench/mutations/` removed |
| `plant_seeds.py --tree --pristine --plan --sealed` | 4 | applies catalogue mutations and novel patches from a plan, writes the sealed record (with each seed's `side_effects` and `late_survivor`), keeps the tree at one commit |
| `plant_seeds.py --suite --sealed --pristine --seeds-dir` | 4 | plants each sealed seed alone and runs its module's pgTAP suite against it in the harness; seals the files that caught it as `suite_caught` (empty: only reading finds it), so the record can split recall into suite-caught and read-caught |
| `classify_claims.py --claims --review-tree --pristine-tree --sealed --out` | 6 | runs every reproduction (the verifier's `repro.verified.*` when present) against both trees in a fresh database each, in the harness the claim's `install` list needs; classifies seed hit, candidate, not reproduced, inverted, invalid reproduction, invalid claim, hypothesis; `--only <id>` reads that one claim directory and needs no `--sealed` |
| `pass_metrics.py --sealed --classified --verdicts ... [--ages] [--coverage] --out` | 8, 10 | recall (with the late-survivor figure) and precision before the count; writes the pass record under `docs/reviews/`, its findings tagged with age and lens, with the seed interactions to check; `--coverage` takes `coverage.py --out`'s JSON and writes the `coverage: <min> (<n> of <m> finders at or above 0.90)` line `stop_check.py` reads; the `exact:` line carries recall, precision and fell rate as fractions, which `stop_check.py` judges the thresholds on; a candidate with no verdict or an unknown verdict string is unverified, never fell, and an unknown string is refused (exit 2) |
| `file_issues.py --groups --claims --verdicts --pinned --pass --out [--post]` | 10 | one issue body per root-cause group with its age, lens and reproductions inline; `--post` files them, Tier 1 first, and writes `filed.json` |

Each Python script has a `--selftest` that CI runs (`.github/workflows/lint.yml`, "Review tooling self-test").
The per-PR mode's scripts are listed under [Per-PR verification tooling](#per-pr-verification-tooling), the
autonomous loop's under [Loop tooling](#loop-tooling).

## Claim format

One directory per claim, grouped by finder. The finder writes it; nothing else does.

```text
<claims>/<finder>/<claim-id>/claim.json
<claims>/<finder>/<claim-id>/repro.sql            or repro.sh
<claims>/<finder>/<claim-id>/repro.verified.sql   or repro.verified.sh   (the verifier's, optional)
```

The one exception to "nothing else writes it": a verifier that changed the fixture or the assertions
stores its rebuilt reproduction as `repro.verified.sql` (or `.sh`) beside the finder's, which it never
edits. When that file exists, `classify_claims.py` runs it instead of the finder's (recording which in
each claim's `repro_used`), `file_issues.py` puts it in the issue, and so the closure run against the
fixed `main` re-runs the sound version.

```json
{"tier": 1, "file": "pgpm_core/install.sql", "line": 4671, "lens": "concurrency",
 "scenario": "one line: what happens and what should have happened",
 "repro": "repro.sql", "install": ["pgpm_core/install.sql"], "fixtures": false}
```

`install` lists the files to load into the fresh database before the reproduction (default: the core
install); `fixtures: true` also loads `fixtures/demo.sql`. The harness follows `install`: a list with
`pgpm_archive/install.sql` runs in the archive harness (`--archive-container`, default `pgpm_test-archive`),
one with `pgpm_hypertable/install.sql` in the timescale harness (`--timescale-container`, default
`pgpm_test-timescale`), anything else in `--container` (default `pgpm_test-15`); an optional `container`
field overrides that. A claim directory without a reproduction file is recorded as a **hypothesis** and is
never counted or filed; one whose `claim.json` is not valid JSON is an **invalid claim**, reported with its
path and not run, and does not stop the run (`--only` and `--finders` never open a claim outside their
selection at all).

## Reproduction contract

The reproduction runs twice, against the review tree and against the pristine commit, each time in a
fresh database in the harness container with the tree under test installed. It must **fail when the
defect is present** and pass when it is absent; that is what lets the same file later close the finding
against the fixed `main`.

- `repro.sql` is piped into `psql -v ON_ERROR_STOP=1`. Present means psql exited non-zero or a line
  began with `not ok`. pgTAP is fine: `create extension if not exists pgtap;` at the top.
- `repro.sh` runs on the host under `bash` with these in the environment: `PSQL` (a command prefix
  that connects to the fresh database, use it as `$PSQL -tAc "..."`), `TREE` (the tree under test),
  `DB`, `CONTAINER`. Non-zero exit means present. Use this for two-session probes, `docker exec`
  against a second connection, or anything a single psql stream cannot express.

Every reproduction holds **at least one `LIVENESS:` assertion**: a premise check that the state the
defect needs was actually reached. Name premise checks `LIVENESS: ...` (other setup checks may be
`GUARD: ...` or `fixture: ...`) and defect checks without a prefix. A failure of prefixed checks alone
reads as "the fixture never ran", not as the defect, so a negative cannot pass (or fail) because
nothing happened. The prefix is exactly one of those three, colon included and case as written: a
defect check described "guard trigger is gone" is a defect check, and so is a `not ok` with no
description at all. In a `repro.sh`, report each check on a line of its own (`ok - LIVENESS: ...`,
`not ok - the rows are gone`): a non-zero exit whose every `not ok` line is a prefixed check reads as
the fixture never ran, exactly as it does for a `repro.sql`. `classify_claims.py`
scans the reproduction's text for `LIVENESS:` and classifies a reproduction without one as
`invalid_repro` without running it.

A reproduction that needs the finder's own environment, a hand edit to pgpm, or a state pgpm refuses
to enter is not a reproduction; the verifier will record why it fell.

## Verdicts

The verifier writes one JSON object keyed by claim id, which `pass_metrics.py` reads:

```json
{"F3-07": {"verdict": "finding",    "tier": 1, "root_cause": "session TimeZone grid", "issue": 501},
 "F2-04": {"verdict": "finding",    "tier": 2, "root_cause": "late rows skipped; fixture needed a frozen monolith",
           "rebuilt": true, "repro": "repro.verified.sql"},
 "F2-01": {"verdict": "fell",       "reason": "documented behaviour; reference.md#set_retain"},
 "F1-04": {"verdict": "known_open", "issue": 439}}
```

Only `candidate` claims need a verdict. A candidate without one is reported as unverified and is not a
finding; it is not a fall either, and neither the fell rate nor "Fell in verification" counts it. A verdict
string other than `finding`, `fell` or `known_open` is refused by `pass_metrics.py` (exit 2) rather than read.

`"rebuilt": true` and `"repro"` mean the verifier changed the fixture or the assertions and stored its
version as `repro.verified.sql` (or `.sh`) in the claim directory. The rebuilt reproduction keeps the
contract above (a `LIVENESS:` assertion, fails when present, passes when absent) and reaches the defect
on the pristine commit on its own. It is the reproduction every later step uses.

## Seed side effects

A plan entry may carry `"side_effects"`, one string saying what the seed does to state other claims
depend on (`"freezes the monolith: every table converted on the tree reads as frozen"`). `plant_seeds.py`
copies it into `sealed.json` unchanged, and `--catalogue` prints a catalogue mutation's side effects
when `bench/mutations/mutate.py` defines an optional `SIDE_EFFECTS` entry for it. `pass_metrics.py`
prints each seed's side effects in the record's "Seeds" section and, under "Seed interactions to
check" in its notes, lists every candidate whose pristine run failed only its liveness checks beside
the side effects of every seed: those are the claims that may have reached their defect through
another seed, and whose issue must carry the verifier's rebuilt reproduction.

## Late-survivor seeds

The catalogue's seeds are found at 0.9 to 1.0, which measures sensitivity to shapes finders already
know. The late-survivor set measures the shapes that survive: `LATE_SURVIVORS` in
`bench/mutations/mutate.py` names existing mutations that put back a Tier 1 or 2 defect which survived
five or more passes with its unit read, each with its issue, `passes_survived` (with its provenance in
the entry's comment) and shape. `mutate.py --late-survivors` lists it (`name`, `issue`,
`passes_survived`, `shape`, tab-separated), and `--list` and `--late-survivors` refuse a stale entry.
A pass plants at least three of its `K` seeds from it.

`plant_seeds.py` seals a planted member with `"late_survivor": {"issue": N, "passes_survived": k}`,
read from the pristine tree's catalogue as `SIDE_EFFECTS` is; a plan entry of either kind may set the
same field explicitly (a novel patch of a late-surviving shape), and the plan's value wins.
`--catalogue` prints a `late_survivor: issue N, passes_survived k` column for members alone.
`pass_metrics.py` reports the members' hits as their own recall: on the summary line after a
semicolon inside the recall's parentheses
(`seeds K=9, recall 1.00 (suite-caught 3/3, read-caught 6/6; late-survivor 3/3)`, or
`(late-survivor 2/3)` without the suite split), and as the stopping row
`late-survivor seed recall >= 0.8 (none planted reads as NOT met)` after the read-caught one.
`stop_check.py` parses both spellings, so they are fixed.

## Seed suite check

`plant_seeds.py --suite --sealed $WORK/sealed.json --pristine . --seeds-dir $WORK/seeds` plants each seed
alone in a copy of the pristine tree's suite directories and runs that tree's pgTAP files against it, each
in a fresh database the way `test.sh` runs them (a template with the module installed and the fixtures
loaded, cloned per file; the two files that need the cron database `postgres` are installed into it and
uninstalled after, or skipped and sealed as `suite_skipped` when pgpm is already there). The suite is
chosen by the seed's file: `pgpm_archive/` runs `tests/archive/db/` in the archive harness (its MinIO
bucket up), `pgpm_hypertable/` runs `tests/timescale/db/` in the timescale harness, anything else runs
`tests/` in the core harness. The verdict per file is `pg_prove`'s where the image has it (core and
archive, as `test.sh` judges them), else `test.sh`'s own reading for the timescale track. Before any seed,
the UNSEEDED tree's suite runs once per track as a control, sealed as `suite_baseline`: a file that fails
there (its first smoke run met a provoked statement timeout and an expected uninstall refusal, read as
`ERROR` lines) is noise, not a catch, and is taken out of every seed's result and reported as
`suite_noise`. Each seed is sealed with `suite_track`, `suite_ran` and `suite_caught`, the list of files
that failed and the baseline did not; `--only S1,S4` re-measures replacements against the sealed baseline,
`--rebaseline` runs the control again. `pass_metrics.py` reports the split only when every seed carries
`suite_caught`.

## Filing issues

`file_issues.py` renders one issue per root-cause group from `groups.json`, a list of
`{"id": "RC1", "title": "...", "tier": 1, "claims": ["F3-07", "F5-02"], "age": "old"}`. The `age` is
optional text (`old`, `young`, or a longer phrase; see [Metric definitions](#metric-definitions)), and
every Tier 1 and 2 group carries one: the run warns on one that does not.

```bash
scripts/review/file_issues.py --groups $WORK/groups.json --claims $WORK/claims \
  --verdicts $WORK/verdicts.json --pinned $pinned --pass N --out $WORK/issues
# read $WORK/issues/*.md, then file them:
scripts/review/file_issues.py ... --out $WORK/issues --post   # --repo, --label bug by default
```

Each `<out>/<group id>.md` starts with `title: <group title> (pass N <group id>)`, then the tier, then
`Age: <age> | Lens: <lens>` (the group's age, and the lenses its claims name, each once, comma-separated;
`Lens:` alone when the group has no age), one section per claim (finder, `file:line`, lens, scenario, the verifier's root cause) with its reproduction
inline, the verifier's rebuilt one when present and saying so, and the acceptance paragraph: the
reproductions fail on the pinned commit and must pass on the fixing commit, and the fix carries a
`bench/` guard and a `bench/mutations` entry proven by `./test.sh discriminate`. Every grouped claim
must have a `finding` verdict and a reproduction, or nothing is written. `--post` files them with
`gh issue create`, Tier 1 first, writing `<out>/filed.json` (`[{id, title, tier, claims, issue, url}]`)
after each, and refuses to run when `filed.json` already exists.

## Metric definitions

- recall: seeds attributed to at least one claim, over `K`. When `plant_seeds.py --suite` measured every
  seed, also split into suite-caught (the seeded tree's own pgTAP suite fails, so running the tests finds
  it) and read-caught (it does not), each as hits over count; the read-caught half is the recall the
  stopping criteria read from pass 5 on.
- late-survivor recall: hits among the seeds sealed with `late_survivor`, over their number (see
  [Late-survivor seeds](#late-survivor-seeds)); a pass that planted none reads its stopping row as NOT met.
- age and lens: the record's findings table is `| tier | age | lens | finding | issue | fix PR |`. The
  lens is the claim's `lens`. The age comes from `pass_metrics.py --ages ages.json`, an object mapping a
  claim id to text: `old` when the defect survived earlier passes with its unit marked read, `young` when
  it sits on code newer than the previous pass's pin, or a longer phrase. The coordinator writes it from
  the coverage ledgers of the earlier passes, at least for every Tier 1 and 2 finding; a claim it does not
  name gets a blank cell. The per-loop convergence report splits Tier 1 into old and young by it.
- precision: findings plus seed hits plus verified known-and-open re-finds, over claims that had a
  reproduction. A correctly reported seed is a true report, and so is a reproduced defect an earlier
  pass's issue already names; a hypothesis is not a claim. The strict figure (findings plus seed hits
  over claims) is reported beside it.
- fell rate: claims that fell in verification over claims that had a reproduction; the stopping
  criteria's reaching alarm (at most 0.3).
- cost: budget units over findings, and over Tier 1 findings.

## Smoke test

With `pgpm_test-15` running (`docker compose --profile pg15 up -d postgres15`):

```bash
scripts/review/build_review_tree.sh HEAD /tmp/rt
printf '{"seeds": [{"mutation": "grid_session_timezone", "lens": "time", "tier": 1}]}' > /tmp/plan.json
scripts/review/plant_seeds.py --tree /tmp/rt --plan /tmp/plan.json --sealed /tmp/sealed.json
# write a claim under /tmp/claims/F1/F1-01/ whose repro.sql sets a non-UTC TimeZone and checks _grid_next
scripts/review/classify_claims.py --claims /tmp/claims --review-tree /tmp/rt --pristine-tree . \
  --sealed /tmp/sealed.json --out /tmp/classified.json
```

The claim classifies as `seed_hit` attributed to `S1`.

## Fix phase tooling

The hunt ends with issues; the fix phase turns them into merged PRs and closes each issue by
re-running its reproduction. `/fix-phase` is the coordinator checklist (`.claude/skills/fix-phase/`),
`fixer` the agent that fixes one issue (`.claude/agents/fixer.md`). The scripts:

| script | does | proof |
|---|---|---|
| `land.sh [--batch] <pr> ...` | rebases each PR onto the current `main` (or, with `--batch`, onto the previous PR's new head: a stack of up to five for a merge-commit queue), under the diff3 conflict style so `keep_both.py` can resolve a same-spot add/add hunk in any file and refuse one both sides edited, verifies what CI would fail on (splices, `test.sh`, unique guard databases, every mutation builds), pushes, waits for the head checks with flake retry, enqueues (up to five requests: GitHub drops some and answers "Something went wrong" to others), waits for the merge with a `MERGED` re-check; in a batch each PR is enqueued as soon as its own head is green and its predecessor has merged; a PR already merged is skipped; a merge group whose every summary check has been green for `LAND_STALL_MIN` (10) minutes while the entry still reads awaiting checks is dequeued and enqueued again once (the GitHub stall #1041 and #1049 met); wait caps and the merge method are environment knobs (`LAND_WAIT_*_MIN`, `LAND_MERGE_METHOD`), exit 6 means a wait or an enqueue did not take and the same command can be rerun | `--rebase-only` dry path; exit codes in its header |
| `landq.sh <workdir> [--batch N] [--next]` | the landing loop: reads `<workdir>/landq.txt` (`<tier> <pr>` lines, appended while it runs), lands the lowest tier first through `land.sh`, up to N of one tier per batch, a line's third word `rule` (`<tier> <pr> rule`, for a PR that adds or tightens a repo-wide rule) putting that PR first in its tier so it sits at the base of the stack and every later PR of the batch is checked with the rule in force (pass 11's L13: four rule PRs landed late each paid a re-anchor round), `--next` printing the batch the next turn would land without landing it; retries a wait timeout up to eight times, stops for a human on anything else; writes `landq.done`, where a PR that merged before its batch stopped gets its `merged` line | pass 3 ran it in scratch form for 24 PRs; pass 4 landed 25 PRs through it in batches; `--next` shows the ordering on a mixed `landq.txt` |
| `gate.sh <lockdir> [--container NAME] -- <cmd>` | serialises the fixers' `./test.sh` runs on one machine: an mkdir mutex plus a wait for the fixed-name harness container to be gone before the holder starts (pass 3's mutex alone let five first runs fail at `compose up`); the container is inferred from the command (`./test.sh timescale` waits on `pgpm_test-timescale`), and one a FAILED previous holder left behind is removed rather than waited on (pass 4: a red run's container made every later holder exit 7) | logs holder, container, duration and exit status to `<lockdir>.log` |
| `landing_stats.py <landq.log>` | per-PR landing measurements for the record: start, merge, minutes, enqueues, flakes, stops, hand fixes, list files resolved; median and total | `--selftest` |
| `keep_both.py <file>` | keep-both resolution of a same-spot add/add conflict: in `CHANGELOG.md` (branch first), `bench/mutations/mutate.py` (with the three structural repairs it needs), `test.sh` and the perf/archive/lint workflows under either conflict style, and in ANY other file under diff3 or zdiff3, whose base section tells an add/add hunk (kept, main first) from one both sides edited (refused) | `--selftest` holds the three conflict shapes pass 2 met, the diff3 hunks of #598 and the any-file hunks of #713; `bench/keep_both_diff3.sh` has git write them |
| `flake_check.sh <run>` | says whether every failed job of a run matches a KNOWN flake signature (narrow: the lock guard's probe with its liveness green and no other failure; a third-party image pull refused by a quota with no test run) | each signature names its issue |
| `closure.sh --claims <dir> --out <json>` | re-runs every reproduction against `main` in the harness (the PG15 and archive services, and the timescale service when a claim installs the hypertable module), using a verifier's `repro.verified.sql` where one exists; refuses to run while a `fix/` PR is open | preconditions checked, not assumed |
| `close_comments.py` | renders one evidence comment per issue from the closure output, `--post` posts them and REOPENS an issue whose sound reproduction still fails | `--selftest` |

Why one PR at a time. Every fix appends at the same three spots (a changelog bullet, a mutation
entry, a guard line), so every rebase conflicts there; `keep_both.py` makes that mechanical. What no
script can remove is the squash queue's shape: a squash commit has no ancestry link to its branch, so
once PR k-1 lands, PR k conflicts with `main` in those files and must be rebased and re-checked before
it can be queued. Stacking PRs on each other does not help (the queue's three-way merge sees the same
conflict), and a plain `git rebase main` of a stacked PR replays its predecessor onto its own squash.
Measured in pass 2: about 24 minutes per PR, serial; in pass 3, a 28-minute median over 24 PRs. The
queue was switched to merge commits on 2026-09-29, after pass 3's last PR. A merge-commit queue keeps a
stacked PR's ancestry, and `land.sh --batch` uses that: up to five PRs rebased onto one another, pushed and
checked in parallel, then enqueued in turn as each predecessor merges (the queue drops a PR stacked on
another queued PR's head; the first live batch, #646 and #647, showed it), so a batch costs one
head-check round plus one merge group per PR instead of a rebase and both per PR. `landq.sh --batch 5`
drives it. Pass 4 landed 25 PRs that way and measured what batching cost (#713): every stop rebased the
whole batch and re-ran every head's checks, and six of the nine stops were same-spot add/add hunks
outside the list files. So since pass 4 `land.sh` rebases under diff3 and `keep_both.py` resolves those
hunks in any file, each PR is enqueued the moment its own head is green and its predecessor has merged,
an enqueue is requested up to five times before the run gives up, and a PR that merged before a stop is
skipped by the rerun and recorded as merged by `landq.sh`.

Two more things pass 3's landing taught. `land.sh` runs `keep_both.py` and `flake_check.sh` from the
checkout's `main` (or from `LAND_TOOLING`), so a PR that fixes the landing tooling cannot be landed by the
copy it fixes: #623's `mutate.py` conflict was refused by the pre-#598 `keep_both.py` that `main` still
held, and resolved cleanly by #623's own. And the PR workflows carry a `concurrency` group keyed by the
PR number, so a rebase or a fix pushed to a PR cancels the superseded head's runs instead of queueing
behind them; pushes to `main` and merge groups are keyed by sha and never cancel each other.

Assign before spawning. Fixers working in parallel each take "the next free" test number and guard
database unless the coordinator hands them out; pass 2 ended with seven files numbered 124. `land.sh`
renumbers a duplicate `pgpm_perfNN` (databases) but cannot renumber files.

## Per-PR verification tooling

The standing mode after convergence (docs/adversarial-review.md, "Per-PR verification"), started early as a
test. `/pr-verify` (`.claude/skills/pr-verify/`) is the coordinator checklist; the `finder` and `verifier`
agents each have a per-PR section. A pull request has four trees where a pass has two, and the classes read
off them are the mode's own:

| script | does | proof |
|---|---|---|
| `pr_verify.sh prepare <pr> --work <dir> [--acceptance <dir>] [--plan <json>] [--mutations a,b]` | resolves the head and the merge base, builds the history-less trees `base`, `head`, `review` (head plus the seed plan, planted by `plant_seeds.py`) and `mutant` (head with the PR's NEW mutations applied, found by comparing the two catalogues), the diff as presented (base against review, so the seed reads as part of the PR), the surface, and copies the acceptance claims; `harness up\|down` runs the private containers (`pgpm_prv-15`, `-archive` with MinIO, `-timescale`) so the fixers' gated runs are never disturbed; `classify` and `report` drive the two scripts below; `cleanup` removes the worktrees | its header; a run on a PR with no new mutation says so rather than building an empty mutant |
| `pr_surface.py --base <tree> --head <tree> --out <dir>` | the slice: every unit (function or procedure, delimited by its dollar-quoted body) a hunk touches, a labelled unit per top-level hunk, every unit that calls a touched one (schema-qualified or bare, one hop), the touched non-SQL files as paths; writes `slices.json` for `coverage.py` (explicit `units`, since this release), `units.txt` for the finder's ledger and `surface.md`; exit 3 when the trees are identical | `--selftest`: hunks, unit extents, top-level hunks, both caller spellings, exercised-by, identical trees |
| `pr_classify.py --claims --base --head [--review] [--mutant] [--sealed] --acceptance ACC --out` | `classify_claims.py`'s loader, contract and harness over four trees: `regression` (fails on head, not base), `pre_existing` (both), `fixed` (base only), `seed_hit` (review only), `not_reproduced`, `invalid_repro`; a base run that failed only its liveness checks does not make a head failure a regression, a head run that failed only its liveness checks while the base fails is `fixed` by a refusal of the premise, flagged; the acceptance finder's claims also run on the mutant and record `fails_on_base`, `passes_on_head`, `mutant_restores` | `--selftest` with a fake runner over every class and both liveness readings |
| `pr_comment.py --classified --pr --head --base --out [--verdicts] [--coverage] [--surface] [--sealed] [--post]` | renders the comment and applies the landing policy, exit 1 = blocked: an acceptance that does not fail on the base, pass on the head or fail on the mutant; a verified regression of any tier; a verified Tier 1 or 2 pre-existing claim; an unverified candidate; a `partial` closing claim; verified Tier 3 to 5 pre-existing claims are listed for filing; the seed witness is reported found or MISSED and never blocks | `--selftest` over each policy clause |

The verifier's `closing.json` is a verdict object with one key, `closing`, `{"verdict": "holds" | "partial",
"reason": "...", "claims": [...]}`: whether the PR's own closing claim survived an attempt to reach the
issue's consequence by a path the diff does not cover. `pr_verify.sh report` merges it with the per-claim
verdicts (`jq -s add`) the way a pass does.

Why the mutant. `./test.sh discriminate` proves the guard FAILS against the mutation; it cannot know whether
the mutation put back the defect the issue describes or a cousin that happens to live on the same lines. The
issue's own reproduction can: run against the mutant it must fail, and when it does not, the guard the
mutation certifies is not a guard for this fix. That check costs one more install per acceptance claim.

## Loop tooling

A loop is one review pass, its fix phase, the record PR, the loop summary and the convergence report, then the
stopping check (`docs/adversarial-review.md`, "Running a loop without a human"). `/review-loop`
(`.claude/skills/review-loop/`) is the driver's checklist; it runs `/review-pass` and `/fix-phase` in turn and
these three scripts around them:

| script | does | proof |
|---|---|---|
| `stop_check.py --history docs/adversarial-review.md --records docs/reviews [--pass N] [--budget-used T] [--decisions Q] [--extended-through P] [--json OUT]` | reads the pass history table and each pass's record (the header lines `pass_metrics.py` writes, the `coverage:` line its `--coverage` adds, the stopping-status rows) and judges the two most recent passes: (a) the full lens cycle, the ten catalogue lenses besides fresh surface used across the two, each pass with zero Tier 1 and coverage at 0.9 (printing the lenses the cycle still owes and the next pass's five least recently used); (b) precision, fell rate, seed recall (read-caught when split) and the late-survivor recall (absent from pass 12 on is NOT met), every threshold on exact values: the record's `exact:` fractions (from pass 13 on a record without them reads unknown) and the coverage line's count of finders at 0.90, never a two-decimal figure; (c) the ceiling (pass 13 unless extended) and the 27M-token budget; (d) an unresolved `BLOCKING` decision; (e) the method's criterion 4, read off the record's `capture-recapture (T1):` line: an estimate (`estimate <x>[, found <y>]`) must round to zero in both passes, and where either pass reads `not attempted` or not computable (`not computable`, `undefined`), (a) and (b) must hold over the three most recent passes instead. One line per criterion, then `continue` (exit 0) or `stop` with the reason (exit 1); a record it cannot read, a lens outside the catalogue or a Tier 1 count the table and the record disagree on is exit 2, never a default | `--selftest`: every branch on synthetic records, and the repository's passes 2 to 11 must parse and read `continue` on their Tier 1 and the owed lenses |
| `loop_state.py <state.json> init\|set\|progress\|show\|check` | the loop's state file: where the driver is after a compaction, and the dead-man switch every wakeup runs first: `check` exits 0 ok, 3 when the last progress is over `--stale-hours` (2) old with a phase open (notify, keep the wakeup), 4 over `--dead-hours` (6) (stop and report); `set --phase waiting` parks the loop on the user (loop 12's record PR awaiting the user's merge), which `check` reads as ok with the time waited, and `set --phase done` closes the loop | `--selftest`: transitions, PRs recorded once, both thresholds, the bounded history, corrupt files refused |
| `decisions_queue.py <queue.md> init\|add\|resolve\|render\|pending` | the queue of decisions the loop took on the user's behalf (`default`, `limit`, `carried`, `scope`) and the ones only the user may take (`blocking`, written `BLOCKING`); `render --since <loop>` is the section the loop summary carries (that loop's entries and every open one); `pending` exits 1 while a `BLOCKING` entry is unresolved | `--selftest`: loop headings, resolve once, refused fields, both exits of `pending` |

`loop_state.json`:

```json
{"loop": 12, "pin": "60f4ad89", "phase": "fix", "step": "3: landing wave 1", "prs": [1230, 1231],
 "started": "2026-10-11T09:00:00Z", "last_progress": "2026-10-11T13:42:10Z",
 "history": [{"time": "2026-10-11T09:00:00Z", "phase": "init", "step": "initialised"}]}
```

`phase` is one of `init`, `review`, `fix`, `record`, `report`, `waiting`, `stop_check` and `done`; `history` keeps the
last 50 transitions; times are UTC. `set` stamps `last_progress`, and so does `progress`, which the driver
calls only when a step actually advanced.

`decisions_queue.md`, one line per entry under a heading per loop:

```text
## Loop 12

- D01 | 2026-10-11 | default | refuse over warn on the archive bound | issue #1230 | PR - | open
- D02 | 2026-10-11 | BLOCKING | cut release v0.7.0 | issue - | PR - | resolved by david (after pass 13)
```

An absent issue or PR is `-`; an entry is `open` until `resolve` writes who resolved it. The text may not
hold `|` or a line break, and the scripts refuse a line that does not have this shape: every line is blank, a
`## Loop N` heading, the header's prose above the first loop heading, or an entry flush left, and a line that
reads as an entry (a list item under any bullet or indent, a `d<nn>` id, a `|` field) is never taken for prose.

## coverage.py

`coverage.py --tree <review tree> --slices <slices.json> --claims <claims dir> [--threshold 0.9] [--out <json>]`
scores each finder's coverage ledger (`<claims>/<finder>/coverage.md`, one `- <unit> | read: yes|no | <notes>`
line per unit) against its slice: functions and procedures for an install.sql slice (a `file:lo-hi` range
keeps the units whose `create` line is inside it), files for a tests, bench, docs or scripts slice, both at
once for a mixed one, and an explicit `units` list (the shape `pr_surface.py` writes: named units plus a
`file:lo-hi` label per top-level hunk) when the slice is a pull request's surface. One row
per finder with the unread units; exit 1 when any finder is below the threshold or has no ledger, which
the review-pass skill treats as "re-run or split before classifying". `--selftest` covers ranges, files
slices, a missing ledger, units outside the slice and the threshold.
