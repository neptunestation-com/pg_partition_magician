#!/usr/bin/env python3
"""Merge the LATEST per-finder classification (classified_<F>_r2.json over classified_<F>.json) into classified.json,
apply the coordinator's attributions (attrib.json: {"F8-04": "S6"}), and recount the summary."""
import json, glob, os, re
from collections import Counter
W = "/Users/davida.ventimiglia/.claude/jobs/8d94cdfa/tmp/pass12"
finders = sorted(os.path.basename(p) for p in glob.glob(f"{W}/claims/F*") if os.path.isdir(p))
out = None; claims = []
for f in finders:
    cands = [f"{W}/classified_{f}_final.json", f"{W}/classified_{f}_r2.json", f"{W}/classified_{f}.json"]
    p = next((c for c in cands if os.path.exists(c)), None)
    if not p: print("NO classification for", f); continue
    d = json.load(open(p))
    if out is None: out = {k: v for k, v in d.items() if k != "claims"}
    mine = [c for c in d["claims"] if c["id"].split("-")[0] == f]
    claims += mine
    print(f, os.path.basename(p), len(mine))
attrib = json.load(open(f"{W}/attrib.json")) if os.path.exists(f"{W}/attrib.json") else {}
for c in claims:
    if c["id"] in attrib:
        c["class"] = "seed_hit"; c["seed"] = attrib[c["id"]]; c["note"] = (c.get("note") or "") + " attributed by the coordinator: a claim at the seeded lines whose pristine run failed only its liveness premise (the premise reads the seeded line itself)"
def key(c): f, n = c["id"].split("-"); return (f, int(n))
claims.sort(key=key)
out["claims"] = claims
out["summary"] = dict(Counter(c["class"] for c in claims))
json.dump(out, open(f"{W}/classified.json", "w"), indent=1)
print(len(claims), "claims;", out["summary"])
print("seed hits:", sorted(set((c["seed"]) for c in claims if c["class"] == "seed_hit")))
print("rebuilt used:", [c["id"] for c in claims if "verified" in str(c.get("repro_used", ""))])
