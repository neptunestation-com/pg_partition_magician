#!/usr/bin/env bash
# Prove bench/doc_install_stops_on_error.sh judges every documented install command, whatever way it hands
# psql the file, by running that guard over a document it must refuse and reading its verdict line by line.
#
# WHY THIS GUARD EXISTS (issue #1178, pass 11 F7-10). doc_install_stops_on_error.sh promises that "every psql
# command in the docs that runs an install.sql" is run and judged, but its parser kept a command only when it
# named install.sql through -f/--file. `psql "$DATABASE_URL" < pgpm_core/install.sql` (no ON_ERROR_STOP, so
# psql runs on past the first error and exits 0) was matched and dropped without a word, and a doc carrying
# it beside a correct -f command passed. Every command the parser could not place went the same way.
#
# HOW. The guard under test is run, from a scratch copy of the files it reads (bench/doc_scan.py and this
# checkout's pgpm_core/install.sql), over two planted documents:
#   control  the correct -f command alone                                        -> the guard must PASS it
#   planted  one command per way of handing psql the file, each on its own line:
#     -f, with ON_ERROR_STOP and --single-transaction                             -> judged, PASSES
#     `< file`, no flags (the issue's command)                                    -> judged, FAILS to stop
#     `<file`, with ON_ERROR_STOP and --single-transaction                        -> judged, PASSES both checks
#     `cat file | psql`, no flags                                                 -> judged, FAILS to stop
#     `-f - < file`, no flags                                                     -> judged, FAILS to stop
#     `< file psql`, no flags (the redirect before the command name)              -> judged, FAILS to stop
#     `-c '\i file'` (names the file, runs it neither through -f nor on stdin)    -> refused as unparsed
#     `-ffile` (the file attached to -f), no flags                                -> judged, FAILS to stop
#     `-f pgpm_core/uninstall.sql` (not an install)                               -> no verdict at all
# Each verdict is read by the line it names, so a command judged for the wrong line, or one refusal standing
# in for another, does not pass. The stdin command that PASSES is the witness that a stdin-fed command is run
# and judged, not refused wholesale; the uninstall line's silence is witnessed by the verdicts on every other
# line of the same document.
#   LIVENESS  the guard passes the control document (it runs here, and passes a clean doc), and it lists the
#             planted -f command, so the planted document was read.
#
# The mutations it is required to fail against (bench/mutations/mutate.py), each in the guard under test:
#   doc_install_stdin_dropped    -- pre-#1178: a command that does not name install.sql through -f is
#                                   skipped, so every stdin-fed command passes unjudged
#   doc_install_unplaced_dropped -- the stdin commands judged, but one that names install.sql and runs it
#                                   neither way is skipped instead of refused
#
# Usage: doc_install_guard_judges_stdin.sh <container> <db> [guard script]
# With no third argument it judges this checkout's bench/doc_install_stops_on_error.sh. With one it judges
# THAT script in its place (bench/discriminate.sh hands it a mutant at a /repo/... path, mapped to this
# checkout). The guard under test is run in <container> with <db> as its scratch prefix.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; UNDER="${3:-}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
UNDER="${UNDER/#\/repo\//$ROOT/}"
UNDER="${UNDER:-$ROOT/bench/doc_install_stops_on_error.sh}"
if [ ! -s "$UNDER" ]; then
  printf 'FAIL  %-62s %s\n' "GUARD: the guard under test is readable" "$UNDER"
  exit 1
fi
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bench" "$work/pgpm_core" "$work/doc"
cp "$UNDER" "$work/bench/doc_install_stops_on_error.sh"
cp "$ROOT/bench/doc_scan.py" "$work/bench/doc_scan.py"
cp "$ROOT/pgpm_core/install.sql" "$work/pgpm_core/install.sql"

GOOD='psql "$DATABASE_URL" -v ON_ERROR_STOP=1 --single-transaction -f pgpm_core/install.sql'
printf '# Install\n\n```bash\n%s\n```\n' "$GOOD" > "$work/doc/control.md"
# One command per fenced block, four lines apart: the command of block k sits on line 4k.
{
  printf '# Install\n'
  for cmd in \
    "$GOOD" \
    'psql "$DATABASE_URL" < pgpm_core/install.sql' \
    'psql "$DATABASE_URL" -v ON_ERROR_STOP=1 --single-transaction <pgpm_core/install.sql' \
    'cat pgpm_core/install.sql | psql "$DATABASE_URL"' \
    'psql "$DATABASE_URL" -f - < pgpm_core/install.sql' \
    '< pgpm_core/install.sql psql "$DATABASE_URL"' \
    "psql \"\$DATABASE_URL\" -c '\\i pgpm_core/install.sql'" \
    'psql "$DATABASE_URL" -fpgpm_core/install.sql' \
    'psql "$DATABASE_URL" --single-transaction -f pgpm_core/uninstall.sql'; do
    printf '\n```bash\n%s\n```\n' "$cmd"
  done
} > "$work/doc/planted.md"

bash "$work/bench/doc_install_stops_on_error.sh" "$C" "${DB}_c" "$work/doc/control.md" > "$work/control.log" 2>&1 </dev/null
crc=$?
bash "$work/bench/doc_install_stops_on_error.sh" "$C" "${DB}_p" "$work/doc/planted.md" > "$work/planted.log" 2>&1 </dev/null
prc=$?

python3 - "$work" "$crc" "$prc" <<'PY'
import re, sys
work, crc, prc = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
control, planted = (open(f"{work}/{n}.log").read().splitlines() for n in ("control", "planted"))
fail = 0

def report(ok, label, detail=""):
    global fail
    print(f"{'PASS' if ok else 'FAIL'}  {label:<66} {detail}", flush=True)
    fail |= not ok

STOPS = "the documented command stops at the first error"
KEEPS = "install.sql's refusal leaves the install as it was"
PARSES = "the documented psql command parses"
NAME = {STOPS: "stops", KEEPS: "refusal-keeps", PARSES: "parses"}

def brief(v):
    return ", ".join(f"{NAME.get(k, k)} {x}" for k, x in sorted(v.items())) or "none"

def verdicts(log, doc, line):
    """{check: PASS|FAIL} for every verdict the guard printed about <doc>:<line>; a verdict line about that
    line that is none of the three checks is kept whole, so it cannot go unseen."""
    out = {}
    for l in log:
        m = re.match(rf"^(PASS|FAIL)  {re.escape(doc)}:{line}: (.*)$", l)
        if m:
            check = next((c for c in (STOPS, KEEPS, PARSES) if m.group(2).startswith(c)), m.group(2))
            out[check] = m.group(1)
    return out

v = verdicts(control, "doc/control.md", 4)
report(crc == 0 and v.get(STOPS) == "PASS" and v.get(KEEPS) == "PASS",
       "LIVENESS: the guard passes the control doc's correct -f command", f"exit {crc}; {brief(v)}")
listed = any(re.match(r"^#\s+doc/planted\.md:4: pgpm_core/install\.sql with flags", l) for l in planted)
report(listed, "LIVENESS: the guard read the planted doc (its -f command is listed)")

expect = [
    (4,  "-f, ON_ERROR_STOP, --single-transaction", {STOPS: "PASS", KEEPS: "PASS"}),
    (8,  "`< file`, no flags (#1178's command)", {STOPS: "FAIL", KEEPS: "FAIL"}),
    (12, "`<file`, ON_ERROR_STOP, --single-transaction", {STOPS: "PASS", KEEPS: "PASS"}),
    (16, "`cat file | psql`, no flags", {STOPS: "FAIL", KEEPS: "FAIL"}),
    (20, "`-f - < file`, no flags", {STOPS: "FAIL", KEEPS: "FAIL"}),
    (24, "`< file psql`, no flags", {STOPS: "FAIL", KEEPS: "FAIL"}),
    (28, "`-c '\\i file'`: refused as unparsed", {PARSES: "FAIL"}),
    (32, "`-ffile` (attached), no flags", {STOPS: "FAIL", KEEPS: "FAIL"}),
    (36, "`-f uninstall.sql`: not an install, no verdict", {}),
]
for line, what, want in expect:
    got = verdicts(planted, "doc/planted.md", line)
    report(got == want, f"planted.md:{line}: {what}", f"verdicts: {brief(got)} (want {brief(want)})")
report(prc != 0, "the guard refuses the planted doc", f"exit {prc}")
if fail:
    print("# the guard under test, over the planted doc:")
    for l in planted:
        print(f"#   {l}")
sys.exit(1 if fail else 0)
PY
