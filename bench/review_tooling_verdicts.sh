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
#       Beneath that line, the count of finders at the gate and coverage.py's own gate are judged on the exact
#       read/units, never on coverage.py's three-decimal figure (188 of 209 = 0.89952 is written 0.9); the
#       controls: 189 of 210, exactly 0.9, is at both gates.
#         pass_metrics_coverage_count_on_rounded  the line's count on the three-decimal coverage again
#         coverage_gate_on_rounded_figure         coverage.py's gate on the three-decimal coverage again
#   (b) #1289: pass_metrics.py counted a candidate with no verdict, or a verdict string it did not know
#       ("known-open"), as FELL: under "Fell in verification" and in the fell rate. The controls: the finding
#       and the seed hit are counted, and the CLI writes the record once the typo is corrected.
#         pass_metrics_unverified_reads_fell      no verdict or an unknown one routed to fell again
#   (c) #1290: decisions_queue.py's parse skipped any line not starting with "- D", so a BLOCKING entry written
#       indented, under a `*` bullet or with a lower-case id was never read and the loop went on. The controls:
#       the exact shape blocks, and the header's prose with a default entry parses with nothing pending.
#         decisions_queue_skips_malformed_line    a line not starting "- D" skipped again
#         decisions_queue_pipe_only_at_line_start a `|` past position zero above the first heading missed again
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
def pm_pass(n, lenses, found, read, units=29):
    sealed = {"seeds": [{"id": f"S{i}", "lens": "x", "tier": 2, "mutation": f"m{i}", "suite_caught": [],
                         **({"late_survivor": {"issue": 1000 + i, "passes_survived": 6}} if i <= 3 else {})}
                        for i in range(1, 10)]}
    claims = [{"id": f"F1-{i:02d}", "finder": "F1", "class": "seed_hit", "seed": f"S{i}", "tier": 2} for i in range(1, 10)]
    claims += [{"id": f"F2-{i:02d}", "finder": "F2", "class": "candidate", "tier": 3, "scenario": "s"} for i in range(1, 15)]
    verdicts = {f"F2-{i:02d}": ({"verdict": "finding", "tier": 3} if i <= found else {"verdict": "fell", "reason": "r"})
                for i in range(1, 15)}
    m = pass_metrics.compute(sealed, {"claims": claims}, verdicts)
    # coverage.py's own row shape: the three-decimal coverage beside the counts it came from
    cov = {"rows": [{"finder": "F1", "units": 40, "read": 40, "coverage": 1.0, "ledger": "present"},
                    {"finder": "F2", "units": units, "read": read, "coverage": round(read / units, 3), "ledger": "present"}]}

    class A:
        pass_n, date, pinned, release, budget = n, f"2026-10-{n:02d}", "abc1234", "x", "x"
        previous_lenses = "fresh surface"
        capture_recapture = "attempted on the duplicated slices: estimate 0 on both"
        root_cause_groups, root_causes_file, notes_file = None, None, None
        coverage_line = pass_metrics.coverage_line(cov)
    A.lenses = "fresh surface, " + lenses
    return m, pass_metrics.record(m, A)


def judge(name, found, read, units=29):
    d = os.path.join(tempfile.mkdtemp(), name)
    rdir = os.path.join(d, "reviews")
    os.makedirs(rdir)
    rows = ["| 1 | 2026-09-24 | `aaaaaaa` | 76 (25 filed as T1) | ~106 | not measured | none | baseline |"]
    m = rec = None
    for n, lenses in ((12, stop_check.A5), (13, stop_check.B5)):
        m, rec = pm_pass(n, lenses, found, read, units)
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
    # the count beneath the coverage line: coverage.py writes 188 of 209 (0.89952) as 0.9, and 189 of 210 is 0.9
    m, rec, v = judge("cov_exact_control", 8, 189, 210)
    say(v["reason"].startswith("converged"), "LIVENESS: (a) a finder at exactly 189/210 = 0.9 is at the gate", v["reason"][:60])
    m, rec, v = judge("cov_rounded", 8, 188, 209)
    say(round(188 / 209, 3) == 0.9 and "coverage: 0.90" in rec,
        "LIVENESS: (a) 188 of 209 (0.89952) is written 0.9 by coverage.py", "")
    say("(1 of 2 finders at or above 0.90)" in rec and not any(p["qualifies"] for p in v["criteria"]["a"]["passes"].values()),
        "(a) a finder at 188/209 is not counted at the 0.9 gate", next((ln for ln in rec.split("\n") if ln.startswith("coverage:")), ""))
except Exception as exc:  # a mutant that breaks the module is a failure of the check, not of the guard
    say(False, "(a) the stopping criteria judge the passes at all", repr(exc)[:120])
try:
    import importlib.util
    spec = importlib.util.spec_from_file_location("coverage_under_test", os.path.join(R, "coverage.py"))
    cov_mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(cov_mod)
    row = {"finder": "F7", "kind": "files", "units": 209, "read": 188, "coverage": round(188 / 209, 3),
           "unread": [], "extra": [], "ledger": "present"}
    say(cov_mod.render([{**row, "units": 210, "read": 189}], 0.9).rstrip().endswith("  ok"),
        "LIVENESS: (a) coverage.py's gate passes a slice at exactly 189/210", "")
    say("BELOW 0.9" in cov_mod.render([row], 0.9), "(a) coverage.py's own gate holds back a slice at 188/209", "")
except Exception as exc:
    say(False, "(a) coverage.py renders its gate at all", repr(exc)[:120])

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
    # above the first loop heading: the bare header parses, and a `|`-field line there is refused, not prose
    head = "\n".join(decisions_queue.HEADER) + "\n"
    say(pending(head) == 0, "LIVENESS: (c) the bare header, no loop heading yet, parses", "")
    line = "Pending | BLOCKING | cut release v0.7.0\n"
    rc, seen = pending(head + line), stop_reads(head + line)
    say(rc == 2 and seen == "refused", "(c) a `|` line above the first loop heading is refused", f"pending exit {rc}, parse {seen}")
sys.exit(1 if fail else 0)
PY

# ---------------------------------------------------------------- (d) land.sh's stall detector
#   land.sh's summaries_green() called a merge group green when every summary check-run that EXISTED on it was
#   green, and a summary job (needs: its shards, if: always()) has no check-run until its shards finish: with
#   the Perf shards still running the group read green, and after LAND_STALL_MIN minutes a healthy group was
#   dequeued and enqueued again (three landings on 2026-10-13). Driven through land.sh's own function with a
#   stub `gh` answering from a fixture of check-runs. The controls: a finished group reads green, and the
#   running group really holds two green summaries, which the old count read as all of them.
#     land_stall_counts_existing_summaries    a required summary with no check-run reads green again
fn=$(awk '/^REQUIRED_SUMMARIES=/{print} /^summaries_green\(\) *\{/{on=1} on{print} on&&/^\}/{exit}' "$R/land.sh")
if ! grep -q '^summaries_green() *{' <<<"$fn"; then
  bad "fixture: land.sh defines summaries_green()" "not found"
else
  # gh api <path> --jq <expr>: the check-runs of a fixture, filtered by ?check_name= as GitHub does
  gh() {
    local path="" jqx="." name=""
    while [ $# -gt 0 ]; do
      case "$1" in api) shift;; --jq) jqx=$2; shift 2;; -*) shift;; *) path=$1; shift;; esac
    done
    case "$path" in *check_name=*) name=${path#*check_name=}; name=${name%%&*}; name=${name//%20/ };; esac
    jq --arg n "$name" '{check_runs: [.[] | select($n == "" or .name == $n)]}' "$GROUP" | jq -r "$jqx"
  }
  eval "$fn"
  REPO=o/r; export REPO   # read by the eval'd function
  group() { GROUP="$work/group.json"; printf '%s\n' "$1" > "$GROUP"; }
  sm() { printf '{"name":"%s","status":"%s","conclusion":%s}' "$1" "$2" "$3"; }
  green='"success"'
  group "[$(sm "Test Summary" completed "$green"),$(sm "Lint summary" completed "$green"),$(sm "Perf summary" completed "$green"),$(sm "perf (shard 1/4)" completed "$green")]"
  summaries_green abc; check $? "LIVENESS: (d) a finished group, all three summaries green, reads green" ""
  # 23:14Z on 2026-10-13: Test and Lint summaries green, the Perf shards running, so no Perf summary yet
  group "[$(sm "Test Summary" completed "$green"),$(sm "Lint summary" completed "$green"),$(sm "perf (shard 2/4)" in_progress null),$(sm "archive (PG15)" in_progress null)]"
  n_green=$(jq '[.[] | select((.name | test("summary"; "i")) and .conclusion == "success")] | length' "$GROUP")
  check "$([ "$n_green" = 2 ] && echo 0 || echo 1)" "LIVENESS: (d) the running group has two summaries, both green" "$n_green green"
  if summaries_green abc; then bad "(d) a group whose Perf shards still run is not green" "read green: a stall would be declared"
  else ok "(d) a group whose Perf shards still run is not green" ""; fi
  group "[$(sm "Test Summary" completed "$green"),$(sm "Lint summary" completed "$green"),$(sm "Perf summary" in_progress null)]"
  if summaries_green abc; then bad "(d) a Perf summary still in progress is not green" "read green"
  else ok "(d) a Perf summary still in progress is not green" ""; fi
  group "[$(sm "Test Summary" completed "$green"),$(sm "Lint summary" completed '"failure"'),$(sm "Perf summary" completed "$green")]"
  if summaries_green abc; then bad "(d) a failed Lint summary is not green" "read green"
  else ok "(d) a failed Lint summary is not green" ""; fi
  unset -f gh
fi

# ---------------------------------------------------------------- (e) flake_check.sh's log read
#   flake_check.sh read job logs with a bare `gh api .../logs`, which gh 2.100 refuses to print when the body
#   holds terminal escape sequences (stdout empty, exit 1), so every log signature read UNKNOWN on such a
#   machine; and an empty log was UNKNOWN by omission rather than said. Driven through the real script with a
#   stub `gh` on PATH that behaves as gh 2.100 or as an older gh, which does not know the flag. The controls:
#   the stub really refuses the bare read, and a readable log that matches nothing still reads UNKNOWN.
#     flake_check_log_without_escape_flag     the log read without --allow-escape-sequences again
#     flake_check_empty_log_reads_unknown     an unreadable log falls through to UNKNOWN again
mkdir -p "$work/bin"
cat > "$work/bin/gh" <<'STUB'
#!/usr/bin/env bash
# a stand-in for gh: GH_STUB=new behaves as gh 2.100 (refuses to print an escaped body without
# --allow-escape-sequences), GH_STUB=old as an older gh (does not know the flag); GH_LOG is the job's log
flag=""; path=""; jqx=""
while [ $# -gt 0 ]; do
  case "$1" in
    api) shift;;
    --help) if [ "$GH_STUB" = new ]; then printf '      --allow-escape-sequences   Allow printing terminal escape sequences\n'; fi
            printf '      --jq string   Query to select values from the response using jq syntax\n'; exit 0;;
    --allow-escape-sequences) flag=1; shift;;
    --jq) jqx=$2; shift 2;;
    -*) shift;;
    *) path=$1; shift;;
  esac
done
if [ -n "$flag" ] && [ "$GH_STUB" = old ]; then echo "unknown flag: --allow-escape-sequences" >&2; exit 1; fi
case "$path" in
  */actions/runs/*/jobs*) body=${GH_JOBS:-'{"jobs":[{"id":101,"status":"completed","conclusion":"failure","steps":[1,2,3,4,5],"name":"perf (shard 2/4)"}]}'};;
  */actions/runs/*) body='{"conclusion":"failure"}';;
  */annotations) body=${GH_ANN:-'[]'};;
  */actions/jobs/*/logs)
    if [ "$GH_STUB" = new ] && [ -z "$flag" ] && grep -q $'\033' "$GH_LOG"; then
      echo "the response contains terminal escape sequences; pass --allow-escape-sequences to output it anyway" >&2; exit 1
    fi
    cat "$GH_LOG"; exit 0;;
  *) echo "stub gh: unknown path $path" >&2; exit 1;;
esac
if [ -n "$jqx" ]; then jq -r "$jqx" <<<"$body"; else printf '%s\n' "$body"; fi
STUB
chmod +x "$work/bin/gh"
E=$'\033'
{
  echo "2026-10-13T23:14:00.1Z ##[group]Run ./test.sh perf"
  echo "2026-10-13T23:14:00.2Z ${E}[36;1m./test.sh perf --shard=2/4${E}[0m"
  echo "2026-10-13T23:14:09.0Z PASS  LIVENESS: the probe was writing before the restore began   12 writes"
  echo "2026-10-13T23:14:09.0Z PASS  LIVENESS: attempts overlapped the restore's own window   3 overlapped"
  echo "2026-10-13T23:14:09.0Z PASS  the FK was actually re-added   yes"
  echo "2026-10-13T23:14:09.0Z FAIL  writes to the MANAGED PARENT are not blocked   got 1, want 0"
} > "$work/flake.log"
{
  echo "2026-10-13T23:14:00.2Z ${E}[36;1m./test.sh perf --shard=2/4${E}[0m"
  echo "2026-10-13T23:14:09.0Z FAIL  the partition kept its rows   got 9, want 10"
} > "$work/real.log"
: > "$work/empty.log"
fc() { PATH="$work/bin:$PATH" GH_STUB=$1 GH_LOG=$2 bash "$R/flake_check.sh" 4242 --repo o/r 2>&1; }

out=$(PATH="$work/bin:$PATH" GH_STUB=new GH_LOG="$work/flake.log" gh api repos/o/r/actions/jobs/101/logs 2>/dev/null); rc=$?
check "$([ "$rc" != 0 ] && [ -z "$out" ] && echo 0 || echo 1)" "LIVENESS: (e) the stub, as gh 2.100, prints nothing for the bare read" "exit $rc, ${#out} bytes"
out=$(fc new "$work/flake.log"); rc=$?
check "$([ "$rc" = 0 ] && grep -q "known flake lock_guard_probe" <<<"$out" && echo 0 || echo 1)" \
  "(e) under gh 2.100 the restore_fk_lock flake is recognised" "exit $rc: ${out:0:70}"
out=$(fc old "$work/flake.log"); rc=$?
check "$([ "$rc" = 0 ] && grep -q "known flake lock_guard_probe" <<<"$out" && echo 0 || echo 1)" \
  "(e) under an older gh the same flake is recognised" "exit $rc: ${out:0:70}"
out=$(fc new "$work/real.log"); rc=$?
check "$([ "$rc" = 1 ] && grep -q "UNKNOWN failure" <<<"$out" && echo 0 || echo 1)" \
  "LIVENESS: (e) a log that reads and matches nothing is UNKNOWN (exit 1)" "exit $rc"
out=$(fc new "$work/empty.log"); rc=$?
check "$([ "$rc" = 3 ] && grep -q "could not read the log" <<<"$out" && ! grep -q UNKNOWN <<<"$out" && echo 0 || echo 1)" \
  "(e) an empty log says it could not be read (exit 3), not UNKNOWN" "exit $rc: ${out:0:70}"

# ---------------------------------------------------------------- (f) land.sh's enqueue request and thread stop
#   land.sh's enqueue() asked for the enqueue with `gh pr merge <pr> --merge`, which on this repository's merge
#   queue does not reliably queue a PR: on 2026-10-15 #1350, green and CLEAN, sat unqueued after two requests,
#   and one enqueuePullRequest mutation queued it at once (#1257 lost hours the same way on 2026-10-12). And a
#   PR held BLOCKED by an unresolved review thread was asked five times over and the run exited 6, "rerun",
#   which cannot help (#1350 at 20:43Z). Driven through land.sh's own functions with a stub `gh` that answers
#   from fixtures, records every call it receives, and behaves as the queue did that day: `gh pr merge` is
#   accepted and queues nothing, the mutation queues the PR. The controls: the stub really records, and with
#   every thread resolved the enqueue goes on to a request; the page-two fixture's first page alone is clean.
#     land_enqueue_by_merge_command           the request is `gh pr merge` again
#     land_enqueue_ignores_threads            the thread check skipped, so a held PR is asked five times
#     land_threads_first_page_only            only the first page of threads read
#     land_enqueue_hides_refusal              a refused request prints nothing of what GitHub said
lfn() { # <name>: land.sh's function <name>: a body opened at the line's end closes on a `}` line of its own,
         # a short one (`f() { cmd; }`, maybe continued) on the first line ending `; }`
  awk -v n="$1" 'index($0, n "() {") == 1 { on = 1; long = ($0 ~ /\(\) *\{ *(#.*)?$/) }
    on { print; if (long ? /^\}/ : /; \}$/) exit }' "$R/land.sh"
}
efn=""
for f in say in_queue threads_clear enqueue_request enqueue; do efn+="$(lfn "$f")"$'\n'; done
if ! grep -q '^enqueue() *{' <<<"$efn" || ! grep -q '^in_queue() *{' <<<"$efn"; then
  bad "fixture: land.sh defines enqueue() and in_queue()" "not found"
else
  calls="$work/gh_calls"; qstate="$work/queue_state"
  # gh pr view <n> --json <f> --jq <e> | gh pr merge ... | gh api graphql -f query=<q> --jq <e>
  gh() {
    local q="" jqx="" sub="" body rc=0
    printf '%s\n' "$*" >> "$calls"
    sub="$1 $2"
    while [ $# -gt 0 ]; do
      case "$1" in -f) q=${2#query=}; shift 2;; --jq) jqx=$2; shift 2;; *) shift;; esac
    done
    case "$sub" in
      "pr merge") return 0;;   # accepted, and on 2026-10-15 nothing was queued
      "pr view")
        case "$jqx" in
          *mergeStateStatus*) body='{"mergeStateStatus":"BLOCKED"}';;
          *) body='{"id":"PR_kwDO1350"}';;
        esac;;
      "api graphql")
        case "$q" in
          *reviewThreads*after:*) body=$(cat "$THREADS2");;
          *reviewThreads*) body=$(cat "$THREADS1");;
          *enqueuePullRequest*)
            if [ "$ENQ" = refuse ]; then
              body='{"data":{"enqueuePullRequest":null},"errors":[{"type":"UNPROCESSABLE","message":"Pull request is in unstable status"}]}'; rc=1
            else
              echo QUEUED > "$qstate"; body='{"data":{"enqueuePullRequest":{"mergeQueueEntry":{"state":"QUEUED","position":1}}}}'
            fi;;
          *mergeQueueEntry*)
            if [ -s "$qstate" ]; then body="{\"data\":{\"repository\":{\"pullRequest\":{\"state\":\"OPEN\",\"mergeQueueEntry\":{\"state\":\"$(cat "$qstate")\"}}}}}"
            else body='{"data":{"repository":{"pullRequest":{"state":"OPEN","mergeQueueEntry":null}}}}'; fi;;
          *) echo "stub gh: unknown query $q" >&2; return 1;;
        esac;;
      *) echo "stub gh: unknown command $sub" >&2; return 1;;
    esac
    if [ -n "$jqx" ]; then jq -r "$jqx" <<<"$body"; else printf '%s\n' "$body"; fi
    return "$rc"
  }
  sleep() { :; }   # the request pauses 20 to 60 s between asks; the stub answers at once
  eval "$efn"
  REPO=o/r; METHOD=merge; export REPO METHOD   # land.sh's globals, read by the eval'd functions
  th() { printf '{"isResolved":%s,"path":"%s","line":%s,"comments":{"nodes":[{"body":"%s"}]}}' "$1" "$2" "$3" "$4"; }
  page() { printf '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":%s,"endCursor":"%s"},"nodes":[%s]}}}}}\n' "$1" "$2" "$3"; }
  page false "" "$(th true scripts/review/land.sh 286 "resolved: use the mutation"),$(th true CHANGELOG.md 3 "resolved too")" > "$work/clean.json"
  page false "" "$(th true CHANGELOG.md 3 "resolved"),$(th false pgpm_core/install.sql 4242 "P1 Badge  The retire lock is taken by name after the identity check, so a swapped table is dropped")" > "$work/held.json"
  page true c1 "$(th true CHANGELOG.md 3 "resolved"),$(th true docs/guide.md 9 "resolved")" > "$work/p1.json"
  page false "" "$(th false bench/review_tooling_verdicts.sh 77 "P2 Badge  The second page holds this thread")" > "$work/p2.json"
  run_enqueue() { : > "$calls"; : > "$qstate"; out=$( (enqueue 1350) 2>&1 ); rc=$?; }

  : > "$calls"; out=$(gh pr view 1350 --repo o/r --json id --jq .id)
  check "$([ "$out" = PR_kwDO1350 ] && grep -q '^pr view 1350' "$calls" && echo 0 || echo 1)" \
    "LIVENESS: (f) the stub answers and records the call it receives" "$out, $(grep -c . "$calls") call(s)"

  THREADS1="$work/clean.json"; THREADS2="$work/clean.json"; ENQ=ok; run_enqueue
  check "$(grep -q -e 'enqueuePullRequest' -e '^pr merge' "$calls" && echo 0 || echo 1)" \
    "LIVENESS: (f) with every thread resolved the enqueue goes on to a request" "exit $rc, $(grep -c . "$calls") call(s)"
  check "$([ "$rc" = 0 ] && [ "$(cat "$qstate")" = QUEUED ] && echo 0 || echo 1)" \
    "(f) the enqueue took: the stub's queue reads QUEUED" "exit $rc, queue '$(cat "$qstate")'"
  check "$(grep -qF 'enqueuePullRequest(input:{pullRequestId:"PR_kwDO1350"}' "$calls" && ! grep -q '^pr merge' "$calls" && echo 0 || echo 1)" \
    "(f) the request is the enqueuePullRequest mutation, never gh pr merge" "$(grep -c enqueuePullRequest "$calls") mutation(s), $(grep -c '^pr merge' "$calls") merge command(s)"

  n_open=$(jq '[.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved | not)] | length' "$work/held.json")
  check "$([ "$n_open" = 1 ] && echo 0 || echo 1)" "LIVENESS: (f) the held fixture has one unresolved thread among two" "$n_open unresolved"
  THREADS1="$work/held.json"; THREADS2="$work/held.json"; run_enqueue
  check "$([ "$rc" = 7 ] && echo 0 || echo 1)" "(f) an unresolved thread stops the run with exit 7" "exit $rc"
  check "$(grep -q 'pgpm_core/install.sql:4242  P1 Badge The retire lock' <<<"$out" && ! grep -q 'CHANGELOG.md:3' <<<"$out" && echo 0 || echo 1)" \
    "(f) the stop names the unresolved thread (path:line, its text), not the resolved one" "${out:0:70}"
  check "$(! grep -q -e 'enqueuePullRequest' -e '^pr merge' "$calls" && echo 0 || echo 1)" \
    "(f) a held PR is never asked to enqueue" "$(grep -c -e 'enqueuePullRequest' -e '^pr merge' "$calls") request(s)"

  n_open=$(jq '[.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved | not)] | length' "$work/p1.json")
  check "$([ "$n_open" = 0 ] && jq -e '.data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage' "$work/p1.json" >/dev/null && echo 0 || echo 1)" \
    "LIVENESS: (f) page one alone is clean and says another page follows" "$n_open unresolved on page one"
  THREADS1="$work/p1.json"; THREADS2="$work/p2.json"; run_enqueue
  check "$([ "$rc" = 7 ] && grep -q 'bench/review_tooling_verdicts.sh:77' <<<"$out" && echo 0 || echo 1)" \
    "(f) a thread on the second page stops the run too" "exit $rc"
  check "$(grep -qF 'reviewThreads(first:100,after:"c1")' "$calls" && echo 0 || echo 1)" \
    "(f) the second page is asked for after the first page's cursor" "$(grep -c reviewThreads "$calls") thread read(s)"

  THREADS1="$work/clean.json"; THREADS2="$work/clean.json"; ENQ=refuse; run_enqueue
  n_req=$(grep -c -e 'enqueuePullRequest' -e '^pr merge' "$calls")
  check "$([ "$n_req" -ge 1 ] && echo 0 || echo 1)" "LIVENESS: (f) the refusing stub was asked to enqueue" "$n_req request(s), exit $rc"
  check "$(grep -q 'Pull request is in unstable status' <<<"$out" && grep -q 'mergeStateStatus BLOCKED' <<<"$out" && echo 0 || echo 1)" \
    "(f) a refusal prints GitHub's message and the PR's mergeStateStatus" "$(grep -m1 refused <<<"$out" | cut -c1-70)"
  unset -f gh sleep
fi

# ---------------------------------------------------------------- (g) land.sh's guard database renumbering
#   #1389 (F13-05): verify_tree renumbered a duplicate guard database at `s.rfind(d)`, a SUBSTRING search, so
#   when the duplicate (pgpm_perf33) prefixed a name later in test.sh (pgpm_perf332) it rewrote that unrelated
#   guard's database, left the duplicate, reported "renumbered" and land.sh amended and pushed the result; and
#   nothing re-checked that the names were unique afterwards. Driven through verify_tree's own Python, read out
#   of land.sh, in a scratch directory holding a planted test.sh and an empty mutation catalogue. The controls:
#   a duplicate that prefixes nothing is renumbered to the next free number, the earlier line kept.
#     land_renumber_by_substring    the duplicate located by substring search again
#     land_renumber_unchecked       the names not re-checked for uniqueness after the renumbering
vt=$(awk "/python3 - <<'PY' \|\| return 1/{on=1;next} on&&/^PY\$/{exit} on" "$R/land.sh")
if ! grep -q 'renumbered the second' <<<"$vt" || ! grep -q 'open("test.sh", "w")' <<<"$vt"; then
  bad "fixture: land.sh's verify_tree renumbering was read" "not found"
else
  V="$work/vt"; mkdir -p "$V/bench/mutations"
  printf 'MUTATIONS = {}\nMUTATION_SRC = {}\n' > "$V/bench/mutations/mutate.py"
  printf '%s\n' "$vt" > "$V/verify.py"
  # renum <test.sh lines...>: run verify_tree's Python on them; sets vrc, vout, and vts (test.sh after, one line)
  renum() {
    printf '%s\n' "$@" > "$V/test.sh"
    vout=$(cd "$V" && python3 verify.py 2>&1); vrc=$?
    vts=$(tr '\n' ' ' < "$V/test.sh"); vts=${vts% }
  }
  renum '"bench/a.sh pgpm_perf7"' '"bench/x.sh pgpm_perf400"' '"bench/new.sh pgpm_perf7"'
  check "$([ "$vrc" = 0 ] && [ "$vts" = '"bench/a.sh pgpm_perf7" "bench/x.sh pgpm_perf400" "bench/new.sh pgpm_perf401"' ] && echo 0 || echo 1)" \
    "LIVENESS: (g) a duplicate prefixing nothing: the later line renumbered" "exit $vrc: $vts"
  renum '"bench/a.sh pgpm_perf33"' '"bench/new.sh pgpm_perf33"' '"bench/obtain.sh pgpm_perf332"'
  check "$(grep -q 'renumbered the second pgpm_perf33 to pgpm_perf333' <<<"$vout" && echo 0 || echo 1)" \
    "LIVENESS: (g) the prefix case reports renumbering pgpm_perf33" "$(grep -m1 renumbered <<<"$vout")"
  check "$([ "$vrc" = 0 ] && [ "$vts" = '"bench/a.sh pgpm_perf33" "bench/new.sh pgpm_perf333" "bench/obtain.sh pgpm_perf332"' ] && echo 0 || echo 1)" \
    "(g) the duplicate's later line renumbered, pgpm_perf332 untouched" "exit $vrc: $vts"
  renum '"bench/a.sh pgpm_perf5"' '"bench/b.sh pgpm_perf5"' '"bench/c.sh pgpm_perf5"'
  check "$([ "$vrc" != 0 ] && grep -q 'still duplicated' <<<"$vout" && [ "$vts" = '"bench/a.sh pgpm_perf5" "bench/b.sh pgpm_perf5" "bench/c.sh pgpm_perf5"' ] && echo 0 || echo 1)" \
    "(g) a name three times over is refused, test.sh unwritten" "exit $vrc: $vts"
fi

# ---------------------------------------------------------------- (h) stop_check.py's criterion 4
#   #1389 (F13-06): criterion 4 ("the Tier 1 capture-recapture estimate rounds to zero") was judged as
#   round(remaining) == 0, and Python rounds a half to even: two duplicated finders at 3 Tier 1 each, 2 shared,
#   estimate 4.5 against 4 found, half a Tier 1 left, read as zero and the loop as converged. The controls: 0.4
#   left rounds to zero and converges, 0.6 does not, so the branch judged is the estimate one.
#     stop_check_capture_half_to_even  round() again
python3 - "$R" <<'PY' || fail=1
import os, sys, tempfile
sys.path.insert(0, sys.argv[1])
import stop_check as s
ok = (" (suite-caught 3/3, read-caught 6/6; late-survivor 3/3)", "precision 0.95 (strict 0.80, fell rate 0.05)", "0.93", None)
fail = 0
with tempfile.TemporaryDirectory() as root:
    def run(name, est):
        d = os.path.join(root, name); os.makedirs(d)
        h, r = s.synth(d, [(12, 0, s.A5) + ok, (13, 0, s.B5) + ok],
                       capture_text={13: f"S8 opus 3, fable 3, overlap 2: estimate {est}, found 4"})
        return s.run(h, r, extended_through=14)
    for est, want in (("4.4", True), ("4.6", False), ("4.5", False)):
        v = run("e" + est.replace(".", "_"), est)
        e = v["criteria"]["e"]
        good = e.get("branch") == "estimate" and e["met"] is want and v["criteria"]["a"]["met"] and v["criteria"]["b"]["met"]
        label = {"4.4": "LIVENESS: (h) 0.4 Tier 1 left rounds to zero (converges)",
                 "4.6": "LIVENESS: (h) 0.6 Tier 1 left does not round to zero",
                 "4.5": "(h) half a Tier 1 left does not round to zero"}[est]
        print(f"{'PASS' if good else 'FAIL'}  {label:<62} {v['verdict']}: {v['reason'][:50]}")
        fail |= not good
sys.exit(fail)
PY

# ---------------------------------------------------------------- (i) flake_check.sh's no-step signatures
#   #1389 (F13-07): lost_runner, documented as jobs with no step and an empty or BlobNotFound log, checked the
#   step count alone, so a job GitHub failed before any step with a log naming a real error (a job container
#   image that does not exist) was called a known flake, exit 0, and land.sh reran it. And runner_not_acquired,
#   documented as the annotation AND no step run, checked the annotation alone. Driven through the real script
#   with the stub `gh` of (e). The controls: an empty log, a BlobNotFound one and a job queued for good are still
#   lost_runner, and the annotation on a job with no step is still runner_not_acquired.
#     flake_check_lost_runner_by_steps_only  the log never read again
job0() { printf '{"jobs":[{"id":9001,"status":"%s","conclusion":%s,"steps":[%s],"name":"perf (shard 3/6)"}]}' "$1" "$2" "${3:-}"; }
fcj() { PATH="$work/bin:$PATH" GH_STUB=new GH_LOG=$1 GH_JOBS=$2 GH_ANN=${3:-[]} bash "$R/flake_check.sh" 4242 --repo o/r 2>&1; }
printf '%s\n' "2026-10-22T12:00:00.0Z ##[error]Failed to initialize container ghcr.io/neptunestation-com/pgpm-test:17-typo" \
  "2026-10-22T12:00:00.0Z ##[error]Error response from daemon: manifest unknown" > "$work/image.log"
printf '%s\n' '<?xml version="1.0" encoding="utf-8"?><Error><Code>BlobNotFound</Code><Message>The specified blob does not exist.</Message></Error>' > "$work/blob.log"
out=$(fcj "$work/empty.log" "$(job0 completed '"failure"')"); rc=$?
check "$([ "$rc" = 0 ] && grep -q "known flake lost_runner" <<<"$out" && echo 0 || echo 1)" \
  "LIVENESS: (i) no step and an empty log: lost_runner" "exit $rc"
out=$(fcj "$work/blob.log" "$(job0 completed '"cancelled"')"); rc=$?
check "$([ "$rc" = 0 ] && grep -q "known flake lost_runner" <<<"$out" && echo 0 || echo 1)" \
  "LIVENESS: (i) no step and a BlobNotFound log: lost_runner" "exit $rc"
out=$(fcj "$work/image.log" "$(job0 queued null)"); rc=$?
check "$([ "$rc" = 0 ] && grep -q "known flake lost_runner" <<<"$out" && echo 0 || echo 1)" \
  "LIVENESS: (i) a job queued for good: lost_runner" "exit $rc"
out=$(fcj "$work/image.log" "$(job0 completed '"failure"')"); rc=$?
check "$([ "$rc" = 1 ] && ! grep -q "known flake" <<<"$out" && grep -q 'manifest unknown\|Failed to initialize container' <<<"$out" && echo 0 || echo 1)" \
  "(i) no step, a log naming a real error: not a flake (exit 1)" "exit $rc: ${out:0:70}"
ann='[{"message":"The job was not acquired by Runner of type hosted even after multiple attempts"}]'
out=$(fcj "$work/empty.log" "$(job0 completed '"failure"')" "$ann"); rc=$?
check "$([ "$rc" = 0 ] && grep -q "known flake runner_not_acquired" <<<"$out" && echo 0 || echo 1)" \
  "LIVENESS: (i) the annotation on a job with no step: runner_not_acquired" "exit $rc"
out=$(fcj "$work/real.log" "$(job0 completed '"failure"' '1,2,3')" "$ann"); rc=$?
check "$([ "$rc" = 1 ] && ! grep -q "known flake" <<<"$out" && echo 0 || echo 1)" \
  "(i) the annotation on a job whose steps ran: not a flake" "exit $rc: ${out:0:70}"

if [ "$fail" = 0 ]; then echo "review_tooling_verdicts: PASS"; else echo "review_tooling_verdicts: FAIL"; fi
exit "$fail"
