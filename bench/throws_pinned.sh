#!/usr/bin/env bash
# Prove that every throws_* assertion around a CALL of a pgpm procedure in the test tree PINS what it
# catches (a SQLSTATE or a message), by asking pgTAP itself whether the assertion would also accept the
# one error a NON-refusing committing procedure raises inside it.
#
# WHY THIS GUARD EXISTS (issue #522). pgTAP's throws_ok and throws_like run the statement under test
# inside a plpgsql function. A committing procedure (transmute, from_hypertable_copy, ...) that does
# NOT refuse runs on to its first COMMIT there and dies with 2D000 "invalid transaction termination",
# and the rollback leaves the table exactly as a refusal would have. So an assertion whose SQLSTATE and
# message are both unconstrained passes for the refusal AND for the conversion it exists to rule out,
# and every state check after it passes too. throws_ok(sql, NULL, 'description') is such an assertion:
# the three-argument overload treats a five-octet second argument as the SQLSTATE and anything else
# (NULL included) as the message, so NULL there constrains nothing. Four of these shipped (tests/72,
# tests/timescale/db/08, 10 and 14); this keeps a fifth from landing.
#
# HOW. For every throws_* pgTAP installs (read from its catalog, see below: ok, like, ilike, matching and
# imatching in pgTAP 1.3) whose statement under test CALLs a pgpm procedure, however the procedure is
# named (schema quoted or not, any case, whitespace or comments around the dot, unqualified, or through a
# format() placeholder; #1182, see calls_pgpm below and its self-check, a third CONTROL),
# however that statement is written (dollar-quoted, single-quoted, built by format()) and however many
# arguments follow it (none included), the SAME assertion is re-issued with that statement swapped for one that raises exactly that 2D000
# (`do $d$ begin commit; end $d$`), and it has to say `not ok`. Nothing here depends on pgpm's code
# being right or wrong: the guard is about the assertions, which is why its mutation lives in a TEST
# file (below). pgpm_core is still installed, so a pattern built from a pgpm helper evaluates
# (tests/123 builds one with pgpm._ts_to_uuid). A pattern that reads a table only its own file
# creates cannot be evaluated here and is reported as INFO, neither pass nor failure: it is an
# expression, and an expression is not the bare NULL this guard exists to catch.
#
# Three CONTROLS run first, so a broken instrument cannot read as a clean tree: a synthetic unpinned
# assertion must say `ok` (the substituted statement really raises 2D000 inside the wrapper, and NULL
# really accepts it), a P0001-pinned one must say `not ok`, and the site recogniser must read every
# spelling in its self-check as a call of a pgpm procedure, and the calls of other procedures there as
# none. Any control failing FAILS the guard.
#
# The mutations it is required to fail against (bench/mutations/mutate.py):
#   throws_ok_null_pattern -- tests/72's refusal assertion put back to throws_ok(..., NULL, desc)
#   throws_ok_one_argument -- a ONE-argument throws_ok($$ call pgpm... $$) beside tests/72's pinned one,
#                             which accepts any error at all. The site pattern used to demand a comma after
#                             the statement, so it never saw this form and passed the file on its pinned
#                             neighbour alone (#601); the neighbour is what makes that failure mode visible
#                             here, since a file with NO site already fails the "found a site" check
#   throws_ok_null_pattern_113 -- tests/113's refusal assertion loosened the same way (review pass 5 seed S6),
#                             on a statement written across lines, the shape the first mutation lacks
#   throws_ilike_unpinned  -- a throws_ilike($$ call pgpm... $$, '%') beside tests/72's pinned assertion. The
#                             site pattern used to be a hand-written list without ilike, so it never saw this
#                             form and passed the file on the pinned neighbour alone (#915)
#   throws_ok_null_pattern_var_desc -- a throws_ok($$ call pgpm... $$, NULL, :'d72') beside tests/72's pinned
#                             assertion: the bare-NULL shape with its DESCRIPTION in a psql variable. The
#                             psql-variable skip used to search every argument after the statement, so it read
#                             the description as an unevaluable pattern and reported the site INFO (#1000)
#   throws_ok_quoted_schema -- a throws_ok($$ call "pgpm".transmute(...) $$, NULL, desc) beside tests/72's pinned
#                             assertion. The site pattern used to be the text `call\s+pgpm\.`, so a quoted schema was no
#                             site at all and the file passed on the pinned neighbour alone (#1182)
# and bench/throws_pinned_sites.sh holds THIS script to its recogniser (mutation throws_pinned_site_by_spelling).
#
# Usage: throws_pinned.sh <container> <db> [test file]
# With no third argument it probes every tests/**/*.sql in the repository. With one it probes THAT
# file only, which is how bench/discriminate.sh points it at a mutant; a /repo/... path is mapped to
# this checkout, because the probe is built on the host and only run through docker exec. Runs on the
# plain core image (pgtap is all it needs from the container); python3 is needed on the host, as it is
# for mutate.py.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; ONLY="${3:-}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail=0

q() { docker exec -i "$C" psql -U postgres "$@"; }

FILES=()
if [ -n "$ONLY" ]; then
  ONLY="${ONLY/#\/repo\//$ROOT/}"
  if [ ! -f "$ONLY" ]; then
    printf 'FAIL  %-58s %s\n' "the file to probe exists" "$ONLY"; exit 1
  fi
  FILES=("$ONLY")
else
  while IFS= read -r f; do FILES+=("$ROOT/$f"); done < <(cd "$ROOT" && find tests -name '*.sql' | sort)
fi

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT

q -d postgres -q -c "drop database if exists $DB" >/dev/null 2>&1
q -d postgres -q -c "create database $DB" >/dev/null 2>&1
q -d "$DB" -q -c "create extension if not exists pgtap;" >/dev/null 2>&1
# The core is installed so a pattern built from a pgpm helper evaluates; nothing under test is in it. The
# from_hypertable module goes in beside it (it installs without TimescaleDB, whose checks run at call time)
# so that its procedures are in the catalog the site recogniser reads below.
for mod in pgpm_core pgpm_hypertable; do
  if ! q -d "$DB" -v ON_ERROR_STOP=1 -q --single-transaction -f "/repo/$mod/install.sql" >/dev/null 2>&1; then
    printf 'FAIL  %-58s %s\n' "$mod installed" "/repo/$mod/install.sql"
    q -d postgres -q -c "drop database if exists $DB" >/dev/null 2>&1
    exit 1
  fi
done

# WHICH throws_* A SITE CAN BE (#915). The site pattern used to be a hand-written list,
# throws_(ok|like|matching|imatching), and it left out pgTAP's throws_ilike: a throws_ilike($$ call pgpm... $$,
# '%') accepts the 2D000 as readily as a NULL pattern does, and the guard never saw it. So the forms are read
# from the pgTAP the probe runs against, every function of the extension named throws_<word>, and a form a
# later pgTAP adds is a site the day it is installed. The one form the controls below use has to be among
# them, or the catalog read itself is broken and an empty pattern would find no site anywhere.
forms=$(q -d "$DB" -tAq -c "select string_agg(distinct substr(p.proname, 8), ' ')
                              from pg_proc p
                              join pg_depend d on d.classid = 'pg_proc'::regclass and d.objid = p.oid and d.deptype = 'e'
                              join pg_extension x on x.oid = d.refobjid and x.extname = 'pgtap'
                             where p.proname ~ '^throws_[a-z]+$'" 2>&1 </dev/null)
if [[ " $forms " == *" ok "* ]]; then
  printf 'PASS  %-58s %s\n' "the site pattern is every throws_* pgTAP installs" "$forms"
else
  printf 'FAIL  %-58s %s\n' "the site pattern is every throws_* pgTAP installs" "read: ${forms:-nothing}"
  q -d postgres -q -c "drop database if exists $DB" >/dev/null 2>&1
  exit 1
fi

# WHICH STATEMENTS A SITE CAN BE (#1182). A site used to be any statement whose text matched `call\s+pgpm\.`,
# so `call "pgpm".transmute(...)`, the same committing procedure with its schema quoted, was never probed and
# an unpinned throws_ok around it passed on its pinned neighbour. The statement is now read for the procedure
# it CALLs, as PostgreSQL reads a name (below), and judged against the procedures pgpm installs, read from
# the catalog the way the forms are. The two procedures the self-check below names have to be among them, or
# the catalog read is broken and the recogniser would match nothing but a schema spelled pgpm.
procs=$(q -d "$DB" -tAq -c "select string_agg(distinct proname, ' ')
                              from pg_proc
                             where pronamespace = 'pgpm'::regnamespace and prokind = 'p'" 2>&1 </dev/null)
if [[ " $procs " == *" transmute "* && " $procs " == *" from_hypertable_copy "* ]]; then
  printf 'PASS  %-58s %s\n' "a site is a call of any procedure pgpm installs" "$procs"
else
  printf 'FAIL  %-58s %s\n' "a site is a call of any procedure pgpm installs" "read: ${procs:-nothing}"
  q -d postgres -q -c "drop database if exists $DB" >/dev/null 2>&1
  exit 1
fi

THROWS_FORMS="$forms" PGPM_PROCS="$procs" python3 - "$ROOT" "${FILES[@]}" > "$work/probe.sql" <<'PY' || { echo "FAIL  the probe could not be built"; q -d postgres -q -c "drop database if exists $DB" >/dev/null 2>&1; exit 1; }
import os, re, sys
root, files = sys.argv[1], sys.argv[2:]
forms = os.environ["THROWS_FORMS"].split()
# A site is a throws_* call whose FIRST argument (the statement under test, as written: dollar-quoted,
# single-quoted or built by format()) calls a pgpm procedure (calls_pgpm below); everything after that
# argument is the assertion's own arguments, possibly none. The argument list is SPLIT, not pattern-matched (#601): a
# pattern that demanded a comma after a dollar-quoted statement never saw the one-argument form, which
# pins nothing at all, nor a single-quoted statement.
CALL = re.compile(r"\bthrows_(" + "|".join(re.escape(f) for f in forms) + r")\s*\(", re.I)
DOLLAR = re.compile(r"\$([A-Za-z_]\w*)?\$")
TAG = "$pr522$"


def split_args(text, i):
    """The top-level arguments of the call whose '(' ends just before i, as raw text, and the index after
    its ')'. Quotes (single, dollar with any tag), nested parentheses and -- comments are respected. None
    when the call never closes: a site the probe cannot delimit is a failure, not a skip."""
    args, start, depth, n = [], i, 0, len(text)
    while i < n:
        c = text[i]
        if c == "'":
            i += 1
            while i < n and not (text[i] == "'" and text[i + 1:i + 2] != "'"):
                i += 2 if text.startswith("''", i) else 1
            i += 1
            continue
        if c == "$":
            d = DOLLAR.match(text, i)
            if d:
                close = text.find(d.group(0), d.end())
                if close < 0:
                    return None
                i = close + len(d.group(0))
                continue
        if text.startswith("--", i):
            i = text.find("\n", i)
            if i < 0:
                return None
            continue
        if c == "(":
            depth += 1
        elif c == ")":
            if depth == 0:
                args.append(text[start:i])
                return args, i + 1
            depth -= 1
        elif c == "," and depth == 0:
            args.append(text[start:i])
            start = i + 1
        i += 1
    return None


PROCS = set(os.environ["PGPM_PROCS"].split())
KEYWORD = re.compile(r"\bcall\b", re.I)
QUOTED_NAME = re.compile(r'(?:([Uu])&)?"((?:[^"]|"")*)"')   # "pgpm", and U&"\0070gpm" with its escapes
UNICODE_ESCAPE = re.compile(r"\\(\\|[0-9A-Fa-f]{4}|\+[0-9A-Fa-f]{6})")
PLAIN_NAME = re.compile(r"[A-Za-z_\u0080-\U0010ffff][A-Za-z0-9_$\u0080-\U0010ffff]*")
PLACEHOLDER = re.compile(r"%(?:\d+\$)?-?\d*[IsL]")      # format()'s %I, %s, %L, %1$I, %-10s
FOLD = str.maketrans("ABCDEFGHIJKLMNOPQRSTUVWXYZ", "abcdefghijklmnopqrstuvwxyz")


def skip_blank(text, i):
    """The index of the first character at or after i that is neither whitespace nor inside a comment."""
    n = len(text)
    while i < n:
        if text[i].isspace():
            i += 1
        elif text.startswith("--", i):
            j = text.find("\n", i)
            i = n if j < 0 else j + 1
        elif text.startswith("/*", i):
            j = text.find("*/", i + 2)
            i = n if j < 0 else j + 2
        else:
            break
    return i


def called_names(text):
    """The name every CALL in text names, as PostgreSQL reads it: dot-separated parts with whitespace and
    comments allowed around each dot, a double-quoted part taken verbatim ("" for ", and a U&"..." part with
    its default \\XXXX and \\+XXXXXX escapes decoded; a UESCAPE clause is not read), an unquoted one folded
    to lower case (ASCII only, as the server folds it), and a format() placeholder kept as None, because the
    value it stands for is only known at run time. A CALL followed by nothing that reads as a name (a word
    in prose, `call :=`) yields nothing."""
    for m in KEYWORD.finditer(text):
        parts, i = [], m.end()
        while True:
            i = skip_blank(text, i)
            q = QUOTED_NAME.match(text, i)
            p = None if q else PLACEHOLDER.match(text, i)
            u = None if q or p else PLAIN_NAME.match(text, i)
            if q:
                name = q.group(2).replace('""', '"')
                if q.group(1):
                    name = UNICODE_ESCAPE.sub(lambda e: "\\" if e.group(1) == "\\" else chr(int(e.group(1).lstrip("+"), 16)), name)
                parts.append(name); i = q.end()
            elif p:
                parts.append(None); i = p.end()
            elif u:
                parts.append(u.group(0).translate(FOLD)); i = u.end()
            else:
                break
            j = skip_blank(text, i)
            if not text.startswith(".", j):
                break
            i = j + 1
        if parts:
            yield parts


def calls_pgpm(text):
    """True when a CALL in text can reach a pgpm procedure: its schema is pgpm however spelled, or its
    procedure is one pgpm installs (with any schema or none, so an unqualified call under a search_path
    counts), or a part of its name is a format() placeholder this reading cannot resolve. Probing a site
    that turns out not to be pgpm's costs nothing a pinned assertion does not already pay; skipping one
    that is pgpm's is the defect this guard exists for (#1182)."""
    for parts in called_names(text):
        if None in parts or parts[-1] in PROCS or (len(parts) >= 2 and parts[-2] == "pgpm"):
            return True
    return False


# The recogniser's own self-check, run on every invocation before any file is read: each spelling the issue
# and the server accept must be a site, and a call of another schema's procedure, a word after `call` in
# prose and a function select must not, so neither a recogniser that sees nothing nor one that sees
# everything gets past it. Printed as a CONTROL row the shell below asserts by name.
SPELLINGS = [
    ("call pgpm.transmute('public.t', 'id', 10)", True),
    ('call "pgpm".transmute(\'public.t\', \'id\', 10)', True),
    ('CALL PGPM . "transmute"(\'public.t\', \'id\', 10)', True),
    ("call\n  pgpm\n  .maintain_all()", True),
    ("call /* c */ pgpm./* c */maintain('public.t')", True),
    ('call"pgpm"."from_hypertable_copy"(\'public.h\')', True),
    ("call transmute('public.t', 'id', 10)", True),
    ("format('call %I.%I(%L, %L, 10)', 'pgpm', 'transmute', 'public.t', 'id')", True),
    ("do $d$ begin call pgpm.maintain_obtain('public.t'); end $d$", True),
    ('call U&"\\0070gpm".U&"m\\0061intain"(\'public.t\')', True),
    ('call U&"\\0050GPM".mk(\'public.t\')', False),
    ("call pg_temp.mk('public.t')", False),
    ('call "PGPM".mk(\'public.t\')', False),
    ("select pgpm.transmute_abort('public.t') -- the call that follows", False),
]
wrong = [t for t, want in SPELLINGS if calls_pgpm(t) != want]
print("select 'CONTROL spellings => " + ("ok" if not wrong else "misread " + str(len(wrong)) + ": "
      + " | ".join(" ".join(t.split()) for t in wrong).replace("'", "''")) + "';")


PSQL_VAR = r""":(?:'\w+'|"\w+")"""


def literal_value(arg):
    """The value of an argument written as one NULL, single-quoted or dollar-quoted literal: None for NULL,
    the text otherwise. Raises ValueError for anything else (an integer, an expression, a variable)."""
    a = arg.strip()
    if a.upper() == "NULL":
        return None
    if len(a) >= 2 and a[0] == "'" and a[-1] == "'" and "'" not in a[1:-1].replace("''", ""):
        return a[1:-1].replace("''", "'")
    d = DOLLAR.match(a)
    if d and a.endswith(d.group(0)) and len(a) >= 2 * len(d.group(0)) and d.group(0) not in a[d.end():-len(d.group(0))]:
        return a[d.end():-len(d.group(0))]
    raise ValueError(a)


def description_index(kind, after):
    """Which of the arguments after the statement pgTAP reads as the DESCRIPTION, or None when none is, or
    when which one is depends on a value this probe does not read. throws_ok(sql, a, b, desc) and
    throws_<like|ilike|matching|imatching>(sql, pattern, desc) are positional. throws_ok(sql, a, b) is not:
    pgTAP reads b as the MESSAGE when a is five octets (or an integer SQLSTATE) and as the description
    otherwise, so b is the description only when a is a literal that is NULL or not five octets."""
    n = len(after)
    if kind == "ok":
        if n == 3:
            return 2
        if n == 2:
            try:
                v = literal_value(after[0])
            except ValueError:
                return None
            return 1 if v is None or len(v.encode()) != 5 else None
        return None
    if kind in ("like", "ilike", "matching", "imatching") and n == 2:
        return 1
    return None


sites = 0
print("create extension if not exists pgtap;")
print("select no_plan();")
# The evaluator. The assertion's own arguments are spliced verbatim after the substituted statement.
# An argument only its file can evaluate (a subselect on a table the test creates) is reported rather
# than fatal; anything else that stops the assertion from running is a defect in this probe and is
# reported as such, so a mis-split argument list cannot hide behind ON_ERROR_STOP.
print("""create function pg_temp.probe(kind text, rest text) returns text language plpgsql as $f$
declare r text;
begin
  -- An empty rest is the one-argument form, re-issued with no arguments after the statement.
  execute format('select throws_%s(%s%s)', kind,
                 '$sut$ do $d$ begin commit; end $d$ $sut$', coalesce(', ' || nullif(btrim(rest), ''), '')) into r;
  return r;
exception
  when undefined_table or undefined_column or undefined_function then
    return 'unevaluable ' || sqlstate || ': ' || sqlerrm;
  when others then
    return 'malformed ' || sqlstate || ': ' || sqlerrm;
end $f$;""")
print(f"select 'CONTROL unpinned => ' || pg_temp.probe('ok', {TAG} NULL, NULL, 'control: an unpinned assertion accepts 2D000' {TAG});")
print(f"select 'CONTROL pinned => ' || pg_temp.probe('ok', {TAG} 'P0001', NULL, 'control: a P0001 pin rejects 2D000' {TAG});")
for path in files:
    src = open(path).read()
    shown = path[len(root) + 1:] if path.startswith(root + "/") else path
    for m in CALL.finditer(src):
        line = src[:m.start()].count("\n") + 1
        if "--" in src[src.rfind("\n", 0, m.start()) + 1:m.start()]:
            continue   # named in a comment, not called
        split = split_args(src, m.end())
        if split is None:
            sys.exit(f"probe: {shown}:{line}: cannot find where this throws_{m.group(1)}( call ends")
        args, _end = split
        if not calls_pgpm(args[0]):
            continue
        kind = m.group(1).lower()
        after = args[1:]
        if TAG in ",".join(after):
            sys.exit(f"probe: {shown} contains the probe's own quoting tag {TAG}; pick another")
        sites += 1
        # A pattern that reads one of its file's own psql variables (:'rel60') is an expression this probe
        # cannot evaluate, like one that reads its file's own table: reported, neither pass nor failure.
        # Only the quoted forms are recognised, because they cannot be anything else; a bare :name that
        # reaches the server is a syntax error, which FAILS as malformed rather than hiding.
        # The skip is scoped to the arguments pgTAP reads as a PATTERN (#1000). It used to search every
        # argument after the statement, so throws_ok($$ call pgpm... $$, NULL, :'d'), the bare-NULL shape
        # this guard exists for with its description in a variable, was reported INFO and passed. The
        # description pins nothing, so a variable there is replaced by a literal and the site is probed.
        desc = description_index(kind, after)
        pattern_args = [a for j, a in enumerate(after) if j != desc]
        psql_var = re.search(PSQL_VAR, ",".join(pattern_args))
        if psql_var:
            name = psql_var.group(0)[2:-1]
            print(f"select '{shown}:{line} => unevaluable psql variable {name}: set by its own file';")
            continue
        if desc is not None and re.search(PSQL_VAR, after[desc]):
            after = after[:desc] + [" 'description read from a psql variable'"] + after[desc + 1:]
        rest = ",".join(after).strip()
        print(f"select '{shown}:{line} => ' || pg_temp.probe('{kind}', {TAG} {rest} {TAG});")
print(f"\\echo SITES {sites}")
PY

out=$(q -d "$DB" -tAq -v ON_ERROR_STOP=1 -f - < "$work/probe.sql" 2>&1)
rc=$?
q -d postgres -q -c "drop database if exists $DB" >/dev/null 2>&1
if [ "$rc" != 0 ]; then
  printf 'FAIL  %-58s %s\n' "the probe ran to completion" "psql exit $rc"
  echo "$out" | tail -15 | sed 's/^/      /'
  exit 1
fi

# The instrument first. A tree with no unpinned site and a probe whose substituted statement no longer
# raises inside the wrapper would print the same clean list, so both controls are asserted by name.
# Each control is read from a here-string, not `echo "$out" | grep -q`: grep -q exits at its first match and
# closes the pipe, echo then dies of EPIPE on a large enough $out, and under pipefail that dead pipeline
# reads as the control FAILING although the line it printed was the expected one (#688's head, 92 sites,
# `line 196: echo: write error: Broken pipe`). A here-string is written whole before grep reads it.
if grep -q '^CONTROL unpinned => ok ' <<<"$out"; then
  printf 'PASS  %-58s %s\n' "control: 2D000 is raised inside the wrapper and NULL accepts it" "ok"
else
  printf 'FAIL  %-58s %s\n' "control: 2D000 is raised inside the wrapper and NULL accepts it" "$(echo "$out" | grep '^CONTROL unpinned' | head -1)"
  fail=1
fi
if grep -qx 'CONTROL spellings => ok' <<<"$out"; then
  printf 'PASS  %-58s %s\n' "control: every spelling of a pgpm call is a site, no other" "ok"
else
  printf 'FAIL  %-58s %s\n' "control: every spelling of a pgpm call is a site, no other" "$(grep '^CONTROL spellings' <<<"$out" | head -1)"
  fail=1
fi
if grep -q '^CONTROL pinned => not ok ' <<<"$out"; then
  printf 'PASS  %-58s %s\n' "control: a P0001 pin rejects that 2D000" "not ok"
else
  printf 'FAIL  %-58s %s\n' "control: a P0001 pin rejects that 2D000" "$(echo "$out" | grep '^CONTROL pinned' | head -1)"
  fail=1
fi

# One row per site, `<path>.sql:<line> => <verdict>`. The filter demands exactly that shape because
# pgTAP's own diagnostic for a throws_like miss echoes the pattern, and several patterns in this tree
# contain ` => ` themselves (`p_track_changes => true`), so a looser match counted diagnostics as sites.
sites=$(echo "$out" | sed -n 's/^SITES //p' | tail -1)
pinned=0; accepts=0; unevaluable=0; malformed=0
while IFS= read -r l; do
  site="${l%% => *}"; verdict="${l#* => }"
  case "$verdict" in
    "not ok "*)      pinned=$((pinned + 1)) ;;
    "ok "*)          accepts=$((accepts + 1))
                     printf 'FAIL  %-58s %s\n' "$site accepts 2D000: a procedure that did NOT refuse satisfies it" "${verdict%% - *}" ;;
    unevaluable*)    unevaluable=$((unevaluable + 1))
                     printf 'INFO  %-58s %s\n' "$site: pattern is an expression this probe cannot evaluate" "${verdict#unevaluable }" ;;
    *)               malformed=$((malformed + 1))
                     printf 'FAIL  %-58s %s\n' "$site: the probe could not run the assertion" "$verdict" ;;
  esac
done < <(echo "$out" | grep -E '^[^ ]+\.sql:[0-9]+ => ')

judged=$((pinned + accepts + unevaluable + malformed))
if [ -z "$sites" ] || [ "$sites" -eq 0 ]; then
  # A file with nothing to probe is a vacuous pass, and in mutant mode it would mean the mutation
  # rewrote the assertion into something this guard no longer recognises: either way, not evidence.
  printf 'FAIL  %-58s %s\n' "the probe found at least one throws_* around call pgpm." "${sites:-none} found"
  fail=1
elif [ "$judged" -ne "$sites" ]; then
  printf 'FAIL  %-58s %s\n' "every site the probe found was judged" "$sites found, $judged judged"
  fail=1
fi
[ "$accepts" -eq 0 ] && [ "$malformed" -eq 0 ] || fail=1

if [ "$fail" = 0 ]; then
  printf 'PASS  %-58s %s\n' "every throws_* around call pgpm. rejects a bare 2D000" "$pinned pinned, $unevaluable by an expression, of $sites"
else
  printf 'FAIL  %-58s %s\n' "every throws_* around call pgpm. rejects a bare 2D000" "$accepts accept, $malformed unprobed, $pinned pinned, $unevaluable by an expression, of $sites"
fi
exit "$fail"
