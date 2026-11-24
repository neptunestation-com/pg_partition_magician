#!/usr/bin/env python3
"""sweep_actions.py <bullets.json>... --main <sha> [--out <dir>]
sweep_actions.py --selftest

Decide each issue's action in a staleness sweep of open issues from its bullets' statuses, and draft its
comment. The sweep's readers (one agent per batch of issues) judge each BULLET against main: fixed, present,
obsolete or unclear, with evidence. The action is then a function of those statuses, so it is computed here
rather than judged: on 2026-11-23 a reader marked #1034 "keep" with four of its seven bullets obsolete, and
the coordinator had to recompute every action by hand to catch it.

  close  every bullet fixed or obsolete
  keep   no bullet fixed or obsolete
  trim   anything else: a comment lists what is gone and what remains

Input: one or more JSON files, each a list of
  {"issue": 1034, "tier": "5", "action": "<the reader's, optional>",
   "bullets": [{"id": "b1", "summary": "...", "status": "fixed|present|obsolete|unclear",
                "evidence": "PR #NNN / sha; path:line ...", "note": "..."}]}

Each bullet is held to the evidence a wrong verdict would need, because a wrong `fixed` closes a live
defect, the worst outcome a sweep has:
  fixed     a PR (#NNN) or commit sha, AND a path:line on main that now does the right thing, the
            tests/ or bench/ file that pins it, or a reproduction that "passes on <sha>" (a closure run);
            a docs bullet may instead quote the doc at a .md path:line
  present   the file on main that shows the mechanism (a wrong `present` only keeps an issue open)
  obsolete  evidence naming the change that removed it (non-empty)
  unclear   a note saying what would settle it
and no em dash anywhere (house style), since the text is posted. An issue with an invalid bullet is
reported and gets no comment; the exit is 1.

Output: one line per issue (its action, the counts, and the reader's action where it disagrees), and with
--out, <out>/<issue>.md (the comment) and <out>/actions.json ({"<issue>": "close|trim|keep"}).
"""
import argparse
import json
import os
import re
import sys

STATUSES = ("fixed", "present", "obsolete", "unclear")
GONE = ("fixed", "obsolete")
REF = re.compile(r"#\d+|\b[0-9a-f]{7,40}\b")
PATH_LINE = re.compile(r"[\w.*-]*[/.][\w./*-]*:\d+")
DOC_LINE = re.compile(r"[\w./-]+\.md:\d+")
PINNED_BY = re.compile(r"\b(tests|bench)/[\w./*-]+\.(sql|sh)\b")
PASSES_ON = re.compile(r"\bpass(es|ing)? on [0-9a-f]{7,40}\b")
PATH = re.compile(r"[\w.-]+/[\w./*-]*|\b[\w-]+\.(sql|sh|py|md|ya?ml|json)\b")


def problems(b):
    st, ev, note = b.get("status"), b.get("evidence") or "", b.get("note") or ""
    out = []
    if st not in STATUSES:
        out.append(f"status {st!r} is not one of {', '.join(STATUSES)}")
    if st == "fixed" and not (REF.search(ev) and (PATH_LINE.search(ev) or PINNED_BY.search(ev) or PASSES_ON.search(ev))
                              or DOC_LINE.search(ev)):
        out.append("fixed needs a PR or sha AND a path:line on main or the test/guard that pins it")
    if st == "present" and not PATH.search(ev):
        out.append("present needs the file on main that shows it")
    if st == "obsolete" and not ev.strip():
        out.append("obsolete needs the change that removed it")
    if st == "unclear" and not note.strip():
        out.append("unclear needs a note saying what would settle it")
    if any("\u2014" in (b.get(k) or "") for k in ("summary", "evidence", "note")):
        out.append("em dash in the text")
    return out


def action(bullets):
    gone = sum(b["status"] in GONE for b in bullets)
    return "close" if gone == len(bullets) else "keep" if gone == 0 else "trim"


def line(b):
    s = f"- {b['id']} ({b['status']}): {b.get('summary', '').strip()}. {b.get('evidence', '').strip()}"
    if b["status"] == "unclear":
        s += f" To settle: {b['note'].strip()}"
    return s


def comment(issue, sha):
    bs, act = issue["bullets"], action(issue["bullets"])
    gone = [line(b) for b in bs if b["status"] in GONE]
    left = [line(b) for b in bs if b["status"] not in GONE]
    out = [f"Staleness sweep against main {sha}."]
    if gone:
        out += ["", "Gone:", ""] + gone
    if left:
        out += ["", "Remaining:", ""] + left
    out += ["", {"close": "Every bullet is gone; closing.", "trim": "Keeping it open for the remaining bullets.",
                 "keep": "Nothing is gone; keeping it open."}[act]]
    return "\n".join(out) + "\n"


def run(issues, sha, out_dir=None, say=print):
    bad, actions = 0, {}
    for issue in sorted(issues, key=lambda i: i["issue"]):
        n, bs = issue["issue"], issue.get("bullets") or []
        errs = [f"{b.get('id', '?')}: {p}" for b in bs for p in problems(b)] or ([] if bs else ["no bullets"])
        if errs:
            bad += 1
            say(f"#{n} INVALID: " + "; ".join(errs))
            continue
        act = action(bs)
        actions[str(n)] = act
        counts = " ".join(f"{s} {sum(b['status'] == s for b in bs)}" for s in STATUSES)
        said = issue.get("action")
        say(f"#{n} {act:5} {counts}" + (f"  (the reader said {said})" if said and said != act else ""))
        if out_dir:
            open(os.path.join(out_dir, f"{n}.md"), "w").write(comment(issue, sha))
    if out_dir:
        json.dump(actions, open(os.path.join(out_dir, "actions.json"), "w"), indent=1)
    return bad


def selftest():
    B = lambda i, st, ev="install.sql:1", note="": {"id": i, "summary": "s", "status": st, "evidence": ev, "note": note}
    # #1034 as the sweep's reader returned it: three present, four struck (obsolete), the reader's action "keep"
    real = {"issue": 1034, "action": "keep", "bullets": [
        B("b1", "present", "bench/upgrade_in_place.sh:199-212"), B("b2", "present", "bench/upgrade_in_place.sh:179"),
        B("b3", "obsolete", "struck after verification (A1034-3)"), B("b4", "obsolete", "struck (A1034-4)"),
        B("b5", "present", "tests/67_regrain_name_collision_test.sql:87"), B("b6", "obsolete", "struck (A1034-6)"),
        B("b7", "obsolete", "struck (A1034-7)")]}
    cases = [
        (real, "trim", "(the reader said keep)"),
        ({"issue": 1, "bullets": [B("b1", "fixed", "PR #754; install.sql:13696"), B("b2", "obsolete", "gone in #900")]},
         "close", None),
        ({"issue": 2, "bullets": [B("b1", "present"), B("b2", "unclear", note="a reproduction")]}, "keep", None),
        ({"issue": 3, "bullets": [B("b1", "fixed", "install.sql:5 looks right now")]}, None, "fixed needs a PR or sha"),
        ({"issue": 4, "bullets": [B("b1", "fixed", "PR #12, no line")]}, None, "fixed needs a PR or sha"),
        ({"issue": 5, "bullets": [B("b1", "present", "still there")]}, None, "present needs the file"),
        # shapes the 2026-11-23 sweep's readers used for real: a guard that pins it, a docs quote, a glob path
        ({"issue": 9, "bullets": [B("b1", "fixed", "PR #860 (6cfad8c); tests/233_grid_floor_across_era_test.sql"),
                                  B("b2", "fixed", "main docs/guide.md:192 'a paused table's keys wait'"),
                                  B("b3", "present", "tests/archive/db/39*:249 still there"),
                                  B("b4", "present", "12 hits in tests/*.sql"),
                                  B("b5", "fixed", "PR #1398; the re-find F1-03 passes on 9c3ed4d")]}, "trim", None),
        ({"issue": 10, "bullets": [B("b1", "fixed", "pgpm_hypertable/install.sql:2536 now reads it under the lock")]},
         None, "fixed needs a PR or sha"),
        ({"issue": 11, "bullets": [B("b1", "fixed", "PR #1052 per the closure comment")]}, None, "fixed needs a PR or sha"),
        ({"issue": 6, "bullets": [B("b1", "unclear")]}, None, "unclear needs a note"),
        ({"issue": 7, "bullets": [B("b1", "present", "install.sql:9 \u2014 still")]}, None, "em dash"),
        ({"issue": 8, "bullets": [B("b1", "gone")]}, None, "is not one of"),
    ]
    fails = 0
    for issue, want_act, want_text in cases:
        said = []
        bad = run([issue], "abc1234", say=said.append)
        got = said[0]
        ok = (bad == 0 and got.split()[1] == want_act) if want_act else (bad == 1 and "INVALID" in got)
        ok = ok and (want_text is None or want_text in got)
        fails += not ok
        print(("ok    " if ok else "FAIL  ") + got)
    c = comment(real, "abc1234")
    ok = "Gone:" in c and "Remaining:" in c and c.count("\n- ") == 7 and "\u2014" not in c
    fails += not ok
    print(("ok    " if ok else "FAIL  ") + "the #1034 comment lists 4 gone and 3 remaining")
    print("selftest: " + ("PASS" if not fails else f"FAIL ({fails})"))
    return 1 if fails else 0


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[1])
    ap.add_argument("files", nargs="*")
    ap.add_argument("--main", help="the sha of main the readers judged against")
    ap.add_argument("--out")
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args()
    if a.selftest:
        sys.exit(selftest())
    if not a.files or not a.main:
        ap.error("give the bullets files and --main")
    issues = [i for f in a.files for i in json.load(open(f))]
    if a.out:
        os.makedirs(a.out, exist_ok=True)
    sys.exit(1 if run(issues, a.main, a.out) else 0)


if __name__ == "__main__":
    main()
