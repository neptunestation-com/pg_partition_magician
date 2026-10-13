---
name: project-pass3-prep
description: "Review pass 3 DONE 2026-09-28 (pinned db64096): 73 claims, recall 9/9, precision 0.92, 55 findings (T1 9, T2 21, T3 18, T4 1, T5 6) in 39 root-cause groups filed as #563-#601 (T1 #563-#571), 4 known-open re-finds commented, 2 fell; record docs/reviews/2026-09-28.md (PR pending); prep PRs #560-#562 merged first; fix phase NOT started"
metadata:
  type: project
  originSessionId: e3676f1f-5dd0-49b1-884e-c5176eaa0ec4
  modified: 2026-09-28T00:00:00Z
---

After [[project-pass2-fix-phase]] the user asked how to run the loop again, then said "do the prep"
(the four items I recommended from issue #558). Work split into three independent PRs, 2026-09-28:

- **PR #560 (mine, branch feat/fix-phase-tooling)**: scripts/review/{land.sh, keep_both.py,
  flake_check.sh, closure.sh, close_comments.py} with selftests wired into the lint job,
  .claude/agents/fixer.md, .claude/skills/fix-phase/SKILL.md, docs/adversarial-review.md "Fix phase"
  section, README section, CHANGELOG bullet. The scratchpad versions were lost in the reboot; these
  are rewritten from the design in the pass-2 record.
- **Subagent PR (branch feat/review-verified-repros)**: verifier writes repro.verified.sql + verdict
  `rebuilt`; classify_claims prefers it; plant_seeds carries `side_effects`; pass_metrics prints seed
  interactions; new file_issues.py (issue rendering/posting, replaces the lost scratch finalize.py);
  finder LIVENESS mandatory.
- **Subagent PR (branch ci/cache-third-party-images)**: actions/cache of the supabase/postgres and
  MinIO image tarballs in timescale/archive/perf workflows; test.sh skips a pull when the image is
  present.
- **Not done, user's decision**: flipping merge queue ruleset 24013010 merge_method SQUASH -> MERGE
  for fix waves (documented in the Fix phase section as a maintainer decision).

**Why:** the pass-2 fix phase showed the hunt tooling was versioned but the landing tooling was not,
and that the squash queue serialises landing (~24 min/PR).

**How to apply:** land #560 FIRST by running its own land.sh from the worktree
(.claude/worktrees/fix-phase-tooling; ROOT resolves to the worktree so keep_both.py is found), then
the two subagent PRs from the main checkout with the merged land.sh. Then pass 3:
`/review-pass <post-prep main sha> 9 <lenses>` with finder model flipped to opus (pass-2 evidence),
fresh-surface lens (25 fix PRs + zone model), plus concurrency and upgrade-compatibility lenses.
#559 (pass-2 record fix-phase section) was re-enqueued 2026-09-28 after the lock-guard flake knocked
it out (5th occurrence, docs-only PR; noted on #556). Lock-guard flake retry is automatic in land.sh.

**Status 2026-09-28 18:30Z:** all three prep PRs merged (land.sh landed #560 using itself, then #561 and
#562 with two real keep-both resolutions: lint.yml + CHANGELOG). Registry-quota flake hit #560's head once
and was retried automatically. Pass 3 could not be started by me: `.claude/skills/review-pass/SKILL.md` has `disable-model-invocation: true` (set in pass 2 so only the user launches a pass), so the user must type `/review-pass db64096e469610f5325bf82228e102d00f9c5cba 9
fresh-surface, concurrency, upgrade-compatibility, regrain-lifecycle, archive, zone-time-model,
contracts-vs-docs, harness-and-ci`; plan: 10 finders (8 slices, finders on opus by Agent model override,
two slices duplicated on fable for the model comparison), verifiers opus/medium, ~5M token budget.

**Pass 3 RUNNING (user typed /review-pass 2026-09-28 18:3xZ):** pinned db64096 (v0.6.0-64), K=9 (6 catalogue
pass-2-fix mutations + 3 novel: retire straddle, archive over-claim, abort pid-only), lenses = fresh surface,
concurrency and locks, upgrade and install paths, time and zones, failure injection, boundary arithmetic and
types, operator error, resource cliffs (4 of 8 differ from pass 2; regrain/archive/harness are SLICES). Ten
finders launched 18:38Z (F1-F8 opus, F9=S3 dup and F10=S8 dup on fable). Work dir scratchpad/pass3 (claims,
tree, slices, prompts); sealed material in scratchpad/pass3_sealed (sealed.json, plan.json, seeds/,
catalogue.txt, budget.md, open.json, finders.tsv, verifier prompt template). Harness pgpm_test-15 +
pgpm_test-archive up from main. Next: classify -> verifiers (one per candidate) -> pass_metrics -> file_issues.

**Pass 3 hunt DONE 2026-09-28 19:06Z:** 73 claims, 12 seed hits, recall 9/9, 61 candidates; finders 2.13M tokens,
11-27 min each (self-reported 20-45). Verification in progress (39 verdicts by 19:40Z: 24 findings T1 3 / T2 8
/ T3 7 / T5 6, 3 fell, 2 known_open); all F1/F4/F6/F7/F8/F9/F10 verified, F2 (7), F3 (6), F5 (9) verifiers
running; F5-06 (lock-table exhaustion) must run ALONE last. Files: pass3/classified.json (merged),
pass3/verdicts/*.json, pass3_sealed/usage.tsv. Then: jq -s add verdicts -> verdicts.json; pass_metrics.py
--pass 3 ...; groups.json; file_issues.py; record PR.

**Pass 3 RESULT (2026-09-28 20:1xZ):** 73 claims / 12 seed hits / recall 1.00 / precision 0.92 / 55 findings
(T1 9: hypertable swap commits before validate #563, retire() trusts stale coverage #564, retain interval
compare '-1 year 360 days' #565, publication membership lost #566, Parquet negative scale zeros #567, ICU
numeric collation accepted #568, hand-cleared cursor resurrects DELETE #569 (tie-break: hand edits count when
pgpm documents handling the state), reconcile bare ::text under DateStyle SQL #570; T2 21 incl. min(uuid) in
#513's site #571 (3 finders), #503 legacy labels after upgrade, regrain() deadlock, maintain_all shared
statement_timeout, GZIP lock-table exhaustion; T5 6 against the review tooling itself #600/#601). Opus vs
fable: both 1.00 precision; opus found 2 T1 fable missed on S3, fable found the deadlock; union best.
Cost 4.44M tokens (finders 2.13M, 62 verifier runs 2.30M), 80.7k/finding, 493k/T1. Fell: F6-04
(constructed old signature), F4-08 (NaN hand edit). Rebuilt repros: F1-08, F1-11, F2-07. Follow-ups not
done: add the 3 novel seeds to bench/mutations (need guards), fix phase (/fix-phase, 39 issues; user's call).
Stopping criteria NOT met (9 T1). Record PR: docs/pass-3-record branch.

**Fix phase 3 STARTED 2026-09-28 ~22:10Z (user typed /fix-phase; #602 record PR enqueued via land.sh).**
Work dir scratchpad/fix3: plan.json + plan.md (23 fixer groups G1-G23 over the 39 issues, tier order;
assigned tests/130-156, tests/archive/db/18-24, tests/timescale/db/21, pgpm_perf42-80; next free
tests/157, archive 25, timescale 22, pgpm_perf81), briefs/G*.md, prs.tsv (issue pr test guard mutation),
gate.sh (mkdir mutex; EVERY ./test.sh run goes through it; stale lock = rmdir fix3/gate.lock), fix/G*/
scratch. Shared infra: docker network fix_net + container fix_minio (alias minio, bucket
archive-test-bucket) for archive fixers; each fixer runs its own pgpm_fix_G<n> container from local
images. G1-G20 spawned 22:1xZ (fixer agent, opus, isolation worktree); G21 extend-to, G22 to-s3, G23
tooling wait for slots. Then: land.sh in tier order (G1..G8 T1 first), closure.sh --claims pass3/claims,
caveats.json, close_comments.py, record fix-phase section, adjacent issues, remove worktrees.

**Update 2026-09-29:** the maintainer decided to switch the merge queue (ruleset 24013010) from SQUASH to MERGE commits before pass 4, after the pass-3 fix phase's landings finish. The flip is one `gh api -X PUT` on the ruleset's merge_queue rule (`merge_method: "MERGE"`); the repo already allows merge commits. Pass-4 prep then includes a batch mode for `scripts/review/land.sh` (up to 5 PRs per merge group) and doc updates in docs/adversarial-review.md and scripts/review/README.md. Pass 3 fix phase measured about 25 to 30 minutes per PR one at a time, about a day for 23 PRs.
**Done 2026-09-29 11:55Z:** the flip ran (before SQUASH, after MERGE) right after PR #626, the last PR of the pass-3 fix phase, merged. Pass-4 prep still owes land.sh a batch mode and the two doc updates.
