#!/usr/bin/env bash
# F12r-02: stop_check.py judges the stopping criteria on the figures pass_metrics.py writes into the record,
# and those are rounded to two decimals first. A pass at precision 16/23 = 0.696 and fell rate 7/23 = 0.304,
# with one finder's coverage at 26/29 = 0.897 (below the 0.9 gate), is recorded as "precision 0.70 (..., fell
# rate 0.30)" and "coverage: 0.90 (1 of 2 finders at or above 0.90)"; pass_metrics' own status rows for that
# record read precision and fell rate NOT met, but stop_check reads 0.70 >= 0.7, 0.30 <= 0.3 and 0.90 >= 0.9 as
# met, and with a second such pass reports the campaign CONVERGED (stop).
# Env: TREE (no database needed; PSQL unused).
set -uo pipefail
python3 - "$TREE" <<'PY'
import os, sys, tempfile, contextlib, io
tree = sys.argv[1]
sys.path.insert(0, os.path.join(tree, "scripts", "review"))
import pass_metrics, stop_check

fail = False
def check(label, ok, detail=""):
    global fail
    print(("ok - " if ok else "not ok - ") + label + (f" ({detail})" if detail else ""))
    if not ok and not label.startswith(("LIVENESS:", "GUARD:", "fixture:")):
        fail = True
    if not ok and label.startswith(("LIVENESS:", "GUARD:", "fixture:")):
        fail = True

A5 = stop_check.A5; B5 = stop_check.B5
cov = {"threshold": 0.9, "rows": [
    {"finder": "F1", "kind": "sql", "units": 40, "read": 40, "coverage": 1.0, "ledger": "ok"},
    {"finder": "F2", "kind": "files", "units": 29, "read": 26, "coverage": round(26 / 29, 3), "ledger": "ok"}]}
cov_line = pass_metrics.coverage_line(cov)
check("LIVENESS: one finder's coverage (26 of 29 units, 0.897) is below the 0.9 gate, and the line's count says so",
      "1 of 2 finders at or above 0.90" in cov_line and cov["rows"][1]["coverage"] < 0.9, cov_line)

def sealed():
    return {"seeds": [{"id": f"S{i}", "lens": "x", "tier": 2, "mutation": f"m{i}", "suite_caught": [],
                       **({"late_survivor": {"issue": 1000 + i, "passes_survived": 6}} if i <= 3 else {})}
                      for i in range(1, 10)]}
claims = [{"id": f"F1-{i:02d}", "finder": "F1", "class": "seed_hit", "seed": f"S{i}", "tier": 2} for i in range(1, 10)]
claims += [{"id": f"F2-{i:02d}", "finder": "F2", "class": "candidate", "tier": 3, "lens": "operator error",
            "scenario": "s"} for i in range(1, 15)]
verdicts = {f"F2-{i:02d}": ({"verdict": "finding", "tier": 3, "root_cause": f"r{i}"} if i <= 7
                            else {"verdict": "fell", "reason": "documented"}) for i in range(1, 15)}
m = pass_metrics.compute(sealed(), {"claims": claims}, verdicts)
check("LIVENESS: the pass's precision is 16/23 and its fell rate 7/23, below and above the lines",
      abs(m["precision"] - 16 / 23) < 1e-9 and abs(m["fell_rate"] - 7 / 23) < 1e-9 and m["by_tier"][1] == 0,
      f"precision {m['precision']:.4f}, fell {m['fell_rate']:.4f}")
status = dict(pass_metrics.stopping_status(m))
check("LIVENESS: pass_metrics' own status rows for this pass read precision and fell rate NOT met",
      status["precision >= 0.7 (verified re-finds of open issues counted as true reports)"] is False
      and status["fell rate <= 0.3"] is False)

with tempfile.TemporaryDirectory() as d:
    rdir = os.path.join(d, "reviews"); os.makedirs(rdir)
    rows = ["| 1 | 2026-09-24 | `aaaaaaa` | 76 (25 filed as T1) | ~106 | not measured | none | baseline |"]
    for n, lenses in ((12, A5), (13, B5)):
        class A:
            pass_n, date, pinned, release = n, f"2026-10-{n:02d}", "abc1234", "0.7.0"
            budget, previous_lenses = "x", "x"
            capture_recapture = "attempted on the duplicated slices: estimate 0 on both"
            root_cause_groups, root_causes_file, notes_file = None, None, None
            coverage_line = cov_line
        A.lenses = "fresh surface, " + lenses
        A.previous_lenses = "fresh surface, operator error"
        rec = pass_metrics.record(m, A)
        with open(os.path.join(rdir, f"2026-10-{n:02d}.md"), "w") as f:
            f.write(rec)
        rows.append(f"| {n} | 2026-10-{n:02d} | `abc1234` | 7 (0 T1) | 23 | 0.70 | 9 / 1.00 | x |")
    hist = os.path.join(d, "method.md")
    with open(hist, "w") as f:
        f.write("\n".join(["# Method", "", stop_check.LENS_SECTION, "## Pass history", "",
                           "| pass | date | pinned | findings (T1) | claims | precision | seeds / recall | notes |",
                           "|---|---|---|---|---|---|---|---|"] + rows + [""]))
    head = open(os.path.join(rdir, "2026-10-13.md")).read().split("\n")[:6]
    check("fixture: the record carries the rounded figures stop_check reads",
          any("precision 0.70 (strict 0.70, fell rate 0.30)" in ln for ln in head) and cov_line in head,
          " / ".join(head[3:6]))
    lenses, hrows, recs = stop_check.load(hist, rdir)
    v = stop_check.decide(lenses, hrows, recs, extended_through=14)
    b = v["criteria"]["b"]["checks"]
    check("stop_check judges precision >= 0.7 NOT met for a pass at 16/23 = 0.696",
          b["precision >= 0.7"]["met"] is False, f"read {b['precision >= 0.7']['values']}")
    check("stop_check judges fell rate <= 0.3 NOT met for a pass at 7/23 = 0.304",
          b["fell rate <= 0.3"]["met"] is False, f"read {b['fell rate <= 0.3']['values']}")
    per = v["criteria"]["a"]["passes"]
    check("stop_check judges coverage NOT at the 0.9 gate when a finder read 0.897",
          not any(p["qualifies"] for p in per.values()), f"coverage read {[p['coverage'] for p in per.values()]}")
    check("stop_check does not declare the campaign converged on these two passes",
          not v["reason"].startswith("converged"), v["lines"][-1][:160])
sys.exit(1 if fail else 0)
PY
