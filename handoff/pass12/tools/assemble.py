#!/usr/bin/env python3
"""assemble.py <record_from_pass_metrics.md> <out.md>: fill the findings table's issue column from
claim_issue.json, replace the generated placeholder sections (null results, fell, known and open,
hypotheses) with the coordinator's, and append root causes, the per-finder table and the notes."""
import json, re, sys
W="/Users/davida.ventimiglia/.claude/jobs/8d94cdfa/tmp/pass12"
src, out = sys.argv[1], sys.argv[2]
cm = json.load(open(f"{W}/claim_issue.json"))
g = json.load(open(f"{W}/groups.json")); rc = {c: x["id"] for x in g for c in x["claims"]}
text = open(src).read()
lines = []
for l in text.split("\n"):
    m = re.match(r"^\| (\d) \| (.*?) \| (.*?) \| (F\d+r?-\d+):(.*)\|\s*\|\s*\|\s*$", l)
    if m and m.group(4) in cm:
        l = f"| {m.group(1)} | {m.group(2)} | {m.group(3)} | {m.group(4)}:{m.group(5)}|#{cm[m.group(4)]} ({rc[m.group(4)]}) | |"
    lines.append(l)
text = "\n".join(lines)
# split into sections by '## ' headers
secs = re.split(r"(?m)^(?=## )", text)
mine = {}
for f in ("null_results.md", "hypotheses.md", "known_open_section.md"):
    for s in re.split(r"(?m)^(?=## )", open(f"{W}/{f}").read()):
        if s.startswith("## "):
            mine[s.split("\n",1)[0].strip()] = s.rstrip("\n") + "\n\n"
outs = []
for s in secs:
    h = s.split("\n",1)[0].strip() if s.startswith("## ") else None
    if h in mine:
        outs.append(mine.pop(h))
    else:
        outs.append(s if s.endswith("\n\n") else s.rstrip("\n") + "\n\n")
for h, s in mine.items(): outs.append(s)   # any section the generator did not emit
outs.append(open(f"{W}/root_causes.md").read().lstrip("\n").rstrip("\n") + "\n\n")
outs.append(open(f"{W}/notes_record.md").read().rstrip("\n") + "\n")
open(out, "w").write("".join(outs))
print("assembled", out, open(out).read().count("\n"), "lines")
