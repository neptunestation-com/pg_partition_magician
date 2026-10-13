#!/usr/bin/env python3
"""Aggregate token usage and wall clock from subagent JSONL transcripts; prints one line per agent. Never prints content."""
import json, sys, pathlib, datetime
def agg(path):
    inp=out=cr=cc=0; first=last=None; n=0
    with open(path) as fh:
        for line in fh:
            try: o=json.loads(line)
            except Exception: continue
            n+=1
            ts=o.get("timestamp") or (o.get("message") or {}).get("timestamp")
            if ts:
                try:
                    t=datetime.datetime.fromisoformat(ts.replace("Z","+00:00"))
                    first=first or t; last=t
                except Exception: pass
            u=(o.get("message") or {}).get("usage") or o.get("usage")
            if u:
                inp+=u.get("input_tokens",0); out+=u.get("output_tokens",0)
                cr+=u.get("cache_read_input_tokens",0); cc+=u.get("cache_creation_input_tokens",0)
    mins=(last-first).total_seconds()/60 if first and last else None
    return dict(lines=n, input=inp, output=out, cache_read=cr, cache_create=cc, total=inp+out+cr+cc, minutes=round(mins,1) if mins is not None else None)
if __name__=="__main__":
    if sys.argv[1]=="--keys":
        with open(sys.argv[2]) as fh:
            for i,line in enumerate(fh):
                if i>2: break
                o=json.loads(line); print(sorted(o.keys()), sorted((o.get("message") or {}).keys()) if isinstance(o.get("message"),dict) else "")
        sys.exit()
    for p in sys.argv[1:]:
        print(pathlib.Path(p).stem, json.dumps(agg(p)))
