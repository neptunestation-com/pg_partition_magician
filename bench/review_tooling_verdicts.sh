#!/usr/bin/env bash
# Prove the review loop's scripts decide what their contracts say on the inputs that once fooled them. Each
# section below names its defect, its issue, the mutations in bench/mutations/mutate.py it is required to fail
# against, and the controls that keep its negatives honest. Each of these scripts decides something nobody
# re-checks by hand (whether the loop stops, what a pass's record says, whether a merge group is stalled,
# whether a CI failure is retried), and each decided it wrong while its own self-test stayed green.
#
# HOW. scripts/review/ is copied to a scratch directory and run there. Given a mutant, the guard puts it in
# place of the script it differs least from, so a mutant of any of them is judged by the same run, and every
# other section runs on the real scripts beside it.
#
# Usage: review_tooling_verdicts.sh <container> <db> [mutant]
# Needs python3, jq and bash on the host and nothing else. <container> and <db> are accepted so
# bench/discriminate.sh can call it the way it calls every guard, and are not used. A /repo/... path is mapped
# to this checkout, which is how discriminate.sh points it at a mutant (named *.sql whatever it mutates).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MUT="${3:-}"
MUT="${MUT/#\/repo\//$ROOT/}"
fail=0
ok()  { printf 'PASS  %-62s %s\n' "$1" "$2"; }
bad() { printf 'FAIL  %-62s %s\n' "$1" "$2"; fail=1; }
check() { if [ "$1" = 0 ]; then ok "$2" "$3"; else bad "$2" "$3"; fi; }

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
R="$work/review"
mkdir -p "$R"
cp "$ROOT"/scripts/review/*.py "$ROOT"/scripts/review/*.sh "$R"/
if [ -n "$MUT" ]; then
  if [ ! -f "$MUT" ]; then bad "fixture: the mutant under test exists" "$MUT"; exit 1; fi
  best=""; bestn=""
  for f in "$R"/*.py "$R"/*.sh; do
    n=$(diff "$MUT" "$f" | grep -c '^[<>]')
    if [ -z "$bestn" ] || [ "$n" -lt "$bestn" ]; then best=$f; bestn=$n; fi
  done
  cp "$MUT" "$best"
  ok "fixture: the mutant stands in for its script" "${best##*/} ($bestn line(s) differ)"
fi

# ---------------------------------------------------------------- (a) (b) (c): the Python scripts
#   (a) #1288: stop_check.py judged precision >= 0.7, fell rate <= 0.3 and coverage >= 0.9 on the two-decimal
#       figures pass_metrics.py writes, so 16/23 = 0.696, 7/23 = 0.304 and a finder at 26/29 = 0.897 read as
#       met and two such passes came back "stop: converged". Driven through the real pass_metrics.compute()
#       and record() and stop_check.load() and decide(). The control is the same two passes one claim and one
#       unit the other side of each line, which converge; each edge is also judged alone beside a clear other.
#         stop_check_precision_on_rounded_figure  the exact fractions parsed and not used
#         stop_check_coverage_on_rounded_minimum  the coverage gate on the two-decimal minimum again
#   (b) #1289: pass_metrics.py counted a candidate with no verdict, or a verdict string it did not know
#       ("known-open"), as FELL: under "Fell in verification" and in the fell rate. The controls: the finding
#       and the seed hit are counted, and the CLI writes the record once the typo is corrected.
#         pass_metrics_unverified_reads_fell      no verdict or an unknown one routed to fell again
#   (c) #1290: decisions_queue.py's parse skipped any line not starting with "- D", so a BLOCKING entry written
#       indented, under a `*` bullet or with a lower-case id was never read and the loop went on. The controls:
#       the exact shape blocks, and the header's prose with a default entry parses with nothing pending.
#         decisions_queue_skips_malformed_line    a line not starting "- D" skipped again
python3 - "$R" <<'PY' || fail=1
import contextlib, io, json, os, subprocess, sys, tempfile
R = sys.argv[1]
sys.path.insert(0, R)
import pass_metrics, stop_check, decisions_queue
fail = 0


def say(good, what, detail=""):
    global fail
    print(f"{'PASS' if good else 'FAIL'}  {what:<62} {detail}")
    fail |= not good


# (a) #1288. Two passes of 23 claims: 9 seed hits and 14 candidates, `found` of them findings and the rest fell;
# finder F2 read `read` of its 29 units. The edge: 16/23 precision, 7/23 fell, 26/29 coverage. The control:
# 17/23, 6/23, 27/29, which every line clears.
def pm_pass(n, lenses, found, read):
    sealed = {"seeds": [{"id": f"S{i}", "lens": "x", "tier": 2, "mutation": f"m{i}", "suite_caught": [],
                         **({"late_survivor": {"issue": 1000 + i, "passes_survived": 6}} if i <= 3 else {})}
                        for i in range(1, 10)]}
    claims = [{"id": f"F1-{i:02d}", "finder": "F1", "class": "seed_hit", "seed": f"S{i}", "tier": 2} for i in range(1, 10)]
    claims += [{"id": f"F2-{i:02d}", "finder": "F2", "class": "candidate", "tier": 3, "scenario": "s"} for i in range(1, 15)]
    verdicts = {f"F2-{i:02d}": ({"verdict": "finding", "tier": 3} if i <= found else {"verdict": "fell", "reason": "r"})
                for i in range(1, 15)}
    m = pass_metrics.compute(sealed, {"claims": claims}, verdicts)
    cov = {"rows": [{"finder": "F1", "coverage": 1.0, "ledger": "ok"},
                    {"finder": "F2", "coverage": round(read / 29, 3), "ledger": "ok"}]}

    class A:
        pass_n, date, pinned, release, budget = n, f"2026-10-{n:02d}", "abc1234", "x", "x"
        previous_lenses = "fresh surface"
        capture_recapture = "attempted on the duplicated slices: estimate 0 on both"
        root_cause_groups, root_causes_file, notes_file = None, None, None
        coverage_line = pass_metrics.coverage_line(cov)
    A.lenses = "fresh surface, " + lenses
    return m, pass_metrics.record(m, A)


def judge(name, found, read):
    d = os.path.join(tempfile.mkdtemp(), name)
    rdir = os.path.join(d, "reviews")
    os.makedirs(rdir)
    rows = ["| 1 | 2026-09-24 | `aaaaaaa` | 76 (25 filed as T1) | ~106 | not measured | none | baseline |"]
    m = rec = None
    for n, lenses in ((12, stop_check.A5), (13, stop_check.B5)):
        m, rec = pm_pass(n, lenses, found, read)
        with open(os.path.join(rdir, f"2026-10-{n:02d}.md"), "w") as f:
            f.write(rec)
        rows.append(f"| {n} | 2026-10-{n:02d} | `abc1234` | 7 (0 T1) | 23 | x | 9 / 1.00 | x |")
    hist = os.path.join(d, "method.md")
    with open(hist, "w") as f:
        f.write("\n".join(["# Method", "", stop_check.LENS_SECTION, "## Pass history", "",
                           "| pass | date | pinned | findings (T1) | claims | precision | seeds / recall | notes |",
                           "|---|---|---|---|---|---|---|---|"] + rows + [""]))
    lenses, hrows, recs = stop_check.load(hist, rdir)
    return m, rec, stop_check.decide(lenses, hrows, recs, extended_through=14)


try:
    m, rec, v = judge("control", 8, 27)
    say(v["verdict"] == "stop" and v["reason"].startswith("converged"),
        "LIVENESS: (a) the control passes (17/23, 6/23, 27/29) converge", v["lines"][-1][:90])
    m, rec, v = judge("edge_prec", 7, 27)
    head = "\n".join(rec.split("\n")[:8])
    say(abs(m["precision"] - 16 / 23) < 1e-9 and "precision 0.70 (strict 0.70, fell rate 0.30)" in head,
        "LIVENESS: (a) a pass at 16/23 and 7/23, printed 0.70 and 0.30", f"precision {m['precision']:.4f}")
    b = v["criteria"]["b"]["checks"]
    say(b["precision >= 0.7"]["met"] is False, "(a) precision >= 0.7 NOT met at 16/23 = 0.696", str(b["precision >= 0.7"]["values"]))
    say(b["fell rate <= 0.3"]["met"] is False, "(a) fell rate <= 0.3 NOT met at 7/23 = 0.304", str(b["fell rate <= 0.3"]["values"]))
    say(v["criteria"]["a"]["met"], "LIVENESS: (a) with coverage clear, the lens cycle itself is met", "")
    m, rec, v = judge("edge_cov", 8, 26)
    say("coverage: 0.90 (1 of 2 finders at or above 0.90)" in rec,
        "LIVENESS: (a) a finder at 26/29 = 0.897, its minimum printed 0.90", "")
    say(not any(p["qualifies"] for p in v["criteria"]["a"]["passes"].values()) and not v["reason"].startswith("converged"),
        "(a) coverage NOT at the 0.9 gate with a finder at 0.897", v["reason"][:70])
    say(v["criteria"]["b"]["met"], "LIVENESS: (a) with precision clear, (b) itself is met", "")
except Exception as exc:  # a mutant that breaks the module is a failure of the check, not of the guard
    say(False, "(a) the stopping criteria judge the passes at all", repr(exc)[:120])

# (b) #1289. One seed hit, one finding, one fell, one with no verdict, one with a verdict string nobody knows.
sealed = {"seeds": [{"id": "S1", "lens": "x", "tier": 1, "mutation": "m"}]}
claims = [{"id": "F1-01", "finder": "F1", "class": "seed_hit", "seed": "S1", "tier": 1},
          {"id": "F1-02", "finder": "F1", "class": "candidate", "tier": 3, "scenario": "a real finding"},
          {"id": "F1-03", "finder": "F1", "class": "candidate", "tier": 3, "scenario": "fell for cause"},
          {"id": "F1-04", "finder": "F1", "class": "candidate", "tier": 2, "scenario": "not yet verified"},
          {"id": "F2-01", "finder": "F2", "class": "candidate", "tier": 2, "scenario": "a misspelt verdict"}]
verdicts = {"F1-02": {"verdict": "finding", "tier": 3, "root_cause": "r"},
            "F1-03": {"verdict": "fell", "reason": "documented"},
            "F2-01": {"verdict": "known-open", "issue": 439}}
try:
    m = pass_metrics.compute(sealed, {"claims": claims}, verdicts)
    say(m["findings"] == 1 and m["seed_hits"] == 1 and m["claims"] == 5,
        "LIVENESS: (b) the finding and the seed hit are counted", f"findings {m['findings']}, seed hits {m['seed_hits']}")
    fell_ids = [r["id"] for r in m["fell_rows"]]
    say(fell_ids == ["F1-03"], "(b) fell is exactly the claim that fell (F1-03)", f"fell rows {fell_ids}")
    say(m["fell_rate"] is not None and abs(m["fell_rate"] - 1 / 5) < 1e-9, "(b) the fell rate is 1/5", f"{m['fell_rate']}")

    class A:
        pass_n, date, pinned, release = 13, "2026-10-14", "abc", "x"
        budget, lenses, previous_lenses, capture_recapture = "", "time", "none", "not attempted"
        root_cause_groups, root_causes_file, notes_file = None, None, None
    rec = pass_metrics.record(m, A)
    sec = rec.split("## Fell in verification", 1)[1].split("\n## ", 1)[0]
    say(sec.strip() == "- F1-03: documented", "(b) Fell in verification lists F1-03 alone", sec.strip().replace("\n", " | "))
    unv = rec.split("## Unverified (not findings)", 1)[1].split("\n## ", 1)[0] if "## Unverified" in rec else ""
    say("- F1-04: no verdict" in unv and "- F2-01: verdict `known-open`" in unv,
        "(b) F1-04 and F2-01 are listed as unverified", unv.strip().replace("\n", " | ")[:80])
except Exception as exc:
    say(False, "(b) pass_metrics computes the pass at all", repr(exc)[:120])
with tempfile.TemporaryDirectory() as d:
    files = {}
    for name, obj in (("sealed", sealed), ("classified", {"claims": claims}), ("verdicts", verdicts)):
        files[name] = os.path.join(d, name + ".json")
        with open(files[name], "w") as fh:
            json.dump(obj, fh)
    out = os.path.join(d, "record.md")
    cmd = [sys.executable, os.path.join(R, "pass_metrics.py"), "--sealed", files["sealed"], "--classified",
           files["classified"], "--verdicts", files["verdicts"], "--pass", "13", "--date", "2026-10-14",
           "--pinned", "abc", "--out", out]
    r = subprocess.run(cmd, capture_output=True, text=True)
    say(r.returncode == 2 and not os.path.exists(out), "(b) the CLI refuses the verdict string \"known-open\"",
        f"exit {r.returncode}")
    verdicts["F2-01"] = {"verdict": "known_open", "issue": 439}
    with open(files["verdicts"], "w") as fh:
        json.dump(verdicts, fh)
    r = subprocess.run(cmd, capture_output=True, text=True)
    say(r.returncode == 0 and os.path.exists(out), "LIVENESS: (b) the CLI writes the corrected file's record",
        f"exit {r.returncode}")

# (c) #1290. The CLI's pending and the parse stop_check.py reads the queue through.
DQ = os.path.join(R, "decisions_queue.py")
with tempfile.TemporaryDirectory() as d:
    base = os.path.join(d, "base.md")
    for args in (["init"], ["add", "--kind", "default", "--text", "refuse over warn", "--loop", "12"]):
        subprocess.run([sys.executable, DQ, base] + args, capture_output=True, text=True, check=True)
    body = open(base).read()
    tail = " D02 | 2026-10-12 | BLOCKING | cut release v0.7.0 | issue - | PR - | open\n"

    def pending(text):
        p = os.path.join(d, "q.md")
        with open(p, "w") as f:
            f.write(text)
        return subprocess.run([sys.executable, DQ, p, "pending"], capture_output=True, text=True).returncode

    def stop_reads(text):
        try:
            return len(decisions_queue.pending_blocking(decisions_queue.parse(text)))
        except decisions_queue.QueueError:
            return "refused"
    say(pending(body) == 0 and "One line per decision" in body, "LIVENESS: (c) the header and a default entry parse, nothing pending", "")
    say(pending(body + "-" + tail) == 1, "LIVENESS: (c) the exact-shape BLOCKING entry blocks (exit 1)", "")
    for label, line in (("indented", "  -" + tail), ("a * bullet", "*" + tail), ("a lower-case id", "- d02" + tail[4:])):
        rc, seen = pending(body + line), stop_reads(body + line)
        say(rc == 2 and seen == "refused", f"(c) {label} BLOCKING entry is refused", f"pending exit {rc}, parse {seen}")
sys.exit(1 if fail else 0)
PY

if [ "$fail" = 0 ]; then echo "review_tooling_verdicts: PASS"; else echo "review_tooling_verdicts: FAIL"; fi
exit "$fail"
