#!/bin/bash
# pv_setup.sh <pr> <issue-for-brief> "<acc label>" "<lens2>" "<note>" <mutation> <claim-id>[,<claim-id>...] [--archive|--timescale]
# Builds the acceptance claims from the pass-12 claim directories (repro.verified.* preferred), the seed plan from
# the PR's quietest mutation, prepares the four trees, writes pr_body/bullet, runs the acceptance classification and
# renders the finder and claims-verifier briefs.
set -u
F=/Users/davida.ventimiglia/.claude/jobs/8d94cdfa/tmp/fix12; W=/Users/davida.ventimiglia/.claude/jobs/8d94cdfa/tmp/pass12
cd /Users/davida.ventimiglia/Work/pg_partition_magician || exit 5
PR=$1; ISSUE=$2; ACC=$3; LENS2=$4; NOTE=$5; MUT=$6; CLAIMS=$7; HARN=${8:-}
V=$F/pv/$PR${ROUND:+_r$ROUND}; mkdir -p $V/acc
i=0
IFS=',' read -ra CL <<< "$CLAIMS"
for c in "${CL[@]}"; do
  i=$((i+1)); d=$(printf 'ACC-%02d' $i); mkdir -p $V/acc/$d
  src=$W/claims/${c%%-*}/$c
  if [ -z "$src" ] || [ ! -d "$src" ]; then src=$F/acc_extra/$c; fi
  if [ -f $src/repro.verified.sql ]; then cp $src/repro.verified.sql $V/acc/$d/repro.sql; r=repro.sql
  elif [ -f $src/repro.verified.sh ]; then cp $src/repro.verified.sh $V/acc/$d/repro.sh; r=repro.sh
  elif [ -f $src/repro.sql ]; then cp $src/repro.sql $V/acc/$d/; r=repro.sql
  else cp $src/repro.sh $V/acc/$d/; r=repro.sh; fi
  for f in "$src"/*; do case "$(basename "$f")" in claim.json|repro.sql|repro.sh|repro.verified.sql|repro.verified.sh) ;; *) cp -R "$f" "$V/acc/$d/";; esac; done
  python3 - "$src/claim.json" "$V/acc/$d/claim.json" "$r" "$c" "$ISSUE" <<'PY'
import json,sys
c=json.load(open(sys.argv[1])); c["container"]={"pgpm_test-15":"pgpm_prv-15","pgpm_test-archive":"pgpm_prv-archive","pgpm_test-timescale":"pgpm_prv-timescale"}.get(c.get("container"), c.get("container")) if c.get("container") else None; c.pop("container") if c.get("container") is None else None; c["id"]=sys.argv[2].split("/")[-2]; c["finder"]="ACC"; c["repro"]=sys.argv[3]; c["scenario"]=f"#{sys.argv[5]} acceptance ({sys.argv[4]}): "+c["scenario"]
json.dump(c,open(sys.argv[2],"w"),indent=1)
PY
  grep -l "/repo" $V/acc/$d/$r >/dev/null 2>&1 && echo "WARNING: $d reads /repo"
done
python3 - "$V/plan.json" "$MUT" <<'PY'
import json,sys
m=sys.argv[2]
json.dump({"seeds":([{"mutation":m,"lens":"fresh surface","tier":3,"why":"the PR's own mutation, its quietest"}] if m and m!="-" else [])},open(sys.argv[1],"w"),indent=1)
PY
if [ "$MUT" = "-" ] || [ -z "$MUT" ]; then PLANOPT=""; rm -f $V/plan.json; else PLANOPT="--plan $V/plan.json"; fi
scripts/review/pr_verify.sh prepare $PR --work $V/pr --acceptance $V/acc $PLANOPT 2>&1 | tail -4
gh pr view $PR --json body --jq .body > $V/pr/pr_body.md
cp $F/issues/$ISSUE.md $V/pr/bullet.md
scripts/review/pr_verify.sh classify --work $V/pr 2>&1 | grep -E "acceptance|fixed|regression|pre_existing|not_reproduced|invalid|  ACC"
cd $F && python3 /Users/davida.ventimiglia/.claude/jobs/8d94cdfa/tmp/fix12/mkverify_briefs.py $PR $ISSUE "" "$ACC" "$LENS2" "$NOTE" && ls $V/pr/brief_*.md | wc -l
echo "units: $(wc -l < $V/pr/surface/units.txt)"; head -12 $V/pr/surface/surface.md
