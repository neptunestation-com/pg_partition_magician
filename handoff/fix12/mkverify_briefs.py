#!/usr/bin/env python3
"""mkverify_briefs.py <pr> <issue> <bullet> <acc-id> "<second lens>" "<finder note>"
Writes $W/v/<pr>/brief_finder.md and brief_claims_verifier.md from the prepared work dir."""
import json, sys
F = "/Users/davida.ventimiglia/.claude/jobs/8d94cdfa/tmp/fix12"
n, issue, bullet_no, acc, lens2, note = sys.argv[1:7]
import os
n = n + os.environ.get("ROUND_SUFFIX", "")
pr = json.load(open(f"{F}/pv/{n}/pr/pr.json"))
cl = json.load(open(f"{F}/pv/{n}/pr/pr_classified.json"))
a = [c for c in cl["claims"] if c.get("acceptance")][0]["acceptance"]
harness = {"core": "`pgpm_prv-15` (PostgreSQL 15, pgTAP available). Fresh database per run: `docker exec pgpm_prv-15 psql -U postgres -qc \"create database prv_<id>_<x>\"`, then the tree's `pgpm_core/install.sql` piped in with `docker exec -i pgpm_prv-15 psql -U postgres -d prv_<id>_<x> -v ON_ERROR_STOP=1 --single-transaction -f - < <tree>/pgpm_core/install.sql`",
           "timescale": "`pgpm_prv-15` (core, PostgreSQL 15, pgTAP) and `pgpm_prv-timescale` (the fleet image with TimescaleDB 2.16; it does not trust the local socket, so every psql is `docker exec -i -e PGPASSWORD=postgres pgpm_prv-timescale psql -h 127.0.0.1 -U postgres -d <db> -v ON_ERROR_STOP=1 -f -`; NEVER run `grant ... to current_user` in that image, it segfaults a backend). Fresh database per run (`prv_<id>_<x>`): `create extension timescaledb; create extension pgtap;`, then the tree's `pgpm_core/install.sql`, `pgpm_hypertable/install.sql` and `tests/timescale/fixtures.sql` piped in with `--single-transaction -f -` in that order (a claim's `install` list names those three files)",
           "archive": "`pgpm_prv-15` (core) and `pgpm_prv-archive` (PostgreSQL 17 with the http extension, pgcrypto and pgTAP already in template1; MinIO at http://minio:9000 with bucket `archive-test-bucket`, credentials minioadmin/minioadmin). Fresh database per run (`prv_<id>_<x>`): the tree's `tests/archive/fixtures.sql`, `pgpm_core/install.sql` and `pgpm_archive/install.sql` piped in with `--single-transaction -f -` in that order, the way test.sh's run_archive loads them (a claim's `install` list names those three files)"}
kind = "timescale" if "pgpm_hypertable" in open(f"{F}/pv/{n}/pr/surface/surface.md").read() else ("archive" if "pgpm_archive" in open(f"{F}/pv/{n}/pr/surface/surface.md").read() else "core")
H = harness[kind]
finder = f"""# Finder brief P1: per-PR verification of PR #{n}

You are the **finder** (`.claude/agents/finder.md`, read it in full first, including its "Per-PR mode" section if your copy has one; the rules below restate what matters) in a per-PR adversarial verification of pg_partition_magician under `docs/adversarial-review.md`. Your slice is ONE pull request's surface.

- PR #{n}: {pr['title']} ({pr['url']}). Its body (a claim to test, not a fact) is at `{F}/pv/{n}/pr/pr_body.md`. The issue bullet it addresses: `{F}/pv/{n}/pr/bullet.md`.
- The review tree (the PR's head as a single history-less commit; review ONLY this tree): `{F}/pv/{n}/pr/review`
- The change as presented, a unified diff of the base against that tree: `{F}/pv/{n}/pr/pr.diff`. You may read it; do not take any other diff and do not look for the base or any other checkout.
- Your slice: `{F}/pv/{n}/pr/surface/surface.md` (files, hunks, units and what calls what), ledger names in `{F}/pv/{n}/pr/surface/units.txt` (one per line; your coverage ledger must list every one of them exactly, `read: yes|no`). {note}
- Lenses: **fresh surface** (what the change introduced, what it left, interactions with the code around it) and **{lens2}**.
- Claims directory: `{F}/pv/{n}/pr/claims`; your finder id is `P1` (claims `P1-01`, `P1-02`, ... under `{F}/pv/{n}/pr/claims/P1/`, plus `null-results.md` and `coverage.md` there).
- Budget: about 150k tokens. Read every unit first, hypothesise second, build third; stop and write up rather than lower the bar.
- Harness: the private containers {H}, then your reproduction the same way. The repository is NOT mounted in any container: a reproduction reaches a file of the tree only through its claim's `install` list, never `\\i /repo/...`. Drop every database you create. Do not run `./test.sh`, do not touch other containers.
- Claim format and reproduction contract: the sections "Claim format" and "Reproduction contract" of `{F}/pv/{n}/pr/review/scripts/review/README.md` bind you: `claim.json` with tier, file, line, lens, scenario, repro, install; a `repro.sql` or `repro.sh` that FAILS when the defect is present and passes when absent, with at least one `LIVENESS:` assertion and every other premise check prefixed `GUARD:` or `fixture:`; identity over cardinality; asymmetric fixtures.

What counts here, in this order: (1) a defect the change INTRODUCED: your reproduction fails on this tree and would pass on the tree before the change (a refusal lost, a contract the body says is unchanged that is not, a message or a log row that changed shape); (2) a defect in the surface the change did not cause (fails before and after; still a claim, tiered honestly by the rubric: Tier 1 data loss or silently wrong result, 2 wedge or outage, 3 acts when it should refuse or a documented contract not kept, 4 misleading documentation, 5 a test or guard that passes for the wrong reason); (3) a claim in the PR body or in the new test's or guard's description that the code does not keep (the new test asserting something the fix does not guarantee is a Tier 5 claim; the body promising a site the code does not cover is a Tier 3 claim with the uncovered site as its reproduction). Tier every claim by consequence, not drama.

Deliverables: the claim directories; `null-results.md` (per lens, what you probed and that it held; then "Hypotheses" without reproductions); `coverage.md` (one line per ledger name: `- <unit> | read: yes|no | <what you probed, or why not>`); a final message of at most ten lines: claims (ids, tiers), lenses, units read over units in the slice, budget used.
"""
cv = f"""# Claims-verifier brief V: per-PR verification of PR #{n}

You are the **verifier** in its **claims-verifier** role (`.claude/agents/verifier.md`: read it in full first, its "Standards" and, if your copy has it, its "Per-PR mode" section; the rules below restate what matters) for pull request #{n} of pg_partition_magician, under `docs/adversarial-review.md` ("Definitions", "Roles and separation", "Between passes"). You see no finder's reasoning; a finder is reviewing the same PR in parallel and you must not look at its claims.

- PR #{n}: {pr['title']} ({pr['url']}); mutations it adds: {pr['mutations']}. Body: `{F}/pv/{n}/pr/pr_body.md`. The change itself (base against head): `{F}/pv/{n}/pr/pr.real.diff`.
- The issue bullet it says it addresses (issue #{issue}{bullet_no}, verified in pass 12 as {acc}): `{F}/pv/{n}/pr/bullet.md`; read the issue with `gh issue view {issue} --repo neptunestation-com/pg_partition_magician --comments` for the verifier's comment with the reproduction and its evidence.
- Source trees, both detached worktrees you may read in full, `bench/mutations/` included (the PR's mutation is one of its claims): head `{F}/pv/{n}/pr/head_src`, base `{F}/pv/{n}/pr/base_src`. Do not edit, commit or branch in either.
- The acceptance claim and the mechanical result already in hand: `{F}/pv/{n}/pr/claims/ACC/ACC-01/` (claim.json, repro.sql). The issue's reproduction fails on the base: {a['fails_on_base']}; passes on the head: {a['passes_on_head']}; fails again on the mutant built from the PR's new mutation(s): {a['mutant_restores']}. So the cheap half holds; your job is the other half.
- Open issues (a path whose mechanism an open issue other than #{issue} already names is `known_open` there, not a new claim): `{F}/open.json`.
- Harness: the private containers {H}, then your reproduction the same way; the repository is NOT mounted, so a file of the tree reaches a reproduction only through its claim's `install` list (never `\\i /repo/...`). Drop what you create; do not run `./test.sh`; do not touch other containers.
- Claims you write go under `{F}/pv/{n}/pr/claims/V/V-NN/` in the format of the README's "Claim format" and "Reproduction contract" sections (`{F}/pv/{n}/pr/head_src/scripts/review/README.md`): claim.json (tier, file, line, lens "closing claim", scenario, repro, install), a repro.sql or repro.sh that FAILS when the defect is present and passes when absent, at least one `LIVENESS:` assertion, other premise checks prefixed `GUARD:`/`fixture:`. Each claim will be classified against the base and the head: a path that fails on both is `pre_existing` (Tier 1 or 2 INSIDE the PR's surface blocks landing; outside it, it is filed), one that fails on the head only is a regression.
- Write your verdict to `{F}/pv/{n}/pr/verdicts/closing.json` as ONE JSON object: `{{"closing": {{"verdict": "holds" | "partial", "reason": "<what you tried and what settled it>", "claims": ["V-01", ...]}}}}`. `partial` when a path to the issue's consequence survives the change in the code the PR claims to cover; `holds` otherwise (a sibling mechanism elsewhere is a claim, not a `partial`, unless the body claims to cover it).

Your job is to DISPROVE the PR's closing claim: reach the issue's consequence (the bullet's Tier) through a path the diff does not cover. Ask, in order, and record each answer in the reason:
1. Which other call sites and entry points reach the same mechanism? Grep the head for the function the fix changed, the state it guards, and the sibling spellings of the same check in the other modules (`pgpm_core/`, `pgpm_archive/`, `pgpm_hypertable/`) and in `pgpm_core/uninstall.sql`.
2. Does the resume path, the upgrade path (an install over an older install with state already recorded), or the scheduled path (maintain / obtain ticks) share the defect?
3. Does the body promise a site the code does not cover? Every "guarantees", "covers", "refuses" sentence is a claim; find the input that breaks it.
4. Does the new guard assert the contract or an implementation spelling, and does each new mutation put back THIS defect (the acceptance reproduction already fails on the combined mutant; if the PR added two mutations, check whether each alone restores the issue's defect, and say which does not)?
5. Is anything the PR documents as a contract change (reference.md, CHANGELOG) a change an operator would meet as a refusal of a documented workflow?
Tier by consequence under the rubric (1 data loss or silently wrong result; 2 wedge or outage; 3 acts when it should refuse or a documented contract not kept; 4 misleading documentation; 5 a test or guard that passes for the wrong reason). Do not fix anything. Budget about 80k tokens; stop and write `holds` with what you tried rather than overrun. Final message of at most six lines: the verdict, the decisive fact, the paths written.
"""
open(f"{F}/pv/{n}/pr/brief_finder.md","w").write(finder); open(f"{F}/pv/{n}/pr/brief_claims_verifier.md","w").write(cv)
print(n, kind, len(finder), len(cv))
