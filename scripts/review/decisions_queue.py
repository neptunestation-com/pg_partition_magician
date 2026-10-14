#!/usr/bin/env python3
"""decisions_queue.py <decisions_queue.md> init
   decisions_queue.py <decisions_queue.md> add --kind default|limit|carried|scope|blocking --text "<text>"
                      [--issue N] [--pr N] [--loop N]
   decisions_queue.py <decisions_queue.md> resolve <id> --by "<who>" [--note "<text>"]
   decisions_queue.py <decisions_queue.md> render [--since <loop>]
   decisions_queue.py <decisions_queue.md> pending
   decisions_queue.py --selftest

The autonomous loop's decision queue (docs/adversarial-review.md, "Running a loop without a human"). A loop
applies the standing defaults for recurring trade-offs without waiting for anyone, but it RECORDS each one
here so the user can read and overturn it later; and a decision the loop may not take on its own (a release,
an action outside this repository, a budget extension, a destructive action outside the method's cleanup, a
Tier 1 regression a fixer could not clear in three rounds) is written here as a `blocking` entry and stops
the loop until it is resolved.

The file is Markdown, one line per entry, under a `## Loop N` heading for the loop that wrote it:

    - D<nn> | <date> | <kind> | <text> | issue #N | PR #N | resolved by <who> (<note>)

An absent issue or PR is written `issue -` / `PR -`, an unresolved entry ends `open`. The kinds:

    default   a standing default applied (refuse over warn, keep the channel, ...)
    limit     a lint limit documented rather than chased past one round
    carried   an issue carried open by decision (a Tier 2 that needs a design decision; never a Tier 1)
    scope     a scope change the lessons suggest
    blocking  a decision only the user can take; written `BLOCKING` so a grep and stop_check.py find it

`pending` prints the unresolved BLOCKING entries and exits 1 when there is one (0 when none); stop_check.py
reads the same file through parse() and stops the loop on the same condition. Exit 2 is a malformed file or
a refused argument (text holding `|` or a newline, an unknown id, resolving twice): never a silent default.
Malformed means any line that is not blank, a `## Loop N` heading, the header's prose above the first loop
heading, or an entry of the shape above, flush left; a line that reads as an entry (a list item under any
bullet or indent, a `d<nn>` id, a `|` field) is never prose, so a hand-written BLOCKING entry the parse could
not read is refused rather than skipped (#1290).
"""
import argparse
import contextlib
import datetime as dt
import io
import os
import re
import sys
import tempfile

KINDS = ("default", "limit", "carried", "scope", "blocking")
HEADER = [
    "# Decisions queue",
    "",
    "One line per decision the autonomous loop applied, documented, carried or is waiting on",
    "(`scripts/review/decisions_queue.py`). A `BLOCKING` entry that is not resolved stops the loop.",
    "",
]
ENTRY = re.compile(r"^- (D\d+) \| (\d{4}-\d{2}-\d{2}) \| ([A-Za-z]+) \| (.*) \| issue (#\d+|-) \| PR (#\d+|-) \| "
                   r"(open|resolved by (.+?)(?: \((.*)\))?)$")
LOOP = re.compile(r"^## Loop (\d+)\s*$")
ENTRY_LIKE = re.compile(r"^\s*(?:[-*+]|\d+[.)])(?:\s|$)|^\s*[Dd]\d+\b|\|")


class QueueError(Exception):
    pass


def parse(text):
    """Entries in file order: {id, num, date, kind, text, issue, pr, loop, resolved, by, note, line}."""
    entries, loop, seen = [], None, set()
    for n, ln in enumerate(text.split("\n"), 1):
        m = LOOP.match(ln)
        if m:
            loop = int(m.group(1))
            continue
        if not ln.strip():
            continue
        # Only the header's prose, above the first loop heading, is not an entry. Every other line, and any line
        # that reads as one (a list item of any bullet or indent, a D<nn> id in either case, a `|` field), is an
        # entry of the exact shape or the file is refused: a BLOCKING entry Markdown renders the same but this
        # parse skipped was never read, and the loop went on past it (#1290).
        if loop is None and not ENTRY_LIKE.match(ln):
            continue
        m = ENTRY.match(ln.rstrip())
        if not m:
            raise QueueError(f"line {n} is not a queue entry of the shape `- D<nn> | <date> | <kind> | <text> | "
                             f"issue #N|- | PR #N|- | open|resolved by <who>`, flush left: {ln!r}")
        kind = m.group(3).lower()
        if kind not in KINDS:
            raise QueueError(f"line {n}: unknown kind {m.group(3)!r} (one of {', '.join(KINDS)})")
        if m.group(1) in seen:
            raise QueueError(f"line {n}: duplicate id {m.group(1)}")
        seen.add(m.group(1))
        resolved = m.group(7) != "open"
        entries.append({
            "id": m.group(1), "num": int(m.group(1)[1:]), "date": m.group(2), "kind": kind,
            "text": m.group(4), "issue": None if m.group(5) == "-" else int(m.group(5)[1:]),
            "pr": None if m.group(6) == "-" else int(m.group(6)[1:]), "loop": loop,
            "resolved": resolved, "by": m.group(8) if resolved else None,
            "note": m.group(9) if resolved else None, "line": n,
        })
    return entries


def load(path):
    if not os.path.exists(path):
        raise QueueError(f"{path} does not exist (create it with `decisions_queue.py {path} init`)")
    with open(path) as f:
        return f.read()


def pending_blocking(entries):
    return [e for e in entries if e["kind"] == "blocking" and not e["resolved"]]


def entry_line(e):
    kind = "BLOCKING" if e["kind"] == "blocking" else e["kind"]
    status = "open"
    if e["resolved"]:
        status = f"resolved by {e['by']}" + (f" ({e['note']})" if e.get("note") else "")
    issue = f"#{e['issue']}" if e.get("issue") else "-"
    pr = f"#{e['pr']}" if e.get("pr") else "-"
    return f"- {e['id']} | {e['date']} | {kind} | {e['text']} | issue {issue} | PR {pr} | {status}"


def write_atomic(path, text):
    d = os.path.dirname(os.path.abspath(path))
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".decisions_queue.")
    with os.fdopen(fd, "w") as f:
        f.write(text)
    os.replace(tmp, path)


def clean_field(name, value):
    if value is None:
        return None
    if "|" in value or "\n" in value or "\r" in value:
        raise QueueError(f"--{name} may not hold `|` or a line break (the entry is one line of `|` fields)")
    value = value.strip()
    if not value:
        raise QueueError(f"--{name} is empty")
    return value


def number(value, what):
    if value is None:
        return None
    m = re.fullmatch(r"#?(\d+)", str(value).strip())
    if not m:
        raise QueueError(f"--{what} must be a number, got {value!r}")
    return int(m.group(1))


def cmd_init(path):
    if os.path.exists(path):
        parse(load(path))  # an existing file must still parse
        return f"{path}: exists"
    write_atomic(path, "\n".join(HEADER))
    return f"{path}: created"


def cmd_add(path, kind, text, issue=None, pr=None, loop=None, today=None):
    if kind not in KINDS:
        raise QueueError(f"unknown kind {kind!r}")
    text = clean_field("text", text)
    body = load(path) if os.path.exists(path) else "\n".join(HEADER)
    entries = parse(body)
    last_loop = None
    for ln in body.split("\n"):
        m = LOOP.match(ln)
        if m:
            last_loop = int(m.group(1))
    e = {"id": f"D{max([x['num'] for x in entries] + [0]) + 1:02d}",
         "date": (today or dt.datetime.now(dt.timezone.utc).date()).isoformat(), "kind": kind, "text": text,
         "issue": number(issue, "issue"), "pr": number(pr, "pr"), "resolved": False}
    lines = body.rstrip("\n").split("\n")
    if loop is not None and loop != last_loop:
        if last_loop is not None and loop < last_loop:
            raise QueueError(f"--loop {loop} is older than the file's last loop heading ({last_loop})")
        lines += ["", f"## Loop {loop}", ""]
    if lines[-1].strip() and not lines[-1].startswith("- D"):
        lines.append("")
    lines.append(entry_line(e))
    write_atomic(path, "\n".join(lines) + "\n")
    parse(load(path))
    return e["id"]


def cmd_resolve(path, ident, by, note=None):
    body = load(path)
    entries = parse(body)
    by, note = clean_field("by", by), clean_field("note", note)
    if by and re.search(r"\(|\)", by):
        raise QueueError("--by may not hold parentheses (the note is the parenthesised part)")
    match = [e for e in entries if e["id"] == ident.upper()]
    if not match:
        raise QueueError(f"no entry {ident}")
    e = match[0]
    if e["resolved"]:
        raise QueueError(f"{e['id']} is already resolved by {e['by']}")
    e.update(resolved=True, by=by, note=note)
    lines = body.split("\n")
    lines[e["line"] - 1] = entry_line(e)
    write_atomic(path, "\n".join(lines))
    parse(load(path))
    return e["id"]


def md_cell(text):
    return (text or "").replace("|", "\\|").replace("_", "\\_")


def render(entries, since=None):
    """The section the loop summary carries: every entry from loop `since` on, and every OPEN entry from an
    earlier loop (a carried issue or a pending decision does not stop mattering when its loop ends)."""
    if since is None:
        shown = list(entries)
        title = "Decisions queue"
    else:
        shown = [e for e in entries if (e["loop"] is not None and e["loop"] >= since) or not e["resolved"]]
        title = f"Decisions queue (loop {since} on)"
    out = [f"### {title}", ""]
    blocking = pending_blocking(entries)
    if blocking:
        out.append("**Open BLOCKING decisions: " + ", ".join(e["id"] for e in blocking) +
                   ". The loop is stopped until each is resolved.**")
    else:
        out.append("Open blocking decisions: none.")
    out.append("")
    if not shown:
        out.append("No decisions queued.")
        return "\n".join(out)
    counts = {k: sum(1 for e in shown if e["kind"] == k) for k in KINDS}
    out.append("By kind: " + ", ".join(f"{k} {counts[k]}" for k in KINDS) + ".")
    out += ["", "| id | loop | date | kind | decision | issue | PR | status |", "|---|---|---|---|---|---|---|---|"]
    for e in shown:
        kind = "BLOCKING" if e["kind"] == "blocking" else e["kind"]
        status = "open" if not e["resolved"] else f"resolved by {e['by']}" + (f" ({e['note']})" if e["note"] else "")
        out.append(f"| {e['id']} | {e['loop'] if e['loop'] is not None else '-'} | {e['date']} | {kind} | "
                   f"{md_cell(e['text'])} | {'#%d' % e['issue'] if e['issue'] else '-'} | "
                   f"{'#%d' % e['pr'] if e['pr'] else '-'} | {md_cell(status)} |")
    return "\n".join(out)


def selftest():
    with tempfile.TemporaryDirectory() as d:
        q = os.path.join(d, "decisions_queue.md")
        try:
            render(parse(load(q)))
            raise AssertionError("a missing file must be an error, not an empty queue")
        except QueueError:
            pass
        assert cmd_init(q).endswith("created") and cmd_init(q).endswith("exists")
        day = dt.date(2026, 10, 11)
        assert cmd_add(q, "default", "refuse over warn on the archive bound", issue="1230", loop=12, today=day) == "D01"
        assert cmd_add(q, "blocking", "release v0.7.0 needs the user", today=day) == "D02"
        assert cmd_add(q, "limit", "check_x.py beaten by a new spelling; documented", pr=1240, today=day) == "D03"
        text = load(q)
        assert "## Loop 12" in text and text.count("## Loop") == 1, text
        assert "- D02 | 2026-10-11 | BLOCKING | release v0.7.0 needs the user | issue - | PR - | open" in text, text
        assert "- D01 | 2026-10-11 | default | refuse over warn on the archive bound | issue #1230 | PR - | open" in text
        es = parse(text)
        assert [e["loop"] for e in es] == [12, 12, 12], es
        assert [e["id"] for e in pending_blocking(es)] == ["D02"]
        # a lower-case hand edit still blocks: lenient toward stopping
        with open(q, "a") as f:
            f.write("- D04 | 2026-10-11 | blocking | push to database.dev | issue - | PR - | open\n")
        assert [e["id"] for e in pending_blocking(parse(load(q)))] == ["D02", "D04"]
        assert cmd_resolve(q, "d04", "david", "not now") == "D04"
        assert cmd_resolve(q, "D02", "david") == "D02"
        es = parse(load(q))
        assert pending_blocking(es) == [], es
        assert es[3]["by"] == "david" and es[3]["note"] == "not now" and es[1]["note"] is None, es
        assert "| resolved by david (not now)" in load(q) and "BLOCKING | push to database.dev" in load(q)
        for bad in (lambda: cmd_resolve(q, "D02", "david"), lambda: cmd_resolve(q, "D99", "x"),
                    lambda: cmd_add(q, "default", "a | b"), lambda: cmd_add(q, "default", "a\nb"),
                    lambda: cmd_add(q, "nonsense", "x"), lambda: cmd_add(q, "default", "x", issue="abc"),
                    lambda: cmd_add(q, "default", "x", loop=11)):
            try:
                bad()
                raise AssertionError("refused argument accepted")
            except QueueError:
                pass
        # a new loop opens a heading; render --since keeps earlier OPEN entries only
        assert cmd_add(q, "carried", "#1199 bullet 2 needs a design decision", issue=1199, loop=13, today=day) == "D05"
        es = parse(load(q))
        assert [e["loop"] for e in es] == [12, 12, 12, 12, 13]
        r = render(es, since=13)
        assert "| D05 | 13 |" in r and "| D01 | 12 |" in r and "| D03 | 12 |" in r, r
        assert "| D02 |" not in r and "| D04 |" not in r, "resolved entries of earlier loops are not carried"
        assert "Open blocking decisions: none." in r and "carried 1" in r, r
        cmd_add(q, "blocking", "extend the budget past the ceiling", today=day)
        r = render(parse(load(q)))
        assert "**Open BLOCKING decisions: D06." in r and "| D06 | 13 |" in r, r
        # a malformed entry line and a duplicate id are parse errors
        for broken in ("- D07 | 2026-10-11 | default | no status field\n",
                       "- D01 | 2026-10-11 | default | dup | issue - | PR - | open\n",
                       "- D08 | 2026-10-11 | whim | x | issue - | PR - | open\n"):
            try:
                parse(load(q) + broken)
                raise AssertionError(f"malformed line accepted: {broken!r}")
            except QueueError:
                pass
        # #1290: a BLOCKING entry Markdown renders the same as the exact shape (indented, a `*` or `+` bullet, a
        # lower-case id, a numbered item) and prose under a loop heading are refused, never skipped; the header's
        # prose still parses, and the exact shape appended to the same file blocks
        good = load(q)
        assert [e["id"] for e in pending_blocking(parse(good + "- D09 | 2026-10-11 | BLOCKING | x | issue - | PR - | open\n"))] == ["D06", "D09"]
        for broken in ("  - D09 | 2026-10-11 | BLOCKING | x | issue - | PR - | open\n",
                       "* D09 | 2026-10-11 | BLOCKING | x | issue - | PR - | open\n",
                       "+ D09 | 2026-10-11 | BLOCKING | x | issue - | PR - | open\n",
                       "- d09 | 2026-10-11 | BLOCKING | x | issue - | PR - | open\n",
                       "1. D09 | 2026-10-11 | BLOCKING | x | issue - | PR - | open\n",
                       "D09 BLOCKING: cut the release first\n",
                       "Pending: cut the release first (BLOCKING)\n"):
            try:
                parse(good + broken)
                raise AssertionError(f"malformed line accepted: {broken!r}")
            except QueueError:
                pass
        assert "One line per decision" in good.split("## Loop", 1)[0] and len(parse(good)) == 6, "the header's prose parses"
        # the CLI: pending exits 1 on the open BLOCKING entry, 0 once it is resolved
        sink = io.StringIO()
        with contextlib.redirect_stdout(sink), contextlib.redirect_stderr(sink):
            assert main([q, "pending"]) == 1
            assert main([q, "resolve", "D06", "--by", "david"]) == 0
            assert main([q, "pending"]) == 0
            assert main([os.path.join(d, "absent.md"), "pending"]) == 2
        assert "D06 | 2026-10-11 | BLOCKING" in sink.getvalue() and "does not exist" in sink.getvalue(), sink.getvalue()
    print("decisions_queue selftest: PASS (init, add with loop headings, BLOCKING rendered and found in any case, "
          "resolve once, refused fields, render --since carries open entries, pending exit codes, malformed lines)")


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    if argv == ["--selftest"]:
        selftest()
        return 0
    ap = argparse.ArgumentParser(prog="decisions_queue.py", description=__doc__.split("\n\n")[1],
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("queue", help="the decisions_queue.md file")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("init", help="create the file with its header (an existing file must parse)")
    a = sub.add_parser("add", help="append an entry; prints its id")
    a.add_argument("--kind", required=True, choices=KINDS)
    a.add_argument("--text", required=True)
    a.add_argument("--issue")
    a.add_argument("--pr")
    a.add_argument("--loop", type=int, help="open a `## Loop N` heading when it differs from the file's last")
    r = sub.add_parser("resolve", help="mark an entry resolved")
    r.add_argument("id")
    r.add_argument("--by", required=True)
    r.add_argument("--note")
    s = sub.add_parser("render", help="the section the loop summary carries")
    s.add_argument("--since", type=int)
    sub.add_parser("pending", help="print the unresolved BLOCKING entries; exit 1 when there is one")
    args = ap.parse_args(argv)
    try:
        if args.cmd == "init":
            print(cmd_init(args.queue))
        elif args.cmd == "add":
            print(cmd_add(args.queue, args.kind, args.text, args.issue, args.pr, args.loop))
        elif args.cmd == "resolve":
            print(f"{cmd_resolve(args.queue, args.id, args.by, args.note)} resolved")
        elif args.cmd == "render":
            print(render(parse(load(args.queue)), args.since))
        elif args.cmd == "pending":
            p = pending_blocking(parse(load(args.queue)))
            for e in p:
                print(entry_line(e))
            if not p:
                print("no pending BLOCKING decision")
            return 1 if p else 0
    except QueueError as exc:
        print(f"decisions_queue: {exc}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
