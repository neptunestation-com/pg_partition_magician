#!/usr/bin/env bash
# Prove that every install command the docs give stops at the first error, and that the core one leaves an
# install exactly as it found it when install.sql refuses, by RUNNING each documented command's flags rather
# than reading them.
#
# WHY THIS GUARD EXISTS (issue #1090). README.md's Install section and docs/guide.md gave the install and
# upgrade command as `psql "$DATABASE_URL" -f pgpm_core/install.sql`, with no `-v ON_ERROR_STOP=1`. psql run
# that way reports an error and carries on with the next statement, and exits 0. So when an upgrade met
# pgpm._surface_prepare()'s refusal (a view of the operator's over a function whose shape changes: "...
# cannot replace ... in place ... Nothing has been changed."), the rest of install.sql ran anyway: it dropped
# the columns the file retires, passed over _surface_settled()'s error too, and appended the new version to
# pgpm.installed over a half-upgraded install, while the operator's script saw success.
#
# HOW. Every psql command in the docs that runs an install.sql (ONBOARDING.md, README.md,
# pgpm_archive/README.md, docs/*.md, and the site's index.html and install.html) is parsed for its flags: the
# options other than the connection, -c and -f. A command runs install.sql when it names it through -f, or
# feeds it on stdin (#1178: `psql ... < install.sql`, `psql ... -f - < install.sql`, `cat install.sql |
# psql ...`), and a stdin-fed command is run on stdin, as written. A command that names install.sql and runs
# it neither way (`psql -c '\i install.sql'`) FAILS as unparsed: what the guard cannot place it cannot judge,
# and it does not pass what it did not judge. bench/doc_install_guard_judges_stdin.sh holds the parser to
# that. Each distinct flag set (with how it reads the script) is then RUN:
#   - over a three-statement script whose middle statement fails: the run must exit non-zero, and the
#     statement after the failure must not have run;
#   - for a command that runs pgpm_core/install.sql, over this checkout's install.sql against an install
#     that has to refuse (bench/install_keeps_dependent_views.sh's stage B: an older observe_window with a
#     view over it, and a column the file retires, as a marker): the run must exit non-zero with the
#     refusal, and leave the marker, the view, the old function and pgpm.installed's rows exactly as they were.
#   LIVENESS  the same refusing install, run with no flags at all, DOES change (the file runs past the
#             refusal), so a pass is the flags' doing; with the view dropped, each documented core flag set
#             really upgrades (a new pgpm.installed row, the marker gone), so the flags do not merely fail
#             everything; README.md, guide.md, pgpm_archive/README.md and index.html each document a core
#             install command, when the full set is scanned (so a deleted command is a failure, not a pass).
#
# The mutation it is required to fail against (bench/mutations/mutate.py):
#   readme_install_runs_past_error -- README.md's pre-#1090 install command put back
#
# Usage: doc_install_stops_on_error.sh <container> <db> [doc]
# With no third argument it scans the files listed above; with one it scans THAT file only, which is how
# bench/discriminate.sh points it at a mutant (a /repo/... path is mapped to this checkout). Its scratch
# databases are <db>_s<n> and <db>_r<n> in <container>, and this checkout's pgpm_core/install.sql is fed
# from the host, so the container need not mount the repository.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ONLY="${3:-}"
if [ -n "$ONLY" ]; then
  ONLY="${ONLY/#\/repo\//$ROOT/}"
  if [ ! -f "$ONLY" ]; then printf 'FAIL  %-62s %s\n' "the doc to scan exists" "$ONLY"; exit 1; fi
fi
python3 - "$ROOT" "$ONLY" "$C" "$DB" <<'PY'
import html, os, re, shlex, subprocess, sys
root, only, container, db = sys.argv[1:5]
sys.path.insert(0, root + "/bench")
import doc_scan
INSTALL = os.path.join(root, "pgpm_core", "install.sql")
fail = 0

def say(ok, what, detail=""):
    print(f"{'PASS' if ok else 'FAIL'}  {what:<62} {detail}", flush=True)

def psql(dbname, args, stdin=None):
    """Run psql in the container; return (exit status, stdout + stderr)."""
    p = subprocess.run(["docker", "exec", "-i", container, "psql", "-U", "postgres", "-X", "-d", dbname, *args],
                       input=stdin, capture_output=True, text=True)
    return p.returncode, p.stdout + p.stderr

def val(dbname, sql):
    return psql(dbname, ["-tAq", "-c", sql])[1].strip()

def fresh(dbname):
    psql("postgres", ["-q", "-c", f"drop database if exists {dbname}"])
    rc, out = psql("postgres", ["-q", "-c", f"create database {dbname}"])
    if rc:
        say(False, f"fixture: create database {dbname}", out.strip()[:80]); sys.exit(1)

def drop(dbname):
    psql("postgres", ["-q", "-c", f"drop database if exists {dbname}"])

# ---- the documented commands ----------------------------------------------------------------------------
TAKES_ARG = {"-f", "--file", "-c", "--command", "-d", "--dbname", "-h", "--host", "-p", "--port",
             "-U", "--username", "-o", "--output", "-L", "--log-file"}
KEEPS_ARG = {"-v", "--set", "--variable", "-P", "--pset"}

# install.sql as a word of its own (or attached to -f): pgpm_core/uninstall.sql is not an install.
NAMES_INSTALL = re.compile(r"(?:(?<![\w.-])|(?<=-f))install\.sql(?![\w-]|\.\w)")

def fed_on_stdin(toks, prefix):
    """The install.sql files a psql command reads on stdin (#1178): a `<` redirect among its own words
    (`< file` or `<file`), one written before the command name, or a pipe into psql from a command that
    names the file (`cat pgpm_core/install.sql | psql ...`)."""
    fed, k = [], 0
    while k < len(toks):
        if toks[k] == "<" and k + 1 < len(toks):
            fed.append(toks[k + 1])
            k += 2
            continue
        if toks[k].startswith("<") and len(toks[k]) > 1:
            fed.append(toks[k][1:])
        k += 1
    pipeline = re.split(r"\|\||&&|;", prefix)[-1]
    own = re.split(r"\|", pipeline)[-1]
    fed += re.findall(r"<\s*([^\s|;&<>]+)", own)
    if re.search(r"\|\s*$", pipeline):
        fed += [w for w in re.findall(r"[^\s'\"|;&<>]+", pipeline[:pipeline.rstrip().rindex("|")])
                if NAMES_INSTALL.search(w)]
    return [f for f in fed if os.path.basename(f) == "install.sql"]

def commands(path):
    """(line, install files, flags, how) for every psql command in <path> that runs an install.sql, where
    how is "-f" when psql reads the file through -f and "<" when it reads it on stdin. A command that names
    install.sql and runs it neither way is returned with files None, as a refusal: the guard cannot judge
    what it cannot place, and it does not pass what it did not judge."""
    out, lines = [], open(path).read().split("\n")
    i = 0
    while i < len(lines):
        start, text = i + 1, lines[i]
        while text.rstrip().endswith("\\") and i + 1 < len(lines):
            i += 1
            text = text.rstrip()[:-1] + " " + lines[i]
        i += 1
        text = html.unescape(re.sub(r"<[^>]*>", " ", text))
        for m in re.finditer(r"(?<![\w-])psql\s+([^`]*)", text):
            prefix = text[:m.start()].rsplit("`", 1)[-1]
            if not (NAMES_INSTALL.search(m.group(1)) or fed_on_stdin([], prefix)):
                continue
            try:
                toks = shlex.split(m.group(1))
            except ValueError as e:
                out.append((start, None, f"unparseable: {e}", None))
                continue
            files, flags, k = [], [], 0
            while k < len(toks):
                t = toks[k]
                if t in TAKES_ARG:
                    if t in ("-f", "--file") and k + 1 < len(toks):
                        files.append(toks[k + 1])
                    k += 2
                    continue
                if t in KEEPS_ARG:
                    flags += toks[k:k + 2]
                    k += 2
                    continue
                if t.startswith("--file="):
                    files.append(t.split("=", 1)[1])
                elif re.match(r"^-f.", t):
                    files.append(t[2:])
                elif t.startswith("-") and not re.match(r"^-[cdfhpUoL].", t):
                    flags.append(t)
                k += 1
            how = "-f"
            installs = [f for f in files if os.path.basename(f) == "install.sql"]
            if not installs:
                # #1178: not named through -f. psql reads stdin when it is given no -f, or -f -, so a file
                # fed there is what the command installs, judged as run: on stdin.
                installs = fed_on_stdin(toks, prefix) if all(f == "-" for f in files) else []
                how = "-f" if files else "<"
                if not installs:
                    out.append((start, None, "names install.sql but runs it neither through -f nor on stdin: "
                                f"psql {m.group(1).strip()[:60]}", None))
                    continue
            out.append((start, installs, tuple(flags), how))
    return out

if only:
    docs = [only]
else:
    docs = doc_scan.living_docs(root) + [os.path.join(root, f) for f in ("index.html", "install.html")]
    docs = [d for d in docs if os.path.isfile(d)]
found = []   # (doc, line, files, run), run = (flags, how)
for d in docs:
    r = doc_scan.rel(root, d)
    for line, files, flags, how in commands(d):
        if files is None:
            say(False, f"{r}:{line}: the documented psql command parses", flags); fail = 1
            continue
        found.append((r, line, files, (flags, how)))
        print(f"#     {r}:{line}: {' '.join(files)} {'on stdin ' if how == '<' else ''}with flags [{' '.join(flags)}]")

def run_args(run):
    """psql's arguments for a documented command's flags, reading the script the way the command does."""
    flags, how = run
    return [*flags, "-q", "-f", "-"] if how == "-f" else [*flags, "-q"]

def shown(run):
    return f"[{' '.join(run[0])}]{' on stdin' if run[1] == '<' else ''}"

def is_core(files):
    return any(f.replace("\\", "/").endswith("pgpm_core/install.sql") for f in files)

want = [doc_scan.rel(root, only)] if only else ["README.md", "docs/guide.md", "pgpm_archive/README.md", "index.html"]
for r in want:
    n = sum(1 for d, _, files, _ in found if d == r and (is_core(files) or only))
    say(n > 0, f"LIVENESS: {r} documents {'an install' if only else 'the core install'} command", f"{n} command(s)")
    if n == 0:
        fail = 1

# ---- every flag set: stops at the first error, and says so ----------------------------------------------
STOP = "create table public.g_before ();\nselect 1/0;\ncreate table public.g_after ();\n"
stop_ok = {}
for n, run in enumerate(sorted({f for _, _, _, f in found}), 1):
    name = f"{db}_s{n}"
    fresh(name)
    rc, _ = psql(name, run_args(run), STOP)
    after = val(name, "select coalesce(to_regclass('public.g_after')::text, 'absent')")
    drop(name)
    stop_ok[run] = (rc != 0, after == "absent")
    print(f"#     flags {shown(run)}: exit {rc}, the statement after the error: {after}")

# ---- core flag sets: install.sql's refusal changes nothing ----------------------------------------------
FIXTURE = """
drop function pgpm.observe_window(regclass, interval);
create function pgpm.observe_window(p_parent regclass, p_since interval default '7 days')
returns table (parent_table regclass, drains bigint) language sql stable as $$ select p_parent, 0::bigint $$;
create view public.ow_old as select parent_table, drains from pgpm.observe_window('pgpm.config');
alter table pgpm.config add column drain_adaptive boolean;
"""
STATE = """select (select count(*) from pg_attribute where attrelid = 'pgpm.config'::regclass
                     and attname = 'drain_adaptive' and not attisdropped)
          || ' | ' || coalesce(to_regclass('public.ow_old')::text, 'no view')
          || ' | ' || pg_get_function_result('pgpm.observe_window(regclass, interval)'::regprocedure)
          || ' | ' || (select string_agg(id::text, ',' order by id) from pgpm.installed)"""
REFUSAL = "cannot replace pgpm.observe_window(regclass,interval) (on which view public.ow_old depends) in place"
src = open(INSTALL).read()

def refusing(name):
    """A fresh install that this checkout's install.sql has to refuse; returns its state."""
    fresh(name)
    rc, out = psql(name, ["-v", "ON_ERROR_STOP=1", "-q", "--single-transaction", "-f", "-"], src)
    if rc:
        say(False, "fixture: pgpm_core installed", out.strip()[-80:]); sys.exit(1)
    rc, out = psql(name, ["-v", "ON_ERROR_STOP=1", "-q", "-f", "-"], FIXTURE)
    if rc:
        say(False, "fixture: older observe_window, a view over it, the marker", out.strip()[-80:]); sys.exit(1)
    return val(name, STATE)

# the premise: run with no flags, the file DOES go on past the refusal and change the install
name = f"{db}_r0"
before = refusing(name)
rc, out = psql(name, ["-q", "-f", "-"], src)
after = val(name, STATE)
drop(name)
ok = REFUSAL in out and after != before
say(ok, "LIVENESS: with no flags, psql -f runs on past the refusal", f"{before} -> {after} (exit {rc})")
if not ok:
    sys.exit(1)

core = sorted({f for _, _, files, f in found if is_core(files)})
refusal_ok = {}
for n, run in enumerate(core, 1):
    name = f"{db}_r{n}"
    before = refusing(name)
    rc, out = psql(name, run_args(run), src)
    after = val(name, STATE)
    refusal_ok[run] = (rc != 0 and REFUSAL in out, after == before, before, after, rc)
    # and the same flags, with nothing to refuse, really upgrade: one new pgpm.installed row, the marker gone
    psql(name, ["-q", "-c", "drop view public.ow_old"])
    UP = ("select (select count(*) from pg_attribute where attrelid = 'pgpm.config'::regclass"
          " and attname = 'drain_adaptive' and not attisdropped) || ' | ' || (select count(*) from pgpm.installed)")
    n0 = int(val(name, UP).split(" | ")[1])
    rc2, out2 = psql(name, run_args(run), src)
    up = val(name, UP)
    drop(name)
    ok = rc2 == 0 and up == f"0 | {n0 + 1}"
    say(ok, f"LIVENESS: flags {shown(run)} upgrade an install that need not refuse",
        f"exit {rc2}, marker | installs: {up} (want 0 | {n0 + 1})")
    if not ok:
        fail = 1

# ---- each documented command, judged by what its flags did ----------------------------------------------
for r, line, files, run in found:
    exited, stopped = stop_ok[run]
    say(exited and stopped, f"{r}:{line}: the documented command stops at the first error",
        f"exit non-zero: {exited}, nothing after the error ran: {stopped}")
    if not (exited and stopped):
        fail = 1
    if is_core(files):
        met, unchanged, b, a, rc = refusal_ok[run]
        say(met and unchanged, f"{r}:{line}: install.sql's refusal leaves the install as it was",
            f"exit {rc}; marker | view | observe_window | installed ids: {b} -> {a}")
        if not (met and unchanged):
            fail = 1
if not fail:
    say(True, "every documented install command stops at the first error", f"{len(found)} command(s)")
sys.exit(1 if fail else 0)
PY
