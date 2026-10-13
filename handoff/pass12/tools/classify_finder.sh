#!/bin/bash
# classify_finder.sh <finder> [<suffix>]: classify one finder's claims (all of them, so a re-run after round 2 re-reads the whole set) into classified_<finder><suffix>.json
W=/Users/davida.ventimiglia/.claude/jobs/8d94cdfa/tmp/pass12
cd /Users/davida.ventimiglia/Work/pg_partition_magician
F=$1; S=${2:-}
scripts/review/classify_claims.py --claims $W/claims --review-tree $W/tree --pristine-tree . --sealed $W/sealed.json --finders $F --seeds-dir $W/seeds --out $W/classified_$F$S.json > $W/classify_$F$S.log 2>&1
echo "exit=$? $F$S"; python3 - "$W/classified_$F$S.json" <<'PY'
import json, sys
c = json.load(open(sys.argv[1]))
for x in c["claims"]:
    extra = ""
    if x["class"] == "seed_hit": extra = " seed=" + str(x.get("seed"))
    if x.get("pristine_liveness_failed") or "liveness" in str(x.get("note","")).lower(): extra += " [pristine liveness failed]"
    print(f"  {x['id']}\tT{x.get('tier')}\t{x['class']}{extra}\t{x.get('lens','')}\t{x.get('file','')}:{x.get('line','')}")
PY
