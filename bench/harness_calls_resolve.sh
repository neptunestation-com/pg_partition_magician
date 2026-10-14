#!/usr/bin/env bash
# Prove that every pgpm routine the at-scale harnesses call (bench/run*.sh) is one this tree installs, called
# the way it is declared: a procedure through CALL, a function through anything else, and an argument list
# that one of its overloads accepts by position and by name.
#
# WHY THIS GUARD EXISTS (issue #1281, F8-03). bench/run_fh.sh, the documented hypertable benchmark, called
# pgpm.from_hypertable_cutover(..., p_regrain_batch => ...). The procedure's batch parameter is p_drain_batch:
# #291's sweep renamed transmute's p_drain_batch to p_regrain_batch and rewrote this call too, though the
# cutover kept its name. So every run of the harness died "procedure ... does not exist" right after its
# online copy, never reaching the cutover, conservation or regrain it exists to measure, and nothing ran the
# harness at a scale small enough to notice. A rename in install.sql that its callers in bench/ do not follow
# is invisible to every other track, because no test runs those scripts.
#
# HOW. This checkout's pgpm_core/install.sql and pgpm_hypertable/install.sql are installed into <db>, and
# every pgpm routine is read from the catalog: its kind, its input parameters' names in order, and how many
# of them have defaults. Every `pgpm.<name>(...)` call in the harness text is then read (the arguments to the
# matching parenthesis, past quoted strings and nested calls), skipping shell comment lines, SQL comment lines
# and the lines that only print (echo, printf, say), and judged:
#   - <name> is a pgpm routine of the kind the call needs (`call pgpm.x(` needs a procedure, any other
#     spelling a function);
#   - one of its overloads accepts the arguments as PostgreSQL resolves a call by name and arity: no more
#     positional arguments than inputs, every named argument one of its inputs that no positional argument
#     already fills, no name twice, no positional argument after a named one, and every input without a
#     default given. Argument TYPES are not judged (the harness's values are shell variables until it runs);
#     no pgpm routine is variadic or has an OUT parameter, and one that does FAILS here rather than being
#     judged by a model that does not cover it.
#   LIVENESS  the install defines from_hypertable_cutover as a procedure and transmute as one too; the scan
#             found at least one call passing named arguments in each harness it reads that holds such a call
#             (run.sh and run_fh.sh by default), so a clean result is not a scan of nothing; and the model
#             above agrees with the SERVER on six calls run for real (against a relation that does not
#             exist, so no body runs): the cutover named as the procedure declares it resolves, with
#             p_regrain_batch it does not, as a function it does not, transmute with its step resolves and
#             without it does not, and status() as a function resolves.
#
# The mutation it is required to fail against (bench/mutations/mutate.py):
#   fh_cutover_regrain_batch -- run_fh.sh's cutover call names p_regrain_batch again (pre-#1281)
#
# Usage: harness_calls_resolve.sh <container> <db> [harness]
# With no third argument it reads every bench/run*.sh of this checkout; with one it reads THAT file only,
# which is how bench/discriminate.sh points it at a mutant (a /repo/... path is mapped to this checkout).
# The install files are fed from the host, so the container need not mount the repository.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ONLY="${3:-}"
if [ -n "$ONLY" ]; then
  ONLY="${ONLY/#\/repo\//$ROOT/}"
  if [ ! -f "$ONLY" ]; then printf 'FAIL  %-62s %s\n' "fixture: the harness to scan exists" "$ONLY"; exit 1; fi
fi
P=(docker exec -i "$C" psql -U postgres)
"${P[@]}" -d postgres -q -c "drop database if exists $DB" >/dev/null 2>&1
if ! { "${P[@]}" -d postgres -q -c "create database $DB" &&
       "${P[@]}" -d "$DB" -v ON_ERROR_STOP=1 -q --single-transaction -f - < "$ROOT/pgpm_core/install.sql" &&
       "${P[@]}" -d "$DB" -v ON_ERROR_STOP=1 -q -f - < "$ROOT/pgpm_hypertable/install.sql"; } >/dev/null 2>&1; then
  printf 'FAIL  %-62s %s\n' "fixture: the core and hypertable modules install into $DB" "in $C"
  "${P[@]}" -d postgres -q -c "drop database if exists $DB" >/dev/null 2>&1
  exit 1
fi

python3 - "$ROOT" "$ONLY" "$C" "$DB" <<'PY'
import glob, json, os, re, subprocess, sys
root, only, container, db = sys.argv[1:5]
fail = 0

def say(ok, what, detail=""):
    global fail
    if not ok:
        fail = 1
    print(f"{'PASS' if ok else 'FAIL'}  {what:<62} {detail}", flush=True)

def psql(sql):
    r = subprocess.run(["docker", "exec", "-i", container, "psql", "-U", "postgres", "-d", db, "-qtA",
                        "-c", sql], capture_output=True, text=True, stdin=subprocess.DEVNULL)
    return r.returncode, (r.stdout + r.stderr).strip()

# Every pgpm routine: kind, input parameter names in order ('' for an unnamed one), defaults, and whether
# the model above covers it (no VARIADIC, no OUT on a procedure).
rc, out = psql("""
  select coalesce(json_agg(json_build_object(
           'name', p.proname, 'kind', p.prokind, 'nin', p.pronargs, 'ndef', p.pronargdefaults,
           'modeled', p.provariadic = 0 and not (p.prokind = 'p' and 'o' = any(coalesce(p.proargmodes, '{}'))),
           'names', coalesce((select array_agg(coalesce(u.n, '') order by u.o)
                                from unnest(p.proargnames, p.proargmodes::text[]) with ordinality u(n, m, o)
                               where u.m is null or u.m in ('i', 'b', 'v')), '{}'))), '[]')
    from pg_proc p where p.pronamespace = 'pgpm'::regnamespace""")
if rc != 0:
    say(False, "fixture: the pgpm routines were read from the catalog", out[:200])
    sys.exit(1)
routines = {}
for r in json.loads(out):
    names = list(r["names"]) + [""] * max(0, r["nin"] - len(r["names"]))
    r["names"] = names[: r["nin"]]
    routines.setdefault(r["name"], []).append(r)

def kinds(name):
    return {r["kind"] for r in routines.get(name, [])}

say("p" in kinds("from_hypertable_cutover") and "p" in kinds("transmute"),
    "LIVENESS: the install defines the cutover and transmute (procedures)",
    f"{len(routines)} pgpm routine names")

def split_args(text):
    """Top-level arguments of an argument list, past quotes and nested parentheses."""
    args, cur, depth, q = [], [], 0, None
    for c in text:
        if q:
            if c == q:
                q = None
        elif c in "'\"":
            q = c
        elif c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
        elif c == "," and depth == 0:
            args.append("".join(cur)); cur = []
            continue
        cur.append(c)
    args.append("".join(cur))
    return [a.strip() for a in args] if "".join(args).strip() else []

NAMED = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)\s*(=>|:=)")

def judge(name, need, args):
    """(ok, detail): whether some overload of pgpm.<name> of kind <need> accepts <args>."""
    cands = routines.get(name, [])
    if not cands:
        return False, f"pgpm.{name} is not a routine this tree installs"
    cands = [r for r in cands if r["kind"] == need]
    if not cands:
        return False, f"pgpm.{name} is a {'procedure' if 'p' in kinds(name) else 'function'}, called as a {'procedure' if need == 'p' else 'function'}"
    pos, named = 0, []
    for a in args:
        m = NAMED.match(a)
        if m:
            named.append(m.group(1))
        elif named:
            return False, "a positional argument follows a named one"
        else:
            pos += 1
    why = []
    for r in cands:
        if not r["modeled"]:
            why.append(f"{r['nin']}-input overload is variadic or has OUT parameters, which this guard does not model")
            continue
        names, nreq = r["names"], r["nin"] - r["ndef"]
        if pos > r["nin"]:
            why.append(f"{r['nin']}-input overload: {pos} positional arguments"); continue
        if len(set(named)) != len(named):
            why.append("a name given twice"); continue
        bad = [n for n in named if n not in names[pos:]]
        if bad:
            why.append(f"{r['nin']}-input overload has no input {', '.join(bad)} past the positional ones"); continue
        covered = set(range(pos)) | {names.index(n) for n in named}
        missing = [names[i] or f"${i + 1}" for i in range(nreq) if i not in covered]
        if missing:
            why.append(f"{r['nin']}-input overload: no value for {', '.join(missing)}"); continue
        return True, f"{pos} positional, named {', '.join(named) or 'none'}"
    return False, "; ".join(why)

CALL = re.compile(r"\bpgpm\.([A-Za-z_][A-Za-z0-9_]*)\s*\(")
SKIP = re.compile(r"^\s*(#|--|(echo|printf|say)\b)")

def calls(text):
    """(line, name, kind needed, args) for every call in <text>, None for args it could not close."""
    masked = "\n".join("" if SKIP.match(ln) else ln for ln in text.split("\n"))
    for m in CALL.finditer(masked):
        i, depth, q = m.end(), 1, None
        while i < len(masked) and depth:
            c = masked[i]
            if q:
                if c == q:
                    q = None
            elif c in "'\"":
                q = c
            elif c == "(":
                depth += 1
            elif c == ")":
                depth -= 1
            i += 1
        line = masked.count("\n", 0, m.start()) + 1
        need = "p" if re.search(r"(?i)\bcall\s+$", masked[max(0, m.start() - 16):m.start()]) else "f"
        yield line, m.group(1), need, (split_args(masked[m.end():i - 1]) if depth == 0 else None)

# The model against the server: each control call is run for real on a relation that does not exist, so it
# either fails to resolve or resolves and stops at the relation (no body runs).
UNRESOLVED = re.compile(r"(procedure|function) pgpm\.\w+\(.*\) does not exist|is a procedure|is not a procedure|is not unique")
NOREL = "'pgpm_guard_no_such_schema.t'"
controls = [
    ("the cutover, named as declared",
     f"call pgpm.from_hypertable_cutover({NOREL}, 'created_at', interval '1 month', p_obtain => 4, p_drain_batch => 50000, p_paused => false, p_predrain => true)", True),
    ("the cutover with p_regrain_batch",
     f"call pgpm.from_hypertable_cutover({NOREL}, 'created_at', interval '1 month', p_obtain => 4, p_regrain_batch => 50000, p_paused => false, p_predrain => true)", False),
    ("the cutover as a function", f"select pgpm.from_hypertable_cutover({NOREL}, 'created_at', interval '1 month')", False),
    ("transmute with its step", f"call pgpm.transmute({NOREL}, 'id', 10::bigint, 3, p_paused => false, p_regrain_batch => 20000)", True),
    ("transmute without its step", f"call pgpm.transmute({NOREL}, 'id', p_paused => false)", False),
    ("status() as a function", f"select * from pgpm.status() where parent = {NOREL}::regclass", True),
]
for label, sql, expect in controls:
    (_, name, need, args), = list(calls(sql))
    model, detail = judge(name, need, args)
    _, out = psql(sql)
    server = not UNRESOLVED.search(out)
    say(model == server == expect,
        f"LIVENESS: model and server agree: {label} {'resolves' if expect else 'does not'}",
        f"model={model} server={server} ({out.splitlines()[0][:70] if out else 'no error'})")

files = [only] if only else sorted(glob.glob(os.path.join(root, "bench", "run*.sh")))
want_named = {os.path.join(root, "bench", f) for f in ("run.sh", "run_fh.sh")}
for path in sorted(want_named - set(files)) if not only else []:
    say(False, f"LIVENESS: {os.path.relpath(path, root)} is among the harnesses read", "not found")
for path in files:
    rel = os.path.relpath(path, root) if not only else os.path.basename(path)
    with open(path) as f:
        text = f.read()
    found = list(calls(text))
    named = 0
    for line, name, need, args in found:
        if args is None:
            say(False, f"{rel}:{line} pgpm.{name}( closes", "could not find its closing parenthesis")
            continue
        named += any(NAMED.match(a) for a in args)
        ok, detail = judge(name, need, args)
        say(ok, f"{rel}:{line} {'call ' if need == 'p' else ''}pgpm.{name}(...) resolves", detail)
    if only or path in want_named:
        say(named > 0, f"LIVENESS: {rel} holds a call passing named arguments", f"{len(found)} calls, {named} named")

print(f"harness_calls_resolve: {'PASS' if not fail else 'FAIL'}")
sys.exit(fail)
PY
rc=$?
"${P[@]}" -d postgres -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$rc"
