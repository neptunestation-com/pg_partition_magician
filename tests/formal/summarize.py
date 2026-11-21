#!/usr/bin/env python3
"""One track's summary of what the invariant oracle judged, and its liveness witness (formal methods Phase 3 W4,
docs/formal/phase3-design.md "Guards on the oracle"). test.sh calls it at the end of each track, and CI runs it the
same way, so a local run and a CI job read one summary.

  summarize.py <core|archive|timescale> <log dir> [title]
  summarize.py --selftest      the liveness rule below against tracks built to pass and to fail

The log dir holds one <file>.oracle per test file, the lines tests/formal/report.sql writes (L, S, E, V, J; its header
says what each is), plus an E line from the runner when the oracle's session failed. Prints the summary and writes it
to <log dir>/summary.txt, and the per-invariant table to <log dir>/summary.tsv.

REPORT MODE. A violation fails nothing yet: every pre-existing one is a claim no one has judged (the design note's
"report first, then enforce"). What fails the track now is the oracle failing to look, never what it saw:
  - an invariant the track should reach judged zero identities over the whole track (REQUIRED below);
  - any E line: check() raised, its session failed, or the bucket could not be read for a parent;
  - a custody file tests/formal/custody_files.txt lists as baselined that left no ledger at all, or no report.
Exit status 1 when any of those holds, else 0. Custody files that left a ledger but whose NoLostRow judged no
identity (their parents gone by the end) are listed, not failed: W6 reads them.
"""
import collections
import os
import re
import sys

INVARIANTS = ["NoLostRow", "NoDuplicateRow", "DropOnlyCovered", "ArchiveNoClobber", "ResolveByRecord", "NoWedge"]
REQUIRED = {
    "core": ["NoLostRow", "NoDuplicateRow", "ResolveByRecord", "NoWedge"],
    "archive": ["NoLostRow", "NoDuplicateRow", "DropOnlyCovered", "ArchiveNoClobber", "ResolveByRecord", "NoWedge"],
    "timescale": ["NoLostRow", "NoDuplicateRow", "ResolveByRecord"],
}
CUSTODY_PREFIX = {"core": re.compile(r"^tests/[0-9]"), "archive": re.compile(r"^tests/archive/db/"),
                  "timescale": re.compile(r"^tests/timescale/db/")}
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def custody(track):
    """(baselined, not baselined) custody files of the track, as paths."""
    base, unbased = [], []
    with open(os.path.join(ROOT, "tests/formal/custody_files.txt")) as fh:
        for line in fh:
            path, _, comment = line.strip().partition("#")
            path = path.strip()
            if not path or not CUSTODY_PREFIX[track].match(path):
                continue
            (unbased if comment.strip().startswith("not baselined") else base).append(path)
    return base, unbased


def liveness_failures(track, stats, errors, no_ledger, files):
    """What fails the track: the oracle failing to look (see the module's docstring), never what it saw."""
    fail = []
    for inv in REQUIRED[track]:
        if stats[inv]["ids"] == 0:
            fail.append("%s judged zero identities on the %s track, which should reach it" % (inv, track))
    if errors:
        fail.append("%d oracle error(s)" % len(errors))
    for p in no_ledger:
        fail.append("%s is a baselined custody file and left %s" % (p, "no report" if p not in files else "no ledger"))
    return fail


def selftest():
    """liveness_failures() against tracks built to pass and to fail (W5: bench/formal_summarize_selftest.sh runs it, and
    bench/mutations/mutate.py's summarize_zero_judged_passes is required to fail it). Exit status 0 when every case
    holds."""
    def stats_of(ids):
        st = {i: collections.Counter() for i in INVARIANTS}
        for inv, n in ids.items():
            st[inv]["ids"] = n
        return st
    every = {i: 7 for i in INVARIANTS}
    cases = [
        ("LIVENESS: every invariant judged on every track", [(t, stats_of(every), [], []) for t in REQUIRED], 0),
        ("a required invariant judged zero identities fails its track",
         [("core", stats_of(dict(every, NoWedge=0)), [], [])], 1),
        ("the archive track fails when ArchiveNoClobber judged nothing",
         [("archive", stats_of(dict(every, ArchiveNoClobber=0)), [], [])], 1),
        ("an invariant a track need not reach may judge nothing",
         [("timescale", stats_of(dict(every, NoWedge=0, DropOnlyCovered=0, ArchiveNoClobber=0)), [], [])], 0),
        ("an oracle error fails the track", [("core", stats_of(every), [("tests/x", "check() raised")], [])], 1),
        ("a baselined custody file with no report fails the track", [("core", stats_of(every), [], ["tests/y"])], 1),
    ]
    bad = 0
    for desc, runs, want in cases:
        got = sum(len(liveness_failures(t, st, err, nl, {})) for t, st, err, nl in runs)
        ok = (got > 0) == (want > 0)
        print("%s - %s" % ("ok" if ok else "not ok", desc))
        bad += 0 if ok else 1
    print("summarize.py selftest: %s" % ("PASS" if bad == 0 else "FAIL (%d case(s))" % bad))
    return 1 if bad else 0


def main():
    if sys.argv[1:] == ["--selftest"]:
        return selftest()
    track, logdir = sys.argv[1], sys.argv[2]
    title = sys.argv[3] if len(sys.argv) > 3 else track
    files = {}
    for name in sorted(os.listdir(logdir)):
        if not name.endswith(".oracle"):
            continue
        rep = {"L": None, "E": [], "V": [], "J": {}, "S": None, "T": None}
        with open(os.path.join(logdir, name), errors="replace") as fh:
            for line in fh:
                f = line.rstrip("\n").split("\t")
                if len(f) < 2 or f[0] not in rep:
                    continue
                label = f[1]
                if f[0] == "L":
                    rep["L"] = int(f[2])
                elif f[0] == "T":
                    rep["T"] = int(f[2])
                elif f[0] == "S":
                    rep["S"] = f[2:5]
                elif f[0] == "E":
                    rep["E"].append("\t".join(f[2:]))
                elif f[0] == "V":
                    rep["V"].append(f[2:6])
                elif f[0] == "J":
                    rep["J"][f[2]] = {"judged": f[3] == "t", "parents": int(f[4]), "ids": int(f[5]),
                                      "expected": int(f[6]), "note": f[7] if len(f) > 7 else ""}
        files[label] = rep

    stats = {i: collections.Counter() for i in INVARIANTS}
    violations, errors = [], []
    for label, rep in files.items():
        for e in rep["E"]:
            errors.append((label, e))
        if not rep["J"] and not rep["E"]:
            errors.append((label, "no judged() rows: the oracle's session ended before judged() ran"))
        for inv, j in rep["J"].items():
            if inv not in stats:
                continue
            if j["judged"] and j["ids"] > 0:
                stats[inv]["files"] += 1
            stats[inv]["ids"] += j["ids"]
            stats[inv]["declared"] += j["expected"]
        for inv, parent, ident, detail in rep["V"]:
            declared_inv = ident.split(":", 1)[0]
            if inv == "UnusedExpectation" and declared_inv in stats:
                stats[declared_inv]["unused"] += 1
            elif inv in stats:
                stats[inv]["violations"] += 1
            violations.append((label, inv, parent, ident, detail))

    base, unbased = custody(track)
    no_ledger = [p for p in base if p not in files or files[p]["L"] in (None, 0)]
    unjudged = [(p, files[p]["J"].get("NoLostRow", {}).get("note", "")) for p in base
                if p in files and files[p]["L"] and files[p]["J"].get("NoLostRow", {}).get("ids", 0) == 0]
    stores = [rep["S"] for rep in files.values() if rep["S"]]

    out = []
    out.append("=== invariant oracle, report mode: %s (%d files) ===" % (title, len(files)))
    out.append("%-18s %13s %12s %11s %9s %8s" % ("invariant", "files judged", "identities", "violations", "declared",
                                                 "unused"))
    tsv = ["invariant\tfiles_judged\tidentities\tviolations\tdeclared\tunused_expectation"]
    for inv in INVARIANTS:
        s = stats[inv]
        out.append("%-18s %13d %12d %11d %9d %8d" % (inv, s["files"], s["ids"], s["violations"], s["declared"],
                                                     s["unused"]))
        tsv.append("\t".join(str(x) for x in (inv, s["files"], s["ids"], s["violations"], s["declared"], s["unused"])))
    times = sorted(((rep["T"], label) for label, rep in files.items() if rep["T"] is not None), reverse=True)
    if times:
        out.append("oracle time (server side, per file): total %.1f s, median %d ms, max %d ms (%s)"
                   % (sum(t for t, _ in times) / 1000.0, times[len(times) // 2][0], times[0][0], times[0][1]))
        out.append("  slowest: " + ", ".join("%s %d ms" % (os.path.basename(lb), t) for t, lb in times[:5]))
    out.append("oracle errors: %d" % len(errors))
    for label, e in errors:
        out.append("  ERROR %s: %s" % (label, e))
    if stores:
        out.append("store loaded (ArchiveNoClobber): %d file(s), %d parent listing(s), %d object(s), %d identities"
                   % (len(stores), sum(int(s[0]) for s in stores), sum(int(s[1]) for s in stores),
                      sum(int(s[2]) for s in stores)))
    out.append("custody files: %d baselined, %d not baselined (custody_files.txt says why)" % (len(base), len(unbased)))
    if unjudged:
        out.append("baselined custody files whose NoLostRow judged no identity (listed, not failed):")
        for p, note in unjudged:
            out.append("  %s  %s" % (p, note))
    if violations:
        # grouped per file and invariant, the first three identities each: one file can report 50,000 (tests/59)
        groups = collections.OrderedDict()
        for v in violations:
            groups.setdefault((v[0], v[1]), []).append(v)
        out.append("violations (reported, not failed: report mode), per file and invariant; every row is in <file>.oracle:")
        for (label, inv), vs in groups.items():
            out.append("  %s  %s  %d" % (label, inv, len(vs)))
            for _, _, parent, ident, detail in vs[:3]:
                out.append("    %s  %s  %s" % (parent, ident[:200], detail[:300]))
            if len(vs) > 3:
                out.append("    ... and %d more" % (len(vs) - 3))

    fail = liveness_failures(track, stats, errors, no_ledger, files)
    out.append("LIVENESS (fails the track): " + ("PASS" if not fail else "FAIL"))
    for f in fail:
        out.append("  FAIL " + f)

    text = "\n".join(out) + "\n"
    sys.stdout.write(text)
    with open(os.path.join(logdir, "summary.txt"), "w") as fh:
        fh.write(text)
    with open(os.path.join(logdir, "summary.tsv"), "w") as fh:
        fh.write("\n".join(tsv) + "\n")
    return 1 if fail else 0


if __name__ == "__main__":
    sys.exit(main())
