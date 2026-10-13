#!/usr/bin/env python3
"""rerun_prompt.py <orig finder> <new id> <units file> "<budget text>": a re-run brief on the units the first finder did not read."""
import sys, re, pathlib
W = pathlib.Path("/Users/davida.ventimiglia/.claude/jobs/8d94cdfa/tmp/pass12")
orig, new, units_file, budget = sys.argv[1:5]
t = (W/"prompts"/f"{orig}.md").read_text()
t = re.sub(rf"\b{orig}\b", new, t)
t = re.sub(r"\bfinder \*\*" + new + r"\*\*\.", f"finder **{new}**, a RE-RUN: the first finder of this slice read fewer than nine tenths of its units, and your slice is exactly the units it did not read (the unit list at the end of this brief), with a fresh budget. Read every one of them in full, under every lens, before you build anything; a claim is as welcome here as in a first run, and a clean slice with a full ledger is a good result.", t, count=1)
t = re.sub(r"- Budget: about [^,]*,", f"- Budget: about {budget},", t, count=1)
units = [u for u in open(units_file).read().split("\n") if u.strip()]
head, _, tail = t.partition("## Units of your slice (copy into the ledger, one line each)\n\n")
rest = tail.split("\n\n## Claim format", 1)[1]
t = head + "## Units of your slice (copy into the ledger, one line each)\n\n" + "\n".join(f"- {u}" for u in units) + "\n\n## Claim format" + rest
(W/"prompts"/f"{new}.md").write_text(t)
print(new, len(units), "units;", len(t), "chars")
