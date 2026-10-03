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
# run_* function, counts for every track. EVERY assignment in the command's prefix is checked, not only
# the one next to `./test.sh` (issue #847): `TS_VERSIONS='2.9.1' TS_PG_TAGS='15.14.1.127' ./test.sh
# timescale` sets an unread knob as surely as the one-knob form does, and the shell is as silent about it.
#   LIVENESS  the docs hold at least one such command, so a clean result is not a scan of nothing;
#   CONTROL   a command naming a variable nothing reads (planted, not from the docs) is reported as
#             unread, so the check can fail at all;
#   CONTROL   a planted command whose FIRST knob is unread and whose last is read yields both knobs to
#             the extractor, the unread one reported as unread: the prefix is read whole.
#
# The mutations it is required to fail against (bench/mutations/mutate.py):
#   onboarding_ts_versions       -- ONBOARDING.md's timescale knob put back to TS_VERSIONS='2.9.1'
#   onboarding_unread_knob_first -- the same unread TS_VERSIONS='2.9.1', placed before the read TS_PG_TAGS
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

# One assignment, and a command: one or more assignments, then ./test.sh <track>. The prefix is matched
# whole and then walked assignment by assignment (#847: binding only the last one let an unread knob
# placed earlier pass).
VALUE = r"=(?:'[^']*'|\"[^\"]*\"|\S+)\s+"
ONE = re.compile(r"([A-Z][A-Z0-9_]*)" + VALUE)
CMD = re.compile(r"\b((?:[A-Z][A-Z0-9_]*" + VALUE + r")+)\./test\.sh\s+([a-z0-9_]+)")

def knobs(text):  # -> [(line, var, track)], one per assignment of every command in text
    out = []
    for m in CMD.finditer(text):
        line, pre, pos = text[:m.start()].count("\n") + 1, m.group(1), 0
        while pos < len(pre):
            a = ONE.match(pre, pos)
            if not a:  # cannot happen: the prefix is a run of exactly these
                raise SystemExit(f"FAIL  could not walk the knob prefix {pre!r}")
            out.append((line, a.group(1), m.group(2)))
            pos = a.end()
    return out

found = []
for d in docs:
    for line, var, track in knobs(open(d).read()):
        found.append((d, line, var, track))

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
# And the extractor (#847): an unread knob FIRST in a prefix that ends with a read one must be seen and
# reported. The tracked docs hold no multi-knob prefix today, so without this nothing would show that the
# whole prefix is read.
planted = knobs("run `PGPM_NO_SUCH_KNOB_599='1' TS_PG_TAGS='15.14.1.127' ./test.sh timescale`\n")
pair = [v for _, v, _ in planted] == ["PGPM_NO_SUCH_KNOB_599", "TS_PG_TAGS"]
ctl2 = pair and not reads("PGPM_NO_SUCH_KNOB_599", "timescale") and reads("TS_PG_TAGS", "timescale")
say(ctl2, "CONTROL: an unread knob before a read one is seen, and unread",
    "extracted " + (",".join(v for _, v, _ in planted) or "nothing"))
fail |= not ctl2
for d, line, var, track in found:
    shown = d[len(test_sh) - len("test.sh"):] if d.startswith(test_sh[:-len("test.sh")]) else d
    ok = reads(var, track)
    say(ok, f"{shown}:{line}: {var} is read by run_{track}", "read" if ok else
        f"NOT read: `{var}=... ./test.sh {track}` silently runs the default")
    fail |= not ok
sys.exit(1 if fail else 0)
PY
