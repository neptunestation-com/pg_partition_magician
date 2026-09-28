#!/usr/bin/env bash
# Prove that every `NAME=value ./test.sh <track>` command the docs tell a developer to type sets a
# variable test.sh actually reads, in that track's own function (or at top level, where every track sees
# it).
#
# WHY THIS GUARD EXISTS (issue #599). ONBOARDING.md said `TS_VERSIONS='2.9.1' ./test.sh timescale` runs
# the from_hypertable track against just 2.9.1. test.sh stopped reading TS_VERSIONS in #155: run_timescale
# loops over ${TS_PG_TAGS:-15.14.1.127}, image tags, so the documented command silently ran the default
# leg and reported PASS for a version it never started. A knob with a wrong name is not an error anywhere:
# the shell sets a variable nothing reads, which is why this has to be checked rather than noticed.
#
# HOW. Each such command in the docs is matched, the named track's `run_<track>() { ... }` body is read
# out of test.sh, and the variable must appear in it as `$NAME` or `${NAME` on a line that is not a
# comment (a variable only named in prose is not read). A variable read at top level, outside every
# run_* function, counts for every track.
#   LIVENESS  the docs hold at least one such command, so a clean result is not a scan of nothing;
#   CONTROL   a command naming a variable nothing reads (planted, not from the docs) is reported as
#             unread, so the check can fail at all.
#
# The mutation it is required to fail against (bench/mutations/mutate.py):
#   onboarding_ts_versions -- ONBOARDING.md's timescale knob put back to TS_VERSIONS='2.9.1'
#
# Usage: doc_env_knobs.sh <container> <db> [doc]
# With no third argument it scans ONBOARDING.md, README.md and docs/*.md; with one it scans THAT file
# only, which is how bench/discriminate.sh points it at a mutant (a /repo/... path is mapped to this
# checkout). Needs python3 on the host and nothing else; <container> and <db> are accepted so
# discriminate.sh can call it the way it calls every guard, and are not used.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ONLY="${3:-}"
DOCS=()
if [ -n "$ONLY" ]; then
  ONLY="${ONLY/#\/repo\//$ROOT/}"
  if [ ! -f "$ONLY" ]; then printf 'FAIL  %-58s %s\n' "the doc to scan exists" "$ONLY"; exit 1; fi
  DOCS=("$ONLY")
else
  DOCS=("$ROOT/ONBOARDING.md" "$ROOT/README.md")
  for f in "$ROOT"/docs/*.md; do DOCS+=("$f"); done
fi

python3 - "$ROOT/test.sh" "${DOCS[@]}" <<'PY'
import re, sys
test_sh, docs = sys.argv[1], sys.argv[2:]
src = open(test_sh).read()
fail = 0

def say(ok, what, detail):
    print(f"{'PASS' if ok else 'FAIL'}  {what:<58} {detail}")

# Bodies of every run_<track>() { ... } (the same shape scripts/check_track_filters.py parses), and the
# top level, which is test.sh with every such body cut out.
bodies = {m.group(1): m.group(2) for m in re.finditer(r"^run_(\w+)\(\) *\{(.*?)\n\}", src, re.S | re.M)}
top = re.sub(r"^run_\w+\(\) *\{.*?\n\}", "", src, flags=re.S | re.M)

def code(text):
    return "\n".join(l for l in text.split("\n") if not l.lstrip().startswith("#"))

def reads(var, track):
    rx = re.compile(r"\$\{?" + re.escape(var) + r"\b")
    return bool(rx.search(code(bodies.get(track, "")))) or bool(rx.search(code(top)))

CMD = re.compile(r"\b([A-Z][A-Z0-9_]*)=(?:'[^']*'|\"[^\"]*\"|\S+)\s+\./test\.sh\s+([a-z0-9_]+)")
found = []
for d in docs:
    text = open(d).read()
    for m in CMD.finditer(text):
        found.append((d, text[:m.start()].count("\n") + 1, m.group(1), m.group(2)))

if len(bodies) < 5:
    say(False, "LIVENESS: test.sh's run_* track bodies were parsed", f"{len(bodies)} found")
    sys.exit(1)
if not found:
    say(False, "LIVENESS: the docs name at least one NAME=... ./test.sh knob", "none found")
    sys.exit(1)
say(True, "LIVENESS: the docs name at least one NAME=... ./test.sh knob", f"{len(found)} found")
# The instrument first: a name nothing reads must be reported as unread.
ctl = not reads("PGPM_NO_SUCH_KNOB_599", "timescale")
say(ctl, "CONTROL: a variable nothing reads is reported as unread", "PGPM_NO_SUCH_KNOB_599")
fail |= not ctl
for d, line, var, track in found:
    shown = d[len(test_sh) - len("test.sh"):] if d.startswith(test_sh[:-len("test.sh")]) else d
    ok = reads(var, track)
    say(ok, f"{shown}:{line}: {var} is read by run_{track}", "read" if ok else
        f"NOT read: `{var}=... ./test.sh {track}` silently runs the default")
    fail |= not ok
sys.exit(1 if fail else 0)
PY
