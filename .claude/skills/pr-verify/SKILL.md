---
name: pr-verify
description: Adversarially verify ONE pull request before it lands, as the coordinator of docs/adversarial-review.md's per-PR verification mode. Re-runs the issue's reproduction on the base, the head and the PR's own mutant, has a finder review the touched units and their callers under the fresh-surface lens with a planted seed as the witness, verifies every candidate independently, and posts the comment that says whether the PR may land.
argument-hint: "<pr> [issue-bullet ...] [lens]"
disable-model-invocation: true
allowed-tools: Bash Read Write Agent
---

You are the **coordinator** of a per-PR adversarial verification. You do not review the code for defects
and you do not fix anything. Read `docs/adversarial-review.md` ("Definitions", "Roles and separation",
"Per-PR verification") and `scripts/review/README.md` ("Per-PR verification tooling", "Claim format",
"Reproduction contract") before step 1. Arguments: `$ARGUMENTS`: the PR number, the issue bullet(s) it
addresses (their verified reproductions are the acceptance claims; none for a PR that closes no issue), and
one lens beside fresh surface. Work in a scratch directory outside the repository, `$W`.

Everything below runs while the PR waits for its head checks, so it adds no landing latency; a PR that
touches `pgpm_core/install.sql`, `pgpm_archive/` or `pgpm_hypertable/` always gets it, any other PR when the
coordinator judges its claims worth the budget (a tooling PR that changes what a check accepts, for one).

## 1. Prepare (mechanical)

- Acceptance claims: for each issue bullet, one claim directory `$W/acc/ACC-NN/` holding the bullet's
  verified reproduction (`repro.verified.*` where the verifier rebuilt it, else `repro.*`) unchanged, and a
  `claim.json` whose `install` list gives the reproduction every file it reads from the tree under test
  (a reproduction that read a file from `/repo` gets that file in `install` and that line removed, because
  the trees differ and `/repo` cannot follow them; say so in the comment). Tier and scenario from the issue.
- A seed plan `$W/plan.json`, one seed that sits in the PR's surface: a catalogue mutation in a touched unit
  (the PR's own new mutation is a fine choice, since its surface is exactly the PR's), or a one-line novel
  patch in the catalogue's style. It is the hunt's liveness witness: a finder that misses it says the hunt
  on this PR proves little, whatever else it found. Plant none only when the surface holds nothing quiet
  to plant, and expect the comment to say the hunt was unwitnessed.
- `scripts/review/pr_verify.sh harness up [--archive] [--timescale]` (private containers `pgpm_prv-*`, so
  the fixers' gated `./test.sh` runs are never disturbed), then

  ```bash
  scripts/review/pr_verify.sh prepare <pr> --work $W/pr --acceptance $W/acc --plan $W/plan.json
  ```

  builds the four trees (base, head, review = head plus the seed, mutant = head with the PR's new
  mutations applied), the diff as presented (`$W/pr/pr.diff`, base against review, so the seed reads as part
  of the PR), the surface (`$W/pr/surface/`: the touched units, their callers, the touched files;
  `units.txt` is the finder's ledger), and copies the acceptance claims under `$W/pr/claims/ACC/`.
  Read `surface.md`: a surface of more than about forty units is two finders (split `slices.json` by hand,
  P1 and P2), fewer than five is a finder on a short budget.

## 2. Hunt and challenge (two agents, in one message)

- One **`finder`** (the agent in `.claude/agents/finder.md`), with: the review tree `$W/pr/review`, the diff
  `$W/pr/pr.diff` and the PR's title and body (a claim to test, not a fact), the slice (`slices.json`,
  `units.txt`, `surface.md`), the lenses (fresh surface plus the one given), the claims directory
  `$W/pr/claims`, its finder id (`P1`), the budget (about 150k tokens for a surface of ten to twenty units),
  the private harness container names, and the text of the README's "Claim format" and "Reproduction
  contract". Never the base tree, `head_src`, `base_src`, `sealed.json` or the plan.
- One **`verifier`** in its **claims-verifier** role (the section of `.claude/agents/verifier.md`), with:
  `$W/pr/head_src` and `$W/pr/base_src` (it may read `bench/mutations/`), the diff, the PR body, the issue
  bullet's text, the acceptance claims and their reproductions, the harness, the claims directory with finder
  id `V`, the verdict path `$W/pr/verdicts/closing.json`, and the open-issue list
  (`gh issue list --state open --label bug --limit 200 --json number,title,body > $W/open.json`). Its job is
  to disprove the PR's closing claim: reach the issue's consequence through a path the diff does not cover.

## 3. Classify (mechanical)

```bash
scripts/review/pr_verify.sh classify --work $W/pr
```

runs every claim against base, head and review (the acceptance ones against the mutant too) and prints the
classes (`regression`, `pre_existing`, `fixed`, `seed_hit`, `not_reproduced`, `invalid_repro`), the acceptance
line per issue reproduction (fails on base, passes on head, mutant restores it) and the coverage of the
finder's ledger. Read it before anything else:

- an acceptance reproduction that does not fail on the base, or does not pass on the head, or that the
  PR's mutation does not make fail: the PR is blocked already; send the finding to its fixer.
- `invalid_repro`: back to its finder.
- coverage below 0.9: the finder re-runs on its unread units before step 4.
- the seed not hit: recorded; the comment will say so.

## 4. Verify the candidates (one verifier each)

For every `regression` and `pre_existing` claim (the finder's and the claims verifier's), spawn one
**`verifier`** with the claim directory, the two trees as the pristine commit = `$W/pr/base` and the review
tree = `$W/pr/head` (for a `regression` the defect is absent on the base: say so, the verifier's task is
then whether the head's failure is a defect in pgpm by the rubric, not whether the base shares it),
`$W/open.json`, the harness, the verdict path `$W/pr/verdicts/<id>.json`, and the classifier command:

```bash
scripts/review/pr_classify.py --claims $W/pr/claims --base $W/pr/base --head $W/pr/head --review $W/pr/review \
  --only <id> --out $W/pr/verify/<id>.json --container pgpm_prv-15 --archive-container pgpm_prv-archive --timescale-container pgpm_prv-timescale
```

Nothing from the finder's transcript. A verifier that rebuilt the fixture stores `repro.verified.*` beside
the original, as in a pass.

## 5. Report and decide (mechanical policy)

```bash
scripts/review/pr_verify.sh report --work $W/pr --budget "<finder tokens, verifiers, wall clock>" [--post]
```

merges the verdicts and renders the comment; `--post` posts it on the PR. Exit 1 is **blocked**: an
acceptance that did not hold, a verified regression of any tier, a verified Tier 1 or 2 pre-existing defect
in the PR's surface, an unverified candidate, or a `partial` closing claim. The fixer fixes in place and the
verification re-runs on the new head (a fresh `--work`; the acceptance claims and the plan are reusable).
Exit 0 is **clear**: enqueue it (`scripts/review/land.sh` or `landq.sh`). Verified pre-existing Tier 3 to 5
claims are filed as issues with their reproductions (`file_issues.py`, pass "pr-<n>") and do not hold the PR.

Then `scripts/review/pr_verify.sh cleanup --work $W/pr` (the worktrees), and `harness down` when the
batch is done. Record the verification in the record of the phase it belongs to: head verified, seed hit or
missed, claims and classes, verdicts, cost. A missed seed is a method result; three in a row on one surface
shape means the brief or the lens needs changing, not the finder.

## Do not

- Give the finder the base tree, `head_src`, `base_src`, the sealed record, or the mutation catalogue.
- Let a verifier see a finder's reasoning.
- Read `clear` off a comment whose acceptance table has a `NO` or a `not run` in it; the policy is in
  `pr_comment.py` so that it is applied the same way every time, but a `not run` means the harness, not the
  PR, and is fixed and re-run before anything is posted.
- Enqueue a PR this verification blocked, or one it has not seen when its files are in the standing list.
