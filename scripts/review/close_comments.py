#!/usr/bin/env python3
"""close_comments.py --closure closure.json --filed filed.json --prs prs.tsv --sha <sha> --out <dir>
                     [--caveats caveats.json] [--repo owner/name] [--post]
close_comments.py --selftest

Turn the closure run (classify_claims.py's output for every reproduction re-run against the fixed
main) into one evidence comment per issue. Without --post the comments are written to <out>/<issue>.md
and a verdict per issue is printed for review; with --post each is posted with `gh issue comment`,
and an issue whose SOUND reproduction still fails is REOPENED, because its fix did not meet its
acceptance test.

Inputs:
  closure.json  classify_claims.py output ({"claims": [{id, class, review:{fails, tail}, ...}]})
  filed.json    file_issues.py output ([{id, title, tier, claims:[...], issue, url}])
  prs.tsv       one row per fix PR: issue<TAB>pr<TAB>test<TAB>guard<TAB>mutation (header row first;
                issue may be a range like 503-506 when one PR fixed a class). A cell that starts with
                "(" is a placeholder, not a path, and is rendered as words.
  caveats.json  {"claims": {"F2-04": "why this reproduction is known unsound"},
                 "issues": {"500": "a note for the whole issue"}}. A still-failing claim WITH a caveat is
                "expected" and does not reopen; one WITHOUT is a reopen. Every caveat must say why.

Verdict per issue: closed (every claim passes or is expected), REOPEN (a claim with no caveat still
fails), incomplete (a claim was not run or is missing: rerun before deciding).
"""
import argparse
import json
import os
import subprocess
import sys
import tempfile


def load_prs(path):
    prs = {}
    rows = open(path).read().splitlines()
    for line in rows[1:]:
        if not line.strip():
            continue
        issue, pr, test, guard, mutation = (line.split("\t") + ["", "", "", "", ""])[:5]
        span = [issue] if "-" not in issue else [str(n) for n in range(int(issue.split("-")[0]), int(issue.split("-")[1]) + 1)]
        for i in span:
            prs[int(i)] = dict(pr=int(pr), test=test, guard=guard, mutation=mutation)
    return prs


def cls(c):
    return c.get("class") or ("not_reproduced" if not c.get("review", {}).get("fails") else "candidate")


def tail(c, n=6):
    lines = [l for l in (c.get("review", {}).get("tail") or "").splitlines() if l.strip()]
    return "\n".join(lines[-n:])


def acceptance(pr):
    def part(label, v, tail=""):
        v = v.strip()
        if not v:
            return ""
        if v.startswith("("):
            return f"{label} {v.strip('()')}".strip()
        return f"{label} `{v}`{tail}".strip()
    if pr["guard"].strip().startswith("("):
        return "Acceptance in the tree: " + "; ".join(x for x in (part("", pr["test"]), part("", pr["guard"]), part("", pr["mutation"])) if x) + "."
    return (part("Acceptance in the tree:", pr["test"], "" if pr["test"].startswith("(") else " (pgTAP)")
            + ", " + part("guard", pr["guard"]) + ", " + part("mutation(s)", pr["mutation"])
            + " proven to be caught by `./test.sh discriminate`.")


def render(closure, filed, prs, caveats, sha):
    claims = {c["id"]: c for c in (closure["claims"] if isinstance(closure, dict) else closure)}
    cav_claims = caveats.get("claims", {})
    cav_issues = {int(k): v for k, v in caveats.get("issues", {}).items()}
    out = {}
    for g in filed:
        issue = g["issue"]
        pr = prs.get(issue, {})
        rows, reopen, incomplete, tails = [], False, False, []
        for cid in g["claims"]:
            c = claims.get(cid)
            if c is None:
                rows.append(f"| {cid} | not run | claim missing from the closure run |")
                incomplete = True
                continue
            k = cls(c)
            if k == "not_reproduced":
                rows.append(f"| {cid} | passes | reproduction no longer fails on `{sha}` |")
            elif k in ("candidate", "seed_hit"):
                if cid in cav_claims:
                    rows.append(f"| {cid} | still fails, expected | repro known unsound: {cav_claims[cid]} |")
                else:
                    rows.append(f"| {cid} | STILL FAILS | see tail below |")
                    reopen = True
                    tails.append((cid, tail(c)))
            elif k == "invalid_repro" and cid in cav_claims:
                rows.append(f"| {cid} | fixture step fails, expected | repro known unsound: {cav_claims[cid]} |")
            else:
                rows.append(f"| {cid} | {k} | {c.get('failure_kind') or ''} |")
                incomplete = True
        verdict = "REOPEN" if reopen else ("incomplete" if incomplete else "closed")
        body = [f"Closure evidence for the fix phase. Fix: PR #{pr.get('pr', '?')} (merged). Every reproduction attached to this issue was re-run against `main` at `{sha}` by `scripts/review/classify_claims.py` in a fresh database, the same harness that verified it on the pinned commit.",
                "", "| claim | result | note |", "|---|---|---|", *rows, ""]
        if pr:
            body += [acceptance(pr), ""]
        if issue in cav_issues:
            body += [f"Note: {cav_issues[issue]}", ""]
        if reopen:
            body += ["A reproduction with no known caveat still fails, so this issue is reopened for review:", ""]
            for cid, t in tails:
                body += [f"`{cid}` tail:", "```", t, "```", ""]
        out[issue] = (verdict, "\n".join(body), pr.get("pr"))
    return out


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument("--closure", required=True)
    ap.add_argument("--filed", required=True)
    ap.add_argument("--prs", required=True)
    ap.add_argument("--sha", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--caveats")
    ap.add_argument("--repo")
    ap.add_argument("--post", action="store_true")
    a = ap.parse_args(argv)
    caveats = json.load(open(a.caveats)) if a.caveats else {}
    result = render(json.load(open(a.closure)), json.load(open(a.filed)), load_prs(a.prs), caveats, a.sha)
    os.makedirs(a.out, exist_ok=True)
    repo = a.repo or subprocess.run(["gh", "repo", "view", "--json", "nameWithOwner", "--jq", ".nameWithOwner"],
                                    capture_output=True, text=True).stdout.strip()
    for issue, (verdict, body, pr) in sorted(result.items()):
        path = os.path.join(a.out, f"{issue}.md")
        open(path, "w").write(body)
        print(f"#{issue}\t{verdict}\tPR #{pr}")
        if a.post:
            subprocess.run(["gh", "issue", "comment", str(issue), "--repo", repo, "--body-file", path], check=True)
            if verdict == "REOPEN":
                subprocess.run(["gh", "issue", "reopen", str(issue), "--repo", repo], check=True)


def selftest():
    closure = {"claims": [
        {"id": "F1-01", "class": "not_reproduced", "review": {"fails": False}},
        {"id": "F1-02", "class": "candidate", "review": {"fails": True, "tail": "ok 1\nnot ok 2 - rows by identity\n# Failed test 2"}},
        {"id": "F2-01", "class": "candidate", "review": {"fails": True, "tail": "not ok 1 - LIVENESS: frozen"}},
        {"id": "F2-02", "class": "invalid_repro", "review": {"fails": True}},
        {"id": "F3-01", "class": "not_reproduced", "review": {"fails": False}},
    ]}
    filed = [{"id": "RC1", "title": "t1", "tier": 1, "claims": ["F1-01", "F1-02"], "issue": 901},
             {"id": "RC2", "title": "t2", "tier": 2, "claims": ["F2-01", "F2-02"], "issue": 902},
             {"id": "RC3", "title": "t3", "tier": 3, "claims": ["F3-01", "F3-09"], "issue": 903},
             {"id": "RC4", "title": "t4", "tier": 2, "claims": ["F3-01"], "issue": 904}]
    with tempfile.TemporaryDirectory() as d:
        p = os.path.join(d, "prs.tsv")
        open(p, "w").write("issue\tpr\ttest\tguard\tmutation\n901\t11\ttests/124_a_test.sql\tbench/a.sh\tm_a\n902-903\t12\t(bench guard only)\tbench/b.sh\tm_b\n904\t13\tscripts/x.sh\t(lint job)\t(selftest re-breaks)\n")
        prs = load_prs(p)
    caveats = {"claims": {"F2-01": "fixture reached the defect only through a planted seed", "F2-02": "liveness step fails on every tree"},
               "issues": {"902": "part B is the acceptance test"}}
    r = render(closure, filed, prs, caveats, "abc1234")
    assert r[901][0] == "REOPEN" and "`F1-02` tail:" in r[901][1] and "not ok 2 - rows by identity" in r[901][1], r[901]
    assert r[902][0] == "closed" and "still fails, expected" in r[902][1] and "fixture step fails, expected" in r[902][1] and "Note: part B" in r[902][1], r[902]
    assert r[903][0] == "incomplete" and "claim missing" in r[903][1], r[903]
    assert r[904][0] == "closed" and r[904][1].count("Acceptance in the tree: `scripts/x.sh`; lint job; selftest re-breaks.") == 1, r[904][1]
    assert "bench guard only, guard `bench/b.sh`" in r[902][1], r[902][1]
    assert prs[903]["pr"] == 12, prs
    # a still-failing claim with NO caveat must never read as expected
    r2 = render(closure, filed, prs, {}, "abc1234")
    assert r2[902][0] == "REOPEN", r2[902][0]
    print("close_comments selftest: PASS (closed / REOPEN / incomplete verdicts, caveats, PR ranges, placeholders)")


if __name__ == "__main__":
    if len(sys.argv) == 2 and sys.argv[1] == "--selftest":
        selftest()
    else:
        main(sys.argv[1:])
