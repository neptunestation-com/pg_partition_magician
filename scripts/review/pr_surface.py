#!/usr/bin/env python3
"""pr_surface.py --base <tree> --head <tree> --out <dir> [--finder P1]
   pr_surface.py --selftest

The SURFACE of a pull request, for per-PR adversarial verification (docs/adversarial-review.md, "Per-PR
verification"): the units its diff touches plus the units that call them, as the one slice the PR's finder
owns and `coverage.py` scores. Two trees are compared, not two commits, because the review trees a
verification works on are history-less exports (`build_review_tree.sh`), and the head tree may carry a
seed: the surface is computed over what the finder will actually be shown.

For every file that differs: its hunks as head-side line ranges. For an install.sql under pgpm_*/ the
hunks are mapped onto its units (a function or procedure runs from its `create` line to the line before
the next one's), and a hunk outside every unit (a table, a grant, an upgrade DO block) becomes a unit of
its own, labelled `<file>:<lo>-<hi>`, so the finder's ledger has to account for it too. Then the callers:
every other unit in the head tree's pgpm_*/ SQL files whose body names a touched unit (schema-qualified
or bare, word-bounded) joins the slice, one hop; a caller found through dynamic SQL built from fragments is
not found, which the brief says. Files under tests/, bench/, docs/ and scripts/ that mention a touched
unit are listed as "exercised by" for the finder's context and are not in the ledger, so the slice stays
the size of the change and not of the suite; a touched file of those kinds is in the ledger as a path.

Writes to <out>:
  surface.json   {"base", "head", "files": [{path, status, hunks}], "units": [{unit, file, lines, why}],
                  "exercised_by": {unit: [paths]}, "slice": <the slices.json entry>}
  slices.json    {"<finder>": {"files": [...], "units": [...], "kind": "mixed"}}   (coverage.py's input)
  units.txt      one unit per line, the ledger's names, for the finder's brief
  surface.md     the same, readable: files and hunks, touched units with their callers, exercised-by lists

Exit 0 when the trees differ, 3 when they are identical (nothing to verify).
"""
import argparse
import difflib
import glob
import json
import os
import re
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from coverage import SQL_FILE, UNIT_RE  # noqa: E402  (one definition of what a unit is)

SKIP_DIRS = {".git", "__pycache__", "node_modules", ".venv"}
PGPM_SQL = re.compile(r"^pgpm_[a-z]+/.*\.sql$")
CONTEXT_DIRS = ("tests", "bench", "docs", "scripts", "fixtures")


def walk(tree):
    out = {}
    for root, dirs, files in os.walk(tree):
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
        for f in files:
            p = os.path.join(root, f)
            out[os.path.relpath(p, tree)] = p
    return out


def read_lines(path):
    if path is None:
        return []
    with open(path, errors="replace") as fh:
        return fh.read().splitlines()


def hunks(base_lines, head_lines):
    """Head-side line ranges [lo, hi] (1-based, inclusive) that differ from base. A pure deletion has no
    head lines; it is recorded at the line where the deletion sits so a reader can find the seam."""
    sm = difflib.SequenceMatcher(None, base_lines, head_lines, autojunk=False)
    out = []
    for tag, _i1, _i2, j1, j2 in sm.get_opcodes():
        if tag == "equal":
            continue
        lo, hi = j1 + 1, max(j2, j1 + 1)
        if out and lo <= out[-1][1] + 1:
            out[-1][1] = max(out[-1][1], hi)
        else:
            out.append([lo, hi])
    return out


DOLLAR = re.compile(r"\$[A-Za-z_][A-Za-z0-9_]*\$|\$\$")


def unit_end(lines, start, limit):
    """The last line of the unit whose create line is `start` (1-based): the line that closes its
    dollar-quoted body and ends the statement with `;`. The body's own tag is matched (an inner `$q$`
    does not close a `$$` body). When no body or no closing is found before `limit` (the next unit's
    create line, or the end), the unit runs to `limit - 1`, as it did before this was measured."""
    text_pos = []
    pos = 0
    joined = []
    for n in range(start - 1, limit - 1):
        text_pos.append(pos)
        joined.append(lines[n])
        pos += len(lines[n]) + 1
    text = "\n".join(joined)
    m = DOLLAR.search(text)
    if not m:
        return limit - 1
    close = text.find(m.group(0), m.end())
    if close < 0:
        return limit - 1
    semi = text.find(";", close + len(m.group(0)))
    if semi < 0:
        return limit - 1
    line_index = max(i for i, p in enumerate(text_pos) if p <= semi)
    return start + line_index


def units_of(lines):
    """[(unit, start, end)] for an install.sql's functions and procedures, end being the line that closes
    the unit's statement (its dollar-quoted body and the `;` after it), so a grant or a table between two
    functions belongs to neither."""
    starts = []
    for n, line in enumerate(lines, 1):
        m = UNIT_RE.match(line)
        if m:
            starts.append((m.group(1).lower(), n))
    out = []
    for k, (name, start) in enumerate(starts):
        limit = starts[k + 1][1] if k + 1 < len(starts) else len(lines) + 1
        out.append((name, start, unit_end(lines, start, limit)))
    return out


def touched_units(rel, lines, ranges):
    """The units of one SQL file that a list of head-side hunks touches, plus a labelled unit per hunk
    that no function or procedure contains."""
    units = units_of(lines)
    out, seen = [], set()
    for lo, hi in ranges:
        inside = False
        for name, start, end in units:
            if start <= hi and lo <= end:
                inside = True
                if name not in seen:
                    seen.add(name)
                    out.append({"unit": name, "file": rel, "lines": [start, end], "why": f"touched at {lo}-{hi}"})
        if not inside:
            label = f"{rel}:{lo}-{hi}"
            if label not in seen:
                seen.add(label)
                out.append({"unit": label, "file": rel, "lines": [lo, hi], "why": "top-level hunk, outside every function"})
    return out


def name_patterns(unit):
    """Regexes that name a unit in SQL text: schema-qualified, and bare when the name is not a plain
    word another identifier is likely to share (an underscore-prefixed or long name)."""
    schema, _, name = unit.partition(".")
    pats = [re.compile(r"\b%s\.%s\s*\(" % (re.escape(schema), re.escape(name)), re.I)]
    if name.startswith("_") or len(name) >= 12:
        pats.append(re.compile(r"(?<![\w.])%s\s*\(" % re.escape(name), re.I))
    return pats


def callers(head, sql_files, touched):
    """Units in the head tree's pgpm_*/ SQL files whose body names a touched unit. One hop."""
    targets = [t for t in touched if "." in t["unit"] and ":" not in t["unit"]]
    if not targets:
        return []
    pats = {t["unit"]: name_patterns(t["unit"]) for t in targets}
    touched_names = {t["unit"] for t in touched}
    out, seen = [], set()
    for rel in sorted(sql_files):
        lines = read_lines(os.path.join(head, rel))
        for name, start, end in units_of(lines):
            if name in touched_names or name in seen:
                continue
            body = "\n".join(lines[start - 1:end])   # the whole unit, create line included (a one-line unit has no other)
            hit = [u for u, ps in pats.items() if u != name and any(p.search(body) for p in ps)]
            if hit:
                seen.add(name)
                out.append({"unit": name, "file": rel, "lines": [start, end], "why": "calls " + ", ".join(sorted(hit))})
    return out


def exercised_by(head, all_files, touched):
    """Non-SQL-module files that mention a touched unit's bare name, for the brief's context."""
    out = {}
    names = [(t["unit"], t["unit"].split(".", 1)[1]) for t in touched if "." in t["unit"] and ":" not in t["unit"]]
    if not names:
        return out
    for rel in sorted(all_files):
        if not rel.startswith(CONTEXT_DIRS):
            continue
        try:
            text = open(os.path.join(head, rel), errors="replace").read()
        except OSError:
            continue
        for unit, bare in names:
            if re.search(r"(?<!\w)%s\b" % re.escape(bare), text):   # qualified or bare
                out.setdefault(unit, []).append(rel)
    return out


def surface(base, head, finder="P1"):
    b, h = walk(base), walk(head)
    files = []
    for rel in sorted(set(b) | set(h)):
        bp, hp = b.get(rel), h.get(rel)
        if bp and hp and open(bp, "rb").read() == open(hp, "rb").read():
            continue
        status = "added" if bp is None else ("deleted" if hp is None else "modified")
        files.append({"path": rel, "status": status, "hunks": hunks(read_lines(bp), read_lines(hp)) if hp else []})
    if not files:
        return None
    touched = []
    for f in files:
        if PGPM_SQL.match(f["path"]) and f["status"] != "deleted":
            touched += touched_units(f["path"], read_lines(h[f["path"]]), f["hunks"])
    sql_files = [rel for rel in h if PGPM_SQL.match(rel)]
    called = callers(head, sql_files, touched)
    units = touched + called
    other_files = [f["path"] for f in files if not PGPM_SQL.match(f["path"]) and f["status"] != "deleted"]
    slice_spec = {"files": sorted({u["file"] for u in units} | set(other_files)),
                  "units": [u["unit"] for u in units], "kind": "mixed"}
    # the ledger's names, exactly as coverage.py will score them: the SQL units, then every touched
    # non-SQL file as a path (a PR that changes a script, a test and a guard has only those)
    ledger = [u["unit"] for u in units] + sorted(other_files)
    return {"base": os.path.abspath(base), "head": os.path.abspath(head), "files": files, "units": units,
            "exercised_by": exercised_by(head, h, touched), "finder": finder, "slice": slice_spec, "ledger": ledger}


def render(s):
    out = [f"# Surface of the change: {len(s['files'])} file(s), {len(s['ledger'])} unit(s) in the ledger", ""]
    out.append("## Files and hunks (head-side lines)")
    for f in s["files"]:
        hk = ", ".join(f"{lo}-{hi}" for lo, hi in f["hunks"]) or "(deleted)"
        out.append(f"- `{f['path']}` ({f['status']}): {hk}")
    out += ["", "## Units (read every one; the ledger names them exactly)"]
    for u in s["units"]:
        out.append(f"- `{u['unit']}` in `{u['file']}` lines {u['lines'][0]}-{u['lines'][1]}: {u['why']}")
    for path in s["ledger"][len(s["units"]):]:
        st = next((f["status"] for f in s["files"] if f["path"] == path), "")
        out.append(f"- `{path}` ({st} file, read it whole)")
    if s["exercised_by"]:
        out += ["", "## Exercised by (context, not in the ledger)"]
        for unit, paths in sorted(s["exercised_by"].items()):
            out.append(f"- `{unit}`: " + ", ".join(f"`{p}`" for p in paths[:12]) + (" ..." if len(paths) > 12 else ""))
    return "\n".join(out) + "\n"


def write(s, out):
    os.makedirs(out, exist_ok=True)
    json.dump(s, open(os.path.join(out, "surface.json"), "w"), indent=1)
    json.dump({s["finder"]: s["slice"]}, open(os.path.join(out, "slices.json"), "w"), indent=1)
    open(os.path.join(out, "units.txt"), "w").write("".join(u + "\n" for u in s["ledger"]))
    open(os.path.join(out, "surface.md"), "w").write(render(s))


def selftest():
    with tempfile.TemporaryDirectory() as d:
        base, head = os.path.join(d, "base"), os.path.join(d, "head")
        for t in (base, head):
            os.makedirs(os.path.join(t, "pgpm_core")); os.makedirs(os.path.join(t, "tests")); os.makedirs(os.path.join(t, "bench"))
            os.makedirs(os.path.join(t, ".git"))
            open(os.path.join(t, ".git", "HEAD"), "w").write("ref: nothing\n")
        core = ("create table pgpm.config (x int);\n"
                "create or replace function pgpm._resolve_child(p regclass) returns oid language sql as $$ select 1 $$;\n"
                "-- a comment\n"
                "create or replace function pgpm.to_s3(p regclass) returns void language plpgsql as $$\n"
                "begin\n"
                "  perform pgpm._resolve_child(p);\n"
                "end $$;\n"
                "create or replace function pgpm.unrelated() returns int language sql as $$ select 2 $$;\n"
                "create or replace procedure pgpm.retire(p regclass) language plpgsql as $$ begin perform _resolve_child(p); end $$;\n"
                "grant execute on function pgpm.unrelated() to public;\n")
        open(os.path.join(base, "pgpm_core", "install.sql"), "w").write(core)
        head_core = core.replace("returns oid language sql as $$ select 1 $$", "returns oid language sql as $$ select 2 $$") \
                        .replace("grant execute on function pgpm.unrelated() to public;\n",
                                 "grant execute on function pgpm.unrelated() to public;\ngrant select on pgpm.config to public;\n")
        open(os.path.join(head, "pgpm_core", "install.sql"), "w").write(head_core)
        open(os.path.join(base, "tests", "1_t.sql"), "w").write("select pgpm.to_s3('x');\n")
        open(os.path.join(head, "tests", "1_t.sql"), "w").write("select pgpm.to_s3('x');\n")   # unchanged: context only
        open(os.path.join(head, "tests", "2_t.sql"), "w").write("select pgpm._resolve_child('x');\n")   # added: in the ledger
        open(os.path.join(head, "bench", "g.sh"), "w").write("#!/bin/sh\n_resolve_child\n")           # added
        open(os.path.join(base, "bench", "old.sh"), "w").write("#!/bin/sh\n")                           # deleted
        ends = [(n, a, b) for n, a, b in units_of(head_core.splitlines())]
        assert ends == [("pgpm._resolve_child", 2, 2), ("pgpm.to_s3", 4, 7), ("pgpm.unrelated", 8, 8), ("pgpm.retire", 9, 9)], ends
        s = surface(base, head, "P1")
        paths = {f["path"]: f for f in s["files"]}
        assert set(paths) == {"pgpm_core/install.sql", "tests/2_t.sql", "bench/g.sh", "bench/old.sh"}, set(paths)
        assert paths["bench/old.sh"]["status"] == "deleted" and paths["tests/2_t.sql"]["status"] == "added"
        assert paths["pgpm_core/install.sql"]["hunks"] == [[2, 2], [11, 11]], paths["pgpm_core/install.sql"]["hunks"]
        names = [u["unit"] for u in s["units"]]
        # touched: the edited function and the top-level grant; callers: to_s3 (qualified) and retire (bare), not unrelated
        assert names == ["pgpm._resolve_child", "pgpm_core/install.sql:11-11", "pgpm.to_s3", "pgpm.retire"], names
        assert s["units"][2]["why"] == "calls pgpm._resolve_child" and s["units"][3]["why"] == "calls pgpm._resolve_child"
        assert s["exercised_by"] == {"pgpm._resolve_child": ["bench/g.sh", "tests/2_t.sql"]}, s["exercised_by"]
        assert s["slice"]["files"] == ["bench/g.sh", "pgpm_core/install.sql", "tests/2_t.sql"], s["slice"]
        assert s["slice"]["kind"] == "mixed"
        out = os.path.join(d, "out"); write(s, out)
        assert open(os.path.join(out, "units.txt")).read().splitlines() == names + ["bench/g.sh", "tests/2_t.sql"]
        sl = json.load(open(os.path.join(out, "slices.json")))
        assert sl["P1"]["units"] == names
        # coverage.py reads the slice: the two touched files plus the units, nothing expanded twice
        from coverage import slice_units
        kind, units = slice_units(head, sl["P1"])
        assert kind == "mixed" and units == names + ["bench/g.sh", "tests/2_t.sql"], (kind, units)
        md = render(s)
        assert "top-level hunk" in md and "Exercised by" in md
        # identical trees: nothing to verify
        assert surface(base, base) is None
        # a pure deletion inside a unit still touches it
        open(os.path.join(head, "pgpm_core", "install.sql"), "w").write(core.replace("  perform pgpm._resolve_child(p);\n", ""))
        s2 = surface(base, head)
        assert [u["unit"] for u in s2["units"]][0] == "pgpm.to_s3", s2["units"]
    print("pr_surface selftest: PASS (hunks, touched units, top-level hunks, qualified and bare callers, exercised-by, slice shape, identical trees)")


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--base"); ap.add_argument("--head"); ap.add_argument("--out"); ap.add_argument("--finder", default="P1")
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args(argv)
    if a.selftest:
        selftest(); return 0
    if not (a.base and a.head and a.out):
        ap.error("--base, --head and --out are required (or --selftest)")
    s = surface(a.base, a.head, a.finder)
    if s is None:
        print("pr_surface: the two trees are identical; nothing to verify", file=sys.stderr)
        return 3
    write(s, a.out)
    print(render(s))
    print(f"written: {a.out}/surface.json, slices.json, units.txt, surface.md")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
