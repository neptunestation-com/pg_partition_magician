#!/usr/bin/env python3
"""keep_both.py <file> | --selftest

Resolve an add/add conflict in one of the fix phase's LIST FILES by keeping both sides. Every fix PR
appends to the same three spots (a bullet at the top of CHANGELOG.md, an entry at the end of
bench/mutations/mutate.py's MUTATIONS dict, a guard line at the end of a run_* list in test.sh, a
self-test line in the lint workflow), so
every rebase of one fix onto another conflicts there, and "keep both" is always the right answer.
Anything else is left to a human: this script refuses a file it does not know.

Order: CHANGELOG.md puts the BRANCH's bullet first (newest on top); the others keep main's side first.

mutate.py needs three structural repairs on top of the textual keep-both, all caused by git factoring
the lines the two appended entries SHARE out of the conflict hunk and into the text after it:

  1. shared closing tail: both entries end with the same lines (`"", 1)],` then `    ),`), so those
     lines follow the `>>>>>>>` marker once and the FIRST entry is left unclosed. Copy the tail (up to
     and including the first `    ),` line) onto the first side when it does not already end closed and
     the second side opens a new entry.
  2. missing entry closer: a top-level `    "key": (` whose previous non-blank, NON-COMMENT line ends
     with `)],` is missing the `    ),` of the entry before it (the second side opened with a comment
     block, which hid the shape from the first repair).
  3. shared closing triple quote: two module-level `NAME = \"\"\"...\"\"\"` block constants appended at
     the same spot share their closing `\"\"\"` the same way; when both sides hold an odd number of
     `\"\"\"` and the line after the hunk is `\"\"\"`, give the first side its own closing line.

The result must parse (mutate.py) and must contain no marker. Duplicate mutation keys, duplicate
`pgpm_perfNN` guard databases and "does every mutation still build" are the caller's checks
(land.sh does them); this script only makes the text whole. Exit 0 on success, 1 on a file it cannot
resolve, 2 on usage.
"""
import ast
import re
import sys

KNOWN = ("CHANGELOG.md", "bench/mutations/mutate.py", "test.sh",
         ".github/workflows/perf.yml", ".github/workflows/archive.yml", ".github/workflows/lint.yml")
CONFLICT = re.compile(r"<<<<<<< [^\n]*\n(.*?)=======\n(.*?)>>>>>>> [^\n]*\n", re.S)
ENTRY_OPEN = re.compile(r'^    "[A-Za-z0-9_]+": \($')
ENTRY_CLOSE = re.compile(r"^    \),\s*$")


def _sig_lines(text):
    return [l for l in text.split("\n") if l.strip() and not l.lstrip().startswith("#")]


def _nl(part):
    return part if (not part or part.endswith("\n")) else part + "\n"


def _shared_tail(rest):
    """Lines after the hunk up to and including the first `    ),`; None if a `}` comes first."""
    out = []
    for l in rest.split("\n"):
        if l.startswith("}"):
            return None
        out.append(l)
        if ENTRY_CLOSE.match(l):
            return "\n".join(out) + "\n"
    return None


def repair_mutate_closers(src):
    lines = src.split("\n")
    out = []
    for l in lines:
        if ENTRY_OPEN.match(l):
            j = len(out) - 1
            while j >= 0 and (not out[j].strip() or out[j].lstrip().startswith("#")):
                j -= 1
            if j >= 0 and out[j].rstrip().endswith(")],"):
                out.append("    ),")
        out.append(l)
    return "\n".join(out)


def resolve_text(s, path):
    if not any(path.endswith(k) for k in KNOWN):
        raise ValueError(f"{path}: not a list file this resolver knows; resolve it by hand")
    is_changelog = path.endswith("CHANGELOG.md")
    is_mutate = path.endswith("mutate.py")
    pos, out = 0, []
    while True:
        m = CONFLICT.search(s, pos)
        if not m:
            out.append(s[pos:])
            break
        out.append(s[pos:m.start()])
        ours, theirs = m.group(1), m.group(2)
        first, second = (theirs, ours) if is_changelog else (ours, theirs)
        first, second = _nl(first), _nl(second)
        if is_mutate and first and second:
            fl, sl = _sig_lines(first), _sig_lines(second)
            first_closed = bool(fl) and ENTRY_CLOSE.match(fl[-1]) is not None
            second_opens = bool(sl) and ENTRY_OPEN.match(sl[0]) is not None
            if not first_closed and second_opens:
                tail = _shared_tail(s[m.end():])
                if tail is not None:
                    first += tail
            rest_first_line = s[m.end():].split("\n", 1)[0]
            if first.count('"""') % 2 == 1 and second.count('"""') % 2 == 1 and rest_first_line.strip() == '"""':
                first += rest_first_line + "\n\n"
        out.append(first + second)
        pos = m.end()
    s2 = "".join(out)
    if "<<<<<<<" in s2 or ">>>>>>>" in s2:
        raise ValueError(f"{path}: conflict markers remain (a hunk the pattern did not match)")
    if is_mutate:
        s2 = repair_mutate_closers(s2)
        ast.parse(s2)   # SyntaxError propagates: the caller must see it
    return s2


def resolve_file(path):
    s2 = resolve_text(open(path).read(), path)
    open(path, "w").write(s2)
    return s2


def _keys(src):
    for node in ast.walk(ast.parse(src)):
        if isinstance(node, ast.Assign) and any(getattr(t, "id", "") == "MUTATIONS" for t in node.targets):
            return [k.value for k in node.value.keys if isinstance(k, ast.Constant)]
    return []


def selftest():
    # shape 1 (#535): both entries end mid-site-tuple; the shared `"", 1)],` + `    ),` follow the hunk
    a = '''MUTATIONS = {
    "a": (
        "g", "d",
        [("x\\n",
<<<<<<< HEAD
          "y\\n", 1)],
    ),
    "b": (
        "g", "d",
        [("p\\n"
          "q\\n",
=======
    "c": (
        "g", "d",
        [("r\\n",
>>>>>>> f1c78ed (msg)
          "", 1)],
    ),
}
'''
    r = resolve_text(a, "bench/mutations/mutate.py")
    assert _keys(r) == ["a", "b", "c"], _keys(r)
    ns = {}
    exec(r, ns)
    assert ns["MUTATIONS"]["b"][2] == [("p\nq\n", "", 1)], ns["MUTATIONS"]["b"]
    assert ns["MUTATIONS"]["c"][2] == [("r\n", "", 1)]
    # shape 2 (#539): the first entry's site list is closed, the second opens with comment lines
    b = '''MUTATIONS = {
    "a": (
        "g", "d",
        [("x\\n", "", 1)],
    ),
<<<<<<< HEAD
    "b": (
        "g", "d",
        [("y\\n", "", 1)],
=======
    # a comment
    # another
    "c": (
        "g", "d",
        [("r\\n", "", 1)],
>>>>>>> 54b6782 (msg)
    ),
}
'''
    r = resolve_text(b, "bench/mutations/mutate.py")
    assert _keys(r) == ["a", "b", "c"], _keys(r)
    # shape 3 (#542): two module-level triple-quoted block constants sharing their closing quote
    c = '''X = 1
<<<<<<< HEAD
FOO_RE = 2
BAR = """    update t set a = 1
     where b = 2;
=======
# a comment about BAZ
BAZ = """    if x then
      y;
    end if;
>>>>>>> b0dce89 (msg)
"""

MUTATIONS = {
    "k": ("g", "d", [(BAR, "", 1)]),
}
'''
    r = resolve_text(c, "bench/mutations/mutate.py")
    ns = {}
    exec(r, ns)
    assert ns["BAR"] == "    update t set a = 1\n     where b = 2;\n", repr(ns["BAR"])
    assert ns["BAZ"].startswith("    if x then") and ns["FOO_RE"] == 2
    # a mutate.py hunk the repairs cannot make whole must raise, never write garbage
    try:
        resolve_text('MUTATIONS = {\n<<<<<<< HEAD\n    "a": (\n=======\n    "b": (\n>>>>>>> x\n}\n', "bench/mutations/mutate.py")
        raise SystemExit("accepted an unparseable result")
    except SyntaxError:
        pass
    # dangling markers and unknown files are refused
    for text, path in (("<<<<<<< HEAD\nfoo\n", "test.sh"), ("<<<<<<< HEAD\na\n=======\nb\n>>>>>>> x\n", "pgpm_core/install.sql")):
        try:
            resolve_text(text, path)
            raise SystemExit(f"accepted {path}")
        except ValueError:
            pass
    # CHANGELOG puts the branch's bullet first; test.sh keeps main's line first; multiple hunks resolve
    r = resolve_text("<<<<<<< HEAD\n- main\n=======\n- branch\n>>>>>>> x\n", "CHANGELOG.md")
    assert r == "- branch\n- main\n", r
    r = resolve_text("A\n<<<<<<< HEAD\nB\n=======\nC\n>>>>>>> x\nD\n<<<<<<< HEAD\nE\n=======\nF\n>>>>>>> x\n", "test.sh")
    assert r == "A\nB\nC\nD\nE\nF\n", r
    r = resolve_text("          python3 a.py --selftest\n<<<<<<< HEAD\n          python3 b.py --selftest\n=======\n          python3 c.py --selftest\n>>>>>>> x\n", ".github/workflows/lint.yml")
    assert r.splitlines() == ["          python3 a.py --selftest", "          python3 b.py --selftest", "          python3 c.py --selftest"], r
    print("keep_both selftest: PASS (3 mutate.py shapes, refusal cases, ordering rules)")


if __name__ == "__main__":
    if len(sys.argv) == 2 and sys.argv[1] == "--selftest":
        selftest()
    elif len(sys.argv) == 2:
        try:
            resolve_file(sys.argv[1])
        except (ValueError, SyntaxError) as e:
            print(f"keep_both: {e}", file=sys.stderr)
            sys.exit(1)
    else:
        print(__doc__)
        sys.exit(2)
