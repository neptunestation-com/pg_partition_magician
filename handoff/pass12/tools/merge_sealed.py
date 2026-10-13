#!/usr/bin/env python3
"""Merge the per-track suite results (sealed_core.json, sealed_archive.json) into sealed.json by seed id."""
import json
W="/Users/davida.ventimiglia/.claude/jobs/8d94cdfa/tmp/pass12"
main=json.load(open(f"{W}/sealed.json"))
def seeds(d): return d["seeds"] if isinstance(d, dict) and "seeds" in d else d
by={s["id"]: s for s in seeds(main)}
for track in ("core","archive"):
    try: part=json.load(open(f"{W}/sealed_{track}.json"))
    except FileNotFoundError: continue
    for s in seeds(part):
        for k,v in s.items():
            if k.startswith("suite_"): by[s["id"]][k]=v
    if isinstance(part, dict):
        for k,v in part.items():
            if k.startswith("suite_") and k not in main: main[k]=v
json.dump(main, open(f"{W}/sealed.json","w"), indent=1)
for s in seeds(main): print(s["id"], s.get("suite_track"), "caught:", s.get("suite_caught"), "noise:", s.get("suite_noise"))
