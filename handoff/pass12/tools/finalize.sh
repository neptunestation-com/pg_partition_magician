#!/bin/bash
# finalize.sh: after the final classification and every verdict: merge, metrics, assemble the record, history row, lint.
set -e
W=/Users/davida.ventimiglia/.claude/jobs/8d94cdfa/tmp/pass12
cd /Users/davida.ventimiglia/Work/pg_partition_magician
LAST=${LAST_VERDICT:?}; TOKENS=${TOKENS:?}; HUNT_END=${HUNT_END:?}
python3 $W/tools/merge_latest.py >/dev/null
jq -s 'add' $W/verdicts/*.json > $W/verdicts.json
scripts/review/pass_metrics.py --pass 12 --date 2026-10-12 --pinned bd55f84021fc4173034d156a41bc91a3f882560d \
  --release "v0.6.0-701-gbd55f840 (0.6.0 + 701: the 29 pass-11 fix PRs, the lever phase before pass 12 with its nine PRs, the records; no release cut)" \
  --sealed $W/sealed.json --classified $W/classified.json --verdicts $W/verdicts.json \
  --budget "19 finders on 17 slices (S1 and S5 duplicated on a second model; F1-F17 opus, F18-F19 fable; the fresh surface split by kind into four slices, the tests in four) plus the coverage re-runs, 350k to 550k tokens / 45 to 65 min each by unit count, plus a bounded round 2 (about 15 min / 100k each, aimed at the late-survivor shapes); one verifier per candidate (opus, medium); $TOKENS agent tokens; hunt 15:40Z on 2026-10-12 to last verdict $LAST on 2026-10-12" \
  --budget-units $TOKENS \
  --lenses "fresh surface, time and zones, boundary arithmetic and types, operator error, failure injection, contracts versus documentation" \
  --previous-lenses "fresh surface, identity and names, concurrency and locks, upgrade and install paths, tests that pass for the wrong reason, resource cliffs" \
  --ages $W/ages.json --coverage $W/coverage.json --capture-recapture "${CAPTURE:-not attempted}" --root-cause-groups 33 \
  --out $W/record_final.md >/dev/null
python3 $W/tools/assemble.py $W/record_final.md $W/record_assembled.md
cp $W/record_assembled.md docs/reviews/2026-10-12-pass12.md
python3 - <<PY
W="$W"
p="docs/adversarial-review.md"; s=open(p).read().split("\n")
row=open(f"{W}/history_row.md").read().strip()
i=[k for k,l in enumerate(s) if l.startswith("| 11 | 2026-10-09 |")][0]
assert not any(l.startswith("| 12 | ") for l in s), "row 12 already present"
s.insert(i+1,row); open(p,"w").write("\n".join(s)); print("history row inserted after line",i+1)
PY
npx -y markdownlint-cli2@0.13.0 docs/reviews/2026-10-12-pass12.md docs/adversarial-review.md 2>&1 | tail -3
