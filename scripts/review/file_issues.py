#!/usr/bin/env python3
"""Render one GitHub issue per root-cause group of a review pass, and optionally file them
(docs/adversarial-review.md, "A pass, step by step", step 10; the /review-pass skill's "File, fix, close").

Inputs:
  --groups    groups.json, the coordinator's root-cause grouping:
              [{"id": "RC1", "title": "grid arithmetic reads the session TimeZone", "tier": 1,
                "claims": ["F3-07", "F5-02"]}, ...]
  --claims    the claims tree, <dir>/<finder>/<claim-id>/claim.json plus its reproduction
  --verdicts  the merged verdicts (every grouped claim must be a "finding")
  --pinned    the pinned commit the reproductions fail on
  --pass      the pass number, for the title suffix "(pass N RCk)"

For each group it writes <out>/<group id>.md: a first line `title: <title> (pass N <id>)`, then the body:
the tier, one section per claim (finder, file:line, lens, scenario, the verifier's root cause) with the
claim's reproduction inline, and the acceptance paragraph. The reproduction is the verifier's rebuilt one
(repro.verified.sql or .sh) when the claim directory holds it, chosen by the same rule classify_claims.py
uses, and the section says so: in pass 2 five issues were filed with the finders' reproductions, which only
reached their defect through another seed's side effect, and the fixers had to write their own acceptance.

With --post it files them with `gh issue create`, Tier 1 first (then by group order), and writes
<out>/filed.json ([{id, title, tier, claims, issue, url}]) after each issue, so a failure part way through
leaves an accurate record. It refuses to post when filed.json already exists, so a re-run cannot file twice.

Usage:
  file_issues.py --groups g.json --claims <dir> --verdicts v.json --pinned <sha> --pass N --out <dir>
                 [--post] [--repo neptunestation-com/pg_partition_magician] [--label bug]
  file_issues.py --selftest
"""
import argparse
import json
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from classify_claims import VERIFIED, load_claims  # noqa: E402  (one rule for which reproduction counts)

DEFAULT_REPO = "neptunestation-com/pg_partition_magician"


def ordered(groups):
    """Tier 1 first; within a tier, the coordinator's order."""
    return [g for _i, g in sorted(enumerate(groups), key=lambda ig: (int(ig[1]["tier"]), ig[0]))]


def fence(text):
    """A backtick fence longer than any backtick run inside the reproduction, so it cannot close early."""
    longest = run = 0
    for ch in text:
        run = run + 1 if ch == "`" else 0
        longest = max(longest, run)
    return "`" * max(3, longest + 1)


def check(groups, claims, verdicts):
    """Refuse a grouping that names an unknown claim, a claim without a reproduction, or a non-finding."""
    for g in groups:
        for k in ("id", "title", "tier", "claims"):
            if k not in g:
                raise SystemExit(f"file_issues: group {g.get('id', '?')} lacks {k!r}")
        for cid in g["claims"]:
            c = claims.get(cid)
            if c is None:
                raise SystemExit(f"file_issues: group {g['id']} names {cid}, which is not in the claims tree")
            if not c.get("repro_used"):
                raise SystemExit(f"file_issues: {cid} has no reproduction; a hypothesis is never filed")
            v = verdicts.get(cid, {}).get("verdict")
            if v != "finding":
                raise SystemExit(f"file_issues: {cid} has verdict {v!r}; only a finding is filed")


def claim_section(c, verdict):
    used = c["repro_used"]
    with open(os.path.join(c["dir"], used)) as fh:
        text = fh.read()
    lang = "sql" if used.endswith(".sql") else "bash"
    if used in VERIFIED:
        note = (f"Reproduction: `{used}`, the verifier's rebuilt reproduction. It supersedes the finder's "
                f"`{c.get('repro')}`, which the verifier had to change before it proved the defect.")
    else:
        note = f"Reproduction: `{used}`, the finder's, run unchanged by the verifier."
    f = fence(text)
    return [
        f"## {c['id']}", "",
        f"- finder: {c['finder']}",
        f"- location: `{c.get('file')}:{c.get('line')}`",
        f"- lens: {c.get('lens', '')}",
        f"- tier: {verdict.get('tier', c.get('tier'))}",
        f"- scenario: {c.get('scenario', '')}",
        f"- root cause (verifier): {verdict.get('root_cause', '')}",
        "", note, "",
        f"{f}{lang}", text.rstrip("\n"), f, "",
    ]


def render_group(group, claims, verdicts, pinned, pass_n):
    """(title, text) for one group; text's first line is the title line."""
    title = f"{group['title']} (pass {pass_n} {group['id']})"
    lines = [f"title: {title}", "",
             f"Tier: {group['tier']}", "",
             f"Found in adversarial review pass {pass_n} at `{pinned}`, root-cause group {group['id']}: "
             + ", ".join(group["claims"]) + ".", ""]
    for cid in group["claims"]:
        lines += claim_section(claims[cid], verdicts[cid])
    lines += [f"Acceptance: the reproduction(s) above fail on {pinned} and must pass on the fixing commit; the "
              "fix carries a bench/ guard and a bench/mutations entry proven by ./test.sh discriminate."]
    return title, "\n".join(lines) + "\n"


def render_all(groups, claims, verdicts, pinned, pass_n, out):
    check(groups, claims, verdicts)
    os.makedirs(out, exist_ok=True)
    rendered = []
    for g in ordered(groups):
        title, text = render_group(g, claims, verdicts, pinned, pass_n)
        path = os.path.join(out, f"{g['id']}.md")
        with open(path, "w") as fh:
            fh.write(text)
        rendered.append({"id": g["id"], "title": title, "tier": int(g["tier"]), "claims": list(g["claims"]),
                         "path": path, "verified": sum(claims[c]["repro_used"] in VERIFIED for c in g["claims"])})
    return rendered


def post(rendered, out, repo, label, run=subprocess.run):
    """File each rendered issue, in the given (tier-first) order, recording filed.json after each."""
    record = os.path.join(out, "filed.json")
    if os.path.exists(record):
        raise SystemExit(f"file_issues: {record} exists; these groups were filed already (remove it to re-file)")
    filed = []
    for r in rendered:
        with open(r["path"]) as fh:
            text = fh.read()
        body = text.split("\n", 1)[1].lstrip("\n")        # drop the title line
        cmd = ["gh", "issue", "create", "--repo", repo, "--title", r["title"], "--body-file", "-"]
        if label:
            cmd += ["--label", label]
        res = run(cmd, input=body, capture_output=True, text=True, check=True)
        url = res.stdout.strip().splitlines()[-1]
        filed.append({"id": r["id"], "title": r["title"], "tier": r["tier"], "claims": r["claims"],
                      "issue": int(url.rstrip("/").rsplit("/", 1)[1]), "url": url})
        with open(record, "w") as fh:
            json.dump(filed, fh, indent=2)
    return filed


def selftest():
    import tempfile
    with tempfile.TemporaryDirectory() as tmp:
        claims_dir, out = os.path.join(tmp, "claims"), os.path.join(tmp, "out")
        fixtures = {
            ("F1", "F1-01"): ({"tier": 2, "file": "pgpm_core/install.sql", "line": 4671, "lens": "concurrency",
                               "scenario": "a concurrent drain loses the late row", "repro": "repro.sql"},
                              {"repro.sql": "-- ORIGINAL F1-01, superseded\n",
                               "repro.verified.sql": "-- VERIFIED F1-01\nselect 'ok 1 - LIVENESS: rebuilt';\n"}),
            ("F2", "F2-01"): ({"tier": 1, "file": "pgpm_core/install.sql", "line": 120, "lens": "time",
                               "scenario": "grid follows the session zone", "repro": "repro.sh"},
                              {"repro.sh": "# ORIGINAL F2-01\necho 'LIVENESS: ok'\necho '```'\n"}),
        }
        for (finder, cid), (claim, files) in fixtures.items():
            cdir = os.path.join(claims_dir, finder, cid)
            os.makedirs(cdir)
            with open(os.path.join(cdir, "claim.json"), "w") as fh:
                json.dump(claim, fh)
            for name, text in files.items():
                with open(os.path.join(cdir, name), "w") as fh:
                    fh.write(text)
        claims = {c["id"]: c for c in load_claims(claims_dir)}
        groups = [{"id": "RC1", "title": "drain races the late row", "tier": 2, "claims": ["F1-01"]},
                  {"id": "RC2", "title": "grid reads the session zone", "tier": 1, "claims": ["F2-01"]}]
        verdicts = {"F1-01": {"verdict": "finding", "tier": 2, "root_cause": "no re-check under the lock"},
                    "F2-01": {"verdict": "finding", "tier": 1, "root_cause": "session TimeZone grid"}}
        rendered = render_all(groups, claims, verdicts, "abc1234", 3, out)
        assert [r["id"] for r in rendered] == ["RC2", "RC1"], rendered        # tier first
        with open(os.path.join(out, "RC1.md")) as fh:
            rc1 = fh.read()
        with open(os.path.join(out, "RC2.md")) as fh:
            rc2 = fh.read()
        assert rc1.splitlines()[0] == "title: drain races the late row (pass 3 RC1)", rc1
        assert "-- VERIFIED F1-01" in rc1 and "ORIGINAL F1-01" not in rc1, rc1
        assert "`repro.verified.sql`, the verifier's rebuilt reproduction" in rc1, rc1
        assert "```sql\n-- VERIFIED F1-01" in rc1, rc1
        assert "Tier: 2" in rc1 and "`pgpm_core/install.sql:4671`" in rc1 and "no re-check under the lock" in rc1
        assert "concurrency" in rc1 and "a concurrent drain loses the late row" in rc1 and "finder: F1" in rc1
        assert ("Acceptance: the reproduction(s) above fail on abc1234 and must pass on the fixing commit; the fix "
                "carries a bench/ guard and a bench/mutations entry proven by ./test.sh discriminate.") in rc1
        assert "# ORIGINAL F2-01" in rc2 and "rebuilt" not in rc2, rc2
        assert "````bash\n# ORIGINAL F2-01" in rc2, rc2                  # fence outgrows the ``` inside
        # a group naming a claim that is missing, or one that is not a finding, is refused before writing
        for bad_groups, bad_verdicts, word in (
                ([{"id": "RC9", "title": "t", "tier": 1, "claims": ["F9-99"]}], verdicts, "F9-99"),
                (groups, {**verdicts, "F1-01": {"verdict": "fell", "reason": "documented"}}, "F1-01")):
            try:
                render_all(bad_groups, claims, bad_verdicts, "abc1234", 3, os.path.join(tmp, "bad"))
            except SystemExit as e:
                assert word in str(e), str(e)
            else:
                raise AssertionError(f"rendered a bad grouping: {bad_groups}")
        calls = []

        def fake(cmd, **kw):
            calls.append((cmd, kw.get("input")))
            n = 600 + len(calls)
            return subprocess.CompletedProcess(cmd, 0, f"https://github.com/{DEFAULT_REPO}/issues/{n}\n", "")
        filed = post(rendered, out, DEFAULT_REPO, "bug", run=fake)
        assert [c[0][c[0].index("--title") + 1] for c in calls] == [
            "grid reads the session zone (pass 3 RC2)", "drain races the late row (pass 3 RC1)"], calls
        assert all(c[0][:3] == ["gh", "issue", "create"] and DEFAULT_REPO in c[0] and "bug" in c[0] for c in calls)
        assert not calls[0][1].startswith("title:") and "# ORIGINAL F2-01" in calls[0][1], calls[0][1]
        with open(os.path.join(out, "filed.json")) as fh:
            on_disk = json.load(fh)
        assert on_disk == filed and [(f["id"], f["issue"], f["tier"], f["claims"]) for f in filed] == [
            ("RC2", 601, 1, ["F2-01"]), ("RC1", 602, 2, ["F1-01"])], filed
        try:
            post(rendered, out, DEFAULT_REPO, "bug", run=fake)
        except SystemExit as e:
            assert "filed.json" in str(e)
        else:
            raise AssertionError("posted twice over an existing filed.json")
        assert len(calls) == 2
    print("file_issues selftest: PASS")
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--groups")
    ap.add_argument("--claims")
    ap.add_argument("--verdicts")
    ap.add_argument("--pinned")
    ap.add_argument("--pass", dest="pass_n")
    ap.add_argument("--out")
    ap.add_argument("--post", action="store_true", help="file the rendered issues with gh, Tier 1 first")
    ap.add_argument("--repo", default=DEFAULT_REPO)
    ap.add_argument("--label", default="bug")
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args()
    if a.selftest:
        return selftest()
    for k in ("groups", "claims", "verdicts", "pinned", "pass_n", "out"):
        if not getattr(a, k):
            ap.error(f"--{k.replace('_n', '')} is required")
    with open(a.groups) as fh:
        groups = json.load(fh)
    with open(a.verdicts) as fh:
        verdicts = json.load(fh)
    claims = {c["id"]: c for c in load_claims(a.claims)}
    rendered = render_all(groups, claims, verdicts, a.pinned, a.pass_n, a.out)
    for r in rendered:
        print(f"T{r['tier']} {r['id']}: {r['title']}  ({r['path']}, {r['verified']} of {len(r['claims'])} "
              "reproductions verified)")
    if a.post:
        for f in post(rendered, a.out, a.repo, a.label):
            print(f"filed #{f['issue']}: {f['title']}")
        print(f"written: {os.path.join(a.out, 'filed.json')}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
