#!/usr/bin/env bash
# Guard the LIVING documentation against the ways it rots. Run by CI (the `Living docs` lint job).
#
# WHY THIS EXISTS. The repo carries two kinds of markdown and used to mark neither: documents that must be
# TRUE against the code, and point-in-time artifacts kept for history. With no boundary between them, a
# frozen design note read as authoritative, and a deletion in install.sql left four documents describing
# machinery that no longer existed. That went unnoticed through an entire docs sweep, and the sweep after it
# found the same rot in three more files. Two greps would have caught both rounds.
#
# CHECK 1: no living document may name an identifier that install.sql no longer defines. A reader copying a
# call out of the reference should not get "function does not exist".
#
# CHECK 2: no living document may link to a frozen artifact. A link from a living doc is precisely what
# makes a frozen one look current -- which is how a superseded design note became "the operating model" in
# three separate documents. Frozen -> living links are fine and encouraged; only this direction is barred.
#
# CHECK 4: no OPERATOR document may cite an issue number. An issue number is provenance for a maintainer; to
# an operator it is a dead end that implies they must read a GitHub thread to understand their own database.
# Provenance belongs in CHANGELOG.md, commit messages and code comments, none of which this checks.
#
# CHECK 5: every version literal a living document tells the operator to type must be the version this tree
# installs. docs/guide.md's database.dev snippet pins `version 'X.Y.Z'` by hand (dbdev recommends pinning),
# and RELEASING.md's list of files to bump at release time did not include it, so the pin sat at 0.4.0
# through two releases and an operator following the guide installed a release the CHANGELOG lists fixes
# for. pgpm_core/extension.control's default_version is the value test.sh and the workflows already build
# from, so every literal is held to that one.
#
# CHECK 6: every `pgpm.log.action` value the operator docs name must be written by some install.sql.
# RELEASING.md makes the action vocabulary part of the version contract because operators build alerts on
# the exact strings, so a documented action nothing writes is an alert that can never fire (the reference
# went on promising `from_hypertable_adopt_fk` after its only writer was deleted). The reference's
# `pgpm.log` vocabulary table, every "logged `x`" sentence in the operator docs, AND every single-quoted
# literal the operator docs compare `action` with in SQL (`action = 'x'`, `action in ('x', 'y')`, a list
# that may span lines) are held to the actions the three install.sql files WRITE: the literal in the
# `action` position of each `insert into pgpm.log (...) values (...)` or `... select ...`, read through a
# tokenizer that knows comments and string literals, so the column list, a multi-row VALUES and a CASE
# (its THEN and ELSE literals) are all read where they are, on one line or many. The SQL is where an alert
# is actually written: the runbook's queries are what an operator copies into one, and before they were
# read a phantom action in them passed this check. The action position, not the line (issue #848): a
# literal pgpm writes only as a `method` ('copy_swap_drop', the method of action 'regrain') is on a
# non-comment install line too, and an alert on it as an action can never fire. Actions are always written
# as literals in install.sql (nothing composes one from a prefix); a write whose action is not one (a
# variable, or a pgpm.log write inside dynamic SQL) FAILS this check, naming the site, rather than being
# read as writing nothing.
#
# `--selftest` re-breaks a scratch copy of the docs and install files eight ways (the stale pin; the
# phantom action in prose, as a table row, in a runbook `action in (...)` list and in a runbook
# `action = '...'` comparison; a method value named as an action in a runbook query; a write whose action
# is a variable; and the vocabulary heading moved so the extractor sees nothing) and requires checks 5 and
# 6 to FAIL against each, after first passing against the unbroken copy. A check that stays green on its
# own re-break guards nothing. CI runs the self-test before the check, as it does for
# check_quoted_splices.py.
#
# CHANGELOG.md is excluded from ALL of these: its entries are historical by design and must keep naming the
# machinery, versions and actions they removed.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
fail=0

LIVING=(README.md ONBOARDING.md docs/guide.md docs/reference.md docs/runbook.md
        pgpm_archive/README.md bench/README.md bench/SIZE_LADDER.md
        index.html install.html)   # the explainer is user-facing documentation too, and rotted the same way

# The three documents an operator reads to run pgpm. Check 4 scopes to these on purpose (README.md is the
# front door and CHANGELOG.md is where provenance belongs), and check 6 reads its "logged `x`" sentences
# from them, because these are the documents that describe what pgpm.log records.
OPERATOR=(docs/guide.md docs/reference.md docs/runbook.md)

# The files whose single-quoted literals are the actions pgpm can write. All three, because the reference
# documents the hypertable and archive modules' actions beside the core's.
INSTALLS=(pgpm_core/install.sql pgpm_hypertable/install.sql pgpm_archive/install.sql)

FROZEN=(frozen/REDESIGN.md frozen/NIGHT-LOG.md frozen/from_hypertable_design.md
        frozen/from_hypertable_test_plan.md frozen/postgresql_online_partition_migration_summary.md
        frozen/blog-partition-a-live-table.md frozen/STORAGE-IO-ON-GREEN.md
        frozen/2026-09-16-lock-sequence-renderer-design.md frozen/2026-09-16-lock-sequence-renderer.md)

# Identifiers that install.sql once defined and no longer does. Deliberately a literal list rather than a
# derived one: deriving "every pgpm identifier" from SQL text produces false positives on prose, and a
# missed entry here costs nothing, while a false positive would block unrelated work. Add to it whenever
# something public is removed -- that is the moment the docs need sweeping anyway.
GONE=(drain_all drain_step 'snapshot()' check_default pgpm.hook drain_budget drain_move
      _ambient_lock_waiters _ambient_congested _aimd_next _feather_congested retain_reclaim
      obtain_reap default_dirty
      feathering_validation adaptive_ticks wal_backoffs lock_backoffs io_backoffs
      _wal_sustainable_bps _ambient_io_latency _ambient_io_surge _ambient_surge
      _forced_checkpoints rows_moved)

# The version this tree installs, read the way test.sh and .github/workflows/test.yml read it. Empty when
# the control file or its line has moved, which check 5 treats as a failure rather than a pass with nothing
# to compare against.
control_version() {  # <root>
  awk -F"'" '/^default_version/ {print $2}' "$1/pgpm_core/extension.control" 2>/dev/null
}

# CHECK 5. Takes the tree root so --selftest can point it at a re-broken copy.
check_version_pins() {  # <root>
  local root="$1" ver f hit n=0 bad=0
  echo "== check 5: version literals in living docs must be the version this tree installs =="
  ver=$(control_version "$root")
  if ! [[ "$ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    printf "FAIL  could not read a semver default_version from pgpm_core/extension.control (got '%s'); there is nothing to hold the docs to\n" "$ver"
    return 1
  fi
  for f in "${LIVING[@]}"; do
    [ -f "$root/$f" ] || continue
    # One `line:version 'X.Y.Z'` per literal. install.html's `version 'DBDEV_VERSION'` is a placeholder
    # the pages workflow fills from the tag, so it is not a semver triple and is rightly not matched.
    while IFS= read -r hit; do
      [ -n "$hit" ] || continue
      n=$((n + 1))
      if [ "${hit#*:}" != "version '$ver'" ]; then
        printf "FAIL  %s:%s tells the operator to type %s, but this tree installs %s (pgpm_core/extension.control); bump it with the release\n" \
          "$f" "${hit%%:*}" "${hit#*:}" "$ver"
        bad=1
      fi
    done < <(grep -noE "version '[0-9]+\.[0-9]+\.[0-9]+'" "$root/$f")
  done
  [ "$bad" = 0 ] || return 1
  if [ "$n" = 0 ]; then
    echo "PASS  no living document pins a version literal (nothing to hold to $ver)"
  else
    echo "PASS  $n version literal(s) in living docs all name $ver, the version this tree installs"
  fi
}

# CHECK 6. Takes the tree root so --selftest can point it at a re-broken copy.
check_log_actions() {  # <root>
  local root="$1" f a n=0 n_table n_sql n_sites bad=0 named stripped sqlnamed written sitesf ref
  ref="$root/docs/reference.md"
  echo "== check 6: every log action the operator docs name must be written by an install.sql =="
  for f in "${INSTALLS[@]}"; do
    if [ ! -f "$root/$f" ]; then
      printf 'FAIL  %s is missing, so this check cannot tell which actions pgpm writes\n' "$f"
      return 1
    fi
  done
  named=$(mktemp); stripped=$(mktemp); sqlnamed=$(mktemp); written=$(mktemp); sitesf=$(mktemp)
  # The actions pgpm writes: the literal in the action position of every pgpm.log INSERT in the three
  # install files, gathered once to a file (one per line) rather than piped per action, because `grep -q`
  # closing a pipe early reads as a failure under pipefail, which would make a written action look
  # unwritten. Its stdout is the count of write sites read, the witness that it read any at all.
  if ! python3 - "$root" "$written" "${INSTALLS[@]}" > "$sitesf" <<'PY'
import os, re, sys
root, out, files = sys.argv[1], sys.argv[2], sys.argv[3:]
TOK = re.compile(r"""
   (?P<ws>\s+)
  |(?P<com>--[^\n]*|/\*.*?\*/)
  |(?P<str>[Ee]'(?:[^'\\]|\\.|'')*'|'(?:[^']|'')*')
  |(?P<dol>\$[A-Za-z_]*\$)
  |(?P<ident>"(?:[^"]|"")*"|[A-Za-z_][A-Za-z0-9_$]*)
  |(?P<other>::|:=|<>|!=|<=|>=|\|\||.)
""", re.S | re.X)
LOG = re.compile(r"\binsert\s+into\s+pgpm\.log\b", re.I)
written, bad, sites = set(), [], 0

def lit(tok):  # the value of a string token
    if tok[0] in "Ee":
        return re.sub(r"\\(.)", r"\1", tok[2:-1]).replace("''", "'")
    return tok[1:-1].replace("''", "'")

def items(toks, i, stop):  # top-level comma-separated items from toks[i], until a ')' at depth 0 or a stop word
    out, cur, depth = [], [], 0
    while i < len(toks):
        kind, v, _ = toks[i]
        lv = v.lower()
        if depth == 0 and (v == ")" or v == ";" or (kind == "ident" and lv in stop)):
            break
        if v == "(":
            depth += 1
        elif v == ")":
            depth -= 1
        if depth == 0 and v == ",":
            out.append(cur); cur = []
        else:
            cur.append(toks[i])
        i += 1
    out.append(cur)
    return out, i

def actions(expr):  # the literals an action expression can evaluate to, or None when it is not literal
    if len(expr) == 1 and expr[0][0] == "str":
        return [lit(expr[0][1])]
    if expr and expr[0][1].lower() == "case":  # CASE ... THEN 'a' ... ELSE 'b' END: its results
        res = [(k, v) for j, (k, v, _) in enumerate(expr) if j and expr[j - 1][1].lower() in ("then", "else")]
        if res and all(k == "str" for k, _ in res):
            return [lit(v) for _, v in res]
    return None

for rel in files:
    text = open(os.path.join(root, rel)).read()
    toks, line, last = [], 1, 0
    for m in TOK.finditer(text):
        k = m.lastgroup
        if k in ("ws", "com", "dol"):
            continue
        line, last = line + text.count("\n", last, m.start()), m.start()
        toks.append((k, m.group(), line))
        if k == "str" and LOG.search(m.group()):  # a write this check cannot read: dynamic SQL
            bad.append(f"{rel}:{toks[-1][2]}: a pgpm.log INSERT inside a string literal (dynamic SQL)")
    for i in range(len(toks) - 5):
        w = [v.lower() for _, v, _ in toks[i:i + 5]]
        if w != ["insert", "into", "pgpm", ".", "log"]:
            continue
        sites += 1
        line, j = toks[i][2], i + 5
        if j >= len(toks) or toks[j][1] != "(":
            bad.append(f"{rel}:{line}: a pgpm.log INSERT with no column list"); continue
        cols, j = items(toks, j + 1, ())
        cols = [c[0][1].lower() if len(c) == 1 else None for c in cols]
        if "action" not in cols:
            bad.append(f"{rel}:{line}: a pgpm.log INSERT whose column list names no action"); continue
        at, j = cols.index("action"), j + 1
        rows = []
        if j < len(toks) and toks[j][1].lower() == "values":
            j += 1
            while j < len(toks) and toks[j][1] == "(":
                row, j = items(toks, j + 1, ())
                rows.append(row); j += 1
                if j < len(toks) and toks[j][1] == "," and j + 1 < len(toks) and toks[j + 1][1] == "(":
                    j += 1
                else:
                    break
        elif j < len(toks) and toks[j][1].lower() == "select":
            row, j = items(toks, j + 1, ("from", "where", "union", "returning", "on", "limit", "order", "group"))
            rows.append(row)
        if not rows:
            bad.append(f"{rel}:{line}: a pgpm.log INSERT that is neither VALUES nor SELECT"); continue
        for row in rows:
            got = actions(row[at]) if at < len(row) else None
            if got is None:
                shown = " ".join(v for _, v, _ in row[at])[:60] if at < len(row) else "(nothing)"
                bad.append(f"{rel}:{line}: a pgpm.log INSERT whose action is not a literal: {shown}")
            else:
                written.update(got)
with open(out, "w") as fh:
    fh.write("".join(a + "\n" for a in sorted(written)))
for b in bad:
    print(f"FAIL  {b}; this check reads the action a write names and cannot tell what this one writes",
          file=sys.stderr)
print(sites)
sys.exit(1 if bad or not sites else 0)
PY
  then
    [ "$(cat "$sitesf")" = 0 ] && printf 'FAIL  read no pgpm.log write in the install files; the writer shape moved and this check is looking at nothing\n'
    rm -f "$named" "$stripped" "$sqlnamed" "$written" "$sitesf"; return 1
  fi
  n_sites=$(cat "$sitesf"); rm -f "$sitesf"
  # Every non-comment install line, to say WHY a named literal is not written when it appears as something
  # else (a method, usually).
  grep -hv '^[[:space:]]*--' "$root/pgpm_core/install.sql" "$root/pgpm_hypertable/install.sql" \
       "$root/pgpm_archive/install.sql" > "$stripped"
  # (a) The vocabulary table under "### `pgpm.log`": every backticked name in its first column. The
  # second column is prose and names functions and `method` values, so it is deliberately not read.
  sed -n '/^### `pgpm\.log`$/,/^### /p' "$ref" | grep -E '^\| `' | awk -F'|' '{print $2}' \
    | grep -oE '`[a-z][a-z0-9_]*`' | tr -d '`' > "$named"
  n_table=$(wc -l < "$named" | tr -d ' ')
  if [ "$n_table" = 0 ]; then
    # The liveness witness: with the heading moved this check would otherwise compare nothing and pass.
    printf 'FAIL  found no action vocabulary table under "### `pgpm.log`" in docs/reference.md; the heading moved and this check is looking at nothing\n'
    rm -f "$named" "$stripped" "$sqlnamed" "$written"; return 1
  fi
  # (b) Prose in the operator docs: "Logged `x` and `y`", "logged `x`", "logs `x` / `y` / `z`". Only the
  # backticked names in that chain, so a trailing "`method`" or a `skip_<mechanism>` placeholder is not read.
  for f in "${OPERATOR[@]}"; do
    [ -f "$root/$f" ] || continue
    grep -oE '[Ll]og(ged|s) `[a-z][a-z0-9_]*`(( and | / |, | or )`[a-z][a-z0-9_]*`)*' "$root/$f" \
      | grep -oE '`[a-z][a-z0-9_]*`' | tr -d '`' >> "$named"
  done
  # (c) The SQL the operator docs tell an operator to type: every single-quoted literal compared with
  # `action` by =, <> or !=, or listed in an `action in (...)` or `action not in (...)` that may span
  # lines, in a fenced block or in inline code alike. These are the strings an alert is built on, so they
  # are held to the same standard as the table and the prose. `action like 'skip_%'` is a pattern, not a
  # name, and is deliberately not read.
  if ! python3 - "$root" "${OPERATOR[@]}" > "$sqlnamed" <<'PY'
import os, re, sys
root, docs = sys.argv[1], sys.argv[2:]
CMP = re.compile(r"\baction\s*(?:(?:=|<>|!=)\s*'([^']*)'|(?:not\s+)?in\s*\(([^)]*)\))", re.I)
for rel in docs:
    path = os.path.join(root, rel)
    if not os.path.isfile(path):
        continue
    for m in CMP.finditer(open(path).read()):
        for lit in ([m.group(1)] if m.group(1) is not None else re.findall(r"'([^']*)'", m.group(2))):
            print(lit)
PY
  then
    printf 'FAIL  could not read the action literals in the operator docs SQL (python3 failed)\n'
    rm -f "$named" "$stripped" "$sqlnamed" "$written"; return 1
  fi
  n_sql=$(grep -c . "$sqlnamed")
  if [ "$n_sql" = 0 ]; then
    # The same witness as the table's: the runbook's alert queries compare `action` with literals, so
    # reading none means the extractor stopped matching them, not that the docs are clean.
    printf 'FAIL  found no action literal (action = ..., action in (...)) in the operator docs SQL; the extractor is looking at nothing\n'
    rm -f "$named" "$stripped" "$sqlnamed" "$written"; return 1
  fi
  cat "$sqlnamed" >> "$named"
  while IFS= read -r a; do
    [ -n "$a" ] || continue
    n=$((n + 1))
    if ! grep -qxF -- "$a" "$written"; then
      if grep -qF -- "'$a'" "$stripped"; then
        printf "FAIL  the operator docs name pgpm.log.action '%s', but no install.sql writes it as an action (the literal is there, in another position: a method, say), so an alert on it can never fire\n" "$a"
      else
        printf "FAIL  the operator docs name pgpm.log.action '%s', but no install.sql writes it, so an alert on it can never fire\n" "$a"
      fi
      for f in "${OPERATOR[@]}"; do
        [ -f "$root/$f" ] && grep -nF -e "\`$a\`" -e "'$a'" -- "$root/$f" | sed "s|^|        $f:|"
      done
      bad=1
    fi
  done < <(sort -u "$named")
  rm -f "$named" "$stripped" "$sqlnamed" "$written"
  [ "$bad" = 0 ] || return 1
  echo "PASS  all $n log actions the operator docs name ($n_table in the vocabulary table, $n_sql literal(s) in their SQL) are written by an install.sql, as the action of one of its $n_sites pgpm.log writes"
}

# --selftest helpers. A re-break is applied to a scratch copy, never to the tree, and refuses to apply when
# its pattern no longer matches exactly the expected number of lines: a drifted pattern would otherwise
# yield an unbroken copy, the check would pass against it, and this would report a check that "does not
# discriminate" for one that is fine. Same discipline as bench/mutations/mutate.py.
rebreak() {  # <file> <find> <replace> <expected line count>
  local file="$1" find="$2" repl="$3" want="$4" got
  got=$(grep -cF -- "$find" "$file" || true)
  if [ "$got" != "$want" ]; then
    printf 'selftest: FAIL  re-break pattern matched %s line(s) in %s, expected %s: the docs moved and this re-break is stale. Fix the pattern; do not let it produce an unbroken copy.\n' \
      "$got" "$file" "$want"
    printf '        pattern: %s\n' "$find"
    return 1
  fi
  FIND="$find" REPL="$repl" python3 - "$file" <<'PY'
import os, sys
path = sys.argv[1]
with open(path) as fh:
    text = fh.read()
with open(path, "w") as fh:
    fh.write(text.replace(os.environ["FIND"], os.environ["REPL"]))
PY
}

expect_pass() {  # <label> <check fn> <root>
  local label="$1" fn="$2" root="$3" out
  if out=$("$fn" "$root" 2>&1); then
    printf 'selftest: ok    %s passes\n' "$label"
  else
    printf 'selftest: FAIL  %s should pass and did not:\n' "$label"
    printf '%s\n' "$out" | sed 's/^/        /'
    return 1
  fi
}

expect_fail() {  # <label> <needle the failure must name> <check fn> <root>
  local label="$1" needle="$2" fn="$3" root="$4" out
  if out=$("$fn" "$root" 2>&1); then
    printf 'selftest: FAIL  %s PASSED against its own re-break: it does not discriminate\n' "$label"
    printf '%s\n' "$out" | sed 's/^/        /'
    return 1
  fi
  if ! printf '%s\n' "$out" | grep -qF -- "$needle"; then
    printf 'selftest: FAIL  %s failed, but not for the re-broken site (expected the output to name %s):\n' "$label" "$needle"
    printf '%s\n' "$out" | sed 's/^/        /'
    return 1
  fi
  printf 'selftest: ok    %s fails, naming %s\n' "$label" "$needle"
}

selftest() {
  local tmp ver stale rc=0
  tmp=$(mktemp -d)
  mkdir -p "$tmp/docs" "$tmp/pgpm_core" "$tmp/pgpm_hypertable" "$tmp/pgpm_archive"
  cp docs/guide.md docs/reference.md docs/runbook.md "$tmp/docs/"
  cp pgpm_core/extension.control pgpm_core/install.sql "$tmp/pgpm_core/"
  cp pgpm_hypertable/install.sql "$tmp/pgpm_hypertable/"
  cp pgpm_archive/install.sql "$tmp/pgpm_archive/"
  ver=$(control_version .)

  # Positive control first: a re-break only means something if the unbroken copy passes.
  expect_pass "check 5 on the unbroken tree" check_version_pins "$tmp" || rc=1
  expect_pass "check 6 on the unbroken tree" check_log_actions "$tmp" || rc=1

  # Re-break 1, the defect as shipped: the guide's database.dev pin two releases stale.
  stale="0.4.0"; [ "$stale" = "$ver" ] && stale="0.3.0"
  if rebreak "$tmp/docs/guide.md" "version '$ver'" "version '$stale'" 1; then
    expect_fail "check 5 against the stale pin" "$stale" check_version_pins "$tmp" || rc=1
  else rc=1; fi
  cp docs/guide.md "$tmp/docs/guide.md"

  # Re-break 2, the defect as shipped: the phantom action back in the reference's prose.
  if rebreak "$tmp/docs/reference.md" 'Logged `from_hypertable_carry_fk`' \
             'Logged `from_hypertable_carry_fk` and `from_hypertable_adopt_fk`' 1; then
    expect_fail "check 6 against the phantom action in prose" "from_hypertable_adopt_fk" check_log_actions "$tmp" || rc=1
  else rc=1; fi
  cp docs/reference.md "$tmp/docs/reference.md"

  # Re-break 3: the phantom action as a vocabulary-table row, so the table path is proven separately.
  if rebreak "$tmp/docs/reference.md" '| `from_hypertable_carry_fk` |' \
             '| `from_hypertable_adopt_fk` | a phantom action for the self-test |'$'\n''| `from_hypertable_carry_fk` |' 1; then
    expect_fail "check 6 against the phantom action as a table row" "from_hypertable_adopt_fk" check_log_actions "$tmp" || rc=1
  else rc=1; fi
  cp docs/reference.md "$tmp/docs/reference.md"

  # Re-break 5, the defect as shipped: a phantom action in the runbook's step-2 alert query, on the
  # continuation line of a multi-line `action in (...)` list, the SQL an operator copies into an alert.
  if rebreak "$tmp/docs/runbook.md" "'retain_detach', 'retain_crossing')" \
             "'retain_detach', 'retain_crossing', 'fail_retain_phantom')" 1; then
    expect_fail "check 6 against the phantom action in an action in (...) query" "fail_retain_phantom" check_log_actions "$tmp" || rc=1
  else rc=1; fi
  cp docs/runbook.md "$tmp/docs/runbook.md"

  # Re-break 6: the same in the other SQL form, an `action = '...'` comparison.
  if rebreak "$tmp/docs/runbook.md" "where action = 'skip_obtain'" "where action = 'skip_obtain_phantom'" 1; then
    expect_fail "check 6 against the phantom action in an action = '...' query" "skip_obtain_phantom" check_log_actions "$tmp" || rc=1
  else rc=1; fi
  cp docs/runbook.md "$tmp/docs/runbook.md"

  # Re-break 7 (#848): a method value named as an action. 'copy_swap_drop' is on a non-comment install line,
  # as the METHOD of an action 'regrain' row, so a line grep counted it written; the alert never fires.
  if rebreak "$tmp/docs/runbook.md" "and action in ('skip_regrain', 'regrain')" \
             "and action in ('skip_regrain', 'copy_swap_drop')" 1; then
    expect_fail "check 6 against a method value named as an action" "copy_swap_drop" check_log_actions "$tmp" || rc=1
  else rc=1; fi
  cp docs/runbook.md "$tmp/docs/runbook.md"

  # Re-break 8: a write whose action is not a literal must fail, naming the site, not read as writing nothing.
  if rebreak "$tmp/pgpm_hypertable/install.sql" "values (p_hypertable, 'from_hypertable_carry_fk', r.conname)" \
             "values (p_hypertable, v_action, r.conname)" 1; then
    expect_fail "check 6 against a write whose action is a variable" "pgpm_hypertable/install.sql:" check_log_actions "$tmp" || rc=1
  else rc=1; fi
  cp pgpm_hypertable/install.sql "$tmp/pgpm_hypertable/install.sql"

  # Re-break 4: the vocabulary heading moved. The extractor then finds nothing, and "nothing is missing"
  # must read as a failure of the check, not a pass of the docs.
  if rebreak "$tmp/docs/reference.md" '### `pgpm.log`' '### `pgpm.logs`' 1; then
    expect_fail "check 6 with the vocabulary heading moved" "looking at nothing" check_log_actions "$tmp" || rc=1
  else rc=1; fi

  rm -rf "$tmp"
  if [ "$rc" = 0 ]; then echo "selftest: PASS (checks 5 and 6 fail against each of their eight re-breaks)"
  else echo "selftest: FAIL"; fi
  return "$rc"
}

if [ "${1:-}" = "--selftest" ]; then
  selftest; exit $?
fi

echo "== check 1: living docs must not name removed identifiers =="
# The list is CURATED, not derived from install.sql, and an earlier version of this script shows why. It
# tried to auto-skip any identifier install.sql still mentioned, so the list could never go stale -- but
# `drain_all` appears there in `drop function if exists pgpm.drain_all(...)`, a line that exists precisely
# BECAUSE the function was removed. The guard read its own gravestone as proof of life and passed against
# the defect. Dead identifiers also legitimately survive in comments and in dead code, so "mentioned in
# install.sql" can never mean "still callable". Curate the list instead: it is one line per removal, added
# at the moment the docs need sweeping anyway.
for ident in "${GONE[@]}"; do
  for f in "${LIVING[@]}"; do
    [ -f "$f" ] || continue
    if grep -nF -- "$ident" "$f" >/dev/null 2>&1; then
      printf 'FAIL  %s names %s, which pgpm_core/install.sql no longer defines\n' "$f" "$ident"
      grep -nF -- "$ident" "$f" | sed 's/^/        /'
      fail=1
    fi
  done
done
[ "$fail" = 0 ] && echo "PASS  no living document names a removed identifier"

echo
echo "== check 2: living docs must not link to frozen artifacts =="
found=0
for f in "${LIVING[@]}"; do
  [ -f "$f" ] || continue
  for t in "${FROZEN[@]}"; do
    base="$(basename "$t")"
    if grep -nF -- "$base" "$f" >/dev/null 2>&1; then
      printf 'FAIL  %s references the frozen artifact %s\n' "$f" "$base"
      grep -nF -- "$base" "$f" | sed 's/^/        /'
      fail=1; found=1
    fi
  done
done
[ "$found" = 0 ] && echo "PASS  no living document references a frozen artifact"

echo
echo "== check 3: every frozen artifact says so =="
for t in "${FROZEN[@]}"; do
  [ -f "$t" ] || continue
  if ! grep -q "Frozen artifact" "$t"; then
    printf 'FAIL  %s carries no frozen-artifact banner, so it reads as current documentation\n' "$t"
    fail=1
  fi
done
[ "$fail" = 0 ] && echo "PASS  every frozen artifact is labelled"

echo
echo "== check 4: operator docs must not cite issue numbers =="
# `#` immediately followed by digits. A markdown anchor is `](#name)` and no heading id here starts with a
# digit, so `(#325)`, `issue #347`, `pre-#429` and `post-#94` all trip it and `[link](#set_obtain)` does
# not. Scoped to the three operator documents on purpose: README.md is the front door and CHANGELOG.md is
# where provenance belongs. Verified to FAIL against the docs as they stood before issue #434 (13 hits).
found=0
for f in "${OPERATOR[@]}"; do
  [ -f "$f" ] || continue
  if grep -nE '#[0-9]+' "$f" >/dev/null 2>&1; then
    printf 'FAIL  %s cites an issue number; state the behaviour and leave the provenance to CHANGELOG.md\n' "$f"
    grep -nE '#[0-9]+' "$f" | sed 's/^/        /'
    fail=1; found=1
  fi
done
[ "$found" = 0 ] && echo "PASS  no operator document cites an issue number"

echo
check_version_pins . || fail=1

echo
check_log_actions . || fail=1

exit "$fail"
