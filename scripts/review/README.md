# scripts/review: tooling for an adversarial review pass

The mechanical parts of a review pass as defined in [`docs/adversarial-review.md`](../../docs/adversarial-review.md).
Everything here is a script; nothing here judges a claim. The `/review-pass` skill (`.claude/skills/review-pass/`)
walks a coordinator through them in order, and the `finder` and `verifier` agents (`.claude/agents/`) are
the two model roles.

| script | step | what it does |
|---|---|---|
| `build_review_tree.sh <sha> <dir>` | 4 | the pinned commit as ONE history-less commit in a fresh repo with no remote; `bench/mutations/` removed |
| `plant_seeds.py --tree --pristine --plan --sealed` | 4 | applies catalogue mutations and novel patches from a plan, writes the sealed record (with each seed's `side_effects`), keeps the tree at one commit |
| `classify_claims.py --claims --review-tree --pristine-tree --sealed --out` | 6 | runs every reproduction (the verifier's `repro.verified.*` when present) against both trees in a fresh database each; classifies seed hit, candidate, not reproduced, inverted, invalid reproduction, hypothesis |
| `pass_metrics.py --sealed --classified --verdicts ... --out` | 8, 10 | recall and precision before the count; writes the pass record under `docs/reviews/`, with the seed interactions to check |
| `file_issues.py --groups --claims --verdicts --pinned --pass --out [--post]` | 10 | one issue body per root-cause group with its reproductions inline; `--post` files them, Tier 1 first, and writes `filed.json` |

Each Python script has a `--selftest` that CI runs (`.github/workflows/lint.yml`, "Review tooling self-test").

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
install); `fixtures: true` also loads `fixtures/demo.sql`. A claim directory without a reproduction file
is recorded as a **hypothesis** and is never counted or filed.

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
nothing happened. In a `repro.sh`, echo the prefix on the line reporting the check. `classify_claims.py`
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
finding.

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

## Filing issues

`file_issues.py` renders one issue per root-cause group from `groups.json`, a list of
`{"id": "RC1", "title": "...", "tier": 1, "claims": ["F3-07", "F5-02"]}`:

```bash
scripts/review/file_issues.py --groups $WORK/groups.json --claims $WORK/claims \
  --verdicts $WORK/verdicts.json --pinned $pinned --pass N --out $WORK/issues
# read $WORK/issues/*.md, then file them:
scripts/review/file_issues.py ... --out $WORK/issues --post   # --repo, --label bug by default
```

Each `<out>/<group id>.md` starts with `title: <group title> (pass N <group id>)`, then the tier, one
section per claim (finder, `file:line`, lens, scenario, the verifier's root cause) with its reproduction
inline, the verifier's rebuilt one when present and saying so, and the acceptance paragraph: the
reproductions fail on the pinned commit and must pass on the fixing commit, and the fix carries a
`bench/` guard and a `bench/mutations` entry proven by `./test.sh discriminate`. Every grouped claim
must have a `finding` verdict and a reproduction, or nothing is written. `--post` files them with
`gh issue create`, Tier 1 first, writing `<out>/filed.json` (`[{id, title, tier, claims, issue, url}]`)
after each, and refuses to run when `filed.json` already exists.

## Metric definitions

- recall: seeds attributed to at least one claim, over `K`.
- precision: findings plus seed hits, over claims that had a reproduction. A correctly reported seed
  is a true report; a hypothesis is not a claim.
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
| `land.sh <pr> ...` | rebases each PR onto the current `main`, resolves the list files, verifies what CI would fail on (splices, `test.sh`, unique guard databases, every mutation builds), pushes, waits for the head checks, enqueues, waits for the merge; one PR at a time, Tier 1 first | `--rebase-only` dry path; exit codes in its header |
| `keep_both.py <file>` | keep-both resolution of an add/add conflict in `CHANGELOG.md`, `bench/mutations/mutate.py`, `test.sh` or the perf/archive workflows, with the three structural repairs `mutate.py` needs; refuses any other file | `--selftest` holds the three conflict shapes pass 2 met |
| `flake_check.sh <run>` | says whether every failed job of a run matches a KNOWN flake signature (narrow: the lock guard's probe with its liveness green and no other failure; a third-party image pull refused by a quota with no test run) | each signature names its issue |
| `closure.sh --claims <dir> --out <json>` | re-runs every reproduction against `main` in the harness, using a verifier's `repro.verified.sql` where one exists; refuses to run while a `fix/` PR is open | preconditions checked, not assumed |
| `close_comments.py` | renders one evidence comment per issue from the closure output, `--post` posts them and REOPENS an issue whose sound reproduction still fails | `--selftest` |

Why one PR at a time. Every fix appends at the same three spots (a changelog bullet, a mutation
entry, a guard line), so every rebase conflicts there; `keep_both.py` makes that mechanical. What no
script can remove is the squash queue's shape: a squash commit has no ancestry link to its branch, so
once PR k-1 lands, PR k conflicts with `main` in those files and must be rebased and re-checked before
it can be queued. Stacking PRs on each other does not help (the queue's three-way merge sees the same
conflict), and a plain `git rebase main` of a stacked PR replays its predecessor onto its own squash.
Measured in pass 2: about 24 minutes per PR, serial. A merge-commit queue would allow groups of five;
that is a repository ruleset decision, recorded in `docs/adversarial-review.md`.

Assign before spawning. Fixers working in parallel each take "the next free" test number and guard
database unless the coordinator hands them out; pass 2 ended with seven files numbered 124. `land.sh`
renumbers a duplicate `pgpm_perfNN` (databases) but cannot renumber files.
