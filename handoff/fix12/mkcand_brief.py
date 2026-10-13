#!/usr/bin/env python3
"""mkcand_brief.py <pr> <claim-id> [<extra note>]: the candidate-verifier brief for one regression/pre_existing
claim of a per-PR verification, written to $W/v/<pr>/briefs/<claim-id>.md and printed."""
import json, os, sys
W = "/Users/davida.ventimiglia/.claude/jobs/8d94cdfa/tmp/fix12"
n, cid = sys.argv[1], sys.argv[2]; note = sys.argv[3] if len(sys.argv) > 3 else ""
finder = cid.split("-")[0]
cdir = f"{W}/pv/{n}/pr/claims/{finder}/{cid}"
claim = json.load(open(f"{cdir}/claim.json"))
rec = json.load(open(f"{W}/pv/{n}/pr/verify/{cid}.json"))["claims"][0]
cls = rec["class"]
surface = open(f"{W}/pv/{n}/pr/surface/surface.md").read()
kind = "timescale" if "pgpm_hypertable" in surface else ("archive" if "pgpm_archive" in surface else "core")
install = {"core": "the tree's files of the claim's `install` list piped in with `docker exec -i pgpm_prv-15 psql -U postgres -d <db> -v ON_ERROR_STOP=1 --single-transaction -f - < <tree>/<file>`, in order",
           "timescale": "in `pgpm_prv-timescale` (TCP: `docker exec -i -e PGPASSWORD=postgres pgpm_prv-timescale psql -h 127.0.0.1 -U postgres -d <db> -v ON_ERROR_STOP=1 -f -`; `create extension timescaledb; create extension pgtap;` first; NEVER grant to current_user there), the claim's `install` list piped in with `--single-transaction -f -`, in order",
           "archive": "in `pgpm_prv-archive` (http, pgcrypto, pgTAP in template1; MinIO at minio:9000, bucket archive-test-bucket, minioadmin/minioadmin), the claim's `install` list piped in with `--single-transaction -f -`, in order"}[kind]
reg = ("The claim classified `regression`: its reproduction fails on the head and NOT on the base, so the base does not share it; "
       "your question is whether the head's behaviour is a defect in pgpm by the rubric, or a change the PR documents that the reproduction merely pins the old spelling of."
       if cls == "regression" else
       "The claim classified `pre_existing`: its reproduction fails on both trees, a review pass's candidate; verify it as one.")
brief = f"""You are the **verifier** for ONE candidate claim of the per-PR adversarial verification of pull request #{n} of pg_partition_magician (docs/adversarial-review.md: read "Definitions", "Roles and separation", "Between passes" in {W}/pv/{n}/pr/head_src/docs/adversarial-review.md first, and the standards in .claude/agents/verifier.md). You see nobody's reasoning: only the claim and its reproduction. Your job is to try to make it fall.

- Claim directory: {cdir} (claim.json, {claim.get('repro')}); its scenario: {claim.get('scenario')}
- Trees: the PRISTINE commit is the PR's merge base, {W}/pv/{n}/pr/base; the REVIEW tree is the PR's head, {W}/pv/{n}/pr/head (history-less exports). {reg} Record: {W}/pv/{n}/pr/verify/{cid}.json. The PR's source with history, for docs and `bench/`: {W}/pv/{n}/pr/head_src (read only; do not edit, commit or branch). {note}
- Re-run it yourself first, exactly so (from the checkout /Users/davida.ventimiglia/Work/pg_partition_magician):

  python3 scripts/review/pr_classify.py --claims {W}/pv/{n}/pr/claims --base {W}/pv/{n}/pr/base --head {W}/pv/{n}/pr/head --only {cid} --out {W}/pv/{n}/pr/verify/{cid}.rerun.json --container pgpm_prv-15 --archive-container pgpm_prv-archive --timescale-container pgpm_prv-timescale

  or by hand: a fresh database per tree (`prv_{cid.lower().replace('-', '_')}_<x>`), {install}, then the reproduction the same way. The repository is NOT mounted in any container. Drop what you create; create roles only when absent and drop them at the end; do not run ./test.sh.
- Open issues (a claim whose MECHANISM an open issue already names is `known_open` with that number; compare by mechanism, not wording; the PR's own issue counts only for the bullet the PR fixes): /Users/davida.ventimiglia/.claude/jobs/8d94cdfa/tmp/fix12/open.json.
- Then read the code the claim points at in the head tree and the documentation (docs/reference.md, docs/guide.md, docs/runbook.md, the unit's own comments). Ask in order: documented and intended? a test artifact rather than pgpm? a state pgpm refuses to enter, a hand edit, or privileges the design says the caller lacks? the environment? the right tier by the rubric (Tier 1 data loss or silently wrong result; 2 wedge; 3 acts when it should refuse or a contract not kept; 4 misleading docs; 5 a test or guard that passes for the wrong reason)? known and open?
- Decide: `finding` (tier, one-phrase root cause), `fell` (the decisive reason, quoting what settles it), or `known_open` (issue). If you changed the fixture or the assertions, store your version as `repro.verified.sql` (or `.sh`) beside the original (never edit the original), keeping the contract (a `LIVENESS:` assertion, fails when the defect is present, passes when absent, reaches the defect on the tree it fails on, on its own) and add `"rebuilt": true, "repro": "repro.verified.sql"`.
- Write the verdict as ONE JSON object to {W}/pv/{n}/pr/verdicts/{cid}.json: {{"{cid}": {{"verdict": "finding", "tier": N, "root_cause": "..."}}}} or {{"{cid}": {{"verdict": "fell", "reason": "..."}}}} or {{"{cid}": {{"verdict": "known_open", "issue": NNN}}}}.

Do not fix anything and do not edit either tree. Budget about 50k tokens. Final message of at most five lines: the verdict, the decisive fact, the paths written.
"""
os.makedirs(f"{W}/pv/{n}/pr/briefs", exist_ok=True)
open(f"{W}/pv/{n}/pr/briefs/{cid}.md", "w").write(brief)
print(brief)
