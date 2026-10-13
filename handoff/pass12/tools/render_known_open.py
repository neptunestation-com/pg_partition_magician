#!/usr/bin/env python3
"""Render one comment per open issue re-found this pass, in the pass-6 shape, from verdicts + claims."""
import json, glob, os, sys
from collections import defaultdict
W = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PIN = "bd55f840"; RECORD = "docs/reviews/2026-10-12-pass12.md"; PASS = 12
vs = {}
for f in sorted(glob.glob(f"{W}/verdicts/*.json")): vs.update(json.load(open(f)))
by = defaultdict(list)
for cid, v in vs.items():
    if v.get("verdict") == "known_open": by[int(v["issue"])].append(cid)
os.makedirs(f"{W}/known_open", exist_ok=True)
for issue, cids in sorted(by.items()):
    cids = sorted(cids, key=lambda c: (c.split("-")[0], int(c.split("-")[1])))
    out = [f"Re-found in adversarial review pass {PASS} (pinned `{PIN}`), classified **known and open** against this issue by the verifier: {', '.join(cids)}. Recorded here with the built reproduction(s); not counted as a new finding. Each reproduction fails on `{PIN}` and must pass on the commit that closes this issue (its `LIVENESS:` lines prove the fixture reached the state). Pass record: `{RECORD}`.", ""]
    for cid in cids:
        fid = cid.split("-")[0]; d = f"{W}/claims/{fid}/{cid}"
        c = json.load(open(f"{d}/claim.json")); v = vs[cid]
        repro = v.get("repro") or c.get("repro")
        inst = ", ".join(c.get("install") or ["pgpm_core/install.sql"])
        out.append(f"### {cid} (finder {fid}, `{c['file']}:{c['line']}`, lens: {c['lens']}, claimed tier {c['tier']})\n")
        out.append(f"**Scenario:** {c['scenario']}\n")
        note = v.get("note") or v.get("reason") or v.get("root_cause") or ""
        if note: out.append(f"**Verifier:** {note}\n")
        if v.get("rebuilt"): out.append(f"The verifier rebuilt the reproduction (`{repro}`); the finder's original is beside it in the pass's claim directory.\n")
        body = open(f"{d}/{repro}").read().rstrip()
        lang = "sql" if repro.endswith(".sql") else "bash"
        out.append(f"<details><summary>Reproduction <code>{repro}</code> (install: {inst})</summary>\n\n```{lang}\n{body}\n```\n\n</details>\n")
    open(f"{W}/known_open/{issue}.md", "w").write("\n".join(out))
    print(issue, cids)
