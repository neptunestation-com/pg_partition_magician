#!/usr/bin/env bash
# Prove that the checks a shell guard's header calls its liveness witnesses or premises, and the premise
# assertions of the pgTAP files the bench wrappers run, print as lines that bench/discriminate.sh reads as
# premises, so a mutant run that failed only them is refused as a starved fixture instead of being certified
# as a catch.
#
# WHY THIS GUARD EXISTS (issue #1095, F7-02). discriminate.sh refuses a guard whose every failure against its
# mutant is a premise witness (#713): its starved() reads each FAIL line and calls the run starved when every
# description begins `LIVENESS:`, `GUARD:` or `fixture:`. It reads the HEAD of the line and nothing else. Eight
# shell guards printed the checks their own headers call liveness witnesses with no prefix at all
# (maintain_lock's "the tick did the work that takes the lock (retain)", archive_lz77_memory's "chunk1 was
# sampled while it ran", ...) or behind a tag (obtain_backoff_headroom's "$2: the lock race really happened",
# archive_deflate_memory's "$label: the call was sampled while it ran"), so a mutant that starved one of them
# (the classic case: maintain_lock's probe starving retain into skip_retain, which then takes no lock) failed
# only a witness and discriminate.sh printed "PASS <guard> fails when the defect is present".
# AND (#1175, #1146 bullet 1) fifteen more guards did the same with premises their headers or comments name:
# obtain_backoff_headroom's "the back-off is still in the future", transmute_lock's "the probe caught the
# validation scan in progress", the upgrade guards' origin witnesses and preconditions, tests_fail_on_defect's
# "planted the defect" lines, lock_trace's interval witnesses, and others. AND (#1033 bullet 3) the premises
# were spelled in words starved() does not read: `WITNESS:` and `precondition:` in bench/, and in about a
# hundred pgTAP files the wrappers run `A LIVENESS:`, `LIVENESS (A):`, `LIVENESS A:`, `witness:`, `setup:`,
# `fixture (A):`, which a wrapper echoes as `not ok N - <description>` for starved() to misread.
# AND (#1380) the premises a guard prints from PYTHON, in a heredoc or a bench/*.py file, were read by no
# scan at all: archive_to_s3_compress.sh's decoder half printed `FAIL  single: LIVENESS: rows were read at
# all`, the run label ahead of the prefix, archive_parquet_snapshot.sh's printed `pyarrow read rows at all`
# with no prefix, and lock_trace.sh's "the probe attached and is delivering events" premise (shell, but
# missing from the FLOOR) failed unprefixed before its exit 1.
#
# WHAT IT ASSERTS.
#   FLOOR  Each witness or premise the listed guards name, read out of the guard's source as written, is
#          printed the way the guard prints it (its OWN check() or say(), or its own `printf 'FAIL ...'` format,
#          or its `echo "FAIL  ..."`) as a FAIL line, and discriminate.sh's OWN starved() (read out of
#          bench/discriminate.sh, not restated here) refuses a run that failed only that line. Judged by what
#          the rule reads, not by a spelling: a prefix behind the tag, or a miscased one, fails here exactly
#          as a missing one does. The list is the inventory of the known sites, the way
#          bench/wrapper_tap_verdicts.sh's WRAPPERS list is; which check is a premise is a judgment a header
#          makes in prose, so a new guard's witnesses are held here once they are listed, and by SPELLING
#          below until then.
#   FLOOR  Each listed guard's DEFECT checks are certified as a catch when they fail alone. This is the
#          instrument's liveness (a rendering that read everything as starved would pass the witnesses), and
#          it pins the asymmetry that matters in the archive guards: "returned a Parquet file", "raised no
#          ERROR" and the like look like witnesses, but they are the only checks the #912/#992 mutants
#          (archive_*_raises, archive_lz77_repeat_differs) fail, so a LIVENESS: prefix on them would make
#          discriminate.sh refuse those guards as starved. upgrade_in_place's "DEGRADE_COLS names every
#          backfilled column" is the same: it reads like a precondition, and it is the one check mutation
#          upgrade_degrade_list_drift exists to fail.
#   SPELLING  Over every bench/*.sh: no label a FAIL-printing helper (or a bare `printf 'FAIL ...'`) is
#          given carries a premise word (`LIVENESS`, `LIVENESS WITNESS`, `WITNESS`, `precondition`, `setup`,
#          `fixture`, `GUARD`, any case, with or without a `(tag)`) followed by a colon anywhere but at its
#          head in exactly the spelling starved() reads (`$2: LIVENESS:`, `Liveness:`, `WITNESS:`,
#          `precondition:`), since starved() cannot see one there.
#   SPELLING  Over every Python helper in bench/: the body of every heredoc in a bench/*.sh, and every
#          bench/*.py. A helper is a function that prints FAIL; each call to it whose label is a literal
#          carrying a premise word and a colon (the shell rule's words) is rendered FAILING through the
#          helper itself (its own format, run label and all) and must be read as starved by starved().
#          Judged by what the rule reads, so a helper that puts its run label ahead of the prefix fails
#          here though every label it is given is spelled right. The FLOOR reads Python calls the same way.
#   SPELLING  Over every pgTAP file a bench/*.sh names (the files the wrappers run, whose `not ok` lines
#          discriminate.sh reads): no SQL string literal begins, after an optional tag of up to three
#          characters, with one of those premise words and a colon unless it begins exactly `LIVENESS:`,
#          `GUARD:` or `fixture:`. The tag goes after the prefix: `LIVENESS: (A) ...`. Both scans are held to
#          planted spellings, positive and negative, before they are trusted with the checkout.
#   LIVENESS  starved() was found and reads a planted witness-only run as starved and a planted defect run
#          as a catch; every floor guard's witnesses and defect checks were found and rendered as FAIL lines;
#          the shell scan read the helper calls of the directory, the floor's own labels among them; the
#          Python scan read the helper calls of the heredocs and bench/*.py, rendered failing, the floor's
#          among them; the SQL scan read the wrapper-run files, tests/296 and tests/297 among them, and
#          their prefixed premises.
#
# Not covered, deliberately: a premise printed with no premise word at all, in a guard the FLOOR does not
# list. Which check is a premise is the header's judgment in prose; the FLOOR is where it is recorded.
#
# The mutations it is required to fail against (bench/mutations/mutate.py):
#   witness_label_unprefixed        -- maintain_lock.sh's retain work witness printed without its prefix,
#                                      the pre-#1095 label
#   witness_label_prefix_behind_tag -- obtain_backoff_headroom.sh's lock-race witness with the prefix behind
#                                      its `$2: ` tag, where starved() cannot read it
#   witness_label_backoff_unprefixed -- obtain_backoff_headroom.sh's back-off premise without its prefix,
#                                      the pre-#1175 label
#   witness_label_scan_witness_unprefixed -- transmute_lock.sh's "the probe caught the validation scan in
#                                      progress" without its prefix, the pre-#1146 label
#   witness_label_on_defect_check   -- upgrade_in_place.sh's DEGRADE_COLS check given a GUARD: prefix, the
#                                      plausible wrong fix that turns upgrade_degrade_list_drift's catch
#                                      into a starved fixture
#   witness_label_precondition_word -- upgrade_unanchored_cell.sh's origin premise spelled `precondition:`,
#                                      the pre-#1033 word
#   witness_label_test_tag_before_prefix -- tests/296's first witness spelled `A LIVENESS: ...` again, the
#                                      pre-#1033 spelling of a wrapper-run file
#   witness_label_py_run_label_first -- archive_to_s3_compress.sh's decoder helper prints the run label
#                                      ahead of the prefix again, the pre-#1380 helper
#   witness_label_py_unprefixed     -- archive_parquet_snapshot.sh's "pyarrow read rows at all" without its
#                                      prefix, the pre-#1380 label
#   witness_label_probe_attached_unprefixed -- lock_trace.sh's "the probe attached and is delivering
#                                      events" without its prefix, the pre-#1380 label
#
# Usage: liveness_witness_labels.sh <container> <db> [guard script or test file]
# With no third argument it judges this checkout. With one it judges THAT file in place of the one it
# stands for, recognised by its file name or, for a mutant bench/discriminate.sh built (<mutation>.sql), by
# the mutation's MUTATION_SRC (a bench/ guard or a tests/ file); a /repo/... path is mapped to this checkout.
# Needs bash and python3 on the host and nothing else; <container> and <db> are accepted so discriminate.sh
# can call it the way it calls every guard, and are not used.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ONLY="${3:-}"
fail=0
ok()  { printf 'PASS  %-78s %s\n' "$1" "$2"; }
bad() { printf 'FAIL  %-78s %s\n' "$1" "$2"; fail=1; }
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# ---- discriminate.sh's own starved(), and that it reads at all ------------------------------------------
starved_fn=$(sed -n '/^starved() {/,/^}/p' "$ROOT/bench/discriminate.sh")
if [ -z "$starved_fn" ]; then bad "LIVENESS: starved() was read out of bench/discriminate.sh" "not found"; exit 1; fi
eval "$starved_fn"
printf 'PASS  a planted defect check   0\nFAIL  LIVENESS: a planted witness   got false, want true\n' > "$work/w.log"
printf 'PASS  LIVENESS: a planted witness   true\nFAIL  a planted defect check   got 3, want 0\n' > "$work/d.log"
printf '    not ok 7 - LIVENESS: (A) a planted witness\n' > "$work/tw.log"
printf '    not ok 7 - a planted defect check\n' > "$work/td.log"
if starved "$work/w.log" && ! starved "$work/d.log" && starved "$work/tw.log" && ! starved "$work/td.log"; then
  ok "LIVENESS: starved() refuses planted witness-only runs, certifies defect runs" "FAIL and TAP"
else
  bad "LIVENESS: starved() refuses planted witness-only runs, certifies defect runs" "it does not"; exit 1
fi

# ---- which file stands in for which -----------------------------------------------------------------------
ONLY_NAME=""; ONLY_TEST=""
if [ -n "$ONLY" ]; then
  ONLY="${ONLY/#\/repo\//$ROOT/}"
  if [ ! -f "$ONLY" ]; then bad "GUARD: the file to judge exists" "$ONLY"; exit 1; fi
  base=$(basename "$ONLY")
  src=$(python3 - "$ROOT/bench/mutations" "${base%.*}" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import mutate
print(mutate.MUTATION_SRC.get(sys.argv[2], ""))
PY
)
  for f in "$ROOT"/bench/*.sh; do
    n=$(basename "$f" .sh)
    if [ "$base" = "$n.sh" ] || [ "$src" = "bench/$n.sh" ]; then ONLY_NAME="$n"; fi
  done
  case "$src" in tests/*.sql) ONLY_TEST="$src" ;; esac
  if [ -z "$ONLY_TEST" ] && [[ "$ONLY" == "$ROOT"/tests/*.sql ]]; then ONLY_TEST="${ONLY#"$ROOT"/}"; fi
  if [ -z "$ONLY_NAME" ] && [ -z "$ONLY_TEST" ]; then
    bad "GUARD: the file to judge stands for a guard in bench/ or a test file" "$ONLY -> '${src}'"; exit 1
  fi
fi
script_of() { if [ "$1" = "$ONLY_NAME" ]; then echo "$ONLY"; else echo "$ROOT/bench/$1.sh"; fi; }

# ---- FLOOR: the witnesses and premises the listed guards name, and a defect check of each ------------------
# <guard>|<W: a witness or premise, must read as starved; D: a defect check, must read as a catch>|<ERE over
# the label as the guard writes it>
FLOOR='
maintain_lock|W|the probe overlapped a running tick
maintain_lock|W|at least one read landed inside the tick \(ml\)
maintain_lock|W|at least one read landed inside the tick \(mg_ret\)
maintain_lock|W|the tick did the work that takes the lock \(obtain\)
maintain_lock|W|the tick did the work that takes the lock \(retain\)
maintain_lock|W|and regrained in the same tick
maintain_lock|D|a concurrent reader is never locked out \(ml\)
maintain_lock|D|a concurrent reader is never locked out \(mg_ret\)
obtain_backoff_headroom|W|the lock race really happened
obtain_backoff_headroom|W|the deferral set a back-off in the future
obtain_backoff_headroom|W|the back-off is still in the future before the low-headroom tick
obtain_backoff_headroom|D|low headroom: the tick extends the grid through the back-off
obtain_backoff_headroom|D|3 steps covered inside the monolith
obtain_int_ceiling|W|transmute built the grid
obtain_int_ceiling|W|the lookahead from the frontier cell crosses
obtain_int_ceiling|W|tick 1 did the work
obtain_int_ceiling|D|no skip_obtain logged for the table
frontier_drought|W|uuidv7: the backfilled frontier is well outside
frontier_drought|W|text_time: the backfilled frontier is well outside
frontier_drought|D|uuidv7: tick \$tick: a partition covers now\(\)
frontier_drought|D|_frontier_native is at or past now\(\)
archive_lz77_memory|W|the probe found the backend pid
archive_lz77_memory|W|chunk1 was sampled while it ran
archive_lz77_memory|W|chunk2 was sampled while it ran
archive_lz77_memory|W|chunk3 was sampled while it ran
archive_lz77_memory|D|chunk1 returned a Parquet file
archive_lz77_memory|D|the probe session raised no ERROR
archive_lz77_memory|D|returned chunk1.s file again
archive_lz77_memory|D|chunk1 peak RSS stays bounded
archive_deflate_memory|W|the probe found the backend pid
archive_deflate_memory|W|the call was sampled while it ran
archive_deflate_memory|D|the call returned a stream for the whole payload
archive_deflate_memory|D|the probe session raised no ERROR
archive_deflate_memory|D|peak RSS stays bounded
archive_encode_memory|W|the probe found the backend pid
archive_encode_memory|W|the encode call was sampled while it ran
archive_encode_memory|D|the encode call returned the whole column
archive_encode_memory|D|the probe session raised no ERROR
archive_encode_memory|D|peak RSS stays bounded
dropped_fk_identity|W|the forged record reads as a pre-#498 capture would
dropped_fk_identity|W|the restore re-added one key from it
dropped_fk_identity|D|the upgrade rewrote the legacy record schema-qualified
dropped_fk_identity|D|and that key references bf.parent
transmute_lock|W|the probe caught the validation scan in progress
transmute_lock|D|ACCESS EXCLUSIVE is not held during the scan
untransmute_race|W|the writer holds ROW EXCLUSIVE on the parent \(its insert is in flight\)
untransmute_race|D|row 7777 is still reachable through public\.ur
transmute_lock_timeout|W|the blocker is holding a conflicting lock
transmute_lock_timeout|W|the same call succeeds once unblocked
transmute_lock_timeout|D|transmute gives up instead of waiting forever
archive_recorded_chunk_tick_race|W|the race fixture was built
archive_recorded_chunk_tick_race|W|the archive module under test installed
archive_recorded_chunk_tick_race|D|the direct call for \[0, 50\) was refused
throws_pinned|W|the probe found at least one throws_\* assertion
throws_pinned|W|2D000 is raised inside the wrapper and NULL accepts it
throws_pinned|W|every site the probe found was judged
throws_pinned|D|accepts 2D000: a procedure that did NOT refuse satisfies it
tests_fail_on_defect|W|planted the defect:
tests_fail_on_defect|W|the clean install loaded
tests_fail_on_defect|W|the install with no length check loaded
tests_fail_on_defect|D|^\$label$
transmute_claim_squat|W|the dead owner.s session really is gone
transmute_claim_squat|W|a squatter holds the pre-#405 advisory key
transmute_claim_squat|W|the squatting session is still connected
transmute_claim_squat|D|the claim row is gone
regrain_outgoing_fk_lock|W|the regrain was pre-copied up to its swap
regrain_outgoing_fk_lock|W|the probe overlapped a running swap
regrain_outgoing_fk_lock|W|at least one write landed inside it
regrain_outgoing_fk_lock|D|writes to the MANAGED PARENT are not blocked
retire_detach_lock|W|the probe overlapped a running retirement
retire_detach_lock|W|^(LIVENESS: )?reads landed inside it
retire_detach_lock|W|^(LIVENESS: )?writes landed inside it
retire_detach_lock|W|the detach really scanned the referencing table
retire_detach_lock|D|the MANAGED PARENT is never blocked
upgrade_in_place|W|the degrade really removed all
upgrade_in_place|W|maintain_obtain\(\) minted nothing after the upgrade
upgrade_in_place|W|all degrade-list columns exist when fresh
upgrade_in_place|W|every backfill line parsed
upgrade_in_place|W|found no backfill lines at all
upgrade_in_place|D|DEGRADE_COLS names every backfilled column
upgrade_in_place|W|catalog read, columns added since it seen
upgrade_in_place|D|DEGRADE_COLS names every column added since
upgrade_in_place|D|the upgrade backfilled child_oid, to each child.s own oid
upgrade_from_release|W|the origin really is
upgrade_from_release|W|the origin carries all
upgrade_from_release|W|the origin recorded the FK as dropped and unrestored
upgrade_from_release|W|no FK is live on the referencing table before the upgrade
upgrade_from_release|W|a fresh install has none of the
upgrade_from_release|D|the tick restored the preserve-managed FK, by name
upgrade_unanchored_cell|W|the origin has no pgpm\.part\.child_oid
upgrade_unanchored_cell|D|the rebuilt row anchors the partition bounded
lock_trace|W|the probe captured events
lock_trace|W|mg_ret requested ACCESS EXCLUSIVE in the tick
lock_trace|W|exactly one backend requested
lock_trace|W|ml.s turn is visible in the same tick
lock_trace|W|no events were dropped
lock_trace|W|the tick did the work that takes the lock \(retain\)
lock_trace|W|and regrained ml in the same tick
lock_trace|W|the probe attached and is delivering events
lock_trace|D|a transaction commits between mg_ret.s lock and ml.s turn
archive_to_s3_compress|W|rows were read at all
archive_to_s3_compress|D|the ids are the partition.s, each once, in control order
archive_parquet_snapshot|W|pyarrow read rows at all
archive_parquet_snapshot|D|id = tag on every row
regrain_truncate_guard_upgrade|W|the source carries capture and no guard
regrain_truncate_guard_upgrade|W|the resume restarted nothing
regrain_truncate_guard_upgrade|D|a TRUNCATE before any tick is refused
'

# helper_def <file> <name>: the shell function <name>, from its definition line to its closing brace.
helper_def() {
  awk -v n="$2" '
    !f && $0 ~ "^[[:space:]]*" n "\\(\\)[[:space:]]*\\{" { f = 1 }
    f { print }
    f && /(^|[;[:space:]])\}[[:space:]]*(#.*)?$/ { exit }
  ' "$1"
}
# sites <script> <ERE>: every site in <script> that prints a FAIL line with a label matching <ERE>, one per
# line as <form><US><printf format, for the printf form><US><label as written>. The forms are the four the
# guards use in shell: `check "<label>"`, `say FAIL "<label>"`, `printf 'FAIL ...' "<label>"` and
# `echo "FAIL  <label>"`, and a fifth, `py`, for a call to a Python helper in one of the script's heredocs,
# whose second field is the line that call prints failing, rendered by pycalls below.
sites() {
  pycalls floor "$1" "$2"
  python3 - "$1" "$2" <<'PY'
import re, sys
path, frag = sys.argv[1], re.compile(sys.argv[2])
forms = [("check", re.compile(r'(?:^|[\s;&|{(])check\s+"([^"]*)"')),
         ("say", re.compile(r'(?:^|[\s;&|{(])say\s+FAIL\s+"([^"]*)"')),
         ("printf", re.compile(r"printf\s+'(FAIL[^']*)'\s+\"([^\"]*)\"")),
         ("echo", re.compile(r'echo\s+"FAIL\s+([^"]*)"'))]
seen = set()
for line in open(path, errors="replace"):
    if line.lstrip().startswith("#"):
        continue
    for form, p in forms:
        for m in p.finditer(line):
            fmt, lab = (m.group(1), m.group(2)) if form == "printf" else ("", m.group(1))
            if frag.search(lab) and (form, lab) not in seen:
                seen.add((form, lab))
                print(f"{form}\x1f{fmt}\x1f{lab}")
PY
}
# render <script> <form> <format> <label>: the line the guard prints when that check fails, through the
# guard's own helper or format. "a" against "b" fails both shapes of check() in the tree: `[ "$2" = "$3" ]`
# and the pre-evaluated `[ "$3" = "1" ]`. A printf format gets the label alone, so a one-%s format is not
# recycled into a second line. The format is the guard's own, read out of its source (hence SC2059).
# shellcheck disable=SC2059
render() {
  case "$2" in
    check) ( fail=0; eval "$(helper_def "$1" check)"; check "$4" "a" "b" ) 2>&1 ;;
    say)   ( eval "$(helper_def "$1" say)"; say FAIL "$4" "a" ) 2>&1 ;;
    printf) ( printf -- "$3" "$4" ) 2>&1 ;;
    echo)  printf 'FAIL  %s\n' "$4" ;;
    py)    printf '%s\n' "$3" ;;
  esac
}

# pycalls floor <file> <ERE> | pycalls scan <file>...: every call to a Python helper (a function that prints
# FAIL) whose label is a literal, in the body of every heredoc of a shell script and in a whole .py file, as
# <file:line><US><helper><US><premise word: 1 or 0><US><label as written><US><the line it prints failing>
# (scan mode), or, for the calls whose label matches <ERE>, as `py<US><the line it prints failing><US><the
# label>`, the shape sites() prints (floor mode). The failing line is the
# helper's OWN: its source is executed with the call's label (each {...} of an f-string read as T), every
# other argument False (a cond, an ok) or, when that prints no FAIL, a distinct string each (an actual
# against an expected), and any global it reads set to T (a run label). `UNPARSED<US><file:line>` marks a
# heredoc that reads as Python (a def or an import) but does not parse, so a scan cannot skip one silently.
pycalls() {
  python3 - "$@" <<'PY'
import ast, builtins, contextlib, io, re, sys, textwrap, warnings
warnings.simplefilter("ignore", SyntaxWarning)   # a shell heredoc's `\$` is not this scan's to judge
mode, args = sys.argv[1], sys.argv[2:]
frag = re.compile(args.pop()) if mode == "floor" else None
PREMISE = re.compile(r'\b(?:liveness(?:\s+witness(?:es)?)?|witness(?:es)?|precondition|setup|fixture|guard)'
                     r'\s*(?:\([^)]{1,4}\))?\s*:', re.I)
HEREDOC = re.compile(r'(?<!<)<<-?\s*([\'"]?)([A-Za-z_][A-Za-z0-9_]*)\1')
PYISH = re.compile(r'^\s*(?:def \w+\(|import \w|from [\w.]+ import )', re.M)
US = "\x1f"

def heredocs(text, base):
    lines = text.split("\n")
    i = 0
    while i < len(lines):
        m = HEREDOC.search(lines[i]) if not lines[i].lstrip().startswith("#") else None
        if not m:
            i += 1
            continue
        j = i + 1
        while j < len(lines) and lines[j].lstrip("\t").rstrip() != m.group(2):
            j += 1
        yield base + i + 1, "\n".join(lines[i + 1:j])
        i = j + 1

def bodies(path):
    # A body that does not parse is searched for heredocs of its own: lock_timeout_pairing_demo.sh feeds
    # its Python through a `$(python3 - <<'PY' ...)` inside a `<<EOF` heredoc.
    text = open(path, errors="replace").read()
    todo = [(0, text)] if path.endswith(".py") else list(heredocs(text, 0))
    while todo:
        off, src = todo.pop(0)
        try:
            yield off, src, ast.parse(src)
        except SyntaxError:
            inner = list(heredocs(src, off))
            if inner:
                todo[:0] = inner
            elif PYISH.search(src):
                yield off, src, None

def literal(node):
    if isinstance(node, ast.Constant) and isinstance(node.value, str):
        return node.value
    if isinstance(node, ast.JoinedStr):
        return "".join(v.value if isinstance(v, ast.Constant) else "T" for v in node.values)
    return None

def render(fn, src, label, at):
    code = textwrap.dedent(ast.get_source_segment(src, fn))
    params = [a.arg for a in fn.args.args]
    free = {n.id for n in ast.walk(fn) if isinstance(n, ast.Name)} - set(params) - set(dir(builtins))
    for attempt in ("false", "distinct"):
        ns = {n: (__import__(n) if n in ("sys", "os", "re", "json") else "T") for n in free}
        try:
            exec(code, ns)
        except Exception:
            return ""
        call = [label if k == at else (False if attempt == "false" else f"v{k}") for k in range(len(params))]
        buf = io.StringIO()
        try:
            with contextlib.redirect_stdout(buf):
                ns[fn.name](*call)
        except BaseException:
            pass
        fails = [line for line in buf.getvalue().split("\n") if line.startswith("FAIL")]
        if fails:
            return fails[0]
    return ""

for path in args:
    for off, src, tree in bodies(path):
        if tree is None:
            print(f"UNPARSED{US}{path}:{off}")
            continue
        helpers = {}
        for fn in ast.walk(tree):
            if isinstance(fn, ast.FunctionDef):
                seg = ast.get_source_segment(src, fn) or ""
                if "FAIL" in seg and "print(" in seg:
                    helpers[fn.name] = fn
        for call in ast.walk(tree):
            if not (isinstance(call, ast.Call) and isinstance(call.func, ast.Name) and call.func.id in helpers):
                continue
            fn = helpers[call.func.id]
            params = [a.arg for a in fn.args.args]
            at, label, written = None, None, None
            for k, a in enumerate(call.args):
                if literal(a) is not None:
                    at, label, written = k, literal(a), ast.get_source_segment(src, a)
                    break
            if at is None:
                for kw in call.keywords:
                    if kw.arg in params and literal(kw.value) is not None:
                        at, label, written = params.index(kw.arg), literal(kw.value), ast.get_source_segment(src, kw.value)
                        break
            if at is None or at >= len(params):
                continue
            written = " ".join(written.split())
            if frag is not None and not frag.search(label):
                continue
            line = render(fn, src, label, at).replace(US, " ")
            prem = 1 if PREMISE.search(label) else 0
            if frag is not None:
                print(f"py{US}{line}{US}{label}")
            else:
                print(f"{path}:{off + call.lineno}{US}{fn.name}{US}{prem}{US}{written}{US}{line}")
PY
}

judged=0; want=0; seen_w=" "; seen_d=" "; floor_guards=" "
while IFS='|' read -r g kind frag; do
  [ -z "$g" ] && continue
  want=$((want + 1))
  [[ "$floor_guards" == *" $g "* ]] || floor_guards+="$g "
  s=$(script_of "$g")
  if [ ! -f "$s" ]; then bad "LIVENESS: the floor guard $g exists" "$s"; continue; fi
  found=$(sites "$s" "$frag")
  if [ -z "$found" ]; then bad "LIVENESS: $g still prints a check matching /$frag/" "not found"; continue; fi
  while IFS=$'\x1f' read -r form fmt raw; do
    # A $variable in the label is the tag the guard fills in at run time; any value stands for it.
    lab=$(sed -E 's/\$\{[^}]*\}|\$[A-Za-z_][A-Za-z0-9_]*|\$[0-9]+/T/g' <<<"$raw")
    if [ "$form" = check ] && ! grep -q 'FAIL' <<<"$(helper_def "$s" check)"; then
      bad "LIVENESS: $g defines the check() it prints failures with" "none"; continue
    fi
    line=$(render "$s" "$form" "$fmt" "$lab")
    if [[ "$line" != FAIL* ]]; then bad "LIVENESS: $g prints a FAIL line for \"$raw\"" "${line:0:60}"; continue; fi
    printf '%s\n' "$line" > "$work/run.log"
    if [ "$kind" = W ]; then
      seen_w+="$g "
      if starved "$work/run.log"; then ok "$g: failing only its premise \"$raw\" is refused as starved" "starved"
      else bad "$g: failing only its premise \"$raw\" is refused as starved" "certified as a catch"; fi
    else
      seen_d+="$g "
      if ! starved "$work/run.log"; then ok "$g: failing its defect check \"$raw\" is certified" "a catch"
      else bad "$g: failing its defect check \"$raw\" is certified" "refused as starved"; fi
    fi
    judged=$((judged + 1))
  done <<<"$found"
done <<<"$FLOOR"
for g in $floor_guards; do
  if [[ "$seen_w" != *" $g "* || "$seen_d" != *" $g "* ]]; then
    bad "LIVENESS: $g had a premise and a defect check judged" "one kind missing"
  fi
done
if [ "$judged" -lt "$want" ]; then bad "LIVENESS: every floor entry was judged" "$judged of at least $want"
else ok "LIVENESS: every floor entry was judged" "$judged labels, $want entries"; fi

# ---- SPELLING: no premise word where starved() cannot read it, anywhere in bench/ ------------------------
# Prints `LABEL<TAB>file:line<TAB>label` for every label a FAIL-printing helper is called with, and
# `HIT<TAB>file:line<TAB>label` for each that carries a premise word and colon anywhere but at its head in
# one of the three spellings starved() reads.
scan() { # <file>...
  python3 - "$@" <<'PY'
import re, sys
DEF = re.compile(r'^\s*(?:function\s+([A-Za-z_]\w*)|([A-Za-z_]\w*)\s*\(\))\s*\{')
END = re.compile(r'(^|[;\s])\}\s*(#.*)?$')
PREMISE = re.compile(r'\b(?:liveness(?:\s+witness(?:es)?)?|witness(?:es)?|precondition|setup|fixture|guard)'
                     r'\s*(?:\([^)]{1,4}\))?\s*:', re.I)
GOOD = re.compile(r'(?:LIVENESS|GUARD|fixture):')
for path in sys.argv[1:]:
    lines = open(path, errors="replace").read().split("\n")
    helpers = set()
    for i, l in enumerate(lines):
        m = DEF.match(l)
        if not m:
            continue
        body, j = [l], i
        while not END.search(lines[j]) and j + 1 < len(lines):
            j += 1
            body.append(lines[j])
        text = "\n".join(body)
        if "FAIL" in text and "$1" in text:
            helpers.add(m.group(1) or m.group(2))
    # a bare printf, an echo, and any helper handed FAIL as its verdict (tests_fail_on_defect's `say FAIL`)
    pats = [re.compile(r"printf\s+'FAIL[^']*'\s+\"([^\"]*)\""),
            re.compile(r'echo\s+"FAIL\s+([^"]*)"'),
            re.compile(r'(?:^|[;&|{(]|\bthen|\belse|\bdo)\s*[A-Za-z_]\w*\s+FAIL\s+"([^"]*)"')]
    if helpers:
        names = "|".join(sorted(helpers))
        pats.append(re.compile(r'(?:^|[;&|{(]|\bthen|\belse|\bdo)\s*(?:' + names + r')\s+"([^"]*)"'))
    for n, l in enumerate(lines, 1):
        if l.lstrip().startswith("#"):
            continue
        for p in pats:
            for m in p.finditer(l):
                label = m.group(1)
                print(f"LABEL\t{path}:{n}\t{label}")
                if PREMISE.search(label) and not GOOD.match(label):
                    print(f"HIT\t{path}:{n}\t{label}")
PY
}

# The scan is held to spellings before it is trusted with the checkout: each planted file defines a
# FAIL-printing check(); the pos_ ones give it a label the rule must refuse, the neg_ ones one it must not.
mkdir -p "$work/scan"
helper='check() { if [ "$2" = "$3" ]; then printf '"'"'PASS  %s\n'"'"' "$1"; else printf '"'"'FAIL  %s\n'"'"' "$1"; fail=1; fi; }'
plant() { printf '%s\n%s\n' "$helper" "$2" > "$work/scan/$1.sh"; }
plant pos_behind_tag    'check "$2: LIVENESS: the race really happened" "$x" t'
plant pos_miscased      'check "Liveness: the race really happened" "$x" t'
plant pos_witness_word  'check "LIVENESS WITNESS: the race really happened" "$x" t'
plant pos_in_function   'raced() { check "$label: LIVENESS: the call was sampled" "$n" 1; }'
plant pos_bare_printf   'printf '"'"'FAIL  %-58s %s\n'"'"' "$t: LIVENESS: the fixture reached" no'
plant pos_witness_only  'check "WITNESS: no guard anywhere before the upgrade" "$x" t'
plant pos_precondition  'check "precondition: the origin has no child_oid" "$x" t'
plant pos_setup_tagged  'check "setup (A): the table exists" "$x" t'
plant neg_at_head       'check "LIVENESS: $2: the race really happened" "$x" t'
plant neg_fixture_head  'check "fixture: the race table was built" "$x" t'
plant neg_guard_head    'check "GUARD: the file to probe exists" "$x" t'
plant neg_prose         'check "every LIVENESS witness held" "$x" t'
plant neg_comment       '# check "$2: LIVENESS: the race really happened" "$x" t'
plant neg_not_a_helper  'echo "$2: LIVENESS: printed by echo, not a FAIL helper"'
scan_ok=1
for f in "$work"/scan/*.sh; do
  n=$(basename "$f" .sh)
  if scan "$f" | grep -q '^HIT'; then got=pos; else got=neg; fi
  if [ "$got" != "${n%%_*}" ]; then scan_ok=0; bad "LIVENESS: the spelling scan reads the planted $n right" "read as $got"; fi
done
[ "$scan_ok" = 1 ] && ok "LIVENESS: the spelling scan reads every planted spelling right" "8 refused, 6 passed"

files=()
for f in "$ROOT"/bench/*.sh; do
  n=$(basename "$f" .sh)
  [ "$n" = liveness_witness_labels ] && continue   # its own planted spellings are quoted, not printed
  files+=("$(script_of "$n")")
done
scan "${files[@]}" > "$work/scan.out"
# Its witness: the whole directory's calls (1622 at #1095), among them a top-level call in maintain_lock.sh and
# one inside obtain_backoff_headroom.sh's raced_tick(), whatever prefix either carries.
nlabels=$(grep -c '^LABEL' "$work/scan.out")
if [ "$nlabels" -ge 1000 ] \
   && grep -qE '^LABEL.*a concurrent reader is never locked out \(ml\)$' "$work/scan.out" \
   && grep -qE '^LABEL.*the lock race really happened: skip_obtain with a lock timeout$' "$work/scan.out"; then
  ok "LIVENESS: the scan read the directory's helper calls, the floor's among them" "$nlabels labels in ${#files[@]} files"
else
  bad "LIVENESS: the scan read the directory's helper calls, the floor's among them" "$nlabels labels in ${#files[@]} files"
fi
hits=$(grep -c '^HIT' "$work/scan.out")
if [ "$hits" = 0 ]; then ok "no guard prints a premise word anywhere but at a label's head" "0 found"
else
  bad "no guard prints a premise word anywhere but at a label's head" "$hits found"
  grep '^HIT' "$work/scan.out" | cut -f2- | sed "s|$ROOT/||; s/^/      /"
fi

# ---- SPELLING: what the Python helpers print, rendered, reads as a premise where it carries one ---------
# Held to planted helpers first, the way the shell scan is: the pos_ ones print a premise-worded label where
# starved() cannot read it, the neg_ ones where it can (or carry no premise at all).
mkdir -p "$work/py"
# Two helpers of the archive decoders' shape (the run label ahead of the name, and the #1380 one that hoists
# the prefix), each in a shell heredoc, and one head-first say() of the doc guards' shape in .py files.
cat > "$work/py/pos_run_label_first.sh" <<'EOF'
python3 - "$hex" "$label" <<'PYEOF'
def check(name, detail, cond):
    print(("PASS  " if cond else "FAIL  ") + f"{label + ': ' + name:<58} {detail}")
check("LIVENESS: rows were read at all", "0 rows", True)
PYEOF
EOF
cat > "$work/py/neg_hoisted.sh" <<'EOF'
python3 - "$hex" "$label" <<'PYEOF'
def check(name, detail, cond):
    head = "LIVENESS: " if name.startswith("LIVENESS: ") else ""
    print(("PASS  " if cond else "FAIL  ") + f"{head + label + ': ' + name[len(head):]:<58} {detail}")
check("LIVENESS: rows were read at all", "0 rows", True)
PYEOF
EOF
cat > "$work/py/say.py" <<'EOF'
def say(ok, what, detail=""):
    global fail
    print(f"{'PASS' if ok else 'FAIL'}  {what:<62} {detail}")
    fail = fail or not ok
EOF
pyplant() { { cat "$work/py/say.py"; printf '%s\n' "$2"; } > "$work/py/$1"; }
pyplant pos_fstring_tag.py     'say(True, f"{r}: LIVENESS: the doc was read", "1")'
pyplant pos_miscased.py        'say(True, "Liveness: the doc was read", "1")'
pyplant neg_head.py            'say(True, "LIVENESS: the doc was read", "1")'
pyplant neg_fixture_head.py    'say(True, f"fixture: {r} was built")'
pyplant neg_prose.py           'say(True, "every LIVENESS witness held", "1")'
pyplant neg_not_a_helper.py    'print(f"{r}: LIVENESS: printed by print, not a FAIL helper")'
{ echo 'python3 - <<PY'; cat "$work/py/say.py"; echo 'say(True, "WITNESS: the doc was read")'; echo 'PY'; } \
  > "$work/py/pos_witness_word.sh"
rm "$work/py/say.py"
# pyjudge <pycalls output>: a HIT line for every premise-worded call whose rendered line starved() does not
# read as starved (or that rendered no FAIL line at all), and the UNPARSED marks as they are.
pyjudge() {
  local where helper prem written line
  while IFS=$'\x1f' read -r where helper prem written line; do
    if [ "$where" = UNPARSED ]; then printf 'UNPARSED\t%s\n' "$helper"; continue; fi
    # a file judged in place of a guard is named as that guard
    if [ -n "$ONLY_NAME" ]; then where="${where/#"$ONLY"/$ROOT/bench/$ONLY_NAME.sh}"; fi
    printf 'CALL\t%s\t%s\n' "$where" "$written"
    [ "$prem" = 1 ] || continue
    printf 'JUDGED\t%s\t%s\n' "$where" "$written"
    printf '%s\n' "$line" > "$work/pyrun.log"
    if [[ "$line" != FAIL* ]] || ! starved "$work/pyrun.log"; then
      printf 'HIT\t%s\t%s -> %s\n' "$where" "$written" "${line:-no FAIL line}"
    fi
  done
}
py_ok=1
for f in "$work"/py/*; do
  n=$(basename "$f"); n="${n%.*}"
  if pycalls scan "$f" | pyjudge | grep -q '^HIT'; then got=pos; else got=neg; fi
  if [ "$got" != "${n%%_*}" ]; then py_ok=0; bad "LIVENESS: the Python scan reads the planted $n right" "read as $got"; fi
done
[ "$py_ok" = 1 ] && ok "LIVENESS: the Python scan reads every planted helper right" "4 refused, 5 passed"

pyfiles=("${files[@]}")
for f in "$ROOT"/bench/*.py; do pyfiles+=("$f"); done
pycalls scan "${pyfiles[@]}" | pyjudge > "$work/py.out"
# Its witness: the helper calls of the heredocs and the .py files (323 at #1380, 100 of them premise-worded),
# among them a defect check and the witness of the decoder half #1380 is about, and a bench/*.py file's.
ncalls=$(grep -c '^CALL' "$work/py.out")
njudged=$(grep -c '^JUDGED' "$work/py.out")
if [ "$ncalls" -ge 250 ] && [ "$njudged" -ge 50 ] \
   && grep -qE '^CALL	[^	]*archive_to_s3_compress[^	]*	"the ids are the partition.s, each once' "$work/py.out" \
   && grep -qE '^JUDGED	[^	]*archive_to_s3_compress[^	]*	"LIVENESS: rows were read at all"' "$work/py.out" \
   && grep -qE '^CALL	[^	]*lock_view_selftest\.py:' "$work/py.out"; then
  ok "LIVENESS: the Python scan read the helper calls of the heredocs and .py files" "$ncalls calls, $njudged premises"
else
  bad "LIVENESS: the Python scan read the helper calls of the heredocs and .py files" "$ncalls calls, $njudged premises"
fi
if grep -q '^UNPARSED' "$work/py.out"; then
  bad "GUARD: every heredoc that reads as Python parses" "$(grep -c '^UNPARSED' "$work/py.out") do not"
  grep '^UNPARSED' "$work/py.out" | cut -f2 | sed "s|$ROOT/||; s/^/      /"
fi
pyhits=$(grep -c '^HIT' "$work/py.out")
if [ "$pyhits" = 0 ]; then ok "no Python helper prints a premise where starved() cannot read it" "0 found"
else
  bad "no Python helper prints a premise where starved() cannot read it" "$pyhits found"
  grep '^HIT' "$work/py.out" | cut -f2- | sed "s|$ROOT/||; s/^/      /"
fi

# ---- SPELLING: the pgTAP files the wrappers run label their premises at the head -------------------------
# sqlscan <file>...: `LIT<TAB>file<TAB>literal` for every literal that begins with a head-form premise
# (`LIVENESS:`, `GUARD:`, `fixture:`), and `HIT<TAB>file<TAB>literal` for every one that begins, after a tag
# of up to three characters, with a premise word and a colon in any other spelling. Literals are read the
# way SQL reads them: '' is a quote, E'' honours backslashes, -- and /* */ are comments, and a dollar quote
# is transparent so a plpgsql body's own literals are read.
sqlscan() {
  python3 - "$@" <<'PY'
import re, sys
PREMISE = re.compile(
    r"^(?:[A-Z][A-Za-z0-9-]{0,5}\s+)?(?i:liveness(?:\s+witness(?:es)?)?|witness(?:es)?|setup|fixture|precondition)"
    r"(?:\s*\([A-Za-z0-9]{1,3}\)|\s+[A-Z][0-9]?)?\s*:")
GOOD = re.compile(r"^(?:LIVENESS|GUARD|fixture):")
def literals(src):
    i, n = 0, len(src)
    while i < n:
        if src.startswith("--", i):
            j = src.find("\n", i); i = n if j < 0 else j
        elif src.startswith("/*", i):
            j = src.find("*/", i + 2); i = n if j < 0 else j + 2
        elif src[i] == "'":
            esc = i > 0 and src[i - 1] in "eE" and (i < 2 or not (src[i - 2].isalnum() or src[i - 2] == "_"))
            j = i + 1
            while j < n:
                if esc and src[j] == "\\":
                    j += 2; continue
                if src[j] == "'":
                    if j + 1 < n and src[j + 1] == "'":
                        j += 2; continue
                    break
                j += 1
            yield src[i + 1:j]
            i = j + 1
        else:
            i += 1
for path, shown in zip(sys.argv[1::2], sys.argv[2::2]):
    for lit in literals(open(path, errors="replace").read()):
        one = " ".join(lit.split())[:120]
        if GOOD.match(lit):
            print(f"LIT\t{shown}\t{one}")
        elif PREMISE.match(lit):
            print(f"HIT\t{shown}\t{one}")
PY
}
mkdir -p "$work/sql"
splant() { printf '%s\n' "$2" > "$work/sql/$1.sql"; }
splant pos_tag_before      "select ok(true, 'A LIVENESS: the parent holds ids 1..150');"
splant pos_tag_after       "select ok(true, 'LIVENESS (A): archiving was deferred exactly once');"
splant pos_tag_bare        "select ok(true, 'LIVENESS A: the monolith is covered');"
splant pos_witness_word    "select is(1, 1, 'WITNESS: the writer recorded one observation');"
splant pos_witness_tagged  "select is(1, 1, 'B witness: the hole is real');"
splant pos_setup_word      "select ok(true, 'setup: sub-range [0, 100) is copied');"
splant pos_fixture_tagged  "select ok(true, 'fixture (A): the monolith is frozen');"
splant pos_precondition    "select ok(true, 'precondition: the FK is suspended');"
splant pos_miscased        "select ok(true, 'Liveness: the tick ran');"
splant pos_in_plpgsql      "do \$\$ begin perform ok(true, 'C LIVENESS: inside a body'); end \$\$;"
splant pos_range_tag       "select ok(true, 'C6-C8 LIVENESS: read whole, the maximum is future-dated');"
splant pos_word_then_tag   "select ok(true, 'WITNESS F1: the owner''s largest id is 20');"
splant neg_head            "select ok(true, 'LIVENESS: (A) the parent holds ids 1..150');"
splant neg_fixture_head    "select ok(true, 'fixture: (C) a row past the monolith');"
splant neg_prose           "select ok(true, 'every LIVENESS witness held');"
splant neg_comment         "-- 'A LIVENESS: only a comment'
select ok(true, 'a contract check');"
splant neg_escaped         "select ok(true, 'the owner''s A LIVENESS: is mid-literal');"
sql_ok=1
for f in "$work"/sql/*.sql; do
  n=$(basename "$f" .sql)
  if sqlscan "$f" "$n" | grep -q '^HIT'; then got=pos; else got=neg; fi
  if [ "$got" != "${n%%_*}" ]; then sql_ok=0; bad "LIVENESS: the SQL spelling scan reads the planted $n right" "read as $got"; fi
done
[ "$sql_ok" = 1 ] && ok "LIVENESS: the SQL spelling scan reads every planted spelling right" "12 refused, 5 passed"

# The files: every tests/ file a bench/*.sh names, by path (`tests/297_..._test.sql`) or by stem
# (bench/reads_under_caller_rls.sh's `241_reads_under_caller_rls_conformance_test`), the one a mutant stands for
# replaced by it. This guard's own text names files only as examples, so it is not read.
wrapper_tests() {
  python3 - "$ROOT" <<'PY'
import glob, os, re, sys
root = sys.argv[1]
stems = {}
for f in glob.glob(os.path.join(root, "tests", "**", "*.sql"), recursive=True):
    stems.setdefault(os.path.basename(f)[:-4], []).append(os.path.relpath(f, root))
found = set()
for b in glob.glob(os.path.join(root, "bench", "*.sh")):
    if b.endswith("/liveness_witness_labels.sh"):
        continue
    text = open(b, errors="replace").read()
    found.update(m.group(0) for m in re.finditer(r"tests/[A-Za-z0-9_/]+\.sql", text)
                 if os.path.isfile(os.path.join(root, m.group(0))))
    for m in re.finditer(r"\b\d+_[A-Za-z0-9_]+_test\b", text):
        found.update(stems.get(m.group(0), []))
print("\n".join(sorted(found)))
PY
}
targs=(); ntests=0
while IFS= read -r t; do
  [ -z "$t" ] && continue
  if [ "$t" = "$ONLY_TEST" ]; then targs+=("$ONLY" "$t"); else targs+=("$ROOT/$t" "$t"); fi
  ntests=$((ntests + 1))
done < <(wrapper_tests)
if [ -n "$ONLY_TEST" ] && [[ " ${targs[*]} " != *" $ONLY "* ]]; then
  bad "GUARD: the test file to judge is one a bench wrapper runs" "$ONLY_TEST"; exit 1
fi
sqlscan "${targs[@]}" > "$work/sql.out"
# Its witness: the wrapper-run files were read (285 at #1175), the two this fix re-spelled among them, with
# the head-form premises they carry.
nlit=$(grep -c '^LIT' "$work/sql.out")
if [ "$ntests" -ge 200 ] && [ "$nlit" -ge 1000 ] \
   && grep -qE '^LIT	tests/296_regrain_children_tablespace_test\.sql	LIVENESS: \(A\) ' "$work/sql.out" \
   && grep -qE '^LIT	tests/297_identity_sequence_grants_test\.sql	LIVENESS: ' "$work/sql.out"; then
  ok "LIVENESS: the SQL scan read the wrapper-run files and their premises" "$nlit premises in $ntests files"
else
  bad "LIVENESS: the SQL scan read the wrapper-run files and their premises" "$nlit premises in $ntests files"
fi
shits=$(grep -c '^HIT' "$work/sql.out")
if [ "$shits" = 0 ]; then ok "no wrapper-run test file spells a premise any way but at its head" "0 found"
else
  bad "no wrapper-run test file spells a premise any way but at its head" "$shits found"
  grep '^HIT' "$work/sql.out" | cut -f2- | head -20 | sed 's/^/      /'
fi
exit "$fail"
