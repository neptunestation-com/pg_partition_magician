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

Definitions used here:
  recall     = seeds attributed to at least one claim / K
  precision  = (findings + seed hits) / claims that had a reproduction. A correctly reported seed is a
               true report, so it counts for the finder; a hypothesis (no reproduction) is not a claim.
  cost       = budget-units / findings, and / Tier 1 findings

Seed interactions. A seed that changes global state (its sealed record's optional "side_effects") can make
another claim reproducible for the wrong reason: in pass 2 five candidates reached their defect only
because a seed had frozen the monolith. The record's "Seeds" section prints each seed's side effects, and
its notes carry "Seed interactions to check": every candidate whose pristine run failed only its liveness
checks, beside the side effects of every seed, so the coordinator can say which claim leaned on which.

Usage:
  pass_metrics.py --pass N --date YYYY-MM-DD --pinned <sha> --release <tag> --sealed s.json
                  --classified c.json --verdicts v.json --budget "8 finders x 2h, 6h wall" --budget-units 16
                  --lenses "fresh surface, concurrency" --previous-lenses "..." --out docs/reviews/YYYY-MM-DD.md
  pass_metrics.py --selftest
"""
import argparse
import json
import sys

TIERS = (1, 2, 3, 4, 5)


def compute(sealed, classified, verdicts, budget_units=None):
    seeds = sealed["seeds"]
    claims = [c for c in classified["claims"] if c.get("class") != "hypothesis"]
    hypotheses = [c for c in classified["claims"] if c.get("class") == "hypothesis"]
    seed_hits = [c for c in claims if c["class"] == "seed_hit"]
    candidates = [c for c in claims if c["class"] == "candidate"]
    hit_ids = {c.get("seed") for c in seed_hits if c.get("seed")}
    K = len(seeds)
    recall = (len([s for s in seeds if s["id"] in hit_ids]) / K) if K else None

    findings, fell, known = [], [], []
    for c in candidates:
        v = verdicts.get(c["id"], {"verdict": "unverified"})
        c = {**c, "verdict": v}
        {"finding": findings, "fell": fell, "known_open": known}.get(v["verdict"], fell).append(c)
    unverified = [c for c in candidates if c["id"] not in verdicts]

    by_tier = {t: 0 for t in TIERS}
    for f in findings:
        t = int(f["verdict"].get("tier") or f.get("tier") or 0)
        if t in by_tier:
            by_tier[t] += 1
    root_causes = {f["verdict"].get("root_cause") for f in findings if f["verdict"].get("root_cause")}

    n_claims = len(claims)
    precision = ((len(findings) + len(seed_hits)) / n_claims) if n_claims else None
    per_finder = {}
    for c in claims:
        d = per_finder.setdefault(c["finder"], {"claims": 0, "true": 0})
        d["claims"] += 1
        if c["class"] == "seed_hit" or any(f["id"] == c["id"] for f in findings):
            d["true"] += 1
    for d in per_finder.values():
        d["precision"] = d["true"] / d["claims"] if d["claims"] else None

    blind = [s for s in seeds if s["id"] not in hit_ids]
    hit_by = {}
    for c in seed_hits:
        if c.get("seed"):
            hit_by.setdefault(c["seed"], []).append(c["id"])
    seed_rows = [{"id": s["id"], "lens": s["lens"], "tier": s["tier"], "what": s.get("mutation") or s.get("patch"),
                  "hit_by": hit_by.get(s["id"], []), "side_effects": s.get("side_effects")} for s in seeds]
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
        "precision": precision, "by_tier": by_tier, "root_causes": sorted(root_causes),
        "known_open": len(known), "fell": len(fell), "unverified": len(unverified),
        "cost_per_finding": cost, "cost_per_t1": cost_t1, "per_finder": per_finder,
        "blind_spots": [{"id": s["id"], "lens": s["lens"], "tier": s["tier"],
                         "what": s.get("mutation") or s.get("patch")} for s in blind],
        "finding_rows": [{"id": f["id"], "tier": int(f["verdict"].get("tier") or f.get("tier") or 0),
                          "scenario": f.get("scenario", ""), "issue": f["verdict"].get("issue")} for f in findings],
        "fell_rows": [{"id": f["id"], "reason": f["verdict"].get("reason", "")} for f in fell],
        "known_rows": [{"id": f["id"], "issue": f["verdict"].get("issue")} for f in known],
        "hypothesis_rows": [{"id": h["id"], "finder": h["finder"], "scenario": h.get("scenario", "")} for h in hypotheses],
        "seed_rows": seed_rows, "interaction_candidates": interaction_candidates,
    }


def stopping_status(m):
    """This pass's half of the stopping criteria (the other half is the previous pass)."""
    rows = [
        ("zero Tier 1 findings", m["by_tier"][1] == 0),
        ("seed recall >= 0.8", m["recall"] is not None and m["recall"] >= 0.8),
        ("precision >= 0.7", m["precision"] is not None and m["precision"] >= 0.7),
    ]
    return rows


def md_cell(text):
    """A table cell: escape `_` and `|` so identifiers like _grid_next do not read as emphasis or a column
    break (pass 2's record failed markdownlint MD037 on exactly that)."""
    return (text or "").replace("|", "\\|").replace("_", "\\_")


def fmt(x, nd=2):
    return "n/a" if x is None else (f"{x:.{nd}f}" if isinstance(x, float) else str(x))


def record(m, a):
    t = m["by_tier"]
    lines = [
        f"# Review pass {a.pass_n}: {a.date}", "",
        f"pinned: `{a.pinned}` ({a.release}) | budget: {a.budget}",
        f"lenses: {a.lenses} | previous pass lenses: {a.previous_lenses}",
        f"seeds K={m['K']}, recall {fmt(m['recall'])}; claims {m['claims']}; findings {m['findings']}; precision {fmt(m['precision'])}",
        f"findings by tier: T1 {t[1]} T2 {t[2]} T3 {t[3]} T4 {t[4]} T5 {t[5]}",
        f"cost per finding: {fmt(m['cost_per_finding'], 1)}; per Tier 1 finding: {fmt(m['cost_per_t1'], 1)}",
        f"root causes: {len(m['root_causes'])} distinct verifier root-cause statements behind the findings"
        + (f"; grouped into {a.root_cause_groups} classes below" if a.root_cause_groups else "")
        + "; closed as a class: to be filled after the fix phase",
        f"known and open (re-found, unfixed from earlier passes): {m['known_open']}",
        f"capture-recapture (T1): {a.capture_recapture}",
        "blind spots (seeds missed, by lens): " + (", ".join(f"{b['id']} {b['what']} ({b['lens']}, T{b['tier']})" for b in m["blind_spots"]) or "none"),
        "",
        f"Per finder (claims, precision): " + ", ".join(f"{k} ({v['claims']}, {fmt(v['precision'])})" for k, v in sorted(m["per_finder"].items())),
        f"Seed hits {m['seed_hits']}, candidates {m['candidates']}, fell {m['fell']}, unverified {m['unverified']}, hypotheses {m['hypotheses']}.",
        "", "## Findings", "", "| tier | finding | issue | fix PR |", "|---|---|---|---|",
    ]
    for f in sorted(m["finding_rows"], key=lambda r: (r["tier"], r["id"])):
        issue = f"#{f['issue']}" if f["issue"] else ""
        lines.append(f"| {f['tier']} | {f['id']}: {md_cell(f['scenario'])} | {issue} | |")
    lines += ["", "## Seeds", ""]
    for r in m["seed_rows"]:
        state = f"hit by {', '.join(r['hit_by'])}" if r["hit_by"] else "missed"
        effects = f"; side effects: {md_cell(r['side_effects'])}" if r["side_effects"] else ""
        lines.append(f"- {r['id']} {md_cell(r['what'])} ({r['lens']}, T{r['tier']}): {state}{effects}")
    if not m["seed_rows"]:
        lines.append("none")
    lines += ["", "## Null results (by lens)", "", "(from the finders' null-results files)", "",
              "## Fell in verification", ""]
    lines += [f"- {r['id']}: {r['reason']}" for r in m["fell_rows"]] or ["none"]
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
    assert abs(m["precision"] - 2 / 5) < 1e-9          # one finding + one seed hit over five claims
    assert m["known_open"] == 1 and m["fell"] == 1 and m["unverified"] == 0
    assert m["per_finder"]["F1"]["precision"] == 2 / 3 and m["per_finder"]["F2"]["precision"] == 0
    assert m["cost_per_finding"] == 16 and m["cost_per_t1"] == 16
    assert [b["id"] for b in m["blind_spots"]] == ["S2"]
    st = dict(stopping_status(m))
    assert st["zero Tier 1 findings"] is False and st["seed recall >= 0.8"] is False

    class A:
        pass_n, date, pinned, release = 2, "2026-10-01", "c5a60df", "0.6.0+"
        budget, lenses, previous_lenses, capture_recapture = "2 x 1h", "time", "none", "not attempted"
        root_cause_groups, root_causes_file, notes_file = 1, None, None
    rec = record(m, A)
    assert "recall 0.50; claims 5; findings 1; precision 0.40" in rec, rec
    assert "| 1 | F1-02: rows lost | #500 | |" in rec
    assert md_cell("a _grid_next | b") == "a \\_grid\\_next \\| b"
    assert "S2 untransmute_no_recheck_under_lock (concurrency, T1)" in rec
    assert "root causes: 1 distinct verifier root-cause statements behind the findings; grouped into 1 classes below" in rec
    assert "- F2-02: #439" in rec and "- F2-03 (F2):" in rec
    # no seed declares side effects and no candidate leaned on its pristine liveness: no interaction section
    assert "Seed interactions to check" not in rec and "side effects" not in rec
    assert "## Seeds" in rec and "- S2 untransmute\\_no\\_recheck\\_under\\_lock (concurrency, T1): missed" in rec, rec
    selftest_seed_interactions()
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
    m = compute(sealed, classified, verdicts, a.budget_units)
    print(f"seeds K={m['K']}  recall {fmt(m['recall'])}  precision {fmt(m['precision'])}   (read these first)")
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
