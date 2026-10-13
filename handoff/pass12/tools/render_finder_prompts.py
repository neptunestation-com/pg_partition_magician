#!/usr/bin/env python3
"""Render the nineteen finder briefs for pass 12: F1-F17 on S1-S13 (S7 split, S8 split by kind, tests in four), F18 = S1 and F19 = S5 (the second-model duplicates)."""
import pathlib
TPL = pathlib.Path(__file__).resolve().parent
W = TPL.parent
tpl = (TPL/"finder_template.md").read_text(); contract = (TPL/"contract.md").read_text()
import json
plan = json.load(open(W/"finder_slice.json"))
budget = {"S1":"55 minutes of wall clock or about 450k tokens","S2":"45 minutes of wall clock or about 350k tokens","S3":"50 minutes of wall clock or about 400k tokens",
          "S4":"55 minutes of wall clock or about 450k tokens","S5":"60 minutes of wall clock or about 500k tokens","S6":"50 minutes of wall clock or about 400k tokens",
          "S7a":"60 minutes of wall clock or about 500k tokens","S7b":"60 minutes of wall clock or about 500k tokens","S8a":"55 minutes of wall clock or about 450k tokens",
          "S8b":"60 minutes of wall clock or about 500k tokens","S8c":"65 minutes of wall clock or about 550k tokens","S8d":"45 minutes of wall clock or about 350k tokens",
          "S9":"60 minutes of wall clock or about 500k tokens","S10":"60 minutes of wall clock or about 500k tokens","S11":"60 minutes of wall clock or about 500k tokens",
          "S12":"65 minutes of wall clock or about 550k tokens","S13":"50 minutes of wall clock or about 400k tokens"}
model = {f: ("fable" if f in ("F18","F19") else "opus") for f in plan}
(W/"prompts").mkdir(exist_ok=True); (W/"round2").mkdir(exist_ok=True)
r2 = (TPL/"round2_template.md").read_text()
rows = ["finder\tslice\tmodel\tbudget"]
for fid, sid in plan.items():
    slice_txt = (W/"slices"/f"{sid}.md").read_text()
    units = (W/"slices"/f"{sid}.units.txt").read_text().strip().split("\n")
    units_txt = "\n".join(f"- {u}" for u in units)
    txt = (tpl.replace("{FID}", fid).replace("{SID}", sid).replace("{TREE}", str(W/"tree"))
              .replace("{CLAIMS}", str(W/"claims")).replace("{fid}", fid.lower()).replace("{BUDGET}", budget[sid])
              .replace("{SLICE}", slice_txt).replace("{UNITS}", units_txt).replace("{CONTRACT}", contract))
    (W/"prompts"/f"{fid}.md").write_text(txt)
    (W/"round2"/f"{fid}.md").write_text(r2.replace("{FID}", fid).replace("{CLAIMS}", str(W/"claims")))
    rows.append(f"{fid}\t{sid}\t{model[fid]}\t{budget[sid]}")
(W/"finders.tsv").write_text("\n".join(rows) + "\n")
print("rendered", len(plan), "prompts and round-2 briefs;", (W/"finders.tsv").read_text())
