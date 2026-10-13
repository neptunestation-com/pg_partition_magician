#!/usr/bin/env python3
"""Per-finder table from the FINAL classification + verdicts + coverage + tokens. Usage: per_finder.py <classified.json>"""
import json, sys, csv
W = "/Users/davida.ventimiglia/.claude/jobs/8d94cdfa/tmp/pass12"
cl = json.load(open(sys.argv[1])); claims = cl["claims"] if isinstance(cl, dict) else cl
vs = json.load(open(f"{W}/verdicts.json"))
cov = {r["finder"]: r for r in json.load(open(f"{W}/coverage.json"))["rows"]}
tok = {r["finder"]: r for r in csv.DictReader(open(f"{W}/tokens_harness.tsv"), delimiter="\t")}
R2 = set(l.strip() for l in open(f"{W}/round2_ids.txt") if l.strip()) if __import__("os").path.exists(f"{W}/round2_ids.txt") else set()
order = [l.split("\t")[0] for l in open(f"{W}/agents.tsv").read().split("\n")[1:] if l.strip()]
rows = {f: dict(claims=0, r2=0, seeds=[], findings=[], known=[], fell=[], other=[]) for f in order}
for c in claims:
    f = c["id"].split("-")[0]; r = rows[f]; r["claims"] += 1
    if c["id"] in R2: r["r2"] += 1
    if c["class"] == "seed_hit": r["seeds"].append(c["id"] + ":" + str(c.get("seed")))
    elif c["class"] == "candidate":
        v = vs.get(c["id"], {}).get("verdict")
        if v == "finding": r["findings"].append(c["id"] + ":T" + str(vs[c["id"]].get("tier")))
        elif v == "known_open": r["known"].append(c["id"] + ":#" + str(vs[c["id"]].get("issue")))
        elif v == "fell": r["fell"].append(c["id"])
        else: r["other"].append(c["id"] + ":unverified")
    else: r["other"].append(c["id"] + ":" + c["class"])
print("finder\tslice\tmodel\ttokens\tcoverage\tclaims(r2)\tseeds\tfindings\tknown_open\tfell\tprecision\tstrict")
for f in order:
    r = rows[f]; n = r["claims"]; t = tok.get(f, {})
    tp = len(r["seeds"]) + len(r["findings"]) + len(r["known"]); strict = len(r["seeds"]) + len(r["findings"])
    print(f"{f}\t{t.get('slice','')}\t{t.get('model','')}\t{t.get('tokens_final_notification','')}\t{cov.get(f,{}).get('coverage','')}\t{n}({r['r2']})\t{len(r['seeds'])}\t{len(r['findings'])}\t{len(r['known'])}\t{len(r['fell'])}\t{(tp/n if n else 0):.2f}\t{(strict/n if n else 0):.2f}")
    for k in ("seeds","findings","known","fell","other"):
        if r[k]: print(f"    {k}: {', '.join(r[k])}")
