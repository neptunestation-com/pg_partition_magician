#!/usr/bin/env bash
# Prove that the guide names every pg_cron grant a role other than a superuser needs before pgpm's jobs run as
# it, and that the guide's raw equivalent of pgpm.schedule() registers every job schedule() does, both measured
# from the pg_cron the harness ships and from pgpm's own source rather than assumed.
#
# WHY THIS GUARD EXISTS (issue #1245). README.md says "no superuser", but pg_cron revokes EXECUTE on
# cron.schedule_in_database from PUBLIC, which pgpm.schedule() calls, and on cron.alter_job, which a tick calls to
# hand a referenced partition's detach to the pgpm_detach job; and it grants no use of its schema. No document
# named a grant, so a non-superuser owner following the guide met `permission denied` at schedule(), or, granted
# that by hand, a referenced partition's retirement that logged fail_retain_detach on every tick and never
# happened. And the guide's raw equivalent of schedule() registered pgpm and pgpm_obtain but not pgpm_detach,
# which retiring a referenced partition needs.
#
# HOW. Three facts are read first. The jobs: every cron.schedule_in_database call in pgpm.schedule()'s body in
# pgpm_core/install.sql, and the job name it passes. The functions pgpm calls: every `cron.<name>(` in that file
# outside comments. The revokes: every `REVOKE ALL ON FUNCTION cron.<name>(<args>) FROM PUBLIC` in the pg_cron
# extension scripts inside <container>, and whether any of them grants USAGE on schema cron to PUBLIC. The grants
# a role needs are the called functions the scripts revoke, each with the signature the revoke names, plus USAGE
# on the schema when the scripts do not grant it. Then the guide must hold `grant execute on function
# cron.<name>(<args>)` for each of them (argument lists compared without spaces) and `grant usage on schema
# cron`, and its paragraph naming "the raw equivalent" must hold `cron.schedule('<job>'` for every job.
#   LIVENESS  schedule() registers at least one job and pgpm_detach is among them; pgpm calls at least one cron
#             function and schedule_in_database is among them; the pg_cron scripts were read and revoke at least
#             one function pgpm calls (so "the guide names every grant" is not a check of an empty set); the
#             guide's raw-equivalent paragraph was found.
#
# The mutations it is required to fail against (bench/mutations/mutate.py):
#   guide_raw_cron_omits_detach       -- the guide's pre-#1245 raw equivalent, pgpm and pgpm_obtain only
#   guide_cron_grants_unnamed         -- the guide's pre-#1245 Run it section, which names no grant
#   guide_cron_alter_job_grant_unnamed -- the schedule_in_database grant named, the alter_job one (#1501) not
#
# Usage: doc_cron_grants.sh <container> <db> [guide]
# With no third argument it reads docs/guide.md; with one it reads THAT file, which is how bench/discriminate.sh
# points it at a mutant (a /repo/... path is mapped to this checkout). <db> is accepted so discriminate.sh can call
# it the way it calls every guard, and is not used.
set -uo pipefail
C="${1:?container}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GUIDE="${3:-$ROOT/docs/guide.md}"
GUIDE="${GUIDE/#\/repo\//$ROOT/}"
if [ ! -f "$GUIDE" ]; then printf 'FAIL  %-66s %s\n' "fixture: the guide to read exists" "$GUIDE"; exit 1; fi
SCRIPTS="$(mktemp)"; trap 'rm -f "$SCRIPTS"' EXIT
if ! docker exec "$C" sh -c 'cat /usr/share/postgresql/*/extension/pg_cron--*.sql' >"$SCRIPTS" 2>/dev/null; then
  printf 'FAIL  %-66s %s\n' "fixture: the pg_cron extension scripts were read from $C" "no"; exit 1
fi

python3 - "$ROOT/pgpm_core/install.sql" "$SCRIPTS" "$GUIDE" <<'PY'
import re, sys
install, scripts, guide = (open(p).read() for p in sys.argv[1:4])
fail = 0

def say(ok, what, detail):
    print(f"{'PASS' if ok else 'FAIL'}  {what:<66} {detail}")

def premise(ok, what, detail):
    say(ok, what, detail)
    if not ok:
        sys.exit(1)

body = re.search(r"^create or replace function pgpm\.schedule\(.*?^\$\$;", install, re.S | re.M)
calls = re.findall(r"cron\.schedule_in_database\(", body.group(0)) if body else []
jobs = re.findall(r"cron\.schedule_in_database\(%L(?:, %L)*\)',\s*'(\w+)'", body.group(0)) if body else []
premise(bool(jobs) and len(jobs) == len(calls) and "pgpm_detach" in jobs,
        "LIVENESS: schedule()'s jobs were read, pgpm_detach among them", ", ".join(jobs) or "none")

code = "\n".join(l.split("--", 1)[0] for l in install.split("\n"))
called = sorted(set(re.findall(r"\bcron\.(\w+)\(", code)))
premise("schedule_in_database" in called, "LIVENESS: the cron functions pgpm calls were read", ", ".join(called))

revoked = {m.group(1): re.sub(r"\s+", "", m.group(2)).lower()
           for m in re.finditer(r"revoke\s+all\s+on\s+function\s+cron\.(\w+)\s*\(([^)]*)\)\s+from\s+public", scripts, re.I)}
schema_public = re.search(r"grant\s+usage\s+on\s+schema\s+cron\s+to\s+public", scripts, re.I) is not None
needed = {f: revoked[f] for f in called if f in revoked}
premise(bool(needed), "LIVENESS: pg_cron revokes at least one function pgpm calls from PUBLIC",
        ", ".join(f"{f}({a})" for f, a in sorted(needed.items())) or f"revokes: {', '.join(revoked) or 'none'}")

flat = re.sub(r"\s+", " ", guide).lower()
granted = {m.group(1): re.sub(r"\s+", "", m.group(2))
           for m in re.finditer(r"grant execute on function cron\.(\w+) ?\(([^)]*)\)", flat)}
for f, args in sorted(needed.items()):
    ok = granted.get(f) == args
    say(ok, f"the guide grants EXECUTE on cron.{f}({args})",
        "named" if ok else (f"named with ({granted[f]})" if f in granted else "NOT named: pgpm calls it, pg_cron revokes it"))
    fail |= not ok
if not schema_public:
    ok = "grant usage on schema cron" in flat
    say(ok, "the guide grants USAGE on schema cron, which pg_cron gives no one",
        "named" if ok else "NOT named: nothing in cron is reachable without it")
    fail |= not ok

prose, fence = [], False
for line in guide.split("\n"):
    if re.match(r"^\s*(```|~~~)", line):
        fence = not fence
        prose.append("")
        continue
    prose.append("" if fence else line)
raw = [p for p in re.split(r"\n\s*\n", "\n".join(prose)) if "raw equivalent" in p.lower()]
premise(len(raw) == 1, "LIVENESS: the guide's raw-equivalent paragraph was found", f"{len(raw)} found")
for j in jobs:
    ok = f"cron.schedule('{j}'" in raw[0]
    say(ok, f"the raw equivalent registers {j}, as schedule() does",
        "registered" if ok else "NOT registered: schedule() creates it and the raw form does not")
    fail |= not ok
sys.exit(1 if fail else 0)
PY
