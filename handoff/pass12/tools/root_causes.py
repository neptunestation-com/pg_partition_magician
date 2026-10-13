#!/usr/bin/env python3
"""root_causes.md from groups.json + issues/filed.json: the '## Root causes' section."""
import json, os
W = "/Users/davida.ventimiglia/.claude/jobs/8d94cdfa/tmp/pass12"
g = json.load(open(f"{W}/groups.json"))
filed = {x["id"]: x for x in json.load(open(f"{W}/issues/filed.json"))} if os.path.exists(f"{W}/issues/filed.json") else {}
lines = ["## Root causes", "", f"{len(g)} root-cause groups behind the findings, one issue each (Tier 1 first). The age and the lens are on each issue as `Age: ... | Lens: ...`.", ""]
for x in sorted(g, key=lambda x: (x["tier"], int(x["id"][2:]))):
    iss = filed.get(x["id"], {}).get("issue")
    lines.append(f"- **{x['id']}** (Tier {x['tier']}, {x.get('age','')}): {x['title']}. Claims {', '.join(x['claims'])}." + (f" Issue #{iss}." if iss else ""))
open(f"{W}/root_causes.md", "w").write("\n".join(lines) + "\n")
cm = {c: filed[x["id"]]["issue"] for x in g if x["id"] in filed for c in x["claims"]}
json.dump(cm, open(f"{W}/claim_issue.json", "w"), indent=1)
print(len(lines) - 4, "groups;", len(cm), "claims mapped to issues")
