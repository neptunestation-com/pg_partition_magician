#!/usr/bin/env python3
"""pr_comment.py --classified <pr_classified.json> --pr <n> --head <sha> --base <sha> --out <file>
                 [--verdicts <json>] [--coverage <json>] [--surface <json>] [--sealed <json>]
                 [--budget "<text>"] [--repo owner/name] [--post]
   pr_comment.py --selftest

Render the verification comment for a pull request from the mechanical output (pr_classify.py), the
verifiers' verdicts and the coverage score, decide whether the PR may land, and with --post post it with
`gh pr comment`. Exit 0 when the PR may land, 1 when landing is BLOCKED, 2 on bad input.

The landing policy (docs/adversarial-review.md, "Per-PR verification"), applied here and nowhere else:
  blocked   an acceptance reproduction that does not fail on the base, or does not pass on the head, or
            that the PR's mutation does not make fail again (the mutation restores a cousin, so the guard
            it certifies is not this fix's); a verified `regression` of any tier; a verified `pre_existing`
            of Tier 1 or 2; a `regression` or `pre_existing` claim with no verdict yet (unverified is not
            clear); a closing-claim verdict of `partial`.
  clear     everything else. Verified Tier 3 to 5 pre-existing claims are listed for filing as issues and
            do not hold the PR; a missed seed is reported as the hunt's sensitivity being unwitnessed on
            this PR, and does not hold the PR either (it measures the hunt, not the change).

Verdicts are the verifier's JSON objects merged by claim id (scripts/review/README.md, "Verdicts"), with
one addition for the claims verifier: a `"closing"` entry, `{"verdict": "holds" | "partial", "reason": ...,
"claims": [ids]}`, saying whether the PR's own closing claim survived an attempt to reach the issue's
consequence by a path the diff does not cover.
"""
import argparse
import json
import os
import subprocess
import sys

BLOCKING_TIERS = (1, 2)


def tail(run, n=8):
    lines = [ln for ln in (run or {}).get("tail", "").splitlines() if ln.strip()]
    return "\n".join(lines[-n:])


def yn(v):
    return {True: "yes", False: "NO", None: "not run"}[v]


def decide(classified, verdicts, acceptance="ACC"):
    """(blocked: bool, reasons: [str], to_file: [claim ids]) from the classes and verdicts."""
    reasons, to_file = [], []
    for c in classified["claims"]:
        cid, cls = c["id"], c["class"]
        if c.get("acceptance"):
            a = c["acceptance"]
            if a["fails_on_base"] is not True:
                reasons.append(f"{cid}: the acceptance reproduction does not fail on the base, so it does not demonstrate the defect the PR says it fixes")
            if a["passes_on_head"] is not True:
                reasons.append(f"{cid}: the acceptance reproduction does not pass on the head" + (" (it failed only its liveness checks: the fix refuses the fixture)" if c.get("note") and "refuses" in c["note"] else ""))
            if a["mutant_restores"] is False:
                reasons.append(f"{cid}: the PR's mutation does not make the acceptance reproduction fail, so it restores a different defect and the guard it certifies is not this fix's")
            continue
        if cls not in ("regression", "pre_existing"):
            continue
        v = verdicts.get(cid)
        if v is None:
            reasons.append(f"{cid}: {cls} with no verdict yet (unverified is not clear)")
            continue
        if v.get("verdict") == "known_open":
            continue
        if v.get("verdict") != "finding":
            continue
        tier = v.get("tier") or c.get("tier")
        if cls == "regression":
            reasons.append(f"{cid}: verified regression (Tier {tier}): the PR introduced it")
        elif tier in BLOCKING_TIERS:
            reasons.append(f"{cid}: verified Tier {tier} defect in the PR's own surface")
        else:
            to_file.append(cid)
    closing = verdicts.get("closing")
    if closing and closing.get("verdict") == "partial":
        reasons.append("closing claim: partial (" + (closing.get("reason") or "see the claims below") + ")")
    return bool(reasons), reasons, to_file


def render(classified, verdicts, coverage, surface, sealed, pr, head, base, budget=""):
    blocked, reasons, to_file = decide(classified, verdicts, classified.get("acceptance", "ACC"))
    acc = [c for c in classified["claims"] if c.get("acceptance")]
    finds = [c for c in classified["claims"] if not c.get("acceptance")]
    out = [f"## Per-PR adversarial verification of `{head[:7]}` (base `{base[:7]}`)", ""]
    out.append(("**Landing: BLOCKED.** " if blocked else "**Landing: clear.** ") +
               "The method is `docs/adversarial-review.md`, \"Per-PR verification\"; every reproduction below ran in a fresh database "
               "against the base, the head and the seeded tree, the acceptance ones against the PR's own mutant too.")
    if reasons:
        out += ["", "Why:"] + [f"- {r}" for r in reasons]
    out += ["", "### Acceptance: the PR's own claims", ""]
    if acc:
        out += ["| reproduction | fails on base | passes on head | PR's mutation restores it | note |", "|---|---|---|---|---|"]
        for c in acc:
            a = c["acceptance"]
            out.append(f"| `{c['id']}` {c.get('scenario') or ''} | {yn(a['fails_on_base'])} | {yn(a['passes_on_head'])} | {yn(a['mutant_restores'])} | {a.get('note') or c.get('note') or ''} |")
    else:
        out.append("No acceptance reproduction was given (the PR does not close a verified issue).")
    closing = verdicts.get("closing")
    out += ["", "### Closing claim", ""]
    if closing:
        out.append(f"**{closing.get('verdict', '?')}**: {closing.get('reason', '')}")
    else:
        out.append("Not verified separately.")
    out += ["", "### Claims in the PR's surface", ""]
    if finds:
        out += ["| claim | tier | class | verdict | scenario |", "|---|---|---|---|---|"]
        for c in finds:
            v = verdicts.get(c["id"], {})
            vt = v.get("verdict", "unverified" if c["class"] in ("regression", "pre_existing") else "")
            if v.get("verdict") == "known_open":
                vt += f" (#{v.get('issue')})"
            if v.get("verdict") == "finding" and v.get("tier"):
                vt += f" T{v['tier']}"
            out.append(f"| `{c['id']}` | {c.get('tier') or ''} | {c['class']} | {vt} | {c.get('scenario') or ''} |")
        for c in finds:
            if c["class"] in ("regression", "pre_existing", "fixed"):
                r = c.get("runs", {})
                out += ["", f"<details><summary><code>{c['id']}</code> {c['class']}: tails</summary>", ""]
                for t in ("base", "head"):
                    if r.get(t):
                        out += [f"{t}:", "```", tail(r[t]), "```"]
                if verdicts.get(c["id"], {}).get("root_cause"):
                    out += [f"Verifier: {verdicts[c['id']]['root_cause']}"]
                out += ["", "</details>"]
    else:
        out.append("None.")
    if to_file:
        out += ["", "To file as issues (verified, below Tier 2, not held against this PR): " + ", ".join(f"`{x}`" for x in to_file)]
    out += ["", "### Seed witness", ""]
    seeds = (sealed or {}).get("seeds", [])
    if seeds:
        hits = {c.get("seed") for c in finds if c["class"] == "seed_hit"}
        for s in seeds:
            found = s["id"] in hits
            out.append(f"- {s['id']} in `{s.get('file')}`" + (f" ({s.get('mutation') or s.get('patch')})" if s.get("mutation") or s.get("patch") else "") +
                       (": **found**" if found else ": **MISSED**; the hunt's sensitivity is unwitnessed on this PR"))
    else:
        out.append("No seed was planted: the hunt's sensitivity on this PR is unwitnessed.")
    out += ["", "### Coverage and budget", ""]
    if coverage:
        for row in coverage.get("rows", []):
            out.append(f"- {row['finder']}: {row['read']} of {row['units']} units read ({row['coverage']:.2f})" +
                       (f"; unread: {', '.join(row['unread'][:8])}" if row.get("unread") else ""))
    if surface:
        out.append(f"- surface: {len(surface.get('files', []))} file(s), {len(surface.get('units', []))} unit(s) (touched units and their callers)")
    if budget:
        out.append(f"- budget: {budget}")
    out += ["", "🤖 Generated with [Claude Code](https://claude.com/claude-code)"]
    return blocked, "\n".join(out) + "\n"


def selftest():
    classified = {"acceptance": "ACC", "claims": [
        {"id": "ACC-01", "finder": "ACC", "class": "fixed", "scenario": "issue repro", "acceptance": {"fails_on_base": True, "passes_on_head": True, "mutant_restores": True}},
        {"id": "P1-01", "finder": "P1", "tier": 3, "class": "regression", "scenario": "a refusal lost", "runs": {"base": {"tail": "ok 1"}, "head": {"tail": "not ok 2 - refused"}}},
        {"id": "P1-02", "finder": "P1", "tier": 3, "class": "pre_existing", "scenario": "old contract gap", "runs": {}},
        {"id": "P1-03", "finder": "P1", "tier": 1, "class": "pre_existing", "scenario": "old data loss", "runs": {}},
        {"id": "P1-04", "finder": "P1", "tier": 2, "class": "seed_hit", "seed": "S1", "scenario": "seed"},
        {"id": "P1-05", "finder": "P1", "tier": 3, "class": "pre_existing", "scenario": "known", "runs": {}},
        {"id": "P1-06", "finder": "P1", "tier": 3, "class": "not_reproduced", "scenario": "nothing"},
    ]}
    verdicts = {"P1-01": {"verdict": "finding", "tier": 3, "root_cause": "x"},
                "P1-02": {"verdict": "finding", "tier": 3, "root_cause": "y"},
                "P1-03": {"verdict": "fell", "reason": "documented"},
                "P1-05": {"verdict": "known_open", "issue": 999},
                "closing": {"verdict": "holds", "reason": "every path covered"}}
    sealed = {"seeds": [{"id": "S1", "file": "pgpm_core/install.sql", "mutation": "m"}]}
    coverage = {"rows": [{"finder": "P1", "units": 10, "read": 10, "coverage": 1.0, "unread": []}]}
    blocked, reasons, to_file = decide(classified, verdicts)
    assert blocked and len(reasons) == 1 and "P1-01" in reasons[0] and "regression" in reasons[0], reasons
    assert to_file == ["P1-02"], to_file   # P1-03 fell, P1-05 is known and open
    b, text = render(classified, verdicts, coverage, {"files": [1], "units": [1, 2]}, sealed, 7, "abcdef0123", "0123456789", "finder 150k")
    assert b and "Landing: BLOCKED" in text and "S1 in `pgpm_core/install.sql` (m): **found**" in text and "known_open (#999)" in text, text
    assert "| `ACC-01` issue repro | yes | yes | yes |" in text and "10 of 10 units read (1.00)" in text
    # clear once the regression is withdrawn (it fell) and nothing else blocks
    verdicts["P1-01"] = {"verdict": "fell", "reason": "the refusal is documented"}
    blocked, reasons, to_file = decide(classified, verdicts)
    assert not blocked and reasons == [] and to_file == ["P1-02"], (blocked, reasons, to_file)
    # an unverified pre-existing claim blocks; a Tier 1 verified pre-existing blocks; a mutation that restores a cousin blocks
    del verdicts["P1-02"]
    assert decide(classified, verdicts)[1] == ["P1-02: pre_existing with no verdict yet (unverified is not clear)"]
    verdicts["P1-02"] = {"verdict": "finding", "tier": 3}
    verdicts["P1-03"] = {"verdict": "finding", "tier": 1, "root_cause": "z"}
    assert "P1-03: verified Tier 1 defect in the PR's own surface" in decide(classified, verdicts)[1]
    verdicts["P1-03"] = {"verdict": "fell", "reason": "r"}
    classified["claims"][0]["acceptance"]["mutant_restores"] = False
    r = decide(classified, verdicts)[1]
    assert len(r) == 1 and "restores a different defect" in r[0], r
    classified["claims"][0]["acceptance"]["mutant_restores"] = None   # no mutant tree: not held against the PR
    assert not decide(classified, verdicts)[0]
    verdicts["closing"] = {"verdict": "partial", "reason": "the sibling path", "claims": ["V-01"]}
    assert decide(classified, verdicts)[1] == ["closing claim: partial (the sibling path)"]
    # a missed seed is reported, not blocking
    verdicts["closing"]["verdict"] = "holds"
    classified["claims"][4]["class"] = "not_reproduced"
    b, text = render(classified, verdicts, coverage, None, sealed, 7, "abcdef0", "0123456", "")
    assert not b and "**MISSED**" in text, text
    print("pr_comment selftest: PASS (policy: acceptance, regression, tiers, unverified, known_open, closing claim, seed witness; rendering)")


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--classified"); ap.add_argument("--verdicts"); ap.add_argument("--coverage"); ap.add_argument("--surface")
    ap.add_argument("--sealed"); ap.add_argument("--pr"); ap.add_argument("--head"); ap.add_argument("--base")
    ap.add_argument("--budget", default=""); ap.add_argument("--out"); ap.add_argument("--repo"); ap.add_argument("--post", action="store_true")
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args(argv)
    if a.selftest:
        selftest(); return 0
    if not (a.classified and a.pr and a.head and a.base and a.out):
        ap.error("--classified, --pr, --head, --base and --out are required (or --selftest)")
    load = lambda p: json.load(open(p)) if p and os.path.exists(p) else None  # noqa: E731
    verdicts = load(a.verdicts) or {}
    blocked, text = render(load(a.classified), verdicts, load(a.coverage), load(a.surface), load(a.sealed), a.pr, a.head, a.base, a.budget)
    open(a.out, "w").write(text)
    print(text)
    if a.post:
        repo = a.repo or subprocess.run(["gh", "repo", "view", "--json", "nameWithOwner", "--jq", ".nameWithOwner"],
                                        capture_output=True, text=True).stdout.strip()
        subprocess.run(["gh", "pr", "comment", str(a.pr), "--repo", repo, "--body-file", a.out], check=True)
        print(f"posted on #{a.pr}")
    print("LANDING: " + ("BLOCKED" if blocked else "clear"))
    return 1 if blocked else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
