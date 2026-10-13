#!/usr/bin/env python3
"""Render one verifier prompt per candidate from a classified JSON. Usage: render_verifier_prompts.py <classified.json> [ids...]"""
import json, sys, pathlib
W = pathlib.Path("/Users/davida.ventimiglia/.claude/jobs/8d94cdfa/tmp/pass12")
tpl = (W/"tools/verifier_template.md").read_text()
classified = json.load(open(sys.argv[1]))
claims = classified["claims"] if isinstance(classified, dict) and "claims" in classified else classified
only = set(sys.argv[2:])
out = W/"verify"; out.mkdir(exist_ok=True); (W/"verdicts").mkdir(exist_ok=True)
n = 0
for rec in claims:
    cid = rec["id"]
    if rec.get("class") != "candidate" or (only and cid not in only): continue
    finder = rec.get("finder") or cid.split("-")[0]
    container = rec.get("container") or "(inferred from the install list)"
    txt = (tpl.replace("{ID}", cid).replace("{IDLC}", cid.lower().replace("-","_")).replace("{CLAIM_DIR}", str(W/"claims"/finder/cid)).replace("{CLAIMS}", str(W/"claims"))
              .replace("{TREE}", str(W/"tree")).replace("{PRISTINE}", "/Users/davida.ventimiglia/Work/pg_partition_magician")
              .replace("{RECORD}", json.dumps(rec, sort_keys=True)).replace("{OPEN}", str(W/"open.json"))
              .replace("{CONTAINER}", container).replace("{VERIFY_DIR}", str(W/"verify"))
              .replace("{VERDICT_PATH}", str(W/"verdicts"/f"{cid}.json")))
    (out/f"{cid}.md").write_text(txt); n += 1
print("rendered", n, "verifier prompts into", out)
