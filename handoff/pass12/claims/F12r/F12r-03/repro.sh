#!/usr/bin/env bash
# F12r-03: pass_metrics.py files a candidate WITHOUT a verdict (and any verdict string it does not know, such as
# a "known-open" typo) under FELL: compute() sends `verdicts.get(id, {"verdict": "unverified"})` through
# `{...}.get(v["verdict"], fell)`. scripts/review/README.md says such a candidate "is reported as unverified and
# is not a finding", and the fell rate is "claims that fell in verification"; instead the record counts it in
# `fell` AND `unverified`, lists it under "## Fell in verification" with an empty reason, and the fell rate the
# stopping criteria and the mid-pass abandon rule read includes it.
# Env: TREE.
set -uo pipefail
python3 - "$TREE" <<'PY'
import os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "scripts", "review"))
import pass_metrics
fail = False
def check(label, ok, detail=""):
    global fail
    print(("ok - " if ok else "not ok - ") + label + (f" ({detail})" if detail else ""))
    fail |= not ok
sealed = {"seeds": [{"id": "S1", "lens": "x", "tier": 1, "mutation": "m"}]}
claims = [{"id": "F1-01", "finder": "F1", "class": "seed_hit", "seed": "S1", "tier": 1},
          {"id": "F1-02", "finder": "F1", "class": "candidate", "tier": 3, "scenario": "a real finding"},
          {"id": "F1-03", "finder": "F1", "class": "candidate", "tier": 3, "scenario": "fell for cause"},
          {"id": "F1-04", "finder": "F1", "class": "candidate", "tier": 2, "scenario": "not yet verified"}]
verdicts = {"F1-02": {"verdict": "finding", "tier": 3, "root_cause": "r"},
            "F1-03": {"verdict": "fell", "reason": "documented"}}
m = pass_metrics.compute(sealed, {"claims": claims}, verdicts)
check("LIVENESS: one candidate (F1-04) has no verdict and is counted unverified; exactly one (F1-03) fell",
      m["unverified"] == 1 and m["candidates"] == 3 and "F1-04" not in verdicts, f"unverified={m['unverified']}")
fell_ids = [r["id"] for r in m["fell_rows"]]
check("the candidate without a verdict is not counted as fell", "F1-04" not in fell_ids, f"fell rows {fell_ids}")
check("the fell rate is the one claim that fell over four, 0.25", abs(m["fell_rate"] - 0.25) < 1e-9,
      f"fell rate {m['fell_rate']}")
class A:
    pass_n, date, pinned, release = 12, "2026-10-12", "abc", "x"
    budget, lenses, previous_lenses, capture_recapture = "", "time", "none", "not attempted"
    root_cause_groups, root_causes_file, notes_file = None, None, None
rec = pass_metrics.record(m, A)
sec = rec.split("## Fell in verification", 1)[1].split("##", 1)[0]
check("the record's Fell in verification section does not list the unverified candidate", "F1-04" not in sec,
      sec.strip().replace("\n", " | "))
# a misspelt verdict is not silently a fall either
m2 = pass_metrics.compute(sealed, {"claims": claims}, {**verdicts, "F1-04": {"verdict": "known-open", "issue": 439}})
check("a verdict string compute() does not know (\"known-open\") is not silently counted as fell",
      "F1-04" not in [r["id"] for r in m2["fell_rows"]], f"fell rows {[r['id'] for r in m2['fell_rows']]}")
sys.exit(1 if fail else 0)
PY
