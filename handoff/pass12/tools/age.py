#!/usr/bin/env python3
"""age.py <file> <line> [<unit>]: the first inputs for a finding's AGE (docs/adversarial-review.md, Between passes).
Prints the blame of the pristine checkout's line against the previous pin (0c38aae): young when the line's commit is
newer than the pin; and whether pass 11's coverage ledgers marked the unit (schema.name or path) read. The coordinator
writes the age with its reason; this only gathers the two inputs."""
import subprocess, sys, json, re
PREV = "0c38aae"
REPO = "/Users/davida.ventimiglia/Work/pg_partition_magician"
S11 = "/Users/davida.ventimiglia/.claude/projects/-Users-davida-ventimiglia-Work-pg-partition-magician/scratch/pass11-loop/pass11"
f, line = sys.argv[1], int(sys.argv[2]); unit = sys.argv[3] if len(sys.argv) > 3 else None
b = subprocess.run(["git", "-C", REPO, "blame", "-L", f"{line},{line}", "--porcelain", "HEAD", "--", f], capture_output=True, text=True).stdout
sha = b.split("\n")[0].split(" ")[0]
summ = subprocess.run(["git", "-C", REPO, "log", "-1", "--format=%h %ad %s", "--date=short", sha], capture_output=True, text=True).stdout.strip()
anc = subprocess.run(["git", "-C", REPO, "merge-base", "--is-ancestor", sha, PREV]).returncode == 0
print(f"line {f}:{line} last changed by {summ}")
print(f"  committed {'at or before' if anc else 'AFTER'} the previous pin {PREV}: line is {'old' if anc else 'young'} by blame")
if unit:
    cov = json.load(open(f"{S11}/coverage.json"))["rows"]
    readers = []
    for r in cov:
        fid = r["finder"]
        # the unit lists per finder
        sl = {"F1":"S1","F2":"S2","F3":"S3","F4":"S4","F5":"S5","F6":"S6","F7":"S7a","F8":"S7b","F9":"S8","F10":"S9","F11":"S10","F12":"S11","F13":"S12","F14":"S4","F15":"S8","F9r":"S8r","F15r":"S8r15","F9r2":"S8r2","F15r2":"S8r15b"}.get(fid)
        try: units = [u for u in open(f"{S11}/slices/{sl}.units.txt").read().split("\n") if u]
        except Exception: units = []
        if unit in units and unit not in set(r.get("unread", [])): readers.append(fid)
    print(f"  pass 11 ledgers: unit {unit} marked read by {readers or 'NO finder'}")
