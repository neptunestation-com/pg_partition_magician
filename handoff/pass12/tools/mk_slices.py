#!/usr/bin/env python3
"""mk_slices.py: build pass-12 slices from the review tree. Reuses pass 11's slice membership by unit NAME for
S1-S6 (the 21 new units assigned below), regenerates line ranges from the tree, splits bench in two and tests in
FOUR, takes the fresh surface from pr_surface and splits it BY KIND into S8a (install units), S8b (tests), S8c (bench),
S8d (docs, scripts, workflows, the rest). Writes slices.json, slices_finders.json and slices/S*.units.txt."""
import json, os, re, glob
W = "/Users/davida.ventimiglia/.claude/jobs/8d94cdfa/tmp/pass12"
P11 = f"{W}/p11slices"
T = f"{W}/tree"
UNIT_RE = re.compile(r'^\s*create\s+(?:or\s+replace\s+)?(?:function|procedure)\s+([a-z_][a-z0-9_]*\.[a-z_][a-z0-9_]*)\s*\(', re.I)
def units(path):
    out = {}
    for i, l in enumerate(open(f"{T}/{path}")):
        m = UNIT_RE.match(l)
        if m: out.setdefault(m.group(1).lower(), []).append(i + 1)
    return out
core, arch, hyper = units("pgpm_core/install.sql"), units("pgpm_archive/install.sql"), units("pgpm_hypertable/install.sql")
where = {}
for n in core: where[n] = "pgpm_core/install.sql"
for n in arch: where[n] = "pgpm_archive/install.sql"
for n in hyper: where[n] = "pgpm_hypertable/install.sql"
allu = {**core, **arch, **hyper}

old = {s: [l.strip() for l in open(f"{P11}/{s}.units.txt") if l.strip()] for s in ["S1","S2","S3","S4","S5","S6"]}
new = {
 "S1": ["pgpm._transmute_refuse_child_holders","pgpm._fk_def_unvalidated","pgpm._refuse_detach_pending"],
 "S2": ["pgpm._naive_grid_zone_off"],
 "S3": ["pgpm._regrain_copy_make","pgpm._regrain_fresh_copy_drift","pgpm._reconvert_remedy","pgpm._regrain_fine_count",
        "pgpm._regrain_swap_budget","pgpm._snapshot_wait","pgpm._regrain_snapshot_wait","pgpm._same_step","pgpm._scratch_written"],
 "S4": ["pgpm._cell_walk_rows","pgpm._cell_walk_step","pgpm._disown_retirement","pgpm._detach_dispatched","pgpm._detach_job_holds",
        "pgpm._disown_unvouched_retirements","pgpm._native_order_key","pgpm._archive_hold_partition"],
 "S5": [], "S6": [],
}
slices = {}; assigned = set()
os.makedirs(f"{W}/slices", exist_ok=True)
for s in ["S1","S2","S3","S4","S5","S6"]:
    names = [u for u in old[s] if u in allu] + [u for u in new[s] if u in allu]
    gone = [u for u in old[s] if u not in allu and not os.path.exists(f"{T}/{u}")]
    files_only = [u for u in old[s] if u not in allu and os.path.exists(f"{T}/{u}")]
    if gone: print("note:", s, "units gone since pass 11:", gone)
    missing_new = [u for u in new[s] if u not in allu]
    assert not missing_new, (s, missing_new)
    ranges = []
    for u in names:
        assigned.add(u)
        for ln in allu[u]: ranges.append(f"{where[u]}:{ln}-{ln}")
    slices[s] = {"files": ranges + files_only}
    open(f"{W}/slices/{s}.units.txt","w").write("\n".join(names + files_only) + "\n")
unassigned = sorted(set(allu) - assigned)
assert not unassigned, ("units in no slice", unassigned)

sh = sorted(os.path.relpath(p, T) for p in glob.glob(f"{T}/bench/*.sh"))
py = sorted(os.path.relpath(p, T) for p in glob.glob(f"{T}/bench/*.py"))
half = (len(sh) + 1) // 2
s7a = sh[:half] + py
s7b = sh[half:] + ["test.sh","scripts/check_archive_object_keys.py","scripts/check_quoted_splices.py","scripts/check_archive_child_by_oid.py",
                   "scripts/check_living_docs.sh","scripts/check_track_filters.py","scripts/image_build_key.sh"] + \
      sorted(os.path.relpath(p, T) for p in glob.glob(f"{T}/.github/workflows/*.yml"))
s7b = [f for f in s7b if os.path.exists(f"{T}/{f}")]
slices["S7a"] = {"files": s7a, "kind": "files"}; slices["S7b"] = {"files": s7b, "kind": "files"}
open(f"{W}/slices/S7a.units.txt","w").write("\n".join(s7a)+"\n"); open(f"{W}/slices/S7b.units.txt","w").write("\n".join(s7b)+"\n")

# fresh surface by kind
surf = json.load(open(f"{W}/surface/surface.json"))
sql_units = [u["unit"] for u in surf["units"]]
files = [f["path"] for f in surf["files"]]
tests_f = [f for f in files if f.startswith("tests/") or f.startswith("fixtures/")]
bench_f = [f for f in files if f.startswith("bench/")]
sql_files = {"pgpm_core/install.sql","pgpm_archive/install.sql","pgpm_hypertable/install.sql"}
rest_f = [f for f in files if f not in tests_f and f not in bench_f and f not in sql_files and not f.startswith("bench/mutations")]
slices["S8a"] = {"units": sql_units, "kind": "mixed"}
slices["S8b"] = {"files": tests_f, "kind": "files"}
slices["S8c"] = {"files": bench_f, "kind": "files"}
slices["S8d"] = {"files": rest_f, "kind": "files"}
for s, lst in (("S8a", sql_units), ("S8b", tests_f), ("S8c", bench_f), ("S8d", rest_f)):
    open(f"{W}/slices/{s}.units.txt","w").write("\n".join(lst)+"\n")

# tests in FOUR slices: core files in name order split in four, archive + timescale + fixtures appended to the last
core_t = sorted(os.path.relpath(p, T) for p in glob.glob(f"{T}/tests/*.sql"))
arch_t = sorted(os.path.relpath(p, T) for p in glob.glob(f"{T}/tests/archive/db/*.sql")) + ["tests/archive/fixtures.sql"]
ts_t = sorted(os.path.relpath(p, T) for p in glob.glob(f"{T}/tests/timescale/db/*.sql")) + ["tests/timescale/fixtures.sql"]
extra = ["fixtures/demo.sql"]
total = len(core_t) + len(arch_t) + len(ts_t) + len(extra)
n = (total + 3) // 4
s9, s10, s11 = core_t[:n], core_t[n:2*n], core_t[2*n:3*n]
s12 = core_t[3*n:] + arch_t + ts_t + extra
for s, lst in (("S9", s9), ("S10", s10), ("S11", s11), ("S12", s12)):
    slices[s] = {"files": lst, "kind": "files"}
    open(f"{W}/slices/{s}.units.txt","w").write("\n".join(lst)+"\n")
docs = ["docs/guide.md","docs/reference.md","docs/runbook.md","README.md","pgpm_archive/README.md","ONBOARDING.md","RELEASING.md","CHANGELOG.md","bench/README.md","bench/figures/README.md","docs/adversarial-review.md","index.html"]
docs = [d for d in docs if os.path.exists(f"{T}/{d}")]
slices["S13"] = {"files": docs, "kind": "files"}
open(f"{W}/slices/S13.units.txt","w").write("\n".join(docs)+"\n")
json.dump(slices, open(f"{W}/slices.json","w"), indent=1)
m = {"F1":"S1","F2":"S2","F3":"S3","F4":"S4","F5":"S5","F6":"S6","F7":"S7a","F8":"S7b","F9":"S8a","F10":"S8b","F11":"S8c","F12":"S8d",
     "F13":"S9","F14":"S10","F15":"S11","F16":"S12","F17":"S13","F18":"S1","F19":"S5"}
json.dump({f: slices[s] for f, s in m.items()}, open(f"{W}/slices_finders.json","w"), indent=1)
json.dump(m, open(f"{W}/finder_slice.json","w"), indent=1)
for s in slices: print(s, len(open(f"{W}/slices/{s}.units.txt").read().split("\n")) - 1)
print("S9:", s9[0], "..", s9[-1]); print("S10:", s10[0], "..", s10[-1]); print("S11:", s11[0], "..", s11[-1]); print("S12:", s12[0], "..", core_t[-1], "+ archive + timescale + fixtures")
