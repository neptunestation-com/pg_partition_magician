#!/usr/bin/env python3
"""Merge the three final classification files into classified.json (claims concatenated, summary recounted)."""
import json, glob
from collections import Counter
W = "/Users/davida.ventimiglia/.claude/jobs/8d94cdfa/tmp/pass12"
parts = [json.load(open(p)) for p in sorted(glob.glob(f"{W}/classified_final_*.json"))]
out = dict(parts[0]); out["claims"] = []
for p in parts: out["claims"] += p["claims"]
out["claims"].sort(key=lambda c: (c["id"].split("-")[0], int(c["id"].split("-")[1])))
if "summary" in out and isinstance(out["summary"], dict):
    out["summary"] = dict(Counter(c["class"] for c in out["claims"]))
json.dump(out, open(f"{W}/classified.json", "w"), indent=1)
print(len(parts), "parts;", len(out["claims"]), "claims;", Counter(c["class"] for c in out["claims"]))
print("seed hits:", sorted((c["id"], c.get("seed")) for c in out["claims"] if c["class"] == "seed_hit"))
print("rebuilt used:", [c["id"] for c in out["claims"] if "verified" in str(c.get("repro_used", ""))])
