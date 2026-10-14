#!/usr/bin/env python3
"""Compute a review pass's metrics and write its record (docs/adversarial-review.md, "Metrics" and
"Pass record"). Recall and precision are computed and printed BEFORE the count of findings, and the
record puts them on the same line, so the count is never read alone.

Inputs:
  --sealed      plant_seeds.py's sealed record (the seeds, their lenses and tiers)
  --classified  classify_claims.py's output (every claim with its class and attributed seed)
  --verdicts    the verifier's verdicts, one per candidate:
                {"F3-07": {"verdict": "finding", "tier": 1, "root_cause": "session TimeZone grid"},
                 "F2-01": {"verdict": "fell", "reason": "documented; reference.md#retain"},
                 "F1-04": {"verdict": "known_open", "issue": 439}}
  --budget-units, --budget  a number (agent-hours or tokens) for cost per finding, and its text form
  --ages        optional: a JSON object mapping a claim id to its AGE, printed in the findings table:
                {"F3-07": "old", "F5-02": "young", "F1-04": "young (on #1152's surface)"}
  --coverage    optional: coverage.py --out's file ({"threshold": t, "rows": [{"finder", "coverage", "ledger",
                ...}]}, the final run after any re-runs); writes the header line
                `coverage: <min over finders> (<n> of <m> finders at or above 0.90)` right after the lenses
                line, which stop_check.py reads for the full-lens-cycle criterion. A finder with no ledger
                counts at 0.00. Without it the record has no coverage line and stop_check.py reads coverage as
                unknown.

Definitions used here:
  recall     = seeds attributed to at least one claim / K; when plant_seeds.py --suite measured every seed,
               also split into suite-caught (the pgTAP suite on the seeded tree fails: a finder that ran the
               tests found it) and read-caught (it does not: only reading finds it), each hits / count. Pass 4's
               9/9 was all suite-caught and measured that the suite was run; the read-caught half is the
               recall the stopping criteria read from pass 5 on.
  precision  = (findings + seed hits + verified known-and-open re-finds) / claims that had a reproduction.
               A correctly reported seed is a true report, and so is a reproduced defect that an earlier
               pass's issue already names (pass 7 made that explicit: 23 of 69 claims re-found nine open
               issues and the strict figure read 0.64 while only 3 claims had fallen); a hypothesis (no
               reproduction) is not a claim. The strict figure, (findings + seed hits) / claims, is kept
               beside it as the novelty rate.
  fell rate  = claims that fell in verification / claims that had a reproduction: the reaching alarm the
               stopping criteria read (at most 0.3), since a fallen claim is the one shape a reviewer
               pushed for defects produces when there are none.
  unverified = candidates with no verdict, or with a verdict string that is none of finding, fell, known_open:
               in the denominators (they had a reproduction) and in no numerator, listed under the record's
               "Unverified (not findings)", never under "Fell in verification". The CLI refuses a verdicts file
               holding an unknown string (exit 2), so a typo such as "known-open" never reaches a record.
  exact      = the record's `exact: recall a/b, precision c/d, strict e/f, fell rate g/h` line, right after the
               summary line: the four figures as fractions. stop_check.py judges the thresholds on it, since a
               two-decimal 0.70 may be 16/23 = 0.696.
  late-survivor recall = the hits among the seeds sealed with "late_survivor" (plant_seeds.py: the catalogue's
               LATE_SURVIVORS, Tier 1 and 2 defects that survived five or more passes with their units read)
               over their number; printed on the summary line after a semicolon inside the recall's
               parentheses, e.g. "seeds K=9, recall 1.00 (suite-caught 3/3, read-caught 6/6; late-survivor 3/3)"
               or "(late-survivor 2/3)" without the suite split, and read by its own stopping row, which a pass
               that planted none reads as NOT met. The catalogue's seeds are found at 0.9 to 1.0; this figure
               measures the shapes that survive.
  cost       = budget-units / findings, and / Tier 1 findings

Age and lens. The findings table is `| tier | age | lens | finding | issue | fix PR |`, so the per-loop
convergence report can split Tier 1 into old and young. The lens is the claim's own "lens" field. The age comes
from --ages: OLD means the defect survived earlier passes with its unit marked read in their coverage ledgers;
YOUNG means it sits on code newer than the previous pass's pin. The coordinator writes the ages file from the
coverage ledgers of the earlier passes (and the pins' diff), at least for every Tier 1 and 2 finding; a finding
it does not name gets a blank cell.

Seed interactions. A seed that changes global state (its sealed record's optional "side_effects") can make
another claim reproducible for the wrong reason: in pass 2 five candidates reached their defect only
because a seed had frozen the monolith. The record's "Seeds" section prints each seed's side effects, and
its notes carry "Seed interactions to check": every candidate whose pristine run failed only its liveness
checks, beside the side effects of every seed, so the coordinator can say which claim leaned on which.

Usage:
  pass_metrics.py --pass N --date YYYY-MM-DD --pinned <sha> --release <tag> --sealed s.json
                  --classified c.json --verdicts v.json --budget "8 finders x 2h, 6h wall" --budget-units 16
                  --lenses "fresh surface, concurrency" --previous-lenses "..." --out docs/reviews/YYYY-MM-DD.md
                  [--ages ages.json] [--coverage coverage.json]
  pass_metrics.py --selftest
"""
import argparse
import json
import sys

TIERS = (1, 2, 3, 4, 5)


def compute(sealed, classified, verdicts, budget_units=None, ages=None):
    ages = ages or {}
    seeds = sealed["seeds"]
    claims = [c for c in classified["claims"] if c.get("class") != "hypothesis"]
    hypotheses = [c for c in classified["claims"] if c.get("class") == "hypothesis"]
    seed_hits = [c for c in claims if c["class"] == "seed_hit"]
    candidates = [c for c in claims if c["class"] == "candidate"]
    hit_ids = {c.get("seed") for c in seed_hits if c.get("seed")}
    K = len(seeds)
    recall = (len([s for s in seeds if s["id"] in hit_ids]) / K) if K else None
    measured = [s for s in seeds if "suite_caught" in s]
    split = None
    if K and len(measured) == K:
        suite_ids = {s["id"] for s in seeds if s["suite_caught"]}
        read_ids = {s["id"] for s in seeds} - suite_ids
        split = {"suite_K": len(suite_ids), "suite_hit": len(suite_ids & hit_ids),
                 "read_K": len(read_ids), "read_hit": len(read_ids & hit_ids)}
        split["read_recall"] = (split["read_hit"] / split["read_K"]) if split["read_K"] else None
    late_ids = {s["id"] for s in seeds if s.get("late_survivor")}
    late_split = None
    if late_ids:
        late_split = {"K": len(late_ids), "hit": len(late_ids & hit_ids)}
        late_split["recall"] = late_split["hit"] / late_split["K"]

    # A candidate is a finding, fell or a known-and-open re-find only by the verifier's word for it. One with no
    # verdict, or with a verdict string that is none of those three (a "known-open" typo), was not verified: it
    # is counted unverified, never fell (README.md, "Verdicts"), and an unknown string is also listed so main()
    # refuses the verdicts file (#1289: both used to land in fell and raise the fell rate the criteria read).
    findings, fell, known, unknown = [], [], [], []
    unverified = [{**c, "verdict": None} for c in candidates if c["id"] not in verdicts]
    for c in candidates:
        v = verdicts.get(c["id"], {"verdict": "unverified"})
        bucket = {"finding": findings, "fell": fell, "known_open": known}.get(v.get("verdict"))
        if bucket is None:
            if c["id"] in verdicts:
                unverified.append({**c, "verdict": v})
                unknown.append({"id": c["id"], "verdict": v.get("verdict")})
            continue
        bucket.append({**c, "verdict": v})

    by_tier = {t: 0 for t in TIERS}
    for f in findings:
        t = int(f["verdict"].get("tier") or f.get("tier") or 0)
        if t in by_tier:
            by_tier[t] += 1
    root_causes = {f["verdict"].get("root_cause") for f in findings if f["verdict"].get("root_cause")}

    n_claims = len(claims)
    precision_strict = ((len(findings) + len(seed_hits)) / n_claims) if n_claims else None
    precision = ((len(findings) + len(seed_hits) + len(known)) / n_claims) if n_claims else None
    fell_rate = (len(fell) / n_claims) if n_claims else None
    known_ids = {k["id"] for k in known}
    per_finder = {}
    for c in claims:
        d = per_finder.setdefault(c["finder"], {"claims": 0, "true": 0, "strict": 0})
        d["claims"] += 1
        if c["class"] == "seed_hit" or any(f["id"] == c["id"] for f in findings):
            d["true"] += 1
            d["strict"] += 1
        elif c["id"] in known_ids:
            d["true"] += 1
    for d in per_finder.values():
        d["precision"] = d["true"] / d["claims"] if d["claims"] else None
        d["precision_strict"] = d["strict"] / d["claims"] if d["claims"] else None

    blind = [s for s in seeds if s["id"] not in hit_ids]
    hit_by = {}
    for c in seed_hits:
        if c.get("seed"):
            hit_by.setdefault(c["seed"], []).append(c["id"])
    seed_rows = [{"id": s["id"], "lens": s["lens"], "tier": s["tier"], "what": s.get("mutation") or s.get("patch"),
                  "hit_by": hit_by.get(s["id"], []), "side_effects": s.get("side_effects"),
                  "suite": s.get("suite_caught") if "suite_caught" in s else None,
                  "suite_skipped": s.get("suite_skipped"), "late_survivor": s.get("late_survivor")} for s in seeds]
    interaction_candidates = [{"id": c["id"], "finder": c["finder"], "tier": c.get("tier"),
                               "scenario": c.get("scenario", "")}
                              for c in candidates if (c.get("pristine") or {}).get("liveness_failed")]
    cost = cost_t1 = None
    if budget_units:
        cost = budget_units / len(findings) if findings else None
        cost_t1 = budget_units / by_tier[1] if by_tier[1] else None

    return {
        "K": K, "recall": recall, "claims": n_claims, "hypotheses": len(hypotheses),
        "seed_hits": len(seed_hits), "candidates": len(candidates), "findings": len(findings),
        "precision": precision, "precision_strict": precision_strict, "fell_rate": fell_rate,
        # the same four figures as the fractions they are, written into the record so stop_check.py judges the
        # thresholds on them and not on the two-decimal figures (#1288: 16/23 = 0.696 printed 0.70, read as met)
        "exact": {"recall": (len({s["id"] for s in seeds} & hit_ids), K),
                  "precision": (len(findings) + len(seed_hits) + len(known), n_claims),
                  "strict": (len(findings) + len(seed_hits), n_claims), "fell rate": (len(fell), n_claims)},
        "by_tier": by_tier, "root_causes": sorted(root_causes),
        "known_open": len(known), "fell": len(fell), "unverified": len(unverified),
        "cost_per_finding": cost, "cost_per_t1": cost_t1, "per_finder": per_finder,
        "blind_spots": [{"id": s["id"], "lens": s["lens"], "tier": s["tier"],
                         "what": s.get("mutation") or s.get("patch")} for s in blind],
        "finding_rows": [{"id": f["id"], "tier": int(f["verdict"].get("tier") or f.get("tier") or 0),
                          "scenario": f.get("scenario", ""), "issue": f["verdict"].get("issue"),
                          "age": ages.get(f["id"], ""), "lens": f.get("lens") or ""} for f in findings],
        "fell_rows": [{"id": f["id"], "reason": f["verdict"].get("reason", "")} for f in fell],
        "unverified_rows": [{"id": c["id"], "verdict": None if c["verdict"] is None else c["verdict"].get("verdict")}
                            for c in unverified],
        "unknown_verdicts": unknown,
        "known_rows": [{"id": f["id"], "issue": f["verdict"].get("issue")} for f in known],
        "hypothesis_rows": [{"id": h["id"], "finder": h["finder"], "scenario": h.get("scenario", "")} for h in hypotheses],
        "seed_rows": seed_rows, "interaction_candidates": interaction_candidates,
        "suite_split": split, "suite_unmeasured": K - len(measured), "late_survivor_split": late_split,
    }


def stopping_status(m):
    """This pass's half of the stopping criteria (the other half is the previous pass)."""
    rows = [
        ("zero Tier 1 findings", m["by_tier"][1] == 0),
        ("seed recall >= 0.8", m["recall"] is not None and m["recall"] >= 0.8),
        ("precision >= 0.7 (verified re-finds of open issues counted as true reports)",
         m["precision"] is not None and m["precision"] >= 0.7),
        ("fell rate <= 0.3", m["fell_rate"] is not None and m["fell_rate"] <= 0.3),
    ]
    if m.get("suite_split"):
        rr = m["suite_split"]["read_recall"]
        rows.insert(2, ("read-caught seed recall >= 0.8 (the seeds the suite does not catch; none planted reads as NOT met)",
                        rr is not None and rr >= 0.8))
    # always present, right after the read-caught row (or the seed recall row without the suite split): a pass
    # that planted none of the late-survivor set has not measured what survives, so that reads as NOT met
    ls = m.get("late_survivor_split")
    rows.insert(3 if m.get("suite_split") else 2, ("late-survivor seed recall >= 0.8 (none planted reads as NOT met)",
                                                   ls is not None and ls["recall"] >= 0.8))
    return rows


def md_cell(text):
    """A table cell: escape `_` and `|` so identifiers like _grid_next do not read as emphasis or a column
    break (pass 2's record failed markdownlint MD037 on exactly that)."""
    return (text or "").replace("|", "\\|").replace("_", "\\_")


def fmt(x, nd=2):
    return "n/a" if x is None else (f"{x:.{nd}f}" if isinstance(x, float) else str(x))


def split_text(m):
    """The recall split for the record's summary line: suite-caught / read-caught when --suite measured every
    seed, then the late-survivor hits over its members after a semicolon when any seed is one; nothing when
    neither applies. stop_check.py parses this spelling, so it is fixed."""
    s, ls = m.get("suite_split"), m.get("late_survivor_split")
    parts = []
    if s:
        parts.append(f"suite-caught {s['suite_hit']}/{s['suite_K']}, read-caught {s['read_hit']}/{s['read_K']}")
    if ls:
        parts.append(f"late-survivor {ls['hit']}/{ls['K']}")
    return f" ({'; '.join(parts)})" if parts else ""


def exact_line(m):
    """The record's `exact:` header line: recall, precision, strict precision and fell rate as the fractions
    they are (`n/a` over an empty denominator). stop_check.py judges the thresholds on these and not on the
    two-decimal figures of the summary line (#1288), and refuses a record whose fractions disagree with them."""
    return "exact: " + ", ".join(f"{k} {f'{n}/{d}' if d else 'n/a'}" for k, (n, d) in m["exact"].items())


COVERAGE_GATE = 0.90


def coverage_line(cov):
    """The record's coverage header line from coverage.py --out's JSON: the minimum over finders (a missing
    ledger scores 0.00, as coverage.py scores it) and how many finders reached the 0.90 gate the stopping
    criteria read, whatever threshold the coverage run itself used."""
    rows = cov.get("rows") if isinstance(cov, dict) else None
    if not rows or not all(isinstance(r, dict) and "finder" in r and "coverage" in r for r in rows):
        raise ValueError("--coverage must be coverage.py --out's JSON: {\"threshold\": t, \"rows\": [{\"finder\": ..., "
                         "\"coverage\": ...}, ...]} with at least one row")
    vals = [0.0 if r.get("ledger") == "missing" else float(r["coverage"]) for r in rows]
    at = sum(1 for v in vals if round(v, 3) >= COVERAGE_GATE)
    return f"coverage: {min(vals):.2f} ({at} of {len(vals)} finders at or above {COVERAGE_GATE:.2f})"


def record(m, a):
    t = m["by_tier"]
    lines = [
        f"# Review pass {a.pass_n}: {a.date}", "",
        f"pinned: `{a.pinned}` ({a.release}) | budget: {a.budget}",
        f"lenses: {a.lenses} | previous pass lenses: {a.previous_lenses}",
    ] + ([getattr(a, "coverage_line")] if getattr(a, "coverage_line", None) else []) + [
        f"seeds K={m['K']}, recall {fmt(m['recall'])}{split_text(m)}; claims {m['claims']}; findings {m['findings']}; "
        f"precision {fmt(m['precision'])} (strict {fmt(m['precision_strict'])}, fell rate {fmt(m['fell_rate'])})",
        exact_line(m),
        f"findings by tier: T1 {t[1]} T2 {t[2]} T3 {t[3]} T4 {t[4]} T5 {t[5]}",
        f"cost per finding: {fmt(m['cost_per_finding'], 1)}; per Tier 1 finding: {fmt(m['cost_per_t1'], 1)}",
        f"root causes: {len(m['root_causes'])} distinct verifier root-cause statements behind the findings"
        + (f"; grouped into {a.root_cause_groups} classes below" if a.root_cause_groups else "")
        + "; closed as a class: to be filled after the fix phase",
        f"known and open (re-found, unfixed from earlier passes): {m['known_open']}",
        f"capture-recapture (T1): {a.capture_recapture}",
        "blind spots (seeds missed, by lens): " + (", ".join(f"{b['id']} {b['what']} ({b['lens']}, T{b['tier']})" for b in m["blind_spots"]) or "none"),
        "",
        f"Per finder (claims, precision, strict): " + ", ".join(f"{k} ({v['claims']}, {fmt(v['precision'])}, {fmt(v['precision_strict'])})" for k, v in sorted(m["per_finder"].items())),
        f"Seed hits {m['seed_hits']}, candidates {m['candidates']}, fell {m['fell']}, unverified {m['unverified']}, hypotheses {m['hypotheses']}.",
        "", "## Findings", "", "| tier | age | lens | finding | issue | fix PR |", "|---|---|---|---|---|---|",
    ]
    for f in sorted(m["finding_rows"], key=lambda r: (r["tier"], r["id"])):
        issue = f"#{f['issue']}" if f["issue"] else ""
        lines.append(f"| {f['tier']} | {md_cell(f['age'])} | {md_cell(f['lens'])} | {f['id']}: {md_cell(f['scenario'])} | {issue} | |")
    lines += ["", "## Seeds", ""]
    for r in m["seed_rows"]:
        state = f"hit by {', '.join(r['hit_by'])}" if r["hit_by"] else "missed"
        effects = f"; side effects: {md_cell(r['side_effects'])}" if r["side_effects"] else ""
        suite = ""
        if r.get("suite") is not None:
            suite = ("; suite: caught by " + ", ".join(md_cell(f) for f in r["suite"])) if r["suite"] else "; suite: not caught (read-caught seed)"
            if r.get("suite_skipped"):
                suite += " (not run: " + ", ".join(md_cell(f) for f in r["suite_skipped"]) + ")"
        ls = r.get("late_survivor")
        late = f"; late survivor: #{ls['issue']}, {ls['passes_survived']} passes" if ls else ""
        lines.append(f"- {r['id']} {md_cell(r['what'])} ({r['lens']}, T{r['tier']}): {state}{effects}{suite}{late}")
    if not m["seed_rows"]:
        lines.append("none")
    lines += ["", "## Null results (by lens)", "", "(from the finders' null-results files)", "",
              "## Fell in verification", ""]
    lines += [f"- {r['id']}: {r['reason']}" for r in m["fell_rows"]] or ["none"]
    lines += ["", "## Unverified (not findings)", ""]
    lines += [f"- {r['id']}: " + ("no verdict" if r["verdict"] is None else
                                  f"verdict `{r['verdict']}` is none of `finding`, `fell`, `known_open`")
              for r in m["unverified_rows"]] or ["none"]
    lines += ["", "## Known and open", ""]
    lines += [f"- {r['id']}: #{r['issue']}" for r in m["known_rows"]] or ["none"]
    lines += ["", "## Hypotheses (not counted)", ""]
    lines += [f"- {r['id']} ({r['finder']}): {md_cell(r['scenario'])}" for r in m["hypothesis_rows"]] or ["none"]
    lines += ["", "## Stopping criteria status", "", "This pass's half; the criteria need the previous pass as well.", ""]
    lines += [f"- {name}: {'met' if ok else 'NOT met'}" for name, ok in stopping_status(m)]
    if getattr(a, "root_causes_file", None):
        with open(a.root_causes_file) as fh:
            lines += ["", "## Root causes", "", fh.read().rstrip("\n")]
    notes_file = getattr(a, "notes_file", None)
    if notes_file or m["interaction_candidates"]:
        lines += ["", "## Coordinator notes"]
    if notes_file:
        with open(notes_file) as fh:
            lines += ["", fh.read().rstrip("\n")]
    if m["interaction_candidates"]:
        lines += ["", "### Seed interactions to check", "",
                  "These candidates failed only their liveness checks on the pristine tree, so on the review tree "
                  "they may have reached their defect through another seed's side effect. For each, say which seed "
                  "it depended on, and file the verifier's rebuilt reproduction (`repro.verified.sql`), not the "
                  "finder's.", ""]
        lines += [f"- {c['id']} ({c['finder']}, T{c['tier']}): {md_cell(c['scenario'])}" for c in m["interaction_candidates"]]
        lines += ["", "Seed side effects:", ""]
        effects = [f"- {r['id']}: {md_cell(r['side_effects'])}" for r in m["seed_rows"] if r["side_effects"]]
        lines += effects or ["- none declared in the sealed record; check the seeds by hand"]
    return "\n".join(lines) + "\n"


def selftest_seed_interactions():
    """A seed's side_effects is printed in the seeds section, and every candidate whose pristine run
    failed only its liveness checks is listed under "Seed interactions to check" beside the side effects
    of every seed (pass 2: five candidates reached their defect only through another seed's effect)."""
    effect = "freezes the monolith: every table converted on the tree reads as frozen"
    sealed = {"seeds": [{"id": "S1", "lens": "time", "tier": 1, "mutation": "frontier_data_only", "side_effects": effect},
                        {"id": "S2", "lens": "boundary", "tier": 2, "patch": "novel.patch"},
                        {"id": "S3", "lens": "retain", "tier": 2, "patch": "tick.patch", "side_effects": "disables the tick"}]}
    classified = {"claims": [
        {"id": "F1-01", "finder": "F1", "class": "seed_hit", "seed": "S2", "tier": 2},
        {"id": "F2-04", "finder": "F2", "class": "candidate", "tier": 1, "scenario": "late rows",
         "review": {"fails": True}, "pristine": {"fails": False, "liveness_failed": True}},
        {"id": "F3-01", "finder": "F3", "class": "candidate", "tier": 2, "scenario": "real on both",
         "review": {"fails": True}, "pristine": {"fails": True}},
    ]}
    verdicts = {"F2-04": {"verdict": "finding", "tier": 1, "root_cause": "r"},
                "F3-01": {"verdict": "finding", "tier": 2, "root_cause": "q"}}
    m = compute(sealed, classified, verdicts)
    assert [c["id"] for c in m["interaction_candidates"]] == ["F2-04"], m["interaction_candidates"]

    class A:
        pass_n, date, pinned, release = 3, "2026-10-01", "abc", "0.7.0"
        budget, lenses, previous_lenses, capture_recapture = "", "time", "none", "not attempted"
        root_cause_groups, root_causes_file, notes_file = None, None, None
    rec = record(m, A)
    assert f"- S1 frontier\\_data\\_only (time, T1): missed; side effects: {effect}" in rec, rec
    assert "- S2 novel.patch (boundary, T2): hit by F1-01\n" in rec, rec
    head = rec.index("## Coordinator notes")
    sec = rec[rec.index("### Seed interactions to check", head):]
    assert "- F2-04 (F2, T1): late rows" in sec and "F3-01" not in sec, sec
    assert f"- S1: {effect}" in sec and "- S3: disables the tick" in sec and "- S2" not in sec, sec


def selftest_suite_split():
    """When every seed carries plant_seeds.py --suite's suite_caught, recall is reported split into
    suite-caught and read-caught, each seed's line says which files caught it, and the stopping status
    gains the read-caught row; when any seed is unmeasured nothing about the record changes."""
    sealed = {"seeds": [{"id": "S1", "lens": "time", "tier": 1, "mutation": "a", "suite_caught": ["tests/122_x_test.sql", "tests/149_y_test.sql"]},
                        {"id": "S2", "lens": "names", "tier": 2, "patch": "n.patch", "suite_caught": []},
                        {"id": "S3", "lens": "docs", "tier": 3, "patch": "d.patch", "suite_caught": [], "suite_skipped": ["tests/31_schedule_test.sql"]},
                        {"id": "S4", "lens": "upgrade", "tier": 1, "mutation": "u", "suite_caught": ["tests/9_z_test.sql"]}]}
    classified = {"claims": [{"id": "F1-01", "finder": "F1", "class": "seed_hit", "seed": "S1", "tier": 1},
                             {"id": "F2-01", "finder": "F2", "class": "seed_hit", "seed": "S2", "tier": 2},
                             {"id": "F2-02", "finder": "F2", "class": "seed_hit", "seed": "S4", "tier": 1}]}
    m = compute(sealed, classified, {})
    assert m["recall"] == 0.75 and m["suite_split"] == {"suite_K": 2, "suite_hit": 2, "read_K": 2, "read_hit": 1, "read_recall": 0.5}, m["suite_split"]
    assert m["suite_unmeasured"] == 0

    class A:
        pass_n, date, pinned, release = 5, "2026-10-01", "abc", "0.7.0"
        budget, lenses, previous_lenses, capture_recapture = "", "time", "none", "not attempted"
        root_cause_groups, root_causes_file, notes_file = None, None, None
    rec = record(m, A)
    assert "seeds K=4, recall 0.75 (suite-caught 2/2, read-caught 1/2); claims 3;" in rec, rec
    assert "- S1 a (time, T1): hit by F1-01; suite: caught by tests/122\\_x\\_test.sql, tests/149\\_y\\_test.sql\n" in rec, rec
    assert "- S2 n.patch (names, T2): hit by F2-01; suite: not caught (read-caught seed)\n" in rec, rec
    assert "- S3 d.patch (docs, T3): missed; suite: not caught (read-caught seed) (not run: tests/31\\_schedule\\_test.sql)\n" in rec, rec
    st = dict(stopping_status(m))
    assert st["seed recall >= 0.8"] is False and st["read-caught seed recall >= 0.8 (the seeds the suite does not catch; none planted reads as NOT met)"] is False, st
    assert [name for name, _ in stopping_status(m)][2].startswith("read-caught"), stopping_status(m)
    # the read-caught row reads NOT met when no read-caught seed was planted at all
    all_caught = {"seeds": [{"id": "S1", "lens": "t", "tier": 1, "mutation": "a", "suite_caught": ["tests/1_test.sql"]}]}
    m2 = compute(all_caught, {"claims": [{"id": "F1-01", "finder": "F1", "class": "seed_hit", "seed": "S1", "tier": 1}]}, {})
    assert m2["recall"] == 1.0 and m2["suite_split"]["read_K"] == 0 and dict(stopping_status(m2))["seed recall >= 0.8"] is True
    assert [ok for name, ok in stopping_status(m2) if name.startswith("read-caught")] == [False]
    # one seed unmeasured: no split, no row, the summary line as before
    sealed["seeds"][1].pop("suite_caught")
    m3 = compute(sealed, classified, {})
    assert m3["suite_split"] is None and m3["suite_unmeasured"] == 1
    rec3 = record(m3, A)
    # the summary line carries no split and the stopping status no read-caught row; the seeds that WERE measured
    # still say what caught them, and the unmeasured one says nothing
    assert "seeds K=4, recall 0.75; claims 3;" in rec3 and "(suite-caught" not in rec3, rec3
    assert "- S2 n.patch (names, T2): hit by F2-01\n" in rec3 and "S1 a (time, T1): hit by F1-01; suite: caught by" in rec3, rec3
    assert len(stopping_status(m3)) == 5 and not any(n.startswith("read-caught") for n, _ in stopping_status(m3))


def selftest_late_survivor_and_age():
    """Seeds sealed with late_survivor get their own recall: on the summary line inside the parentheses after a
    semicolon (with and without the suite split), under compute()'s late_survivor_split, and as a stopping row
    right after the read-caught one that reads NOT met when none was planted. The findings table carries the
    age (--ages, by claim id) and the claim's lens."""
    late = {"issue": 1157, "passes_survived": 10}
    sealed = {"seeds": [{"id": "S1", "lens": "locks", "tier": 1, "mutation": "a", "suite_caught": [], "late_survivor": late},
                        {"id": "S2", "lens": "locks", "tier": 1, "mutation": "b", "suite_caught": ["tests/1_test.sql"],
                         "late_survivor": {"issue": 1158, "passes_survived": 10}},
                        {"id": "S3", "lens": "names", "tier": 2, "patch": "c.patch", "suite_caught": [],
                         "late_survivor": {"issue": 550, "passes_survived": 9}},
                        {"id": "S4", "lens": "time", "tier": 2, "patch": "d.patch", "suite_caught": []},
                        {"id": "S5", "lens": "time", "tier": 3, "patch": "e.patch", "suite_caught": ["tests/2_test.sql"]}]}
    classified = {"claims": [
        {"id": "F1-01", "finder": "F1", "class": "seed_hit", "seed": "S1", "tier": 1},
        {"id": "F1-02", "finder": "F1", "class": "seed_hit", "seed": "S3", "tier": 2},
        {"id": "F2-01", "finder": "F2", "class": "seed_hit", "seed": "S4", "tier": 2},
        {"id": "F2-02", "finder": "F2", "class": "seed_hit", "seed": "S5", "tier": 3},
        {"id": "F3-01", "finder": "F3", "class": "candidate", "tier": 1, "lens": "concurrency and locks",
         "scenario": "pending detach dropped"},
        {"id": "F3-02", "finder": "F3", "class": "candidate", "tier": 2, "lens": "fresh surface", "scenario": "new script"},
        {"id": "F4-01", "finder": "F4", "class": "candidate", "tier": 3, "scenario": "no lens, no age"},
    ]}
    verdicts = {"F3-01": {"verdict": "finding", "tier": 1, "issue": 1157},
                "F3-02": {"verdict": "finding", "tier": 2, "issue": 1159},
                "F4-01": {"verdict": "finding", "tier": 3}}
    ages = {"F3-01": "old", "F3-02": "young (on #1152's surface)"}
    m = compute(sealed, classified, verdicts, ages=ages)
    # a liveness witness for the split: the members are the three sealed as such, two of them hit, and the
    # suite split (which the late-survivor figure sits beside, not inside) is the usual one
    assert m["late_survivor_split"] == {"K": 3, "hit": 2, "recall": 2 / 3}, m["late_survivor_split"]
    assert m["suite_split"]["read_K"] == 3 and m["suite_split"]["read_hit"] == 3, m["suite_split"]

    class A:
        pass_n, date, pinned, release = 12, "2026-10-12", "abc", "0.7.0"
        budget, lenses, previous_lenses, capture_recapture = "", "locks", "none", "not attempted"
        root_cause_groups, root_causes_file, notes_file = None, None, None
    rec = record(m, A)
    assert "seeds K=5, recall 0.80 (suite-caught 1/2, read-caught 3/3; late-survivor 2/3); claims 7;" in rec, rec
    assert "| tier | age | lens | finding | issue | fix PR |\n|---|---|---|---|---|---|\n" in rec, rec
    assert "| 1 | old | concurrency and locks | F3-01: pending detach dropped | #1157 | |\n" in rec, rec
    assert "| 2 | young (on #1152's surface) | fresh surface | F3-02: new script | #1159 | |\n" in rec, rec
    assert "|  |  | F4-01: no lens, no age |  | |\n" in rec, rec
    assert "- S1 a (locks, T1): hit by F1-01; suite: not caught (read-caught seed); late survivor: #1157, 10 passes\n" in rec, rec
    assert "- S4 d.patch (time, T2): hit by F2-01; suite: not caught (read-caught seed)\n" in rec, rec
    names = [n for n, _ in stopping_status(m)]
    row = "late-survivor seed recall >= 0.8 (none planted reads as NOT met)"
    assert names[names.index(row) - 1].startswith("read-caught seed recall"), names
    assert dict(stopping_status(m))[row] is False                       # 2/3 < 0.8
    # without the suite split the figure stands alone in the parentheses, and the row follows the seed recall
    for s in sealed["seeds"]:
        s.pop("suite_caught")
    m2 = compute(sealed, classified, verdicts)
    assert "seeds K=5, recall 0.80 (late-survivor 2/3); claims 7;" in record(m2, A), record(m2, A)
    names2 = [n for n, _ in stopping_status(m2)]
    assert names2[names2.index(row) - 1] == "seed recall >= 0.8", names2
    # every member hit: met; no ages file: the age column is blank, the lens still there
    hit_all = {"claims": classified["claims"] + [{"id": "F5-01", "finder": "F5", "class": "seed_hit", "seed": "S2", "tier": 1}]}
    m3 = compute(sealed, hit_all, verdicts)
    assert m3["late_survivor_split"]["recall"] == 1.0 and dict(stopping_status(m3))[row] is True
    assert "| 1 |  | concurrency and locks | F3-01: pending detach dropped | #1157 | |\n" in record(m3, A)
    # none planted: no split, no mention on the summary line, and the row reads NOT met
    for s in sealed["seeds"]:
        s.pop("late_survivor", None)
    m4 = compute(sealed, classified, verdicts)
    assert m4["late_survivor_split"] is None and "late-survivor" not in record(m4, A).split("\n")[4], record(m4, A)
    assert dict(stopping_status(m4))[row] is False


def selftest_coverage_line(m, A):
    """--coverage: the line is the minimum over finders and the count at the 0.90 gate, sits right after the
    lenses line, is absent without the file, and is the spelling stop_check.py reads."""
    cov = {"threshold": 0.9, "rows": [
        {"finder": "F1", "kind": "sql", "units": 40, "read": 40, "coverage": 1.0, "ledger": "ok"},
        {"finder": "F2", "kind": "files", "units": 50, "read": 43, "coverage": 0.86, "ledger": "ok"},
        {"finder": "F3", "kind": "sql", "units": 10, "read": 9, "coverage": 0.9, "ledger": "ok"}]}
    line = coverage_line(cov)
    assert line == "coverage: 0.86 (2 of 3 finders at or above 0.90)", line
    cov["rows"].append({"finder": "F4", "kind": "sql", "units": 5, "read": 0, "coverage": 0.0, "ledger": "missing"})
    assert coverage_line(cov) == "coverage: 0.00 (2 of 4 finders at or above 0.90)", coverage_line(cov)
    for bad in ({}, {"rows": []}, {"rows": [{"finder": "F1"}]}, []):
        try:
            coverage_line(bad)
            raise AssertionError(f"accepted a coverage file without rows: {bad!r}")
        except ValueError:
            pass

    class B(A):
        coverage_line = "coverage: 0.93 (13 of 13 finders at or above 0.90)"
    lines = record(m, B).split("\n")
    assert lines[3].startswith("lenses: ") and lines[4] == B.coverage_line and lines[5].startswith("seeds K="), lines[:7]
    assert not any(ln.startswith("coverage: ") for ln in record(m, A).split("\n")), "no --coverage, no line"
    # the other side of the contract: stop_check.py reads this exact line as the minimum, figure first
    import os
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import re as _re
    import stop_check
    mm = _re.match(r"^coverage: " + stop_check.NUM + r"\b", line)
    assert mm and stop_check.num(mm.group(1)) == 0.86, line


def selftest_exact_and_unverified():
    """#1289: a candidate with no verdict and one with a verdict string compute() does not know are unverified,
    never fell: not in the fell rate, not under "Fell in verification", listed under "Unverified (not findings)",
    and the CLI refuses the unknown string while it accepts the same file without it. #1288: the record's
    `exact:` line carries the figures as fractions, and stop_check.py reads them in place of the rounded ones."""
    import os
    import subprocess
    import tempfile
    sealed = {"seeds": [{"id": "S1", "lens": "time", "tier": 1, "mutation": "a"},
                        {"id": "S2", "lens": "time", "tier": 2, "mutation": "b"}]}
    classified = {"claims": [
        {"id": "F1-01", "finder": "F1", "class": "seed_hit", "seed": "S1", "tier": 1},
        {"id": "F1-02", "finder": "F1", "class": "candidate", "tier": 3, "scenario": "a real finding"},
        {"id": "F1-03", "finder": "F1", "class": "candidate", "tier": 3, "scenario": "fell for cause"},
        {"id": "F1-04", "finder": "F1", "class": "candidate", "tier": 2, "scenario": "not yet verified"},
        {"id": "F2-01", "finder": "F2", "class": "candidate", "tier": 2, "scenario": "a misspelt verdict"}]}
    verdicts = {"F1-02": {"verdict": "finding", "tier": 3, "root_cause": "r"},
                "F1-03": {"verdict": "fell", "reason": "documented"},
                "F2-01": {"verdict": "known-open", "issue": 439}}
    m = compute(sealed, classified, verdicts)
    assert [r["id"] for r in m["fell_rows"]] == ["F1-03"] and m["fell"] == 1, m["fell_rows"]
    assert m["unverified_rows"] == [{"id": "F1-04", "verdict": None}, {"id": "F2-01", "verdict": "known-open"}], m
    assert m["unverified"] == 2 and m["unknown_verdicts"] == [{"id": "F2-01", "verdict": "known-open"}], m
    assert m["claims"] == 5 and abs(m["fell_rate"] - 1 / 5) < 1e-9 and m["known_open"] == 0, m
    assert m["exact"] == {"recall": (1, 2), "precision": (2, 5), "strict": (2, 5), "fell rate": (1, 5)}, m["exact"]

    class A:
        pass_n, date, pinned, release = 13, "2026-10-14", "abc", "0.7.0"
        budget, lenses, previous_lenses, capture_recapture = "", "time", "none", "not attempted"
        root_cause_groups, root_causes_file, notes_file = None, None, None
    rec = record(m, A)
    lines = rec.split("\n")
    assert lines[4].startswith("seeds K=2, recall 0.50;") and "precision 0.40 (strict 0.40, fell rate 0.20)" in lines[4], lines[:6]
    assert lines[5] == "exact: recall 1/2, precision 2/5, strict 2/5, fell rate 1/5", lines[5]
    fell_sec = rec.split("## Fell in verification\n", 1)[1].split("\n## ", 1)[0]
    assert fell_sec.strip() == "- F1-03: documented", fell_sec
    unv_sec = rec.split("## Unverified (not findings)\n", 1)[1].split("\n## ", 1)[0]
    assert unv_sec.strip() == ("- F1-04: no verdict\n- F2-01: verdict `known-open` is none of `finding`, `fell`, "
                               "`known_open`"), unv_sec
    # no claims at all: every fraction reads n/a
    empty = compute({"seeds": []}, {"claims": []}, {})
    assert exact_line(empty) == "exact: recall n/a, precision n/a, strict n/a, fell rate n/a", exact_line(empty)
    # the CLI: the unknown string is refused (exit 2) and no record is written; corrected, the record is written
    with tempfile.TemporaryDirectory() as d:
        files = {}
        for name, obj in (("sealed", sealed), ("classified", classified), ("verdicts", verdicts)):
            files[name] = os.path.join(d, name + ".json")
            with open(files[name], "w") as fh:
                json.dump(obj, fh)
        out = os.path.join(d, "record.md")
        cmd = [sys.executable, os.path.abspath(__file__), "--sealed", files["sealed"], "--classified", files["classified"],
               "--verdicts", files["verdicts"], "--pass", "13", "--date", "2026-10-14", "--pinned", "abc", "--out", out]
        r = subprocess.run(cmd, capture_output=True, text=True)
        assert r.returncode == 2 and "F2-01 'known-open'" in r.stderr and not os.path.exists(out), (r.returncode, r.stderr)
        verdicts["F2-01"] = {"verdict": "known_open", "issue": 439}
        with open(files["verdicts"], "w") as fh:
            json.dump(verdicts, fh)
        r = subprocess.run(cmd, capture_output=True, text=True)
        assert r.returncode == 0 and os.path.exists(out), (r.returncode, r.stderr)
        with open(out) as fh:
            assert "exact: recall 1/2, precision 3/5, strict 2/5, fell rate 1/5\n" in fh.read()


def selftest():
    sealed = {"seeds": [{"id": "S1", "lens": "time", "tier": 1, "mutation": "grid_session_timezone"},
                        {"id": "S2", "lens": "concurrency", "tier": 1, "mutation": "untransmute_no_recheck_under_lock"}]}
    classified = {"claims": [
        {"id": "F1-01", "finder": "F1", "class": "seed_hit", "seed": "S1", "tier": 1},
        {"id": "F1-02", "finder": "F1", "class": "candidate", "tier": 1, "scenario": "rows lost"},
        {"id": "F1-03", "finder": "F1", "class": "candidate", "tier": 3, "scenario": "documented"},
        {"id": "F2-01", "finder": "F2", "class": "not_reproduced", "tier": 2},
        {"id": "F2-02", "finder": "F2", "class": "candidate", "tier": 2},
        {"id": "F2-03", "finder": "F2", "class": "hypothesis", "error": "no reproduction file"},
    ]}
    verdicts = {"F1-02": {"verdict": "finding", "tier": 1, "root_cause": "x", "issue": 500},
                "F1-03": {"verdict": "fell", "reason": "documented"},
                "F2-02": {"verdict": "known_open", "issue": 439}}
    m = compute(sealed, classified, verdicts, budget_units=16)
    assert m["K"] == 2 and m["recall"] == 0.5, m
    assert m["claims"] == 5 and m["hypotheses"] == 1
    assert m["findings"] == 1 and m["by_tier"][1] == 1
    assert abs(m["precision_strict"] - 2 / 5) < 1e-9   # one finding + one seed hit over five claims
    assert abs(m["precision"] - 3 / 5) < 1e-9          # ... plus the verified known-open re-find; the not_reproduced claim still counts
    assert abs(m["fell_rate"] - 1 / 5) < 1e-9
    assert m["known_open"] == 1 and m["fell"] == 1 and m["unverified"] == 0
    assert m["per_finder"]["F1"]["precision"] == 2 / 3 and m["per_finder"]["F1"]["precision_strict"] == 2 / 3
    assert m["per_finder"]["F2"]["precision"] == 1 / 2 and m["per_finder"]["F2"]["precision_strict"] == 0
    assert m["cost_per_finding"] == 16 and m["cost_per_t1"] == 16
    assert [b["id"] for b in m["blind_spots"]] == ["S2"]
    st = dict(stopping_status(m))
    assert st["zero Tier 1 findings"] is False and st["seed recall >= 0.8"] is False
    assert st["precision >= 0.7 (verified re-finds of open issues counted as true reports)"] is False   # 3 of 5
    assert st["fell rate <= 0.3"] is True

    class A:
        pass_n, date, pinned, release = 2, "2026-10-01", "c5a60df", "0.6.0+"
        budget, lenses, previous_lenses, capture_recapture = "2 x 1h", "time", "none", "not attempted"
        root_cause_groups, root_causes_file, notes_file = 1, None, None
    rec = record(m, A)
    assert "recall 0.50; claims 5; findings 1; precision 0.60 (strict 0.40, fell rate 0.20)" in rec, rec
    assert "Per finder (claims, precision, strict): F1 (3, 0.67, 0.67), F2 (2, 0.50, 0.00)" in rec, rec
    assert "| 1 |  |  | F1-02: rows lost | #500 | |" in rec
    assert md_cell("a _grid_next | b") == "a \\_grid\\_next \\| b"
    assert "S2 untransmute_no_recheck_under_lock (concurrency, T1)" in rec
    assert "root causes: 1 distinct verifier root-cause statements behind the findings; grouped into 1 classes below" in rec
    assert "- F2-02: #439" in rec and "- F2-03 (F2):" in rec
    # no seed declares side effects and no candidate leaned on its pristine liveness: no interaction section
    assert "Seed interactions to check" not in rec and "side effects" not in rec
    assert "## Seeds" in rec and "- S2 untransmute\\_no\\_recheck\\_under\\_lock (concurrency, T1): missed" in rec, rec
    selftest_seed_interactions()
    selftest_suite_split()
    selftest_late_survivor_and_age()
    selftest_coverage_line(m, A)
    selftest_exact_and_unverified()
    print("pass_metrics selftest: PASS")
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--sealed"); ap.add_argument("--classified"); ap.add_argument("--verdicts")
    ap.add_argument("--pass", dest="pass_n"); ap.add_argument("--date"); ap.add_argument("--pinned")
    ap.add_argument("--release", default=""); ap.add_argument("--budget", default="")
    ap.add_argument("--budget-units", type=float); ap.add_argument("--lenses", default="")
    ap.add_argument("--previous-lenses", default=""); ap.add_argument("--capture-recapture", default="not attempted")
    ap.add_argument("--root-causes", dest="root_causes_file", help="markdown file with the coordinator's root-cause grouping, appended as a section")
    ap.add_argument("--root-cause-groups", type=int, help="number of classes in that grouping, for the summary line")
    ap.add_argument("--notes", dest="notes_file", help="markdown file appended as 'Coordinator notes'")
    ap.add_argument("--ages", help="JSON file mapping a claim id to its age ('old', 'young' or a phrase) for the findings table")
    ap.add_argument("--coverage", help="coverage.py --out's JSON; writes the record's coverage header line")
    ap.add_argument("--out"); ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args()
    if a.selftest:
        return selftest()
    for k in ("sealed", "classified", "verdicts", "pass_n", "date", "pinned", "out"):
        if not getattr(a, k):
            ap.error(f"--{k.replace('_n', '').replace('_', '-')} is required")
    with open(a.sealed) as fh:
        sealed = json.load(fh)
    with open(a.classified) as fh:
        classified = json.load(fh)
    with open(a.verdicts) as fh:
        verdicts = json.load(fh)
    ages = {}
    if a.ages:
        with open(a.ages) as fh:
            ages = json.load(fh)
        if not isinstance(ages, dict) or not all(isinstance(v, str) for v in ages.values()):
            ap.error("--ages must hold one JSON object mapping a claim id to its age text")
    a.coverage_line = None
    if a.coverage:
        with open(a.coverage) as fh:
            try:
                a.coverage_line = coverage_line(json.load(fh))
            except ValueError as exc:
                ap.error(str(exc))
        print(a.coverage_line)
    else:
        print("WARNING: no --coverage, so the record has no coverage line and stop_check.py reads coverage as "
              "unknown (NOT met)", file=sys.stderr)
    m = compute(sealed, classified, verdicts, a.budget_units, ages=ages)
    if m["unknown_verdicts"]:
        ap.error("--verdicts holds a verdict that is none of finding, fell, known_open (a typo is not a fall, #1289): "
                 + ", ".join(f"{u['id']} {u['verdict']!r}" for u in m["unknown_verdicts"]))
    print(f"seeds K={m['K']}  recall {fmt(m['recall'])}{split_text(m)}  precision {fmt(m['precision'])} "
          f"(strict {fmt(m['precision_strict'])}, fell rate {fmt(m['fell_rate'])})   (read these first)")
    if not m["late_survivor_split"]:
        print("WARNING: no seed is sealed as a late survivor, so the late-survivor recall row reads NOT met; plant at "
              "least three from mutate.py --late-survivors next time", file=sys.stderr)
    if m["suite_unmeasured"]:
        print(f"WARNING: {m['suite_unmeasured']} seed(s) carry no suite_caught, so recall is not split into suite-caught / "
              "read-caught; run plant_seeds.py --suite before the hunt next time", file=sys.stderr)
    print(f"claims {m['claims']}  findings {m['findings']}  by tier {m['by_tier']}  unverified {m['unverified']}")
    for r in m["seed_rows"]:
        if r["side_effects"]:
            print(f"seed {r['id']} side effects: {r['side_effects']}")
    if m["interaction_candidates"]:
        print("seed interactions to check (pristine liveness failed): "
              + ", ".join(c["id"] for c in m["interaction_candidates"]))
    if m["unverified"]:
        print("WARNING: candidates without a verdict are not findings; run the verifier on them first", file=sys.stderr)
    with open(a.out, "w") as fh:
        fh.write(record(m, a))
    print(f"record written: {a.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
