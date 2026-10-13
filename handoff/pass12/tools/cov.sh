#!/bin/bash
# cov.sh: score every finder's coverage ledger present so far (exit 1 is expected while ledgers are missing)
W=/Users/davida.ventimiglia/.claude/jobs/8d94cdfa/tmp/pass12
cd /Users/davida.ventimiglia/Work/pg_partition_magician
python3 - <<'PY'
import json, os, glob
W="/Users/davida.ventimiglia/.claude/jobs/8d94cdfa/tmp/pass12"
s=json.load(open(f"{W}/slices.json")); m=json.load(open(f"{W}/finder_slice.json"))
out={f:s[k] for f,k in m.items()}
# re-run finders: slices/<finder>.units.txt with an explicit unit list (F9r, F11r2, ...)
for p in glob.glob(f"{W}/slices/F*.units.txt"):
    rf=os.path.basename(p)[:-10]
    out[rf]={"units":[u for u in open(p).read().split("\n") if u]}
json.dump(out,open(f"{W}/slices_finders.json","w"),indent=1)
PY
scripts/review/coverage.py --tree $W/tree --slices $W/slices_finders.json --claims $W/claims --out $W/coverage.json "$@" 2>&1 | grep -v "ledger missing"
