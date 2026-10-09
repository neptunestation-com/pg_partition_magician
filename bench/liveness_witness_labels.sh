#!/usr/bin/env bash
# Prove that the checks a shell guard's header calls its liveness witnesses print as lines that
# bench/discriminate.sh reads as premises, so a mutant run that failed only them is refused as a starved
# fixture instead of being certified as a catch.
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
#
# WHAT IT ASSERTS.
#   FLOOR  Each witness the eight guards' headers name, read out of the guard's source as written, is printed
#          through the guard's OWN check() as a FAIL line, and discriminate.sh's OWN starved() (read out of
#          bench/discriminate.sh, not restated here) refuses a run that failed only that line. Judged by what
#          the rule reads, not by a spelling: a prefix behind the tag, or a miscased one, fails here exactly
#          as a missing one does. The list is the inventory of the known sites, the way
#          bench/wrapper_tap_verdicts.sh's WRAPPERS list is; which check is a premise is a judgment a header
#          makes in prose, so a new guard's witnesses are held here once they are listed, and by SPELLING
#          below until then.
#   FLOOR  Each guard's listed DEFECT checks are certified as a catch when they fail alone. This is the
#          instrument's liveness (a rendering that read everything as starved would pass the witnesses), and
#          it pins the asymmetry that matters in the archive guards: "returned a Parquet file", "raised no
#          ERROR" and the like look like witnesses, but they are the only checks the #912/#992 mutants
#          (archive_*_raises, archive_lz77_repeat_differs) fail, so a LIVENESS: prefix on them would make
#          discriminate.sh refuse those guards as starved.
#   SPELLING  Over every bench/*.sh: no label a FAIL-printing helper (or a bare `printf 'FAIL ...'`) is
#          given carries a LIVENESS prefix anywhere but at its head in exactly that spelling (`$2: LIVENESS:`,
#          `Liveness:`, `LIVENESS WITNESS:`), since starved() cannot see one there. The scan is held to
#          planted spellings, positive and negative, before it is trusted with the checkout.
#   LIVENESS  starved() was found and reads a planted witness-only run as starved and a planted defect run
#          as a catch; every floor guard's witnesses and defect checks were found and rendered as FAIL lines;
#          the scan read the helper calls of the directory, the floor's own labels among them.
#
# Not covered, deliberately: other premise vocabularies (`WITNESS:`, `precondition:`) that starved() does not
# read are #1033's bullet 3, and the SPELLING rule only concerns the LIVENESS spelling.
#
# The mutations it is required to fail against (bench/mutations/mutate.py):
#   witness_label_unprefixed        -- maintain_lock.sh's retain work witness printed without its prefix,
#                                      the pre-#1095 label
#   witness_label_prefix_behind_tag -- obtain_backoff_headroom.sh's lock-race witness with the prefix behind
#                                      its `$2: ` tag, where starved() cannot read it
#
# Usage: liveness_witness_labels.sh <container> <db> [guard script]
# With no third argument it judges this checkout. With one it judges THAT script in place of the guard it
# stands for, recognised by its file name or, for a mutant bench/discriminate.sh built (<mutation>.sql), by
# the mutation's MUTATION_SRC; a /repo/... path is mapped to this checkout. Needs bash and python3 on the
# host and nothing else; <container> and <db> are accepted so discriminate.sh can call it the way it calls
# every guard, and are not used.
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
if starved "$work/w.log" && ! starved "$work/d.log"; then
  ok "LIVENESS: starved() refuses a planted witness-only run, certifies a defect run" "both"
else
  bad "LIVENESS: starved() refuses a planted witness-only run, certifies a defect run" "it does not"; exit 1
fi

# ---- which script stands in for which guard -------------------------------------------------------------
ONLY_NAME=""
if [ -n "$ONLY" ]; then
  ONLY="${ONLY/#\/repo\//$ROOT/}"
  if [ ! -f "$ONLY" ]; then bad "the script to judge exists" "$ONLY"; exit 1; fi
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
  if [ -z "$ONLY_NAME" ]; then bad "the script to judge stands for a guard in bench/" "$ONLY -> '${src}'"; exit 1; fi
fi
script_of() { if [ "$1" = "$ONLY_NAME" ]; then echo "$ONLY"; else echo "$ROOT/bench/$1.sh"; fi; }

# ---- FLOOR: the witnesses the eight guards' headers name, and a defect check of each ----------------------
# <guard>|<W: a witness, must read as starved; D: a defect check, must read as a catch>|<ERE over the label>
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
'

# helper_def <file> <name>: the shell function <name>, from its definition line to its closing brace.
helper_def() {
  awk -v n="$2" '
    !f && $0 ~ "^[[:space:]]*" n "\\(\\)[[:space:]]*\\{" { f = 1 }
    f { print }
    f && /(^|[;[:space:]])\}[[:space:]]*(#.*)?$/ { exit }
  ' "$1"
}
# render <helper def> <label>: the line the guard prints when that check fails. "a" against "b" fails both
# shapes of check() in the tree: `[ "$2" = "$3" ]` and the pre-evaluated `[ "$3" = "1" ]`.
render() { ( fail=0; eval "$1"; check "$2" "a" "b" ) 2>&1; }

judged=0; want=0; seen_w=" "; seen_d=" "
while IFS='|' read -r g kind frag; do
  [ -z "$g" ] && continue
  want=$((want + 1))
  s=$(script_of "$g")
  if [ ! -f "$s" ]; then bad "LIVENESS: the floor guard $g exists" "$s"; continue; fi
  def=$(helper_def "$s" check)
  if ! grep -q 'FAIL' <<<"$def"; then bad "LIVENESS: $g defines the check() it prints failures with" "none"; continue; fi
  labels=$(grep -vE '^[[:space:]]*#' "$s" | grep -oE "check \"[^\"]*(${frag})[^\"]*\"" | sed -E 's/^check "//; s/"$//' | sort -u)
  if [ -z "$labels" ]; then bad "LIVENESS: $g still prints a check matching /$frag/" "not found"; continue; fi
  while IFS= read -r raw; do
    # A $variable in the label is the tag the guard fills in at run time; any value stands for it.
    lab=$(sed -E 's/\$\{[^}]*\}|\$[A-Za-z_][A-Za-z0-9_]*|\$[0-9]+/T/g' <<<"$raw")
    line=$(render "$def" "$lab")
    if [[ "$line" != FAIL* ]]; then bad "LIVENESS: $g's check() prints a FAIL line for \"$raw\"" "${line:0:60}"; continue; fi
    printf '%s\n' "$line" > "$work/run.log"
    if [ "$kind" = W ]; then
      seen_w+="$g "
      if starved "$work/run.log"; then ok "$g: failing only its witness \"$raw\" is refused as starved" "starved"
      else bad "$g: failing only its witness \"$raw\" is refused as starved" "certified as a catch"; fi
    else
      seen_d+="$g "
      if ! starved "$work/run.log"; then ok "$g: failing its defect check \"$raw\" is certified" "a catch"
      else bad "$g: failing its defect check \"$raw\" is certified" "refused as starved"; fi
    fi
    judged=$((judged + 1))
  done <<<"$labels"
done <<<"$FLOOR"
for g in maintain_lock obtain_backoff_headroom obtain_int_ceiling frontier_drought archive_lz77_memory \
         archive_deflate_memory archive_encode_memory dropped_fk_identity; do
  if [[ "$seen_w" != *" $g "* || "$seen_d" != *" $g "* ]]; then
    bad "LIVENESS: $g had a witness and a defect check judged" "one kind missing"
  fi
done
if [ "$judged" -lt "$want" ]; then bad "LIVENESS: every floor entry was judged" "$judged of at least $want"
else ok "LIVENESS: every floor entry was judged" "$judged labels, $want entries"; fi

# ---- SPELLING: no LIVENESS prefix where starved() cannot read it, anywhere in bench/ ---------------------
# Prints `LABEL<TAB>file:line<TAB>label` for every label a FAIL-printing helper is called with, and
# `HIT<TAB>file:line<TAB>label` for each that carries a LIVENESS prefix anywhere but at its head.
scan() { # <file>...
  python3 - "$@" <<'PY'
import re, sys
DEF = re.compile(r'^\s*(?:function\s+([A-Za-z_]\w*)|([A-Za-z_]\w*)\s*\(\))\s*\{')
END = re.compile(r'(^|[;\s])\}\s*(#.*)?$')
PREMISE = re.compile(r'liveness(?:\s+witness(?:es)?)?\s*:', re.I)
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
    pats = [re.compile(r"printf\s+'FAIL[^']*'\s+\"([^\"]*)\"")]
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
                if PREMISE.search(label) and not label.startswith("LIVENESS:"):
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
plant neg_at_head       'check "LIVENESS: $2: the race really happened" "$x" t'
plant neg_prose         'check "every LIVENESS witness held" "$x" t'
plant neg_comment       '# check "$2: LIVENESS: the race really happened" "$x" t'
plant neg_not_a_helper  'echo "$2: LIVENESS: printed by echo, not a FAIL helper"'
scan_ok=1
for f in "$work"/scan/*.sh; do
  n=$(basename "$f" .sh)
  if scan "$f" | grep -q '^HIT'; then got=pos; else got=neg; fi
  if [ "$got" != "${n%%_*}" ]; then scan_ok=0; bad "LIVENESS: the spelling scan reads the planted $n right" "read as $got"; fi
done
[ "$scan_ok" = 1 ] && ok "LIVENESS: the spelling scan reads every planted spelling right" "5 refused, 4 passed"

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
if [ "$hits" = 0 ]; then ok "no guard prints a LIVENESS prefix anywhere but at a label's head" "0 found"
else
  bad "no guard prints a LIVENESS prefix anywhere but at a label's head" "$hits found"
  grep '^HIT' "$work/scan.out" | cut -f2- | sed "s|$ROOT/||; s/^/      /"
fi
exit "$fail"
