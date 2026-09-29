#!/usr/bin/env bash
# Prove that every throws_* assertion around `call pgpm.<procedure>` in the test tree PINS what it
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
# HOW. For every throws_(ok|like|matching|imatching) whose statement under test contains `call pgpm.`,
# however that statement is written (dollar-quoted, single-quoted, built by format()) and however many
# arguments follow it (none included), the SAME assertion is re-issued with that statement swapped for one that raises exactly that 2D000
# (`do $d$ begin commit; end $d$`), and it has to say `not ok`. Nothing here depends on pgpm's code
# being right or wrong: the guard is about the assertions, which is why its mutation lives in a TEST
# file (below). pgpm_core is still installed, so a pattern built from a pgpm helper evaluates
# (tests/123 builds one with pgpm._ts_to_uuid). A pattern that reads a table only its own file
# creates cannot be evaluated here and is reported as INFO, neither pass nor failure: it is an
# expression, and an expression is not the bare NULL this guard exists to catch.
#
# Two CONTROLS run first, so a broken instrument cannot read as a clean tree: a synthetic unpinned
# assertion must say `ok` (the substituted statement really raises 2D000 inside the wrapper, and NULL
# really accepts it) and a P0001-pinned one must say `not ok`. Either control failing FAILS the guard
# before any site is judged.
#
# The mutations it is required to fail against (bench/mutations/mutate.py):
#   throws_ok_null_pattern -- tests/72's refusal assertion put back to throws_ok(..., NULL, desc)
#   throws_ok_one_argument -- a ONE-argument throws_ok($$ call pgpm... $$) beside tests/72's pinned one,
#                             which accepts any error at all. The site pattern used to demand a comma after
#                             the statement, so it never saw this form and passed the file on its pinned
#                             neighbour alone (#601); the neighbour is what makes that failure mode visible
#                             here, since a file with NO site already fails the "found a site" check
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
python3 - "$ROOT" "${FILES[@]}" > "$work/probe.sql" <<'PY' || { echo "FAIL  the probe could not be built"; exit 1; }
import re, sys
root, files = sys.argv[1], sys.argv[2:]
# A site is a throws_* call whose FIRST argument (the statement under test, as written: dollar-quoted,
# single-quoted or built by format()) contains `call pgpm.`; everything after that argument is the
# assertion's own arguments, possibly none. The argument list is SPLIT, not pattern-matched (#601): a
# pattern that demanded a comma after a dollar-quoted statement never saw the one-argument form, which
# pins nothing at all, nor a single-quoted statement.
CALL = re.compile(r"\bthrows_(ok|like|matching|imatching)\s*\(", re.I)
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
        if not re.search(r"\bcall\s+pgpm\.", args[0], re.I):
            continue
        rest = ",".join(args[1:]).strip()
        if TAG in rest:
            sys.exit(f"probe: {shown} contains the probe's own quoting tag {TAG}; pick another")
        sites += 1
        # A pattern that reads one of its file's own psql variables (:'rel60') is an expression this probe
        # cannot evaluate, like one that reads its file's own table: reported, neither pass nor failure.
        # Only the quoted forms are recognised, because they cannot be anything else; a bare :name that
        # reaches the server is a syntax error, which FAILS as malformed rather than hiding.
        psql_var = re.search(r""":(?:'\w+'|"\w+")""", rest)
        if psql_var:
            name = psql_var.group(0)[2:-1]
            print(f"select '{shown}:{line} => unevaluable psql variable {name}: set by its own file';")
            continue
        print(f"select '{shown}:{line} => ' || pg_temp.probe('{m.group(1).lower()}', {TAG} {rest} {TAG});")
print(f"\\echo SITES {sites}")
PY

q -d postgres -q -c "drop database if exists $DB" >/dev/null 2>&1
q -d postgres -q -c "create database $DB" >/dev/null 2>&1
q -d "$DB" -q -c "create extension if not exists pgtap;" >/dev/null 2>&1
# The core is installed so a pattern built from a pgpm helper evaluates; nothing under test is in it.
if ! q -d "$DB" -v ON_ERROR_STOP=1 -q --single-transaction -f /repo/pgpm_core/install.sql >/dev/null 2>&1; then
  printf 'FAIL  %-58s %s\n' "pgpm_core installed" "/repo/pgpm_core/install.sql"
  q -d postgres -q -c "drop database if exists $DB" >/dev/null 2>&1
  exit 1
fi

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
if echo "$out" | grep -q '^CONTROL unpinned => ok '; then
  printf 'PASS  %-58s %s\n' "control: 2D000 is raised inside the wrapper and NULL accepts it" "ok"
else
  printf 'FAIL  %-58s %s\n' "control: 2D000 is raised inside the wrapper and NULL accepts it" "$(echo "$out" | grep '^CONTROL unpinned' | head -1)"
  fail=1
fi
if echo "$out" | grep -q '^CONTROL pinned => not ok '; then
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
