#!/usr/bin/env python3
"""stop_check.py --history docs/adversarial-review.md --records docs/reviews [--pass N] [--budget-used <tokens>]
                [--decisions <decisions_queue.md>] [--extended-through <pass>] [--json <out>]
   stop_check.py --selftest

Whether the autonomous loop starts another loop (docs/adversarial-review.md, "Stopping criteria" and
"Running a loop without a human"). Reads the pass history table of the method document and, for each pass
in it, the record under --records whose first line is `# Review pass N: ...`, then judges the two most
recent passes (N and the pass before it; N defaults to the last row of the table):

  (a) the full lens cycle: the catalogue lenses other than fresh surface (which every pass uses and which
      does not count) all used across the two passes, each pass with zero Tier 1 findings and coverage of
      0.9 or better. A lens is paid only by a pass that qualifies; the lenses no qualifying pass of the two
      used are what the cycle still OWES, and they are printed;
  (b) precision >= 0.7 and fell rate <= 0.3 in each pass; seed recall >= 0.8 in each (the read-caught
      figure when the record has the suite split) AND on the late-survivor seeds (absent from pass 12 on
      reads as NOT met; absent before pass 12 is not judged);
  (c) the ceiling: the next pass would exceed 13 (or --extended-through) is a stop, "ceiling";
      --budget-used above 27M agent tokens for the current loop is a stop, "budget";
  (d) a BLOCKING entry of the decisions queue (decisions_queue.py) not resolved is a stop with its text;
  (e) the method's criterion 4: the Tier 1 capture-recapture estimate rounds to zero in both passes, or,
      when either pass reads "not attempted" or not computable ("not computable", "undefined"), (a) and (b)
      hold over the THREE most recent passes instead of two.

Verdict: `stop` when (c) or (d) applies, or with "converged" when (a), (b) and (e) are all met; `continue`
otherwise. Exit 0 continue, 1 stop, 2 a parse error (a record that does not have the shape, a lens not in
the catalogue, the table's Tier 1 count disagreeing with the record's, a missing file): never a silent
default. A figure a record does not state (a fell rate before pass 7, coverage before pass 12) reads as
NOT met where a criterion needs it, and is printed as unknown.

Record header lines read (pass_metrics.py writes them; anything in parentheses after the recall is optional):
  lenses: <list> | previous pass lenses: <list>
  seeds K=<n>, recall <r> (suite-caught a/b, read-caught c/d; late-survivor e/f); ... precision <p> (strict <s>, fell rate <e>)
  exact: recall a/b, precision c/d, strict e/f, fell rate g/h   (from pass 13 on; each fraction must round to its figure)
  findings by tier: T1 <n> T2 <n> ...
  coverage: <min over finders> (<n> of <m> finders at or above 0.90)   (optional; pass_metrics.py --coverage)
The thresholds are judged on exact values, never on a two-decimal figure (#1288: 16/23 = 0.696 prints 0.70):
recall, precision and fell rate on the `exact:` fractions (a record of pass 13 or later without the line reads
them as unknown; an earlier record is read on its figures, the only thing it states), the read-caught and
late-survivor recall on their own counts, and the coverage gate on the count of finders at 0.90, all of them.
  capture-recapture (T1): <prose with `estimate <x>[, found <y>]`, or `not attempted`, or `not computable`>
and the `## Stopping criteria status` rows `- <criterion>: met|NOT met`, where a row naming coverage stands
in for the coverage line when the header has none.
"""
import argparse
import contextlib
import glob
import io
import json
import os
import re
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import decisions_queue  # noqa: E402

CEILING = 13
BUDGET = 27_000_000
LATE_SURVIVOR_FROM = 12
EXACT_FROM = 13  # the first pass whose record pass_metrics.py writes with the `exact:` line (#1288)
FRAC = r"(\d+/\d+|n/a)"
CYCLE_SIZE = 5  # lenses per pass besides fresh surface
FRESH = "fresh surface"
NUM = r"([0-9]*\.?[0-9]+|n/a)"


class ParseError(Exception):
    pass


def num(s):
    return None if s in (None, "n/a") else float(s)


def frac(a, b):
    return None if int(b) == 0 else int(a) / int(b)


def section(text, title):
    out, on = [], False
    for ln in text.split("\n"):
        if ln.startswith("## "):
            on = ln[3:].strip() == title
            continue
        if on:
            out.append(ln)
    return out


def catalogue(text):
    """The lens catalogue: the bold names of the "Lenses" section's list, lower case, in order."""
    names = [m.group(1).strip().lower() for ln in section(text, "Lenses")
             for m in [re.match(r"^- \*\*(.+?)\*\*", ln)] if m]
    if FRESH not in names or len(names) < 3:
        raise ParseError("the method document's Lenses section does not list the catalogue "
                         f"(found {names!r})")
    return names


def history(text):
    """{pass: {"t1": int or None, "baseline": bool}} from the Pass history table."""
    rows = {}
    for ln in section(text, "Pass history"):
        if not ln.startswith("|"):
            continue
        cells = [c.strip() for c in ln.strip().strip("|").split("|")]
        if not cells or not cells[0].isdigit():
            continue
        if len(cells) < 7:
            raise ParseError(f"pass history row has {len(cells)} cells: {ln[:80]!r}")
        n = int(cells[0])
        if n in rows:
            raise ParseError(f"pass {n} appears twice in the pass history table")
        baseline = cells[5].lower() == "not measured"
        m = re.search(r"(\d+) T1\b", cells[3])
        if not m and not baseline:
            raise ParseError(f"pass {n}'s history row states no Tier 1 count ({cells[3][:60]!r})")
        rows[n] = {"t1": int(m.group(1)) if m else None, "baseline": baseline}
    if not rows:
        raise ParseError("no rows in the method document's Pass history table")
    return rows


def lens_list(text, lenses):
    text = text.strip()
    while True:
        stripped = re.sub(r"\([^()]*\)", "", text)
        if stripped == text:
            break
        text = stripped
    text = text.strip().rstrip(".")
    if not text or text.lower().startswith("none"):
        return []
    out = []
    for part in text.split(","):
        name = part.strip().lower()
        if not name:
            continue
        if name not in lenses:
            raise ParseError(f"lens {name!r} is not in the catalogue")
        out.append(name)
    return out


def capture(text, where):
    """Criterion 4's reading of a record's `capture-recapture (T1):` line, which is prose the coordinator
    writes. `not attempted` (leading) reads as not attempted; any `not computable` or `undefined` (for one
    slice or for the tree) reads as not computable; otherwise every `estimate <x>` is an estimate, of the
    Tier 1 still to find when it stands alone (`estimate 0 on both`) and of the population when a
    `, found <y>` follows (`estimate 2, found 2`: x - y remain), and the pass's figure is the largest. Prose
    that is none of these is a parse error, never a default."""
    t = text.strip().lower()
    if t.startswith("not attempted"):
        return {"kind": "not attempted", "remaining": None}
    if "not computable" in t or "undefined" in t:
        return {"kind": "not computable", "remaining": None}
    found = re.findall(r"\bestimate (\d+(?:\.\d+)?)(?:, found (\d+(?:\.\d+)?))?", t)
    if not found:
        raise ParseError(f"{where}: the capture-recapture line states no estimate and does not say it was not "
                         f"attempted or not computable: {text[:80]!r}")
    left = [float(x) - (float(y) if y else 0.0) for x, y in found]
    return {"kind": "estimate", "remaining": max(left)}


def record(path, lenses):
    with open(path) as f:
        text = f.read()
    first = text.split("\n", 1)[0]
    m = re.match(r"^# Review pass (\d+):", first)
    if not m:
        return None
    n = int(m.group(1))
    header = []
    for ln in text.split("\n")[1:]:
        if ln.startswith("## "):
            break
        header.append(ln)
    where = f"{os.path.basename(path)} (pass {n})"

    def line(prefix):
        hits = [ln for ln in header if ln.startswith(prefix)]
        if len(hits) > 1:
            raise ParseError(f"{where}: two `{prefix}` header lines")
        return hits[0] if hits else None

    r = {"pass": n, "file": path}
    ln = line("lenses: ")
    if ln is None:
        raise ParseError(f"{where}: no `lenses:` header line")
    r["lenses"] = lens_list(ln[len("lenses: "):].split(" | previous pass lenses:")[0], lenses)
    if not r["lenses"]:
        raise ParseError(f"{where}: the lenses line names no lens")

    ln = line("seeds K=")
    m = ln and re.match(r"^seeds K=(\d+), recall " + NUM + r"(?: \(([^()]*)\))?[;,]", ln)
    if not m:
        raise ParseError(f"{where}: no `seeds K=<n>, recall <r>` header line of the expected shape")
    r["K"], r["recall"] = int(m.group(1)), num(m.group(2))
    split = m.group(3) or ""
    for key, label in (("suite", "suite-caught"), ("read", "read-caught"), ("late", "late-survivor")):
        mm = re.search(label + r" (\d+)/(\d+)", split)
        r[key] = (int(mm.group(1)), int(mm.group(2))) if mm else None
    if split and not any(r[k] for k in ("suite", "read", "late")):
        raise ParseError(f"{where}: the recall's parenthesis has none of suite-caught, read-caught, late-survivor")

    m = re.search(r"\bprecision " + NUM + r"(?: \(strict " + NUM + r"(?:, fell rate " + NUM + r")?\))?",
                  "\n".join(header))
    if not m:
        raise ParseError(f"{where}: no `precision <p>` in the header")
    r["precision"], r["strict"], r["fell"] = num(m.group(1)), num(m.group(2)), num(m.group(3))

    # The thresholds are judged on the record's `exact:` fractions, never on the two-decimal figures above: 16/23
    # = 0.696 prints 0.70, and 0.70 >= 0.7 (#1288). Each fraction must round to its figure. From EXACT_FROM on a
    # record without the line states none of the four, so they read unknown (NOT met); before it, the figures
    # are all a record has, and they are read as they are.
    ln = line("exact: ")
    if ln is not None:
        m = re.match(r"^exact: recall " + FRAC + r", precision " + FRAC + r", strict " + FRAC + r", fell rate "
                     + FRAC + r"\s*$", ln)
        if not m:
            raise ParseError(f"{where}: `exact:` line not of the shape `exact: recall a/b, precision c/d, strict e/f, "
                             f"fell rate g/h`: {ln!r}")
        exact = {}
        for key, figure, spelled in zip(("recall", "precision", "strict", "fell"),
                                        (r["recall"], r["precision"], r["strict"], r["fell"]), m.groups()):
            v = None if spelled == "n/a" else frac(*spelled.split("/"))
            if (v is None) != (figure is None) or (v is not None and abs(v - figure) > 0.005 + 1e-9):
                raise ParseError(f"{where}: the exact {key} {spelled} disagrees with the record's figure "
                                 f"{'n/a' if figure is None else figure}")
            exact[key] = v
        r["recall"], r["precision"], r["strict"], r["fell"] = (exact["recall"], exact["precision"], exact["strict"],
                                                                exact["fell"])
        r["exact"] = True
    else:
        r["exact"] = False
        if n >= EXACT_FROM:
            r["recall"] = r["precision"] = r["strict"] = r["fell"] = None

    ln = line("findings by tier: ")
    m = ln and re.match(r"^findings by tier: T1 (\d+)\b", ln)
    if not m:
        raise ParseError(f"{where}: no `findings by tier: T1 <n>` header line")
    r["t1"] = int(m.group(1))

    ln = line("capture-recapture (T1): ")
    if ln is None:
        raise ParseError(f"{where}: no `capture-recapture (T1):` header line")
    r["capture"] = capture(ln[len("capture-recapture (T1): "):], where)

    ln = line("coverage: ")
    status = []
    for s in section(text, "Stopping criteria status"):
        mm = re.match(r"^- (.+?): (met|NOT met)(?:\s|$)", s)
        if mm:
            status.append((mm.group(1), mm.group(2) == "met"))
    r["status"] = status
    if ln is not None:
        # The gate is judged on the count of finders at it, which pass_metrics.py takes from the unrounded
        # values; the minimum is printed to two decimals, and a finder at 26/29 = 0.897 prints 0.90 (#1288).
        m = re.match(r"^coverage: " + NUM + r" \((\d+) of (\d+) finders at or above 0\.90\)", ln)
        if not m:
            raise ParseError(f"{where}: `coverage:` line without a figure and its finder count "
                             f"(`coverage: <min> (<n> of <m> finders at or above 0.90)`): {ln!r}")
        r["coverage"], r["coverage_from"] = num(m.group(1)), "header"
        r["coverage_at"], r["coverage_of"] = int(m.group(2)), int(m.group(3))
        if r["coverage_at"] > r["coverage_of"] or r["coverage"] is None or (
                r["coverage_at"] == r["coverage_of"] and r["coverage"] < 0.895) or (
                r["coverage_at"] < r["coverage_of"] and r["coverage"] > 0.9 + 1e-9):
            raise ParseError(f"{where}: the coverage line's minimum and its count of finders at 0.90 disagree: {ln!r}")
    else:
        rows = [ok for name, ok in status if "coverage" in name.lower()]
        r["coverage"] = None
        r["coverage_from"] = "unknown"
        if rows:
            r["coverage_from"] = "status rows: met" if all(rows) else "status rows: NOT met"
    return r


def coverage_ok(r):
    if r["coverage_from"] == "header":
        return r["coverage_of"] > 0 and r["coverage_at"] == r["coverage_of"]
    if r["coverage_from"].startswith("status rows"):
        return r["coverage_from"] == "status rows: met"
    return False


def coverage_text(r):
    if r["coverage_from"] == "header":
        return f"{r['coverage']:.2f} ({r['coverage_at']} of {r['coverage_of']} finders at 0.90)"
    return r["coverage_from"]


def load(history_path, records_dir):
    for p in (history_path, records_dir):
        if not os.path.exists(p):
            raise ParseError(f"{p} does not exist")
    with open(history_path) as f:
        text = f.read()
    lenses = catalogue(text)
    rows = history(text)
    recs = {}
    for path in sorted(glob.glob(os.path.join(records_dir, "*.md"))):
        r = record(path, lenses)
        if r is None:
            continue
        if r["pass"] in recs:
            raise ParseError(f"two records for pass {r['pass']}: {recs[r['pass']]['file']} and {path}")
        recs[r["pass"]] = r
    for n, r in recs.items():
        if n not in rows:
            raise ParseError(f"record {os.path.basename(r['file'])} is pass {n}, which the history table lacks")
        if rows[n]["t1"] is not None and rows[n]["t1"] != r["t1"]:
            raise ParseError(f"pass {n}: the history table says {rows[n]['t1']} Tier 1, the record {r['t1']}")
    for n, row in rows.items():
        if not row["baseline"] and n not in recs:
            raise ParseError(f"pass {n} is in the history table with no record under {records_dir}")
    return lenses, rows, recs


def parse_tokens(s):
    m = re.fullmatch(r"\s*([0-9]*\.?[0-9]+)\s*([kKmM]?)\s*", s or "")
    if not m:
        raise ParseError(f"--budget-used must be a token count like 9790000, 9.79M or 500k, got {s!r}")
    return int(round(float(m.group(1)) * {"": 1, "k": 1e3, "m": 1e6}[m.group(2).lower()]))


def fmt(x):
    return "unknown" if x is None else f"{x:.2f}"


def window(win, recs, cycle):
    """Criteria (a) and (b) over the passes in `win` (two, or three in criterion 4's fallback): the per-pass
    readings, whether each holds, and the lines that print them."""
    k = len(win)
    lines = []
    per, paid, used = {}, set(), set()
    for p in win:
        r = recs.get(p)
        if r is None:
            per[p] = {"record": False, "t1": None, "coverage": "no record", "qualifies": False, "lenses": []}
            continue
        q = r["t1"] == 0 and coverage_ok(r)
        per[p] = {"record": True, "t1": r["t1"], "coverage": coverage_text(r), "qualifies": q, "lenses": r["lenses"]}
        used |= set(r["lenses"])
        if q:
            paid |= set(r["lenses"])
    owed = [x for x in cycle if x not in paid]
    full = k >= 2
    a_met = full and all(per[p]["qualifies"] for p in win) and not owed
    t1_text = ", ".join(f"pass {p} {per[p]['t1'] if per[p]['t1'] is not None else 'no record'}" for p in win)
    cov_text = ", ".join(f"pass {p} {per[p]['coverage']}" for p in win)
    lines.append(f"(a) lens cycle: {len([x for x in cycle if x in used])}/{len(cycle)} cycle lenses used across "
                 f"the {k} passes; Tier 1: {t1_text}; coverage: {cov_text}: {'met' if a_met else 'NOT met'}")
    lines.append(f"    the cycle owes (lenses no Tier-1-free pass at coverage 0.9 of the {k} used): "
                 f"{', '.join(owed) if owed else 'nothing'}")

    b = {}

    def judge(name, values, ok):
        verdicts = {p: (v is not None and ok(v)) for p, v in values.items()}
        b[name] = {"values": {str(p): v for p, v in values.items()}, "met": all(verdicts.values()) and full}
        return b[name]["met"]

    rec_or_none = {p: recs.get(p) for p in win}
    prec = {p: (r["precision"] if r else None) for p, r in rec_or_none.items()}
    fell = {p: (r["fell"] if r else None) for p, r in rec_or_none.items()}
    recall, recall_src = {}, {}
    for p, r in rec_or_none.items():
        if r is None:
            recall[p], recall_src[p] = None, "no record"
        elif r["read"]:
            recall[p], recall_src[p] = frac(*r["read"]), f"read-caught {r['read'][0]}/{r['read'][1]}"
        else:
            recall[p], recall_src[p] = r["recall"], "overall"
    pm = judge("precision >= 0.7", prec, lambda v: v >= 0.7)
    lines.append("(b) precision >= 0.7: " + ", ".join(f"pass {p} {fmt(v)}" for p, v in prec.items())
                 + f": {'met' if pm else 'NOT met'}")
    fm = judge("fell rate <= 0.3", fell, lambda v: v <= 0.3)
    lines.append("    fell rate <= 0.3: " + ", ".join(f"pass {p} {fmt(v)}" for p, v in fell.items())
                 + f": {'met' if fm else 'NOT met'}")
    rm = judge("seed recall >= 0.8", recall, lambda v: v >= 0.8)
    lines.append("    seed recall >= 0.8: " + ", ".join(f"pass {p} {fmt(recall[p])} ({recall_src[p]})" for p in win)
                 + f": {'met' if rm else 'NOT met'}")
    late, late_txt, late_met = {}, [], True
    for p, r in rec_or_none.items():
        if r is not None and r["late"]:
            v = frac(*r["late"])
            late[str(p)] = v
            late_txt.append(f"pass {p} {fmt(v)} ({r['late'][0]}/{r['late'][1]})")
            late_met &= v is not None and v >= 0.8
        elif p >= LATE_SURVIVOR_FROM or r is None:
            late[str(p)] = None
            late_txt.append(f"pass {p} absent")
            late_met = False
        else:
            late[str(p)] = "not judged"
            late_txt.append(f"pass {p} not judged (before pass {LATE_SURVIVOR_FROM})")
    late_met = late_met and full
    b["late-survivor recall >= 0.8"] = {"values": late, "met": late_met}
    lines.append("    late-survivor recall >= 0.8: " + ", ".join(late_txt) + f": {'met' if late_met else 'NOT met'}")
    b_met = all(v["met"] for v in b.values())
    return {"a_met": a_met, "b_met": b_met, "per": per, "owed": owed, "b": b, "lines": lines}


def decide(lenses, rows, recs, current=None, budget_used=None, decisions=None, extended_through=None):
    """The criteria and the verdict, as a dict; `lines` is what main prints."""
    n = max(rows) if current is None else current
    if n not in rows:
        raise ParseError(f"--pass {n} is not in the history table (last is {max(rows)})")
    before = sorted(p for p in rows if p < n)
    prev = before[-1] if before else None
    pair = [p for p in (prev, n) if p is not None]
    triple = before[-2:] + [n]
    cycle = [x for x in lenses if x != FRESH]
    lines, crit = [], {}
    lines.append(f"pass {n} (previous {prev if prev is not None else 'none'}); judged on passes "
                 f"{' and '.join(str(p) for p in pair)}")

    two = window(pair, recs, cycle)
    a_met, b_met, per, owed, b = two["a_met"], two["b_met"], two["per"], two["owed"], two["b"]
    lines += two["lines"][:2]
    last_use = {x: max([p for p, r in recs.items() if p <= n and x in r["lenses"]] or [0]) for x in cycle}
    nxt = sorted(cycle, key=lambda x: (last_use[x], cycle.index(x)))[:CYCLE_SIZE]
    lines.append(f"    next pass lenses by the cycle rule (fresh surface plus the {CYCLE_SIZE} least recently used): "
                 + ", ".join([FRESH] + [f"{x} (last {last_use[x] or 'never'})" for x in nxt]))
    lines += two["lines"][2:]
    crit["a"] = {"met": a_met, "passes": {str(p): v for p, v in per.items()}, "owed": owed,
                 "next_lenses": [FRESH] + nxt}
    crit["b"] = {"met": b_met, "checks": b}

    # criterion 4: the Tier 1 capture-recapture estimate rounds to zero in both passes; where either pass did
    # not attempt it or could not compute it, (a) and (b) must hold over the three most recent passes instead
    cr = {p: (recs[p]["capture"] if p in recs else {"kind": "no record", "remaining": None}) for p in pair}
    cr_text = ", ".join(f"pass {p} " + (f"estimate, {cr[p]['remaining']:g} remaining" if cr[p]["kind"] == "estimate"
                                        else cr[p]["kind"]) for p in pair)
    if len(pair) == 2 and all(cr[p]["kind"] == "estimate" for p in pair):
        c4_met = all(round(cr[p]["remaining"]) == 0 for p in pair)
        c4 = {"branch": "estimate", "met": c4_met, "remaining": {str(p): cr[p]["remaining"] for p in pair}}
        lines.append(f"(e) capture-recapture, criterion 4: {cr_text}: rounds to zero in both: {'met' if c4_met else 'NOT met'}")
    else:
        three = window(triple, recs, cycle) if len(triple) == 3 else {"a_met": False, "b_met": False, "owed": None}
        c4_met = three["a_met"] and three["b_met"]
        c4 = {"branch": "three passes", "met": c4_met, "passes": triple, "a_met": three["a_met"],
              "b_met": three["b_met"], "owed": three["owed"]}
        lines.append(f"(e) capture-recapture, criterion 4: {cr_text}: so (a) and (b) over the three passes "
                     f"{', '.join(str(p) for p in triple)}: (a) {'met' if three['a_met'] else 'NOT met'}, "
                     f"(b) {'met' if three['b_met'] else 'NOT met'}: {'met' if c4_met else 'NOT met'}")
    crit["e"] = c4

    # (c) the ceiling and the budget
    ceiling = CEILING if extended_through is None else extended_through
    stops = []
    over_ceiling = n + 1 > ceiling
    lines.append(f"(c) ceiling: next pass {n + 1}, ceiling {ceiling}: {'STOP' if over_ceiling else 'within'}")
    if over_ceiling:
        stops.append(f"ceiling (the next pass, {n + 1}, would exceed pass {ceiling}"
                     f"{'' if extended_through else '; the user may extend it'})")
    over_budget = budget_used is not None and budget_used > BUDGET
    lines.append("    budget: " + ("not given" if budget_used is None else f"{budget_used:,} of {BUDGET:,} agent tokens")
                 + f": {'STOP' if over_budget else 'within'}")
    if over_budget:
        stops.append(f"budget ({budget_used:,} agent tokens used this loop, over the {BUDGET:,} ceiling)")
    crit["c"] = {"ceiling": ceiling, "next_pass": n + 1, "over_ceiling": over_ceiling,
                 "budget_used": budget_used, "over_budget": over_budget}

    # (d) a pending blocking decision
    pending = [] if decisions is None else decisions_queue.pending_blocking(decisions)
    if decisions is None:
        lines.append("(d) blocking decisions: no queue given")
    elif pending:
        lines.append("(d) blocking decisions: STOP: " + "; ".join(f"{e['id']} {e['text']}" for e in pending))
    else:
        lines.append("(d) blocking decisions: none pending")
    for e in pending:
        stops.append(f"blocking decision {e['id']}: {e['text']}")
    crit["d"] = {"queue": decisions is not None, "pending": [{"id": e["id"], "text": e["text"]} for e in pending]}

    if a_met and b_met and c4_met:
        how = ("the Tier 1 capture-recapture estimate rounding to zero in both" if c4["branch"] == "estimate" else
               f"(a) and (b) holding over passes {', '.join(str(p) for p in triple)} in place of an estimate")
        verdict, reason = "stop", "; ".join(
            [f"converged: the full lens cycle with zero Tier 1 and coverage >= 0.9 in passes {prev} and {n}, "
             f"precision, fell rate and both recalls met in each, and {how}"] + stops)
    elif stops:
        verdict, reason = "stop", "; ".join(stops)
    else:
        why = []
        if not a_met:
            t1 = [f"pass {p} has {per[p]['t1']} Tier 1" for p in pair if per[p]["t1"]]
            nocov = [f"pass {p} coverage {per[p]['coverage']}" for p in pair
                     if per[p]["record"] and not coverage_ok(recs[p])]
            norec = [f"pass {p} has no record" for p in pair if not per[p]["record"]]
            parts = ["Tier 1 findings: " + ", ".join(t1)] if t1 else []
            parts += ["coverage not shown at 0.9: " + ", ".join(nocov)] if nocov else []
            parts += norec + (["only one pass to judge"] if len(pair) < 2 else [])
            parts.append(f"the cycle owes {len(owed)} lens{'es' if len(owed) != 1 else ''}"
                         + (": " + ", ".join(owed) if owed else ""))
            why.append("(a) not met: " + "; ".join(parts))
        if not b_met:
            why.append("(b) not met: " + ", ".join(k for k, v in b.items() if not v["met"]))
        if not c4_met:
            why.append("(e) not met: " + ("a capture-recapture estimate does not round to zero"
                                          if c4["branch"] == "estimate" else
                                          f"(a) and (b) do not hold over passes {', '.join(str(p) for p in triple)}"))
        verdict, reason = "continue", "not converged: " + "; ".join(why)
    lines.append(f"verdict: {verdict}: {reason}")
    return {"pass": n, "previous": prev, "criteria": crit, "verdict": verdict, "reason": reason, "lines": lines}


# ------------------------------------------------------------------ selftest

LENS_SECTION = """## Lenses

- **Fresh surface** (always): regions merged since the last pass.
- **Concurrency and locks**: x.
- **Time and zones**: x.
- **Boundary arithmetic and types**: x.
- **Upgrade and install paths**: x.
- **Identity and names**: x.
- **Operator error**: x.
- **Failure injection**: x.
- **Contracts versus documentation**: x.
- **Tests that pass for the wrong reason**: x.
- **Resource cliffs**: x.
"""
A5 = "concurrency and locks, time and zones, boundary arithmetic and types, upgrade and install paths, identity and names"
B5 = "operator error, failure injection, contracts versus documentation, tests that pass for the wrong reason, resource cliffs"


CR_ZERO = "attempted on the two duplicated slices: S8 opus 0 Tier 1, fable 0, estimate 0 on both"


def synth_exact(prec):
    """The `exact:` line pass_metrics.py would write beside a summary tail like "precision 0.95 (strict 0.80,
    fell rate 0.05)": each figure over 100 (a figure the tail does not state is n/a), recall 9/9."""
    def f(label):
        m = re.search(r"\b" + label + r" ([0-9.]+)", prec)
        return f"{round(float(m.group(1)) * 100)}/100" if m else "n/a"
    return f"exact: recall 9/9, precision {f('precision')}, strict {f('strict')}, fell rate {f('fell rate')}"


def synth(d, passes, history_t1=None, capture_text=None, exact=None):
    """Write a method document and records for `passes`: [(n, t1, lenses, seeds_paren, precision_tail, coverage,
    status_rows)]; `capture_text` maps a pass to its capture-recapture line (default: an estimate of zero), and
    a pass mapped to None has no such line; `exact` maps a pass to its `exact:` line (default: synth_exact's),
    None for none."""
    rows = ["| 1 | 2026-09-24 | `aaaaaaa` | 76 (25 filed as T1) | ~106 | not measured | none | baseline |"]
    os.makedirs(os.path.join(d, "reviews"), exist_ok=True)
    for (n, t1, lenses, paren, prec, cov, status) in passes:
        t1_table = (history_t1 or {}).get(n, t1)
        rows.append(f"| {n} | 2026-10-{n:02d} | `bbbbbbb` | 30 ({t1_table} T1; groups) | 70 | 0.9 | 9 / 1.00 | notes |")
        head = [f"# Review pass {n}: 2026-10-{n:02d}", "", "pinned: `bbbbbbb` | budget: x",
                f"lenses: fresh surface, {lenses} | previous pass lenses: fresh surface, x (the same, by decision)"]
        if cov is not None:  # pass_metrics.py --coverage's exact spelling, right after the lenses line
            at = 13 if float(cov) >= 0.9 else 12
            head.append(f"coverage: {cov} ({at} of 13 finders at or above 0.90)")
        head += [f"seeds K=9, recall 1.00{paren}; claims 70; findings 30; {prec}"]
        ex = (exact or {}).get(n, synth_exact(prec))
        if ex is not None:
            head.append(ex)
        head += [f"findings by tier: T1 {t1} T2 1 T3 2 T4 0 T5 3"]
        cr = (capture_text or {}).get(n, CR_ZERO)
        if cr is not None:
            head.append(f"capture-recapture (T1): {cr}")
        body = head + ["", "## Findings", "", "## Stopping criteria status", "",
                       "This pass's half; the criteria need the previous pass as well.", ""]
        body += status or ["- zero Tier 1 findings: " + ("met" if t1 == 0 else "NOT met")]
        with open(os.path.join(d, "reviews", f"2026-10-{n:02d}.md"), "w") as f:
            f.write("\n".join(body) + "\n")
    doc = ["# Method", "", LENS_SECTION, "## Pass history", "",
           "| pass | date | pinned | findings (T1) | claims | precision | seeds / recall | notes |",
           "|---|---|---|---|---|---|---|---|"] + rows + [""]
    with open(os.path.join(d, "method.md"), "w") as f:
        f.write("\n".join(doc))
    return os.path.join(d, "method.md"), os.path.join(d, "reviews")


def run(hist, recs_dir, **kw):
    lenses, rows, recs = load(hist, recs_dir)
    return decide(lenses, rows, recs, **kw)


def expect_parse_error(fn, what):
    try:
        fn()
    except ParseError:
        return
    raise AssertionError(f"accepted: {what}")


def selftest():
    good_prec = "precision 0.95 (strict 0.80, fell rate 0.05)"
    split = " (suite-caught 3/3, read-caught 6/6; late-survivor 3/3)"
    with tempfile.TemporaryDirectory() as root:
        def case(name, passes, **kw):
            d = os.path.join(root, name)
            os.makedirs(d)
            return synth(d, passes, **kw)

        # converged: two Tier-1-free passes covering the ten cycle lenses, coverage at the gate, every rate met
        h, r = case("converged", [(12, 0, A5, split, good_prec, "0.93", None), (13, 0, B5, split, good_prec, "0.91", None)])
        v = run(h, r)
        assert v["verdict"] == "stop" and v["reason"].startswith("converged"), v["lines"]
        assert v["criteria"]["a"]["owed"] == [] and v["criteria"]["b"]["met"], v["criteria"]
        assert "; ceiling" in v["reason"], "pass 13 is also the ceiling: both reasons are given, converged first"
        v = run(h, r, extended_through=15)
        assert v["verdict"] == "stop" and v["reason"].startswith("converged") and "ceiling" not in v["reason"], v["reason"]

        # a Tier 1 in either pass: continue, naming the Tier 1 and the lenses the cycle still owes
        h, r = case("t1", [(11, 0, A5, split, good_prec, "0.93", None), (12, 2, B5, split, good_prec, "0.95", None)])
        v = run(h, r)
        assert v["verdict"] == "continue", v["lines"]
        assert "pass 12 has 2 Tier 1" in v["reason"] and "the cycle owes 5 lenses" in v["reason"], v["reason"]
        assert v["criteria"]["a"]["owed"] == B5.split(", "), v["criteria"]["a"]["owed"]
        assert v["criteria"]["a"]["next_lenses"][1:] == A5.split(", "), "the five least recently used are pass 11's"

        # the cycle incomplete although both passes qualify: the same five lenses twice
        h, r = case("repeat", [(11, 0, A5, split, good_prec, "0.93", None), (12, 0, A5, split, good_prec, "0.95", None)])
        v = run(h, r)
        assert v["verdict"] == "continue" and v["criteria"]["a"]["owed"] == B5.split(", "), v["lines"]

        # coverage: a header figure below 0.9 fails (a); without a header, status rows decide; neither: unknown
        h, r = case("cov", [(11, 0, A5, split, good_prec, "0.86", None), (12, 0, B5, split, good_prec, "0.95", None)])
        v = run(h, r)
        assert v["verdict"] == "continue" and "pass 11 coverage 0.86" in v["reason"], v["reason"]
        assert v["criteria"]["a"]["owed"] == A5.split(", "), "an unqualified pass pays no lens"
        rows_met = ["- zero Tier 1 findings: met", "- coverage >= 0.9 on every slice: met"]
        h, r = case("covrows", [(12, 0, A5, split, good_prec, None, rows_met), (13, 0, B5, split, good_prec, None, rows_met)])
        v = run(h, r, extended_through=14)
        assert v["verdict"] == "stop" and v["reason"].startswith("converged"), v["lines"]
        rows_not = ["- zero Tier 1 findings: met", "- coverage >= 0.9 on every slice: NOT met (fresh surface 0.81)"]
        h, r = case("covrows_not", [(12, 0, A5, split, good_prec, None, rows_met), (13, 0, B5, split, good_prec, None, rows_not)])
        v = run(h, r, extended_through=14)
        assert v["verdict"] == "continue" and "status rows: NOT met" in v["reason"], v["reason"]
        h, r = case("covnone", [(12, 0, A5, split, good_prec, None, None), (13, 0, B5, split, good_prec, None, None)])
        v = run(h, r, extended_through=14)
        assert v["verdict"] == "continue" and "coverage unknown" in v["reason"], v["reason"]

        # (b): precision, fell rate, read-caught recall, late-survivor recall, each one failing alone
        for name, paren, prec, needle in (
                ("prec", split, "precision 0.65 (strict 0.60, fell rate 0.05)", "precision >= 0.7"),
                ("fell", split, "precision 0.95 (strict 0.60, fell rate 0.35)", "fell rate <= 0.3"),
                ("nofell", split, "precision 0.95 (strict 0.60)", "fell rate <= 0.3"),
                ("read", " (suite-caught 3/3, read-caught 4/6; late-survivor 3/3)", good_prec, "seed recall >= 0.8"),
                ("read0", " (suite-caught 9/9, read-caught 0/0; late-survivor 3/3)", good_prec, "seed recall >= 0.8"),
                ("late", " (suite-caught 3/3, read-caught 6/6; late-survivor 1/3)", good_prec, "late-survivor"),
                ("lateabsent", " (suite-caught 3/3, read-caught 6/6)", good_prec, "late-survivor")):
            h, r = case("b_" + name, [(12, 0, A5, split, good_prec, "0.93", None), (13, 0, B5, paren, prec, "0.93", None)])
            v = run(h, r, extended_through=14)
            assert v["verdict"] == "continue" and v["criteria"]["a"]["met"], (name, v["lines"])
            assert needle in v["reason"] and v["reason"].count("(b) not met") == 1, (name, v["reason"])
        # read-caught decides over the overall recall when the split is present
        h, r = case("b_readwins", [(12, 0, A5, " (suite-caught 0/3, read-caught 6/6; late-survivor 3/3)", good_prec, "0.93", None),
                                   (13, 0, B5, split, good_prec, "0.93", None)])
        assert run(h, r, extended_through=14)["reason"].startswith("converged")
        # late-survivor absent before pass 12 is not judged
        h, r = case("b_early", [(10, 0, A5, " (suite-caught 3/3, read-caught 6/6)", good_prec, "0.93", None),
                                (11, 0, B5, " (suite-caught 3/3, read-caught 6/6)", good_prec, "0.93", None)])
        v = run(h, r)
        assert v["reason"].startswith("converged"), v["lines"]
        assert "not judged" in "\n".join(v["lines"])
        # ...and from pass 12 exactly, absent is NOT met (pass 11 beside it still not judged)
        h, r = case("b_twelve", [(11, 0, A5, " (suite-caught 3/3, read-caught 6/6)", good_prec, "0.93", None),
                                 (12, 0, B5, " (suite-caught 3/3, read-caught 6/6)", good_prec, "0.93", None)])
        v = run(h, r)
        assert v["verdict"] == "continue" and "late-survivor" in v["reason"], v["lines"]
        assert "pass 11 not judged" in "\n".join(v["lines"]) and "pass 12 absent" in "\n".join(v["lines"]), v["lines"]

        # (c) the ceiling at the last pass, the budget at any pass; (d) a blocking decision
        h, r = case("ceiling", [(12, 1, A5, split, good_prec, "0.93", None), (13, 1, B5, split, good_prec, "0.93", None)])
        v = run(h, r)
        assert v["verdict"] == "stop" and v["reason"].startswith("ceiling"), v["reason"]
        assert run(h, r, extended_through=14)["verdict"] == "continue"
        assert run(h, r, current=12)["verdict"] == "continue", "--pass 12: the next pass is 13, within"
        v = run(h, r, current=12, budget_used=parse_tokens("27.5M"))
        assert v["verdict"] == "stop" and v["reason"].startswith("budget"), v["reason"]
        assert run(h, r, current=12, budget_used=parse_tokens("27000000"))["verdict"] == "continue"
        q = os.path.join(root, "decisions_queue.md")
        decisions_queue.cmd_init(q)
        decisions_queue.cmd_add(q, "default", "refuse over warn", loop=12)
        assert run(h, r, current=12, decisions=decisions_queue.parse(decisions_queue.load(q)))["verdict"] == "continue"
        decisions_queue.cmd_add(q, "blocking", "cut release v0.7.0", loop=12)
        v = run(h, r, current=12, decisions=decisions_queue.parse(decisions_queue.load(q)))
        assert v["verdict"] == "stop" and "blocking decision D02: cut release v0.7.0" in v["reason"], v["reason"]
        decisions_queue.cmd_resolve(q, "D02", "david", "later")
        assert run(h, r, current=12, decisions=decisions_queue.parse(decisions_queue.load(q)))["verdict"] == "continue"

        # (e) criterion 4, the estimate branch: both passes state an estimate, which must round to zero in each
        ok12, ok13 = (12, 0, A5, split, good_prec, "0.93", None), (13, 0, B5, split, good_prec, "0.93", None)
        h, r = case("cr_left", [ok12, ok13], capture_text={13: "S8: n1 = 3, n2 = 2, overlap 1, estimate 6, found 4"})
        v = run(h, r, extended_through=14)
        assert v["verdict"] == "continue" and v["criteria"]["a"]["met"] and v["criteria"]["b"]["met"], v["lines"]
        assert v["criteria"]["e"] == {"branch": "estimate", "met": False, "remaining": {"12": 0.0, "13": 2.0}}, v["criteria"]["e"]
        assert "(e) not met: a capture-recapture estimate does not round to zero" in v["reason"], v["reason"]
        h, r = case("cr_round", [ok12, ok13], capture_text={13: "S8: estimate 0.4 (a fraction left)"})
        v = run(h, r, extended_through=14)
        assert v["reason"].startswith("converged") and "rounding to zero" in v["reason"], v["lines"]
        # the fallback branch: an estimate not attempted or not computable in either pass asks for (a) and (b)
        # over THREE passes; two qualifying passes alone are then not enough
        for name, text in (("cr_na", "not attempted"), ("cr_nc", "S8 opus 1, fable 0, no overlap, so not computable"),
                           ("cr_undef", "S3: overlap 0, estimate undefined")):
            h, r = case(name, [ok12, ok13], capture_text={12: text})
            v = run(h, r, extended_through=14)
            assert v["verdict"] == "continue" and v["criteria"]["e"]["branch"] == "three passes", (name, v["lines"])
            assert v["criteria"]["e"]["passes"] == [1, 12, 13] and "(e) not met" in v["reason"], (name, v["reason"])
            ok11 = (11, 0, B5, " (suite-caught 3/3, read-caught 6/6)", good_prec, "0.95", None)
            h, r = case(name + "3", [ok11, ok12, ok13], capture_text={12: text})
            v = run(h, r, extended_through=14)
            assert v["reason"].startswith("converged") and "over passes 11, 12, 13" in v["reason"], (name, v["lines"])
            # the third pass must hold (a) and (b) too: a Tier 1 or a low precision in pass 11 keeps the loop going
            for bad11, needle in (((11, 1, B5, " (read-caught 6/6)", good_prec, "0.95", None), "(a) NOT met, (b) met"),
                                  ((11, 0, B5, " (read-caught 6/6)", "precision 0.5 (strict 0.5, fell rate 0.1)", "0.95", None),
                                   "(a) met, (b) NOT met")):
                h, r = case(name + "3bad" + needle[4], [bad11, ok12, ok13], capture_text={12: text})
                v = run(h, r, extended_through=14)
                assert v["verdict"] == "continue" and needle in "\n".join(v["lines"]), (name, needle, v["lines"])
                assert "(e) not met: (a) and (b) do not hold over passes 11, 12, 13" in v["reason"], v["reason"]
        # the coverage line pass_metrics.py --coverage writes, figure first: read as the minimum
        h, r = case("covline", [ok12, ok13])
        assert load(h, r)[2][13]["coverage"] == 0.93 and load(h, r)[2][13]["coverage_from"] == "header"

        # #1288: the thresholds on exact values. pass_metrics.py's own record of a pass at 16/23 (0.696, printed
        # 0.70) and fell 7/23 (0.304, printed 0.30), with a finder at 26/29 (0.897, printed 0.90): every one NOT
        # met; the same records at 17/23, 6/23 and 27/29 converge, so the NOT met is the figures', not a parse's
        import pass_metrics

        def pm_record(n, lenses, found, read, units=29):
            sealed = {"seeds": [{"id": f"S{i}", "lens": "x", "tier": 2, "mutation": f"m{i}", "suite_caught": [],
                                 **({"late_survivor": {"issue": 1000 + i, "passes_survived": 6}} if i <= 3 else {})}
                                for i in range(1, 10)]}
            claims = [{"id": f"F1-{i:02d}", "finder": "F1", "class": "seed_hit", "seed": f"S{i}", "tier": 2}
                      for i in range(1, 10)]
            claims += [{"id": f"F2-{i:02d}", "finder": "F2", "class": "candidate", "tier": 3, "scenario": "s"}
                       for i in range(1, 15)]
            verdicts = {f"F2-{i:02d}": ({"verdict": "finding", "tier": 3} if i <= found else
                                        {"verdict": "fell", "reason": "r"}) for i in range(1, 15)}
            m = pass_metrics.compute(sealed, {"claims": claims}, verdicts)
            cov = {"rows": [{"finder": "F1", "units": 40, "read": 40, "coverage": 1.0, "ledger": "present"},
                            {"finder": "F2", "units": units, "read": read, "coverage": round(read / units, 3),
                             "ledger": "present"}]}

            class A:
                pass_n, date, pinned, release, budget = n, f"2026-10-{n:02d}", "abc1234", "x", "x"
                previous_lenses, capture_recapture = "fresh surface", CR_ZERO
                root_cause_groups, root_causes_file, notes_file = None, None, None
                coverage_line = pass_metrics.coverage_line(cov)
            A.lenses = "fresh surface, " + lenses
            return pass_metrics.record(m, A)

        def pm_case(name, found, read, units=29):
            d = os.path.join(root, name)
            h, r = synth(d, [(12, 0, A5, split, good_prec, "0.93", None), (13, 0, B5, split, good_prec, "0.93", None)])
            for n, lenses in ((12, A5), (13, B5)):
                with open(os.path.join(r, f"2026-10-{n:02d}.md"), "w") as f:
                    f.write(pm_record(n, lenses, found, read, units))
            return run(h, r, extended_through=14), load(h, r)[2]

        v, recs = pm_case("pm_edge", 7, 26)
        head = open(os.path.join(root, "pm_edge", "reviews", "2026-10-13.md")).read()
        assert "precision 0.70 (strict 0.70, fell rate 0.30)" in head and "coverage: 0.90 (1 of 2" in head, head[:600]
        assert abs(recs[13]["precision"] - 16 / 23) < 1e-9 and abs(recs[13]["fell"] - 7 / 23) < 1e-9, recs[13]
        b = v["criteria"]["b"]["checks"]
        assert b["precision >= 0.7"]["met"] is False and b["fell rate <= 0.3"]["met"] is False, b
        assert not any(p["qualifies"] for p in v["criteria"]["a"]["passes"].values()), v["criteria"]["a"]
        assert v["verdict"] == "continue" and "pass 13 coverage 0.90 (1 of 2 finders at 0.90)" in v["reason"], v["reason"]
        v, recs = pm_case("pm_clear", 8, 27)
        assert v["verdict"] == "stop" and v["reason"].startswith("converged"), v["lines"]
        # each lever alone: the edge precision with clear coverage fails (b) only; the edge coverage alone (a) only
        v, _ = pm_case("pm_prec", 7, 27)
        assert v["criteria"]["a"]["met"] and not v["criteria"]["b"]["met"], v["lines"]
        v, _ = pm_case("pm_cov", 8, 26)
        assert not v["criteria"]["a"]["met"] and v["criteria"]["b"]["met"], v["lines"]
        # the count beneath the line is exact too: 188 of 209 (0.89952) is written 0.900 by coverage.py and does
        # not qualify; 189 of 210 (exactly 0.9) does
        v, _ = pm_case("pm_cov_rounded", 8, 188, 209)
        assert not v["criteria"]["a"]["met"] and v["criteria"]["b"]["met"], v["lines"]
        v, _ = pm_case("pm_cov_exact", 8, 189, 210)
        assert v["reason"].startswith("converged"), v["lines"]
        # a record of pass 13 without the exact line states no exact figure: unknown, NOT met; pass 12's figures stand
        h, r = case("noexact", [ok12, ok13], exact={12: None, 13: None})
        v = run(h, r, extended_through=14)
        assert v["criteria"]["b"]["checks"]["precision >= 0.7"]["values"] == {"12": 0.95, "13": None}, v["criteria"]["b"]
        assert v["verdict"] == "continue" and "precision >= 0.7" in v["reason"], v["reason"]
        # an exact fraction that does not round to its figure, a malformed exact line, a coverage line without its
        # count or whose count contradicts its minimum: parse errors
        for name, kw, edit in (
                ("exact_off", {"exact": {13: "exact: recall 9/9, precision 16/23, strict 80/100, fell rate 5/100"}}, None),
                ("exact_shape", {"exact": {13: "exact: precision 95/100"}}, None),
                ("cov_nocount", {}, ("coverage: 0.93 (13 of 13 finders at or above 0.90)", "coverage: 0.93")),
                ("cov_all_low", {}, ("coverage: 0.93 (13 of 13 finders", "coverage: 0.86 (13 of 13 finders")),
                ("cov_some_high", {}, ("coverage: 0.93 (13 of 13 finders", "coverage: 0.93 (12 of 13 finders"))):
            h, r = case(name, [ok12, ok13], **kw)
            if edit:
                p13 = os.path.join(r, "2026-10-13.md")
                with open(p13) as f:
                    body = f.read()
                assert edit[0] in body, (name, body[:400])
                with open(p13, "w") as f:
                    f.write(body.replace(edit[0], edit[1]))
            expect_parse_error(lambda: run(h, r, extended_through=14), name)

        # parse errors: never a silent default
        h, r = case("cr_prose", [ok12, ok13], capture_text={13: "both finders agreed, nothing left"})
        expect_parse_error(lambda: run(h, r), "a capture-recapture line that is none of the three readings")
        h, r = case("cr_missing", [ok12, ok13], capture_text={13: None})
        expect_parse_error(lambda: run(h, r), "a record without a capture-recapture line")
        h, r = case("mismatch", [(12, 0, A5, split, good_prec, "0.93", None), (13, 0, B5, split, good_prec, "0.93", None)],
                    history_t1={13: 1})
        expect_parse_error(lambda: run(h, r), "the table's Tier 1 count disagreeing with the record's")
        h, r = case("badlens", [(12, 0, A5, split, good_prec, "0.93", None),
                                (13, 0, "operator error, gut feeling", split, good_prec, "0.93", None)])
        expect_parse_error(lambda: run(h, r), "a lens outside the catalogue")
        h, r = case("norecord", [(12, 0, A5, split, good_prec, "0.93", None), (13, 0, B5, split, good_prec, "0.93", None)])
        os.remove(os.path.join(r, "2026-10-13.md"))
        expect_parse_error(lambda: run(h, r), "a history row without its record")
        h, r = case("noseeds", [(12, 0, A5, split, good_prec, "0.93", None), (13, 0, B5, split, good_prec, "0.93", None)])
        p13 = os.path.join(r, "2026-10-13.md")
        with open(p13) as f:
            body = f.read()
        for broken in (body.replace("seeds K=9, recall 1.00", "seeds: nine"),
                       body.replace("findings by tier: T1 0", "findings by tier: none"),
                       body.replace("precision 0.95", "precise"),
                       body.replace("coverage: 0.93", "coverage: most of it")):
            with open(p13, "w") as f:
                f.write(broken)
            expect_parse_error(lambda: run(h, r), "a malformed header line: " + broken.split("\n")[4][:40])
        expect_parse_error(lambda: run(h, os.path.join(root, "nowhere")), "a missing records directory")
        expect_parse_error(lambda: parse_tokens("lots"), "a budget that is not a number")
        h, r = case("pass", [(12, 0, A5, split, good_prec, "0.93", None)])
        expect_parse_error(lambda: run(h, r, current=14), "--pass outside the table")

        # the CLI: exit codes and the JSON
        h, r = case("cli", [(11, 1, A5, split, good_prec, "0.93", None), (12, 0, B5, split, good_prec, "0.93", None)])
        out = os.path.join(root, "verdict.json")
        sink = io.StringIO()
        with contextlib.redirect_stdout(sink), contextlib.redirect_stderr(sink):
            assert main(["--history", h, "--records", r, "--json", out]) == 0
            assert main(["--history", h, "--records", r, "--budget-used", "30M"]) == 1
            assert main(["--history", h, "--records", os.path.join(root, "nowhere")]) == 2
            assert main(["--history", h, "--records", r, "--decisions", os.path.join(root, "absent.md")]) == 2
        with open(out) as f:
            j = json.load(f)
        assert j["verdict"] == "continue" and j["criteria"]["a"]["owed"] == A5.split(", "), j
        assert "verdict: continue" in sink.getvalue() and "parse error" in sink.getvalue(), sink.getvalue()

    # the repository's own history: passes 2 to 11 parse and read continue, on Tier 1 and the owed lenses
    repo = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    lenses, rows, recs = load(os.path.join(repo, "docs", "adversarial-review.md"), os.path.join(repo, "docs", "reviews"))
    assert len(lenses) == 11 and lenses[0] == FRESH, lenses
    assert set(range(2, 12)) <= set(recs), sorted(recs)
    for n in range(2, 12):
        assert recs[n]["lenses"] and recs[n]["t1"] > 0, (n, recs[n])
    assert recs[7]["read"] == (5, 9) and recs[2]["read"] is None and recs[11]["fell"] == 0.07, (recs[7], recs[11])
    real = decide(lenses, rows, recs, current=11)
    assert real["verdict"] == "continue", real["lines"]
    assert "Tier 1 findings: pass 10 has 2 Tier 1, pass 11 has 3 Tier 1" in real["reason"], real["reason"]
    assert "the cycle owes 10 lenses" in real["reason"], real["reason"]
    # criterion 4 on the real prose: pass 2 not attempted, pass 3's "estimate 2, found 2" none left, pass 7's
    # "undefined for the tree" not computable, pass 10's "estimate 0 on both" zero, pass 11 not computable
    assert recs[2]["capture"]["kind"] == "not attempted" and recs[3]["capture"] == {"kind": "estimate", "remaining": 0.0}
    assert recs[7]["capture"]["kind"] == "not computable" and recs[10]["capture"]["remaining"] == 0.0
    assert recs[11]["capture"]["kind"] == "not computable" and real["criteria"]["e"]["passes"] == [9, 10, 11]
    # the latest pass must parse and be judged; its verdict is not pinned, since a later record may rightly
    # read stop (converged, or the ceiling) and this self-test must not turn main red on it
    latest = decide(lenses, rows, recs)
    assert latest["verdict"] in ("continue", "stop") and latest["pass"] == max(rows), latest
    print("stop_check selftest: PASS (converged, Tier 1, repeated lenses, coverage header/status rows/unknown, "
          "each (b) check alone, read-caught over overall, late-survivor before and from pass 12, ceiling and "
          "--extended-through, budget, blocking decision, criterion 4 on an estimate and over three passes, the thresholds on "
          "the exact fractions and the coverage count (#1288), parse errors, CLI exits and JSON; the repository's "
          "passes 2 to 11)")
    print("  real history: " + real["lines"][-1])


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    if argv == ["--selftest"]:
        selftest()
        return 0
    ap = argparse.ArgumentParser(prog="stop_check.py", description=__doc__.split("\n\n")[1],
                                 formatter_class=argparse.RawDescriptionHelpFormatter, epilog=__doc__.split("\n\n", 2)[2])
    ap.add_argument("--history", required=True, help="docs/adversarial-review.md")
    ap.add_argument("--records", required=True, help="docs/reviews")
    ap.add_argument("--pass", dest="pass_n", type=int, help="the pass just finished (default: the table's last)")
    ap.add_argument("--budget-used", help="agent tokens this loop has used (9790000, 9.79M, 500k)")
    ap.add_argument("--decisions", help="the loop's decisions_queue.md")
    ap.add_argument("--extended-through", type=int, help="the last pass the user has authorised (default 13)")
    ap.add_argument("--json", help="write the criteria and the verdict here")
    try:
        a = ap.parse_args(argv)
    except SystemExit as exc:
        return 2 if exc.code else 0
    try:
        budget = None if a.budget_used is None else parse_tokens(a.budget_used)
        dec = None
        if a.decisions is not None:
            try:
                dec = decisions_queue.parse(decisions_queue.load(a.decisions))
            except decisions_queue.QueueError as exc:
                raise ParseError(f"decisions queue: {exc}")
        lenses, rows, recs = load(a.history, a.records)
        v = decide(lenses, rows, recs, a.pass_n, budget, dec, a.extended_through)
    except ParseError as exc:
        print(f"stop_check: parse error: {exc}", file=sys.stderr)
        return 2
    print("\n".join(v["lines"]))
    if a.json:
        with open(a.json, "w") as f:
            json.dump({k: v[k] for k in ("pass", "previous", "criteria", "verdict", "reason")}, f, indent=2)
            f.write("\n")
    return 0 if v["verdict"] == "continue" else 1


if __name__ == "__main__":
    sys.exit(main())
