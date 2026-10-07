#!/usr/bin/env python3
"""pr_classify.py --claims <dir> --base <tree> --head <tree> --out <json>
                  [--review <tree>] [--mutants-dir <dir>] [--sealed <json>] [--acceptance ACC]
                  [--container pgpm_test-15] [--archive-container ...] [--timescale-container ...] [--keep-dbs]
   pr_classify.py --selftest

The mechanical half of per-PR adversarial verification (docs/adversarial-review.md, "Per-PR verification").
A review pass runs each reproduction against two trees (the seeded review tree and the pristine commit);
a pull request has up to four, and the question each answers is different:

  base     the PR's merge base: the tree WITHOUT the change
  head     the PR's head: the tree WITH the change
  review   head plus the seed the coordinator planted (what the finder was shown); defaults to head
  mutants  one tree per NEW mutation of the PR (<mutants-dir>/<name>/), the head with that mutation alone
           applied: the defect the PR claims to fix, put back; two mutations that edit the same lines
           cannot be applied in sequence (#1052's pair), so each gets its own tree and the acceptance
           holds when ANY of them makes the issue's reproduction fail

Every claim under <claims>/<finder>/<id>/ (the format in scripts/review/README.md; `classify_claims.py`'s
loader, reproduction contract and harness are reused unchanged) is run against base, head and review, and a
claim of the ACCEPTANCE finder (default directory name `ACC`: the issue's verified reproductions, which the
PR claims to turn green) against the mutant too. Classes, from where the reproduction fails:

  seed_hit        fails on review and not on head (the base may fail too: the seed is usually the PR's own
                  new mutation, which puts back the defect the base had): the finder found the seed
                  (attributed through --sealed, nearest)
  regression      fails on head and not on base: the PR introduced it. Blocks landing once verified.
  pre_existing    fails on head and on base: a defect in the PR's surface the PR did not cause; a review
                  pass's "candidate". A verifier rules on it; Tier 1 or 2 blocks landing, lower tiers are filed.
  fixed           fails on base and not on head: the PR fixes it. For an acceptance claim this is the
                  expected class; for a finder's claim it is a defect the PR happens to close.
  not_reproduced  fails nowhere.
  invalid_repro   the reproduction's own LIVENESS/GUARD/fixture checks failed on the review tree (it never
                  reached the defect on the tree the finder reviewed), or it carries no `LIVENESS:` at all.
  not_run         a tree could not be installed in the claim's container; hypothesis and invalid_claim as
                  in classify_claims.py.

Two readings that need a note rather than a class: a base run that failed only its liveness checks does
not make a head failure a regression (the base run never reached the defect: `pre_existing`, "verifier must
rebuild"), and a head run that failed only its liveness checks while base fails the defect is `fixed` with
the note that the fix refuses the fixture's premise (pass 9's F5-05: a verifier must say whether the refusal
is the behaviour the issue asked for). An acceptance claim also records `acceptance`:
`{"fails_on_base", "passes_on_head", "mutant_restores": {name: bool}, "any_restores"}`; `any_restores` is None
when no mutant tree was given, and False when NO new mutation of the PR makes the issue's reproduction fail,
which means the mutations put back some defect but not the one the issue describes, so the guard they
certify is not a guard for this fix. A reproduction that fails on every tree with the SAME last error line
(a missing extension, a fixture that cannot load) gets a note: it probably never ran, and its verifier
reads the tail before anything else.
"""
import argparse
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from classify_claims import HARNESS_DEFAULTS, Harness, load_claims, near_seeds, summary as _summary  # noqa: E402

TAGS = {"base": "b", "head": "h", "review": "r"}
CLASSES = ("regression", "pre_existing", "fixed", "seed_hit", "not_reproduced", "invalid_repro", "not_run",
           "hypothesis", "invalid_claim")


def pr_class(runs):
    """The class from the runs ({'base': {...}, 'head': {...}, 'review': {...}}), each a classify_claims.py
    runner result: fails True/False/None, liveness_failed True when only premise checks failed."""
    b, h = runs["base"], runs["head"]
    rv = runs.get("review") or h
    if any(r.get("fails") is None for r in (b, h, rv)):
        return "not_run", None
    if rv.get("liveness_failed"):
        return "invalid_repro", "the reproduction's own LIVENESS/GUARD/fixture checks failed on the tree the finder reviewed, so it never reached the defect"
    H, B, R = bool(h["fails"]), bool(b["fails"]), bool(rv["fails"])
    if "review" in runs and R and not H:
        # the finder's tree fails and the real head does not: the finder found the seed, whatever the base
        # does. The base usually fails too, because the seed of choice is the PR's own new mutation, which
        # puts back exactly the defect the base had (the trial's first two PRs read as `fixed` before this).
        return "seed_hit", None
    if H and B:
        return "pre_existing", None
    if H and not B:
        if b.get("liveness_failed"):
            return "pre_existing", "the base run failed only its liveness/guard checks, so it never reached the defect there; the verifier must rebuild the setup before calling this a regression"
        return "regression", None
    if B and not H:
        if h.get("liveness_failed"):
            return "fixed", "the head run failed only its liveness/guard checks: the fix refuses the fixture's premise; a verifier must say whether that refusal is the behaviour the issue asked for"
        return "fixed", None
    return "not_reproduced", None


TAP_LINE = re.compile(r"^\s*(?:not )?ok\b", re.M)


def same_last_error(runs):
    """The last ERROR line when every run failed with the same one AND none of them printed a single
    assertion result (`ok` / `not ok`): the reproduction died before its first check (a missing extension,
    a fixture that cannot load). A defect whose own error is the same on every tree, after the liveness
    checks passed, is a pre-existing defect and is not flagged (#1053's upgrade-path claim)."""
    if len(runs) < 2 or not all(r.get("fails") for r in runs.values()):
        return None
    if any(TAP_LINE.search(r.get("tail") or "") for r in runs.values()):
        return None
    lasts = set()
    for r in runs.values():
        errs = [ln for ln in (r.get("tail") or "").splitlines() if "ERROR" in ln]
        lasts.add(errs[-1].split("ERROR", 1)[1].strip() if errs else None)
    return lasts.pop() if len(lasts) == 1 and None not in lasts else None


def run_all(claims, trees, runner, seeds=(), acceptance="ACC"):
    out = []
    for c in claims:
        rec = {k: c.get(k) for k in ("id", "finder", "tier", "file", "line", "lens", "scenario", "repro")}
        rec["repro_used"] = c.get("repro_used") or c.get("repro")
        if c.get("invalid_claim"):
            rec.update({"class": "invalid_claim", "error": c["invalid_claim"]}); out.append(rec); continue
        if c.get("error"):
            rec.update({"class": "hypothesis", "error": c["error"]}); out.append(rec); continue
        if c.get("invalid"):
            rec.update({"class": "invalid_repro", "error": c["invalid"]}); out.append(rec); continue
        is_acc = c.get("finder") == acceptance
        runs = {}
        # the review tree is the finder's: an acceptance claim is judged on base, head and mutant only (on a
        # seeded tree whose seed is the PR's own mutation the issue's reproduction fails, which is the seed
        # doing its job, not a class for the acceptance claim; #1049's read as seed_hit before this)
        for name in ("base", "head") + (() if is_acc else ("review",)):
            if trees.get(name):
                runs[name] = runner(trees[name], c, TAGS[name])
        mutants = trees.get("mutants") or {}
        if is_acc:
            for name, path in sorted(mutants.items()):
                runs["mutant:" + name] = runner(path, c, "m_" + name)
        cls, note = pr_class(runs)
        rec.update({"runs": runs, "class": cls})
        if note:
            rec["note"] = note
        same = same_last_error(runs)
        if same and not note:
            rec["note"] = f"every tree fails with the same last error line ({same[:120]}); the reproduction may never have run (a missing extension, a fixture that cannot load): read the tail first"
        if cls == "seed_hit":
            near = near_seeds(c, seeds) if seeds else []
            rec["seed"] = near[0] if near else None
            if not near:
                rec["note"] = "seed hit with no seed near this file:line (or no --sealed); check the claim's location"
        if is_acc:
            restores = {}
            starved = []
            for name in sorted(mutants):
                m = runs["mutant:" + name]
                restores[name] = bool(m.get("fails")) if m.get("fails") is not None else None
                if m.get("liveness_failed"):
                    starved.append(name)
            known = [v for v in restores.values() if v is not None]
            rec["acceptance"] = {
                "fails_on_base": bool(runs["base"].get("fails")) if runs["base"].get("fails") is not None else None,
                "passes_on_head": (runs["head"].get("fails") is False and not runs["head"].get("liveness_failed"))
                                   if runs["head"].get("fails") is not None else None,
                "mutant_restores": restores,
                "any_restores": (any(known) if known else None),
            }
            if starved:
                rec["acceptance"]["note"] = "mutant run failed only its liveness checks (the mutation starves the fixture rather than restoring the defect): " + ", ".join(starved)
        out.append(rec)
    return out


def summary(results, acceptance="ACC"):
    counts = {}
    for r in results:
        counts[r["class"]] = counts.get(r["class"], 0) + 1
    lines = ["class           n", "--------------  --"]
    for k in CLASSES:
        if k in counts:
            lines.append(f"{k:<15} {counts[k]:>2}")
    for r in results:
        if r.get("acceptance"):
            a = r["acceptance"]
            mr = ", ".join(f"{k}={v}" for k, v in a["mutant_restores"].items()) or "no mutant tree"
            lines.append(f"  {r['id']} (acceptance): fails on base {a['fails_on_base']}, passes on head {a['passes_on_head']}, "
                         f"mutant restores: {mr} (any: {a['any_restores']})" + (f"  ({a['note']})" if a.get("note") else ""))
    for r in results:
        if r.get("note") and r["class"] != "seed_hit":
            lines.append(f"  {r['id']}: {r['note']}")
    for r in results:
        if r["class"] == "seed_hit":
            lines.append(f"  {r['id']}: seed {r.get('seed') or '?'}")
        if r["class"] in ("regression", "pre_existing") and r["finder"] != acceptance:
            lines.append(f"  {r['id']}: {r['class']} (tier {r.get('tier')}), a verifier rules on it")
        if r["class"] in ("invalid_repro", "not_run", "invalid_claim") and r.get("error"):
            lines.append(f"  {r['id']}: {r['error']}")
    return "\n".join(lines)


def selftest():
    F, P = {"fails": True}, {"fails": False}
    L = {"fails": False, "liveness_failed": True}
    assert pr_class({"base": P, "head": F}) == ("regression", None)
    assert pr_class({"base": F, "head": F}) == ("pre_existing", None)
    assert pr_class({"base": F, "head": P}) == ("fixed", None)
    assert pr_class({"base": P, "head": P}) == ("not_reproduced", None)
    assert pr_class({"base": P, "head": P, "review": F}) == ("seed_hit", None)
    assert pr_class({"base": F, "head": P, "review": F}) == ("seed_hit", None)   # the seed is the PR's own mutation
    assert pr_class({"base": F, "head": P, "review": P}) == ("fixed", None)
    assert pr_class({"base": F, "head": F, "review": F}) == ("pre_existing", None)
    assert pr_class({"base": {"fails": None}, "head": F}) == ("not_run", None)
    assert pr_class({"base": P, "head": P, "review": L})[0] == "invalid_repro"
    # a base run that never reached the defect does not make a head failure a regression
    cls, note = pr_class({"base": L, "head": F}); assert cls == "pre_existing" and "rebuild" in note, (cls, note)
    # the fix refusing the fixture's premise reads as fixed, flagged
    cls, note = pr_class({"base": F, "head": L, "review": P}); assert cls == "fixed" and "refuses" in note, (cls, note)

    import tempfile
    with tempfile.TemporaryDirectory() as d:
        claims = os.path.join(d, "claims")
        def mk(finder, cid, body="select 1; -- LIVENESS: here"):
            p = os.path.join(claims, finder, cid); os.makedirs(p)
            json.dump({"tier": 1, "file": "pgpm_core/install.sql", "line": 10, "lens": "fresh surface",
                       "scenario": cid, "repro": "repro.sql"}, open(os.path.join(p, "claim.json"), "w"))
            open(os.path.join(p, "repro.sql"), "w").write(body)
        for cid in ("ACC-01", "ACC-02"):
            mk("ACC", cid)
        for cid in ("P1-01", "P1-02", "P1-03", "P1-04"):
            mk("P1", cid)
        mk("P1", "P1-05", "select 1;")   # no LIVENESS: invalid
        E = {"fails": True, "exit": 3, "tail": "psql:<stdin>:12: ERROR:  function plan(integer) does not exist"}
        D = {"fails": True, "exit": 3, "tail": "ok 1 - LIVENESS: prepared\nnot ok 4 - write after the rename\npsql:<stdin>:40: ERROR:  relation x does not exist"}
        mk("P1", "P1-06"); mk("P1", "P1-07")
        table = {  # (claim, tree) -> result
            ("ACC-01", "base"): F, ("ACC-01", "head"): P, ("ACC-01", "review"): P, ("ACC-01", "m_a"): F, ("ACC-01", "m_b"): P,
            ("ACC-02", "base"): F, ("ACC-02", "head"): P, ("ACC-02", "review"): P, ("ACC-02", "m_a"): P, ("ACC-02", "m_b"): P,   # both restore a cousin
            ("P1-06", "base"): E, ("P1-06", "head"): E, ("P1-06", "review"): E,     # never ran
            ("P1-07", "base"): D, ("P1-07", "head"): D, ("P1-07", "review"): D,     # the defect's own error, after a liveness check
            ("P1-01", "base"): P, ("P1-01", "head"): F, ("P1-01", "review"): F,     # regression
            ("P1-02", "base"): F, ("P1-02", "head"): F, ("P1-02", "review"): F,     # pre-existing
            ("P1-03", "base"): P, ("P1-03", "head"): P, ("P1-03", "review"): F,     # seed hit
            ("P1-04", "base"): P, ("P1-04", "head"): P, ("P1-04", "review"): P,     # nothing
        }
        seen = []
        def fake(tree, c, tag):
            seen.append((c["id"], os.path.basename(tree), tag))
            return dict(table[(c["id"], os.path.basename(tree))])
        trees = {k: os.path.join(d, k) for k in ("base", "head", "review")}
        trees["mutants"] = {"a": os.path.join(d, "m_a"), "b": os.path.join(d, "m_b")}
        seeds = [{"id": "S1", "file": "pgpm_core/install.sql", "lines": [12]}]
        res = run_all(load_claims(claims), trees, fake, seeds)
        by = {r["id"]: r for r in res}
        assert by["ACC-01"]["class"] == "fixed" and by["ACC-01"]["acceptance"] == {"fails_on_base": True, "passes_on_head": True, "mutant_restores": {"a": True, "b": False}, "any_restores": True}, by["ACC-01"]
        assert by["ACC-02"]["acceptance"]["any_restores"] is False, by["ACC-02"]
        assert by["P1-06"]["class"] == "pre_existing" and "same last error" in by["P1-06"]["note"], by["P1-06"]
        assert by["P1-07"]["class"] == "pre_existing" and not by["P1-07"].get("note"), by["P1-07"]
        assert by["P1-01"]["class"] == "regression" and by["P1-02"]["class"] == "pre_existing"
        assert by["P1-03"]["class"] == "seed_hit" and by["P1-03"]["seed"] == "S1", by["P1-03"]
        assert by["P1-04"]["class"] == "not_reproduced" and by["P1-05"]["class"] == "invalid_repro"
        # the mutant tree is run for acceptance claims only; the invalid claim is never run
        assert all(not t.startswith("m_") for cid, t, _ in seen if cid.startswith("P1")), seen
        assert not any(cid == "P1-05" for cid, _, _ in seen)
        assert {t for cid, t, _ in seen if cid == "ACC-01"} == {"base", "head", "m_a", "m_b"}   # never the finder's tree
        text = summary(res)
        assert "regression       1" in text and "a=True, b=False (any: True)" in text and "seed S1" in text, text
        # without a review tree, head stands in for it
        res2 = run_all(load_claims(claims, only="P1-03"), {"base": trees["base"], "head": trees["head"]}, fake)
        assert res2[0]["class"] == "not_reproduced"
    print("pr_classify selftest: PASS (regression, pre-existing, fixed, seed hit, liveness notes, acceptance with mutant, invalid repro)")


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--claims"); ap.add_argument("--base"); ap.add_argument("--head")
    ap.add_argument("--review", help="head plus the seed, the tree the finder was shown (default: head)")
    ap.add_argument("--mutants-dir", help="directory of mutant trees, one per new mutation (<dir>/<name>/), run for the acceptance claims")
    ap.add_argument("--sealed", help="plant_seeds.py's sealed record, to attribute a seed hit")
    ap.add_argument("--acceptance", default="ACC", help="the finder directory holding the issue's reproductions (default ACC)")
    ap.add_argument("--only"); ap.add_argument("--out")
    ap.add_argument("--container", default=HARNESS_DEFAULTS["core"])
    ap.add_argument("--archive-container", default=HARNESS_DEFAULTS["archive"])
    ap.add_argument("--timescale-container", default=HARNESS_DEFAULTS["timescale"])
    ap.add_argument("--keep-dbs", action="store_true"); ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args(argv)
    if a.selftest:
        selftest(); return 0
    if not (a.claims and a.base and a.head and a.out):
        ap.error("--claims, --base, --head and --out are required (or --selftest)")
    seeds = json.load(open(a.sealed))["seeds"] if a.sealed else []
    claims = load_claims(a.claims, a.only)
    if not claims:
        print("pr_classify: no claims found", file=sys.stderr); return 1
    trees = {"base": os.path.abspath(a.base), "head": os.path.abspath(a.head),
             "review": os.path.abspath(a.review) if a.review else None, "mutants": {}}
    if a.mutants_dir:
        for name in sorted(os.listdir(a.mutants_dir)):
            path = os.path.join(a.mutants_dir, name)
            if os.path.isdir(path) and os.path.isfile(os.path.join(path, "pgpm_core", "install.sql")):
                trees["mutants"][os.path.abspath(path) and name] = os.path.abspath(path)
    h = Harness(a.container, keep=a.keep_dbs, archive=a.archive_container, timescale=a.timescale_container)
    results = run_all(claims, trees, h.run, seeds, a.acceptance)
    json.dump({"trees": trees, "acceptance": a.acceptance, "claims": results}, open(a.out, "w"), indent=2)
    print(summary(results, a.acceptance))
    print(f"written: {a.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
