---
name: review-pass
description: Run an adversarial review pass of pgpm end to end under docs/adversarial-review.md, as its coordinator. Pins a commit, plants blind seeds, fans out finders, verifies every candidate independently, and writes the pass record with recall and precision before the count.
argument-hint: "[pinned-sha] [K] [lens, lens, ...]"
disable-model-invocation: true
allowed-tools: Bash Read Write Agent
---

You are the **coordinator** of review pass N of pg_partition_magician. You do not review code for
defects and you do not fix anything. Read `docs/adversarial-review.md` in full before step 1, and
`scripts/review/README.md` for the file formats. Arguments: `$ARGUMENTS` (pinned sha, K, lenses; ask
for any that is missing, and for the budget).

Work in a scratch directory outside the repository (the session scratchpad). Refer to it as `$WORK`.

## 1. Pin and budget

- `pinned=$(git rev-parse <sha>)`; record the release it corresponds to (`git describe --tags`).
- Record the budget: number of finders, a per-finder token or turn cap, a wall-clock limit. Fixed now.
- Record this pass's lenses and the previous pass's (from the latest `docs/reviews/*.md`). At least
  half must differ. **Fresh surface is always included**: list the PRs merged since the previous pinned
  commit and the files and hunks they touched (`git log --oneline <prev>..<pinned>`, `git diff --stat`).

## 2. Seeds (sealed)

- `scripts/review/plant_seeds.py --catalogue` lists every catalogue mutation with its file and track.
- Write `$WORK/plan.json` with K seeds spanning the lenses and tiers 1 to 3, at least a third of them
  **novel patches** you write for this pass in the catalogue's style (a quiet defect: a dropped
  re-check, an off-by-one at a boundary, a `%I` over a `_q` fragment). Save novel patches under
  `$WORK/seeds/`.
- Give every seed that changes global state other claims depend on (freezes the monolith, disables a
  tick, alters a default) a `"side_effects"` string in its plan entry. It is sealed with the seed and
  `pass_metrics.py` sets it beside the candidates that may have leaned on it. Prefer planting such a
  seed alone in a tree of its own when the budget allows.
- `scripts/review/build_review_tree.sh $pinned $WORK/tree`
- `scripts/review/plant_seeds.py --tree $WORK/tree --pristine . --plan $WORK/plan.json --sealed $WORK/sealed.json`
- `scripts/review/plant_seeds.py --suite --sealed $WORK/sealed.json --pristine . --seeds-dir $WORK/seeds`
  with the core harness up (and the archive or timescale harness when a seed sits in that module). It
  runs the unseeded tree's suite once as a control (a file that fails there is noise, not a catch), then
  plants each seed alone and runs that tree's own pgTAP suite against it, sealing the files that catch it
  as `suite_caught`. Read the table: a seed the suite catches will be found by any finder that runs the
  tests (pass 4's F8 found all nine that way in twelve minutes), so replace seeds until the split is the
  one the pass wants, and re-run `--suite --only` for the replacements. The record then reports recall as
  suite-caught / read-caught.
- Never show `$WORK/sealed.json`, `$WORK/plan.json` or `$WORK/seeds/` to a finder, and never mention
  which functions were seeded.

## 3. Slices

Divide the review tree into as many slices as finders: by module and function group, so every
`pgpm_core/install.sql` function, `pgpm_archive/install.sql`, `bench/`, `tests/` and `docs/` belong to
exactly one slice. The fresh-surface hunks go to a dedicated slice in addition to their home slice.

## 4. Hunt

Start `pgpm_test-15` from the pristine checkout (`docker compose --profile pg15 up -d postgres15`).
Spawn one **`finder`** agent per slice (the `finder` type from `.claude/agents/`), all in one message so
they run in parallel. Each prompt contains: the review tree path, the slice, the lenses, the claims
directory `$WORK/claims`, its finder id (`F1`, `F2`, ...), the budget, the container name, and the text
of `scripts/review/README.md`'s "Claim format" and "Reproduction contract" sections. Say nothing about
seeds.

**Model-tier split** (the methodology's way of choosing models with data): give two slices to a second
finder each, run with a different `model` on the Agent call, same prompt. Record which finder id ran on
which model; per-finder recall and precision are computed later.

If the user has opted into multi-agent orchestration ("use a workflow"), the fan-out and per-claim
verification below fit the Workflow tool's pipeline shape; otherwise use the Agent tool directly.

## 5. Classify (mechanical)

```bash
scripts/review/classify_claims.py --claims $WORK/claims --review-tree $WORK/tree --pristine-tree . \
  --sealed $WORK/sealed.json --out $WORK/classified.json
```

Read the summary. `inverted` or an unattributed `seed_hit` means a claim's location or the sealed
record is wrong; look before going on. A reproduction with no `LIVENESS:` assertion is
`invalid_repro` and was not run; send it back to its finder. A candidate flagged "pristine liveness
failed" may have reached its defect through another seed's side effect; its verifier must rebuild it.

## 6. Verify (one verifier per candidate)

Export the open-issue list: `gh issue list --state open --label bug --limit 200 --json number,title,body > $WORK/open.json`.
For every `candidate` in `$WORK/classified.json`, spawn one **`verifier`** agent with: the claim's
directory, the two tree paths, its classifier record, `$WORK/open.json`, the container, the verdict
path `$WORK/verdicts/<id>.json`, and the exact classifier command for its claim:

```bash
scripts/review/classify_claims.py --claims $WORK/claims --review-tree $WORK/tree --pristine-tree . \
  --only <id> --out $WORK/verify/<id>.classified.json
```

No `--sealed` (one candidate needs no attribution, and the sealed record is not a verifier's to read); the
container follows the claim's install list unless its `claim.json` names one. Pass 4's F7-03 verifier had
to guess the arguments (#679). Give it nothing from the finder's transcript. A verifier that changed
the fixture or the assertions stores its version as `repro.verified.sql` (or `.sh`) in the claim
directory and marks its verdict `"rebuilt": true`; check that every candidate flagged "pristine liveness
failed" came back either rebuilt or `fell`. Then
`jq -s 'add' $WORK/verdicts/*.json > $WORK/verdicts.json`.

## 7. Metrics and record

```bash
scripts/review/pass_metrics.py --pass N --date $(date +%F) --pinned $pinned --release <tag> \
  --sealed $WORK/sealed.json --classified $WORK/classified.json --verdicts $WORK/verdicts.json \
  --budget "<text>" --budget-units <n> --lenses "<list>" --previous-lenses "<list>" \
  --out docs/reviews/$(date +%F).md
```

**Report recall and precision before the count of findings, always**, recall with its suite-caught /
read-caught split (the stopping criteria read the read-caught half), precision with its strict figure
and the fell rate beside it (verified re-finds of open issues count as true reports; the fell rate is
the reaching alarm). Then the findings by tier, the
blind spots (seeds missed, by lens), and the per-finder table including the model-tier split. If any
candidate is unverified, say so and do not call it a finding. Under "Seed interactions to check" the
record lists the candidates whose pristine run failed only its liveness checks; replace that list, in
the record, with which claim depended on which seed's side effect.

## 8. File, fix, close

- Write `$WORK/groups.json`, one entry per root-cause group
  (`{"id": "RC1", "title": "...", "tier": 1, "claims": [...]}`), render the issues and read every one
  before filing:

  ```bash
  scripts/review/file_issues.py --groups $WORK/groups.json --claims $WORK/claims \
    --verdicts $WORK/verdicts.json --pinned $pinned --pass N --out $WORK/issues
  scripts/review/file_issues.py --groups $WORK/groups.json --claims $WORK/claims \
    --verdicts $WORK/verdicts.json --pinned $pinned --pass N --out $WORK/issues --post
  ```

  Each issue carries its claims' reproductions inline (the verifier's `repro.verified.*` when present)
  and the acceptance paragraph; `--post` files them labelled `bug`, Tier 1 first, and writes
  `$WORK/issues/filed.json`. Fill the issue numbers from it into the record.
- List, for the fix phase, the open issues whose bullets this pass re-found with a reproduction (the
  record's "Known and open" section, the comments posted on them): they join the pass's own issues in
  `/fix-phase`'s list, since each now has an acceptance test.
- Fixes are separate work under `CLAUDE.md`'s rules (guard plus mutation per fix), one PR each, merged
  in order with a rebase and fresh CI per PR. A finding closes when its own reproduction passes on the
  fixed `main`; the verifier's `classify_claims.py --only <id>` against the new `main` is that check.
- Add each fixed defect's mutation to the catalogue if the fix PR did not, and the novel seeds from
  `$WORK/seeds/` now that the pass is over.
- Open the PR that adds `docs/reviews/<date>.md` and updates the "Pass history" table in
  `docs/adversarial-review.md`.

## Do not

- Report a finding count before recall and precision.
- Let a finder see seeds, the catalogue, the pristine tree, another finder's claims, or the open-issue
  list.
- Let a verifier see a finder's reasoning.
- Count a hypothesis, an unverified candidate, or a known-and-open re-find as a finding.
