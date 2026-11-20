#!/usr/bin/env python3
"""Propose, and later check, where the custody test files call the invariant oracle's row ledger.

Phase 3 W3 (docs/formal/phase3-design.md, "Row ledger (opt-in)"). A custody file opts in with
pgpm_formal.baseline(<parent>) after its fixture's rows are written and before the first pgpm call that can move
or drop them. This script is the PROPOSAL for that placement, read file by file by hand before any line lands, and
then the standing CHECK that the placements and the runners stay consistent.

  migrate_baseline.py propose [file ...]   per file: the parents it hands pgpm, where each one's rows are last
                                           written before pgpm first acts on it, and later writes and deletes
                                           (default: every file in tests/formal/custody_files.txt)
  migrate_baseline.py check                the standing checks below; exit 1 on any finding
  migrate_baseline.py --selftest           the checks against small planted cases

The checks (W6 re-runs them):
  1. every path tests/formal/custody_files.txt lists exists, and is either baselined (it calls
     pgpm_formal.baseline) or carries `# not baselined: <reason>`, never both;
  2. no test file outside the list calls pgpm_formal (a baseline nobody listed is a file W6 would not look for);
  3. in a baselined file, each baseline(<literal parent>) comes before the first pgpm call that names that parent
     and can move or drop its rows (transmute excepted when the fixture helper itself transmutes: mk_archive_table);
  4. every runner that executes a baselining file installs tests/formal/oracle.sql: test.sh (each track's template
     or per-file database), and each bench/ script and scripts/review/ tool that names the file;
  5. every pgpm_formal.expect(...) names a literal invariant and a non-empty reason.
"""
import os
import re
import sys

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
LIST = os.path.join(ROOT, "tests", "formal", "custody_files.txt")

# A pgpm call that can move or drop a parent's rows: the conversion, every maintenance path, retention, retirement,
# regrain, adoption, the archive steps, and the archive fixture helper that transmutes inside itself.
MOVING = re.compile(
    r"\b(?:pgpm\.(?:transmute|maintain|maintain_all|retain|retire|regrain|regrain_step|regrain_history|untransmute"
    r"|forget_missing|adopt_partition|_archive_step|archive_to_s3)|archive\.to_s3|mk_archive_table)\s*\(",
    re.I)
PARENT_ARG = re.compile(
    r"\b(?:pgpm\.(?:transmute|maintain|retain|retire|regrain|regrain_step|regrain_history|untransmute|forget_missing"
    r"|adopt_partition|set_retain|set_archive_fn|obtain))\s*\(\s*'([^']+)'", re.I)
FIXTURE = re.compile(r"\bmk_archive_table\s*\(\s*'([^']+)'", re.I)
CREATE = re.compile(r"^\s*create\s+(?:unlogged\s+)?table\s+(?:if\s+not\s+exists\s+)?([\w.\"]+)", re.I)
INSERT = re.compile(r"^\s*insert\s+into\s+([\w.\"]+)", re.I)
DELETE = re.compile(r"^\s*delete\s+from\s+(?:only\s+)?([\w.\"]+)", re.I)
BASELINE = re.compile(r"pgpm_formal\.baseline\s*\(\s*'([^']+)'", re.I)
EXPECT = re.compile(r"pgpm_formal\.expect\s*\(\s*'([^']*)'\s*,\s*'((?:[^']|'')*)'\s*,\s*'((?:[^']|'')*)'", re.I | re.S)
INVARIANTS = {"NoLostRow", "NoDuplicateRow", "DropOnlyCovered", "ArchiveNoClobber", "ResolveByRecord", "NoWedge"}


def norm(name):
    """A table name as the file spells it, schema-qualified (public by default), unquoted, lower case."""
    n = name.replace('"', "").lower()
    return n if "." in n else "public." + n


def read_list(path=LIST):
    """custody_files.txt: {path: reason or None}; a `# not baselined: <reason>` comment on the path's line."""
    out = {}
    with open(path) as fh:
        for line in fh:
            body, _, comment = line.partition("#")
            body = body.strip()
            if not body:
                continue
            m = re.match(r"\s*not baselined:\s*(.+)", comment)
            out[body] = m.group(1).strip() if m else None
    return out


def statement_end(lines, i):
    """The index of the line that ends the statement starting at line i (the first line ending in `;`)."""
    for j in range(i, len(lines)):
        if lines[j].split("--")[0].rstrip().endswith(";"):
            return j
    return i


def propose(path):
    lines = open(path).read().split("\n")
    parents = []  # in order of first appearance as a pgpm argument
    for ln in lines:
        for m in list(PARENT_ARG.finditer(ln)) + list(FIXTURE.finditer(ln)):
            p = norm(m.group(1))
            if p not in parents:
                parents.append(p)
    out = []
    for p in parents:
        first_move = next((i for i, ln in enumerate(lines) if MOVING.search(ln) and p.split(".")[1] in ln.lower()), None)
        created = next((i for i, ln in enumerate(lines) if (m := CREATE.match(ln)) and norm(m.group(1)) == p), None)
        fixture = next((i for i, ln in enumerate(lines) if (m := FIXTURE.search(ln)) and norm(m.group(1)) == p), None)
        last_ins = None
        for i, ln in enumerate(lines[: first_move if first_move is not None else len(lines)]):
            m = INSERT.match(ln)
            if m and norm(m.group(1)) == p:
                last_ins = statement_end(lines, i)
        if fixture is not None:
            at, why = statement_end(lines, fixture), "after mk_archive_table (it creates, fills and transmutes)"
        elif last_ins is not None:
            at, why = last_ins, "after the last insert before pgpm first acts on it"
        elif created is not None:
            at, why = statement_end(lines, created), "after its create (no insert found before pgpm acts: read the file)"
        else:
            out.append(f"  {p}: no create, insert or fixture found in the file (built by a helper or dynamically: read it)")
            continue
        later = []
        for i, ln in enumerate(lines):
            if i <= at:
                continue
            for rx, what in ((INSERT, "wrote"), (DELETE, "deleted")):
                m = rx.match(ln)
                if m and norm(m.group(1)) == p:
                    later.append(f"{what}? line {i + 1}")
        out.append(f"  {p}: baseline after line {at + 1} ({why}); first moving call line "
                   f"{first_move + 1 if first_move is not None else '-'}" + (f"; later: {', '.join(later)}" if later else ""))
    return out


def installs_oracle(path, seen=None):
    """Does a runner install the oracle: name tests/formal/oracle.sql itself, or exec a bench script that does (the
    grid_timezone.sh wrappers hand their test file to it)."""
    seen = set() if seen is None else seen
    if path in seen or not os.path.exists(path):
        return False
    seen.add(path)
    text = open(path).read()
    if "tests/formal/oracle.sql" in text:
        return True
    for m in re.finditer(r'exec bash "\$\(dirname "\$0"\)/([\w.]+\.sh)"', text):
        if installs_oracle(os.path.join(os.path.dirname(path), m.group(1)), seen):
            return True
    return False


def runners_of(rel, root=ROOT):
    """The files outside tests/ that name a test file: test.sh's tracks run them by glob, so they are added apart."""
    found = []
    for d in ("bench", os.path.join("scripts", "review")):
        for dirpath, _, names in os.walk(os.path.join(root, d)):
            if "mutations" in dirpath:
                continue
            for n in names:
                if n.endswith((".sh", ".py")):
                    fp = os.path.join(dirpath, n)
                    try:
                        # by basename: a multi-file wrapper names its files without the directory
                        if os.path.basename(rel) in open(fp).read():
                            found.append(os.path.relpath(fp, root))
                    except UnicodeDecodeError:
                        pass
    return found


def check(listing=None, root=ROOT):
    problems = []
    listing = read_list() if listing is None else listing
    for rel, reason in sorted(listing.items()):
        fp = os.path.join(root, rel)
        if not os.path.exists(fp):
            problems.append(f"{rel}: listed in custody_files.txt and missing")
            continue
        text = open(fp).read()
        bl = BASELINE.findall(text)
        if reason is not None and bl:
            problems.append(f"{rel}: marked `not baselined` and calls pgpm_formal.baseline")
        if reason is None and not bl:
            problems.append(f"{rel}: a custody file that never calls pgpm_formal.baseline and gives no `not baselined` reason")
        lines = text.split("\n")
        for p in set(norm(x) for x in bl):
            at = next(i for i, ln in enumerate(lines) if (m := BASELINE.search(ln)) and norm(m.group(1)) == p)
            short = p.split(".")[1]
            # a baseline placed after pgpm first acts says why, with `not before`, on its line or in the comment
            # block right above it or a run of baselines it heads (a table transmuted empty, a fixture built inside a retry loop or another role)
            j = at
            while j > 0 and (lines[j - 1].lstrip().startswith("--") or BASELINE.search(lines[j - 1])):
                j -= 1
            if re.search(r"not before", "\n".join(lines[j:at + 1]), re.I):
                continue
            # from the table's last creation before the baseline: a namesake made earlier is another table
            start = max([i for i, ln in enumerate(lines[:at])
                         if re.search(r"create\s+table\s+(?:if\s+not\s+exists\s+)?(?:[\w\"]+\.)?\"?" + re.escape(short)
                                      + r"\"?\s*\(", ln.split("--")[0], re.I)] or [0])
            for i, ln in enumerate(lines[start:at], start):
                code = ln.split("--")[0]
                if MOVING.search(code) and re.search(r"'(?:[\w\"]+\.)?" + re.escape(short) + r"'", code, re.I) \
                   and not FIXTURE.search(code):
                    problems.append(f"{rel}:{i + 1}: pgpm acts on {p} before its baseline at line {at + 1}")
                    break
        for inv, ident, why in EXPECT.findall(text):
            if inv not in INVARIANTS:
                problems.append(f"{rel}: expect() names {inv!r}, not an invariant")
            if not why.strip():
                problems.append(f"{rel}: expect({inv}, {ident}) gives no reason")
        if bl:
            for r in runners_of(rel, root):
                if not installs_oracle(os.path.join(root, r)):
                    problems.append(f"{r}: runs {rel}, which calls pgpm_formal.baseline, and never installs tests/formal/oracle.sql")
    # 2: no unlisted file uses the oracle
    for d in ("tests", os.path.join("tests", "archive", "db"), os.path.join("tests", "timescale", "db")):
        for n in sorted(os.listdir(os.path.join(root, d))):
            rel = os.path.join(d, n)
            if n.endswith(".sql") and rel not in listing and "pgpm_formal." in open(os.path.join(root, rel)).read():
                problems.append(f"{rel}: calls pgpm_formal and is not in custody_files.txt")
    # 4, test.sh: each track's template or per-file database installs the oracle
    ts = open(os.path.join(root, "test.sh")).read()
    helper = re.search(r"^install_oracle\(\) \{.*?^\}", ts, re.S | re.M)
    helper_ok = helper is not None and "tests/formal/oracle.sql" in helper.group(0)
    for fn in ("run_version", "run_archive", "run_timescale"):
        body = re.search(r"^" + fn + r"\(\) \{.*?^\}", ts, re.S | re.M)
        if body is None or not ("tests/formal/oracle.sql" in body.group(0)
                                or (helper_ok and re.search(r"^\s*install_oracle ", body.group(0), re.M))):
            problems.append(f"test.sh: {fn} does not install tests/formal/oracle.sql")
    return problems


def selftest():
    import tempfile
    ok = True
    with tempfile.TemporaryDirectory() as d:
        for sub in ("tests", "tests/archive/db", "tests/timescale/db", "tests/formal", "bench"):
            os.makedirs(os.path.join(d, sub))
        cases = {
            "tests/1_good_test.sql": "create table public.a (id int);\ninsert into public.a values (1);\n"
                                     "select pgpm_formal.baseline('public.a');\ncall pgpm.transmute('public.a', 'id', 10);\n",
            "tests/2_late_test.sql": "create table public.b (id int);\ncall pgpm.transmute('public.b', 'id', 10);\n"
                                     "select pgpm_formal.baseline('public.b');\n",
            "tests/3_none_test.sql": "select 1;\n",
            "tests/4_stray_test.sql": "select pgpm_formal.baseline('public.z');\n",
            "tests/5_expect_test.sql": "select pgpm_formal.baseline('public.e');\n"
                                       "select pgpm_formal.expect('NoLost', 'x', 'why');\n",
            # schema-qualified outside public: still caught
            "tests/6_schema_test.sql": "create table s6.c (id int);\ncall pgpm.transmute('s6.c', 'id', 10);\n"
                                       "select pgpm_formal.baseline('s6.c');\n",
            # a late baseline that says why, heading a run of baselines: accepted
            "tests/7_said_test.sql": "create table public.d (id int);\ncreate table public.f (id int);\n"
                                     "call pgpm.transmute('public.d', 'id', 10);\ncall pgpm.transmute('public.f', 'id', 10);\n"
                                     "-- here, not before transmute: it converts the tables empty\n"
                                     "select pgpm_formal.baseline('public.d');\nselect pgpm_formal.baseline('public.f');\n",
            # a namesake made again before its baseline: the earlier table's transmute is another table's
            "tests/8_again_test.sql": "create table public.g (id int);\ncall pgpm.transmute('public.g', 'id', 10);\n"
                                      "drop table public.g;\ncreate table public.g (id int);\n"
                                      "select pgpm_formal.baseline('public.g');\ncall pgpm.transmute('public.g', 'id', 10);\n",
        }
        cases["bench/wrap.sh"] = 'T=/repo/tests/1_good_test.sql\nexec bash "$(dirname "$0")/shared.sh" "$@"\n'
        cases["bench/shared.sh"] = "q -f /repo/tests/formal/oracle.sql\n"
        cases["bench/bare.sh"] = "pg_prove /repo/tests/1_good_test.sql\n"
        cases["bench/byname.sh"] = 'FILES="1_good_test.sql"\nfor f in $FILES; do pg_prove "$DIR/$f"; done\n'
        for rel, body in cases.items():
            open(os.path.join(d, rel), "w").write(body)
        open(os.path.join(d, "test.sh"), "w").write(
            "run_version() {\n  tests/formal/oracle.sql\n}\nrun_archive() {\n  tests/formal/oracle.sql\n}\n"
            "run_timescale() {\n  nothing\n}\n")
        listing = {"tests/1_good_test.sql": None, "tests/2_late_test.sql": None, "tests/3_none_test.sql": None,
                   "tests/5_expect_test.sql": None, "tests/9_missing_test.sql": None, "tests/6_schema_test.sql": None,
                   "tests/7_said_test.sql": None, "tests/8_again_test.sql": None}
        got = "\n".join(check(listing, d))
        for want in ("2_late_test.sql:2: pgpm acts on public.b before its baseline",
                     "3_none_test.sql: a custody file that never calls",
                     "4_stray_test.sql: calls pgpm_formal and is not in custody_files.txt",
                     "5_expect_test.sql: expect() names 'NoLost'",
                     "9_missing_test.sql: listed in custody_files.txt and missing",
                     "run_timescale does not install",
                     "bench/bare.sh: runs tests/1_good_test.sql",
                     "bench/byname.sh: runs tests/1_good_test.sql",
                     "6_schema_test.sql:2: pgpm acts on s6.c before its baseline"):
            if want not in got:
                print(f"selftest FAIL: no finding containing {want!r}\n{got}")
                ok = False
        if any(x in got for x in ("1_good_test.sql:", "bench/wrap.sh", "7_said_test.sql:", "8_again_test.sql:")):
            print(f"selftest FAIL: the good file was reported\n{got}")
            ok = False
    print("selftest:", "PASS" if ok else "FAIL")
    return 0 if ok else 1


def main(argv):
    if argv[1:2] == ["--selftest"]:
        return selftest()
    if argv[1:2] == ["check"]:
        problems = check()
        for p in problems:
            print(p)
        print(f"migrate_baseline.py check: {len(problems)} finding(s) over {len(read_list())} custody files")
        return 1 if problems else 0
    if argv[1:2] == ["propose"]:
        files = argv[2:] or sorted(read_list())
        for f in files:
            print(f)
            for line in propose(os.path.join(ROOT, f)):
                print(line)
        return 0
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
