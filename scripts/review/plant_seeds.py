#!/usr/bin/env python3
"""Plant blind seeds in a review tree (docs/adversarial-review.md, "Seeding").

A seed is a known defect put back into the review tree before a pass so the pass's sensitivity can be
measured: a pass that reports none of them has not shown it could find anything. Seeds come from two
sources, both named in a PLAN file the coordinator writes:

  {"seeds": [
     {"mutation": "untransmute_no_recheck_under_lock", "lens": "concurrency", "tier": 1},
     {"patch": "seeds/novel_grid_off_by_one.patch",      "lens": "boundary",    "tier": 1,
      "file": "pgpm_core/install.sql", "why": "one-line description for the sealed record",
      "side_effects": "freezes the monolith: every table converted on the tree reads as frozen"}
  ]}

"side_effects" is optional on either kind: what the seed does to state OTHER claims depend on (freezing
the monolith, disabling a tick). Pass 2 had five candidates that reached their defect only because a
seed had frozen the monolith, so it is carried into the sealed record unchanged, and pass_metrics.py
lists it beside every candidate whose pristine run failed only its liveness checks. The catalogue itself
(bench/mutations/mutate.py) may define an optional SIDE_EFFECTS dict keyed by mutation name; --catalogue
prints it where present. The plan's field is what reaches the sealed record.

A "mutation" entry is applied with the PRISTINE checkout's bench/mutations/mutate.py (the review tree
has no catalogue), which refuses to write anything if its pattern has drifted. A "patch" entry is a
unified diff the coordinator wrote for this pass (a novel seed), applied with `git apply` inside the
tree. Every entry is recorded in the SEALED file the finders never see, together with the lines it
touched in the pristine tree, which is what classify_claims.py later uses to attribute a seed hit.

After planting, the tree's single commit is amended so it stays history-less.

The suite check (--suite). Pass 4's recall of 9/9 measured "the suite was run" as much as "the lens saw
the defect": every seed had a test-file guard, and the finder that ran the whole pgTAP suite against the
tree found all nine in twelve minutes before reading any code (#679). So before the hunt, --suite plants
each seed ALONE in a copy of the pristine tree and runs that tree's own suite against it, and the files
that fail are sealed with the seed as "suite_caught" (an empty list: the suite does not catch it, so only
reading can). pass_metrics.py then reports recall as suite-caught / read-caught, and the coordinator can
replace seeds before the hunt until the split is the one the pass wants. Which suite a seed is judged by
follows its file: pgpm_archive/ or tests/archive/ runs tests/archive/db/*.sql in the archive harness (its
MinIO bucket up, as for the archive track); pgpm_hypertable/ or tests/timescale/ runs tests/timescale/db/*.sql
in the timescale harness (over TCP, as test.sh connects to the fleet image); everything else runs tests/*.sql
in the core harness. Every file gets a fresh database the way test.sh gives it one: a template with the
module installed and the fixtures loaded, cloned per file; tests/31 and 78 need the cron database
`postgres`, which is installed into and uninstalled from, or skipped (sealed as "suite_skipped") when pgpm
is already installed there. The verdict per file is pg_prove's exit status where the image has pg_prove
(the core and archive images do, which is also how test.sh judges those suites), else test.sh's own reading
for the timescale track: a `not ok`, a plan shortfall (`# Looks like you planned N tests but ran M`) or an
ERROR line. Before any seed, the UNSEEDED tree's suite is run once per track as a control and sealed as
"suite_baseline": a file that fails there fails for a reason that is not the seed, so it is taken out of
every seed's "suite_caught" and reported on the seed as "suite_noise" instead (the first smoke run of this
check read two deliberate ERROR lines, a provoked statement timeout and an expected uninstall refusal, as
catches of a seed in a doc). The control is also the runner's liveness witness: a clean baseline says the
suite ran green against the tree it was given.

Usage:
  plant_seeds.py --tree <review-tree> --pristine <checkout> --plan <plan.json> --sealed <out.json>
  plant_seeds.py --suite --sealed <sealed.json> --pristine <checkout> [--seeds-dir <dir>] [--only S1,S4]
                 [--container pgpm_test-15] [--archive-container ...] [--timescale-container ...] [--work <dir>]
  plant_seeds.py --catalogue [--pristine <checkout>]      # every mutation, its file and track
  plant_seeds.py --selftest
"""
import argparse
import json
import os
import re
import shutil
import subprocess
import sys


def load_mutate(pristine):
    sys.path.insert(0, os.path.join(pristine, "bench", "mutations"))
    import mutate  # noqa: E402  (the catalogue is code, not data, on purpose: see its docstring)
    return mutate


def catalogue(mutate):
    side = getattr(mutate, "SIDE_EFFECTS", {})
    rows = []
    for name, (guard, why, _edits) in mutate.MUTATIONS.items():
        row = {
            "mutation": name,
            "guard": guard,
            "file": mutate.MUTATION_SRC.get(name, "pgpm_core/install.sql"),
            "track": mutate.MUTATION_TRACK.get(name, "perf"),
            "why": why,
        }
        if side.get(name):
            row["side_effects"] = side[name]
        rows.append(row)
    return rows


def catalogue_line(r):
    line = f"{r['mutation']}\t{r['file']}\t{r['track']}\t{r['guard']}"
    return line + (f"\tside effects: {r['side_effects']}" if r.get("side_effects") else "")


def touched_lines(text, edits):
    """Line numbers in `text` where a mutation's find-patterns match (for seed attribution)."""
    lines = set()
    for find, _replace, _expected in edits:
        if hasattr(find, "finditer"):
            spans = [m.start() for m in find.finditer(text)]
        else:
            spans, i = [], text.find(find)
            while i != -1:
                spans.append(i)
                i = text.find(find, i + 1)
        for s in spans:
            lines.add(text.count("\n", 0, s) + 1)
    return sorted(lines)


def patch_lines(patch_text):
    """Files and pristine-side line numbers a unified diff touches: (file, [lines])."""
    out, cur = {}, None
    for line in patch_text.splitlines():
        if line.startswith("--- "):
            cur = line[4:].strip()
            cur = cur[2:] if cur.startswith("a/") else cur
            out.setdefault(cur, [])
        elif line.startswith("@@") and cur is not None:
            m = re.match(r"@@ -(\d+)(?:,(\d+))? ", line)
            if m:
                start = int(m.group(1))
                n = int(m.group(2) or 1)
                out[cur].extend(range(start, start + max(n, 1)))
    return out


def validate(plan):
    for i, entry in enumerate(plan.get("seeds", []), 1):
        if ("mutation" in entry) == ("patch" in entry):
            raise SystemExit(f"plant_seeds: entry {i} must name exactly one of 'mutation' or 'patch'")
        for k in ("lens", "tier"):
            if k not in entry:
                raise SystemExit(f"plant_seeds: entry {i} lacks {k!r}; the sealed record needs it")
        if "side_effects" in entry and not isinstance(entry["side_effects"], str):
            raise SystemExit(f"plant_seeds: entry {i}'s side_effects must be one string describing the effect")
    if not plan.get("seeds"):
        raise SystemExit("plant_seeds: the plan has no seeds; a pass without seeds cannot measure its recall")


def plant(tree, pristine, plan, sealed_path, run=subprocess.run):
    validate(plan)
    mutate = load_mutate(pristine)
    sealed = {"pinned": None, "seeds": []}
    head = run(["git", "-C", pristine, "rev-parse", "HEAD"], capture_output=True, text=True, check=True)
    sealed["pinned"] = head.stdout.strip()

    for i, entry in enumerate(plan["seeds"], 1):
        if "mutation" in entry:
            name = entry["mutation"]
            if name not in mutate.MUTATIONS:
                raise SystemExit(f"plant_seeds: unknown mutation {name!r}; see --catalogue")
            rel = mutate.MUTATION_SRC.get(name, "pgpm_core/install.sql")
            target = os.path.join(tree, rel)
            with open(os.path.join(pristine, rel)) as fh:
                pristine_text = fh.read()
            _guard, why, edits = mutate.MUTATIONS[name]
            # mutate.py refuses (non-zero) when a pattern's count has drifted: never a silent no-op seed
            run([sys.executable, os.path.join(pristine, "bench", "mutations", "mutate.py"),
                 name, target, target], check=True)
            sealed["seeds"].append({
                "id": f"S{i}", "kind": "mutation", "mutation": name, "file": rel,
                "lens": entry["lens"], "tier": entry["tier"], "why": why,
                "lines": touched_lines(pristine_text, edits),
            })
        elif "patch" in entry:
            ppath = entry["patch"]
            with open(ppath) as fh:
                ptext = fh.read()
            # working tree only: mutations applied above are unstaged, so `--index` would refuse with
            # "does not match index"; everything is staged together before the amend below
            run(["git", "-C", tree, "apply", os.path.abspath(ppath)], check=True)
            files = patch_lines(ptext)
            sealed["seeds"].append({
                "id": f"S{i}", "kind": "patch", "patch": os.path.basename(ppath),
                "file": entry.get("file") or (next(iter(files)) if files else None),
                "lens": entry["lens"], "tier": entry["tier"], "why": entry.get("why", ""),
                "lines": sorted({ln for lns in files.values() for ln in lns}),
            })
        if entry.get("side_effects"):
            sealed["seeds"][-1]["side_effects"] = entry["side_effects"]

    # keep the tree history-less: one commit, amended
    run(["git", "-C", tree, "-c", "user.name=review", "-c", "user.email=review@localhost", "add", "-A"], check=True)
    run(["git", "-C", tree, "-c", "user.name=review", "-c", "user.email=review@localhost",
         "commit", "-q", "--amend", "--no-edit"], check=True,
        env={**os.environ, "GIT_AUTHOR_DATE": "2000-01-01T00:00:00Z", "GIT_COMMITTER_DATE": "2000-01-01T00:00:00Z"})
    n = run(["git", "-C", tree, "rev-list", "--count", "HEAD"], capture_output=True, text=True, check=True)
    if n.stdout.strip() != "1":
        raise SystemExit("plant_seeds: the review tree has more than one commit; seeds would be readable as a diff")

    with open(sealed_path, "w") as fh:
        json.dump(sealed, fh, indent=2)
    return sealed


# ---- the suite check -----------------------------------------------------------------------------------

SUITE_FAIL = re.compile(r"^not ok|^# Looks like you (?:failed|planned)|ERROR:", re.M)
HARNESS_DEFAULTS = {"core": "pgpm_test-15", "archive": "pgpm_test-archive", "timescale": "pgpm_test-timescale"}
CRON_DB_FILES = ("31_schedule_test.sql", "78_retain_detach_dispatch_test.sql")
SUITE_DIRS = ("tests", "fixtures", "pgpm_core", "pgpm_archive", "pgpm_hypertable")


def seed_track(seed):
    """Which suite judges a seed: 'archive', 'timescale' or 'core', from the file it changes."""
    parts = (seed.get("file") or "").replace("\\", "/").split("/")
    if parts[0] == "pgpm_archive" or parts[:2] == ["tests", "archive"]:
        return "archive"
    if parts[0] == "pgpm_hypertable" or parts[:2] == ["tests", "timescale"]:
        return "timescale"
    return "core"


def suite_verdict(output):
    """True when a test file's output reports a failure, read the way test.sh's run_timescale reads it."""
    return SUITE_FAIL.search(output) is not None


def isolate_seed(pristine, seed, seeds_dir, dst, run=subprocess.run):
    """A copy of the pristine tree's suite directories carrying exactly ONE seed (and any other file the
    seed touches, so a seed in a doc or a bench script applies, even though no suite reads it). With seed
    None the copy carries nothing: the control the baseline runs against."""
    os.makedirs(dst)
    for d in SUITE_DIRS:
        src = os.path.join(pristine, d)
        if os.path.isdir(src):
            shutil.copytree(src, os.path.join(dst, d), ignore=shutil.ignore_patterns("*.pyc", "__pycache__"))
    if seed is None:
        return
    extra = [seed["file"]] if seed.get("file") else []
    if seed["kind"] == "patch":
        if not seeds_dir:
            raise SystemExit(f"plant_seeds: seed {seed['id']} is a patch; --seeds-dir must name the directory holding {seed['patch']}")
        with open(os.path.join(seeds_dir, seed["patch"])) as fh:
            extra += list(patch_lines(fh.read()))
    for rel in extra:
        if not os.path.exists(os.path.join(dst, rel)) and os.path.isfile(os.path.join(pristine, rel)):
            os.makedirs(os.path.dirname(os.path.join(dst, rel)), exist_ok=True)
            shutil.copy2(os.path.join(pristine, rel), os.path.join(dst, rel))
    if seed["kind"] == "mutation":
        target = os.path.join(dst, seed["file"])
        run([sys.executable, os.path.join(pristine, "bench", "mutations", "mutate.py"), seed["mutation"], target, target],
            check=True)
    else:
        with open(os.path.join(seeds_dir, seed["patch"])) as fh:
            run(["patch", "-p1", "-s", "-d", dst], stdin=fh, check=True)


class SuiteRunner:
    """Runs one module's pgTAP files from a seeded tree in its harness, each in a fresh database, and returns
    (files that failed, files skipped, files run). Files reach the container with `docker cp`, so `\\ir` and
    the other path-relative metacommands resolve inside the seeded tree as they do under /repo."""

    def __init__(self, containers, run=subprocess.run):
        self.containers, self.run = containers, run

    def prefix(self, track, db):
        c = self.containers[track]
        if track == "timescale":   # the fleet image does not trust the local socket (test.sh's run_timescale)
            return ["docker", "exec", "-i", "-e", "PGPASSWORD=postgres", c, "psql", "-h", "127.0.0.1", "-U", "postgres", "-d", db]
        return ["docker", "exec", "-i", c, "psql", "-U", "postgres", "-d", db]

    def psql(self, track, db, *args, stdin=None, check=True, stop=True):
        cmd = self.prefix(track, db) + (["-v", "ON_ERROR_STOP=1"] if stop else []) + list(args)
        return self.run(cmd, input=stdin, capture_output=True, text=True, check=check)

    def file(self, track, db, *args, path):
        with open(path) as fh:
            return self.psql(track, db, *args, "-f", "-", stdin=fh.read())

    def ship(self, track, tree, remote):
        c = self.containers[track]
        self.run(["docker", "exec", c, "rm", "-rf", remote], check=True, capture_output=True)
        self.run(["docker", "exec", c, "mkdir", "-p", remote], check=True, capture_output=True)
        for d in SUITE_DIRS:
            if os.path.isdir(os.path.join(tree, d)):
                self.run(["docker", "cp", os.path.join(tree, d), f"{c}:{remote}/{d}"], check=True, capture_output=True)

    def has_pg_prove(self, track):
        if not hasattr(self, "_pg_prove"):
            self._pg_prove = {}
        if track not in self._pg_prove:
            r = self.run(["docker", "exec", self.containers[track], "sh", "-c", "command -v pg_prove"],
                         capture_output=True, text=True, check=False)
            self._pg_prove[track] = r.returncode == 0
        return self._pg_prove[track]

    def run_file(self, track, db, path):
        """True when the file FAILS: pg_prove's verdict where the image has it, else the regex over psql's output."""
        if self.has_pg_prove(track):
            c = self.containers[track]
            if track == "timescale":
                cmd = ["docker", "exec", "-e", "PGPASSWORD=postgres", c, "sh", "-c", f"pg_prove -h 127.0.0.1 -U postgres -d {db} {path}"]
            else:
                cmd = ["docker", "exec", c, "sh", "-c", f"pg_prove -U postgres -d {db} {path}"]
            return self.run(cmd, capture_output=True, text=True, check=False).returncode != 0
        r = self.psql(track, db, "-tAq", "-f", path, check=False, stop=False)
        return suite_verdict((r.stdout or "") + (r.stderr or ""))

    def core(self, tree, sid):
        remote, tmpl = f"/tmp/pgpm_seed_{sid.lower()}", f"pgpm_seed_{sid.lower()}_tmpl"
        self.ship("core", tree, remote)
        self.psql("core", "postgres", "-qc", f"drop database if exists {tmpl}")
        self.psql("core", "postgres", "-qc", f"create database {tmpl}")
        self.psql("core", tmpl, "-qc", "create extension if not exists pgtap")
        self.file("core", tmpl, "-q", "--single-transaction", path=os.path.join(tree, "pgpm_core", "install.sql"))
        self.psql("core", "postgres", "-qc", f"alter database {tmpl} set poc.seed_count = 8000; alter database {tmpl} set poc.events_count = 4000")
        self.file("core", tmpl, "-q", path=os.path.join(tree, "fixtures", "demo.sql"))
        failed, skipped, ran, cron_ready = [], [], 0, None
        files = sorted(f for f in os.listdir(os.path.join(tree, "tests")) if f.endswith(".sql"))
        for n, b in enumerate(files, 1):
            if b in CRON_DB_FILES:
                if cron_ready is None:
                    # pg_cron lives in cron.database_name (postgres): install the seeded tree there, as test.sh does,
                    # unless pgpm is already installed in it (then these files are skipped and said so)
                    has = self.psql("core", "postgres", "-tAc", "select count(*) from pg_namespace where nspname = 'pgpm'").stdout.strip()
                    cron_ready = has == "0"
                    if cron_ready:
                        self.psql("core", "postgres", "-qc", "create extension if not exists pg_cron; create extension if not exists pgtap")
                        self.file("core", "postgres", "-q", "--single-transaction", path=os.path.join(tree, "pgpm_core", "install.sql"))
                        self.psql("core", "postgres", "-qc", "alter database postgres set poc.seed_count = 8000; alter database postgres set poc.events_count = 4000")
                        self.file("core", "postgres", "-q", path=os.path.join(tree, "fixtures", "demo.sql"))
                if not cron_ready:
                    skipped.append(f"tests/{b}")
                    continue
                db = "postgres"
            else:
                db = f"pgpm_seed_{sid.lower()}_{n}"
                self.psql("core", "postgres", "-qc", f"drop database if exists {db}")
                self.psql("core", "postgres", "-qc", f"create database {db} template {tmpl}")
            ran += 1
            if self.run_file("core", db, f"{remote}/tests/{b}"):
                failed.append(f"tests/{b}")
            if db != "postgres":
                self.psql("core", "postgres", "-qc", f"drop database if exists {db}", check=False)
        if cron_ready:
            # the cron database is shared: take the seeded install and the fixtures out again, as test.sh does
            self.file("core", "postgres", "-q", "--single-transaction", path=os.path.join(tree, "pgpm_core", "uninstall.sql"))
            self.psql("core", "postgres", "-qc", "drop table if exists public.messages, public.events_id, public.events_uuid cascade; "
                      "drop function if exists public.generate_messages(int, int)", check=False)
        self.psql("core", "postgres", "-qc", f"drop database if exists {tmpl}", check=False)
        return failed, skipped, ran

    def archive(self, tree, sid):
        remote, tmpl = f"/tmp/pgpm_seed_{sid.lower()}", f"pgpm_seed_{sid.lower()}_tmpl"
        self.ship("archive", tree, remote)
        self.psql("archive", "postgres", "-qc", f"drop database if exists {tmpl}")
        self.psql("archive", "postgres", "-qc", f"create database {tmpl}")
        self.psql("archive", tmpl, "-qc", "create extension if not exists http; create extension if not exists pgcrypto; create extension if not exists pgtap")
        self.file("archive", tmpl, "-q", path=os.path.join(tree, "tests", "archive", "fixtures.sql"))
        self.file("archive", tmpl, "-q", "--single-transaction", path=os.path.join(tree, "pgpm_core", "install.sql"))
        self.file("archive", tmpl, "-q", path=os.path.join(tree, "pgpm_archive", "install.sql"))
        failed, ran = [], 0
        files = sorted(f for f in os.listdir(os.path.join(tree, "tests", "archive", "db")) if f.endswith(".sql"))
        for n, b in enumerate(files, 1):
            db = f"pgpm_seed_{sid.lower()}_{n}"
            self.psql("archive", "postgres", "-qc", f"drop database if exists {db}")
            self.psql("archive", "postgres", "-qc", f"create database {db} template {tmpl}")
            ran += 1
            if self.run_file("archive", db, f"{remote}/tests/archive/db/{b}"):
                failed.append(f"tests/archive/db/{b}")
            self.psql("archive", "postgres", "-qc", f"drop database if exists {db}", check=False)
        self.psql("archive", "postgres", "-qc", f"drop database if exists {tmpl}", check=False)
        return failed, [], ran

    def timescale(self, tree, sid):
        remote = f"/tmp/pgpm_seed_{sid.lower()}"
        self.ship("timescale", tree, remote)
        failed, ran = [], 0
        files = sorted(f for f in os.listdir(os.path.join(tree, "tests", "timescale", "db")) if f.endswith(".sql"))
        for n, b in enumerate(files, 1):
            db = f"pgpm_seed_{sid.lower()}_{n}"
            self.psql("timescale", "postgres", "-qc", f"drop database if exists {db}")
            self.psql("timescale", "postgres", "-qc", f"create database {db}")
            self.psql("timescale", "postgres", "-qc", f"alter database {db} set client_min_messages = warning")
            self.psql("timescale", db, "-qc", "create extension if not exists timescaledb; create extension if not exists pgtap")
            self.file("timescale", db, "-q", "--single-transaction", path=os.path.join(tree, "pgpm_core", "install.sql"))
            self.file("timescale", db, "-q", path=os.path.join(tree, "pgpm_hypertable", "install.sql"))
            self.file("timescale", db, "-q", path=os.path.join(tree, "tests", "timescale", "fixtures.sql"))
            ran += 1
            if self.run_file("timescale", db, f"{remote}/tests/timescale/db/{b}"):
                failed.append(f"tests/timescale/db/{b}")
            self.psql("timescale", "postgres", "-qc", f"drop database if exists {db}", check=False)
        return failed, [], ran


def suite_check(sealed, pristine, seeds_dir, work, runner, only=None, rebaseline=False):
    """For each seed (or those in `only`), plant it alone and run its suite; record suite_track, suite_ran,
    suite_caught (the failing files, less the baseline's), suite_noise (the failing files the baseline also
    fails) and suite_skipped on the seed in place. The baseline, the UNSEEDED tree's suite per track, runs
    once and is sealed as suite_baseline; an existing one is reused unless `rebaseline`. Returns the seeds
    measured."""
    baseline = sealed.setdefault("suite_baseline", {})
    rows = []
    for seed in sealed["seeds"]:
        if only and seed["id"] not in only:
            continue
        track = seed_track(seed)
        if track not in baseline or rebaseline:
            tree = os.path.join(work, f"baseline_{track}")
            if os.path.isdir(tree):
                shutil.rmtree(tree)
            isolate_seed(pristine, None, seeds_dir, tree)
            failed, _skipped, ran = getattr(runner, track)(tree, f"base_{track}")
            baseline[track] = {"failed": failed, "ran": ran}
        tree = os.path.join(work, seed["id"])
        if os.path.isdir(tree):
            shutil.rmtree(tree)
        isolate_seed(pristine, seed, seeds_dir, tree)
        failed, skipped, ran = getattr(runner, track)(tree, seed["id"])
        noise = [f for f in failed if f in baseline[track]["failed"]]
        seed["suite_track"], seed["suite_ran"] = track, ran
        seed["suite_caught"] = [f for f in failed if f not in noise]
        for key, val in (("suite_noise", noise), ("suite_skipped", skipped)):
            if val:
                seed[key] = val
            else:
                seed.pop(key, None)
        rows.append(seed)
    return rows


def baseline_line(track, b):
    state = f"fails without any seed: {', '.join(b['failed'])} (noise, not a catch)" if b["failed"] else "clean"
    return f"baseline\t{track}\t{b['ran']} files\t{state}"


def suite_line(seed):
    caught = seed.get("suite_caught")
    state = f"caught by {', '.join(caught)}" if caught else "not caught"
    noise = f"; noise {', '.join(seed['suite_noise'])}" if seed.get("suite_noise") else ""
    skipped = f"; skipped {', '.join(seed['suite_skipped'])}" if seed.get("suite_skipped") else ""
    return f"{seed['id']}\t{seed.get('suite_track', '?')}\t{seed.get('suite_ran', 0)} files\t{state}{noise}{skipped}"


def selftest_suite():
    """The suite check: a seed's track follows its file; the verdict is test.sh's; a patch seed is planted
    alone (end to end, with a scratch pristine tree whose suite directories are copied and the patched file
    carried along); each seed is sealed with its track, count and the files that caught it; --only restricts."""
    import tempfile
    assert seed_track({"file": "pgpm_core/install.sql"}) == "core" and seed_track({}) == "core"
    assert seed_track({"file": "pgpm_archive/install.sql"}) == "archive" and seed_track({"file": "tests/archive/db/16_x.sql"}) == "archive"
    assert seed_track({"file": "pgpm_hypertable/install.sql"}) == "timescale" and seed_track({"file": "tests/timescale/fixtures.sql"}) == "timescale"
    assert seed_track({"file": "docs/runbook.md"}) == "core" and seed_track({"file": "bench/retire_straddle.sh"}) == "core"
    assert suite_verdict("ok 1 - a\nnot ok 2 - b\n") and suite_verdict("ok 1\n# Looks like you planned 3 tests but ran 2\n")
    assert suite_verdict("psql:x.sql:4: ERROR:  relation \"t\" does not exist\n") and not suite_verdict("ok 1 - a\nok 2 - b\n1..2\n")
    assert not suite_verdict("# a comment that mentions not ok in passing\n ok 1\n")
    with tempfile.TemporaryDirectory() as tmp:
        pristine = os.path.join(tmp, "pristine")
        for d in ("tests", "fixtures", "pgpm_core", "docs", "bench/mutations"):
            os.makedirs(os.path.join(pristine, d))
        for rel, text in (("tests/01_a_test.sql", "select 1;\n"), ("fixtures/demo.sql", "-- demo\n"),
                          ("pgpm_core/install.sql", "-- core\nline 2\n"), ("docs/runbook.md", "p1\np2\n")):
            with open(os.path.join(pristine, rel), "w") as fh:
                fh.write(text)
        seeds_dir = os.path.join(tmp, "seeds")
        os.makedirs(seeds_dir)
        with open(os.path.join(seeds_dir, "doc.patch"), "w") as fh:
            fh.write("--- a/docs/runbook.md\n+++ b/docs/runbook.md\n@@ -1,2 +1,2 @@\n p1\n-p2\n+P2\n")
        with open(os.path.join(seeds_dir, "core.patch"), "w") as fh:
            fh.write("--- a/pgpm_core/install.sql\n+++ b/pgpm_core/install.sql\n@@ -1,2 +1,2 @@\n -- core\n-line 2\n+LINE 2\n")
        sealed = {"seeds": [{"id": "S1", "kind": "patch", "patch": "core.patch", "file": "pgpm_core/install.sql", "lens": "x", "tier": 1},
                            {"id": "S2", "kind": "patch", "patch": "doc.patch", "file": "docs/runbook.md", "lens": "y", "tier": 3},
                            {"id": "S3", "kind": "patch", "patch": "core.patch", "file": "pgpm_core/install.sql", "lens": "z", "tier": 2}]}
        seen = []

        class FakeRunner:
            # tests/147 fails on every tree, seed or none (the smoke run's provoked statement timeout): noise
            def core(self, tree, sid):
                seen.append((sid, open(os.path.join(tree, "pgpm_core", "install.sql")).read(),
                             open(os.path.join(tree, "docs", "runbook.md")).read() if os.path.exists(os.path.join(tree, "docs", "runbook.md")) else None))
                failed = ["tests/147_sweep_test.sql"] + (["tests/01_a_test.sql"] if sid == "S1" else [])
                return failed, (["tests/31_schedule_test.sql"] if sid == "S2" else []), 167
        work = os.path.join(tmp, "work")
        os.makedirs(work)
        rows = suite_check(sealed, pristine, seeds_dir, work, FakeRunner(), only={"S1", "S2"})
        assert [r["id"] for r in rows] == ["S1", "S2"] and "suite_caught" not in sealed["seeds"][2], sealed
        s1, s2 = sealed["seeds"][0], sealed["seeds"][1]
        assert sealed["suite_baseline"] == {"core": {"failed": ["tests/147_sweep_test.sql"], "ran": 167}}, sealed["suite_baseline"]
        assert s1["suite_caught"] == ["tests/01_a_test.sql"] and s1["suite_noise"] == ["tests/147_sweep_test.sql"], s1
        assert s1["suite_ran"] == 167 and s1["suite_track"] == "core", s1
        assert s2["suite_caught"] == [] and s2["suite_noise"] == ["tests/147_sweep_test.sql"] and s2["suite_skipped"] == ["tests/31_schedule_test.sql"], s2
        # the baseline ran ONCE, on an unseeded tree, before the seeds; each seed tree carried ITS seed alone:
        # S1's install is patched and its doc is pristine, S2's the reverse
        assert [sid for sid, _c, _d in seen] == ["base_core", "S1", "S2"], seen
        by = {sid: (core, doc) for sid, core, doc in seen}
        assert by["base_core"] == ("-- core\nline 2\n", None), by
        assert by["S1"] == ("-- core\nLINE 2\n", None) and by["S2"] == ("-- core\nline 2\n", "p1\nP2\n"), by
        assert suite_line(s1) == "S1\tcore\t167 files\tcaught by tests/01_a_test.sql; noise tests/147_sweep_test.sql", suite_line(s1)
        assert suite_line(s2) == "S2\tcore\t167 files\tnot caught; noise tests/147_sweep_test.sql; skipped tests/31_schedule_test.sql", suite_line(s2)
        assert baseline_line("core", sealed["suite_baseline"]["core"]) == "baseline\tcore\t167 files\tfails without any seed: tests/147_sweep_test.sql (noise, not a catch)"
        assert baseline_line("core", {"failed": [], "ran": 3}) == "baseline\tcore\t3 files\tclean"
        # a re-measure of one seed reuses the sealed baseline (no second baseline run) unless asked to redo it
        seen.clear()
        suite_check(sealed, pristine, seeds_dir, work, FakeRunner(), only={"S3"})
        assert [sid for sid, _c, _d in seen] == ["S3"] and sealed["seeds"][2]["suite_noise"] == ["tests/147_sweep_test.sql"], seen
        seen.clear()
        suite_check(sealed, pristine, seeds_dir, work, FakeRunner(), only={"S3"}, rebaseline=True)
        assert [sid for sid, _c, _d in seen] == ["base_core", "S3"], seen
    r = SuiteRunner({"core": "c", "archive": "a", "timescale": "t"})
    assert r.prefix("timescale", "d")[:5] == ["docker", "exec", "-i", "-e", "PGPASSWORD=postgres"] and "-h" in r.prefix("timescale", "d")
    assert r.prefix("core", "d") == ["docker", "exec", "-i", "c", "psql", "-U", "postgres", "-d", "d"]


def selftest_side_effects():
    """A seed's side_effects string reaches sealed.json unchanged (end to end: a real plant of a patch
    seed into a throwaway git tree), a seed without one gets no key, and the catalogue carries the
    optional SIDE_EFFECTS entry only where the catalogue module defines one."""
    import tempfile
    import types
    with tempfile.TemporaryDirectory() as tmp:
        git = ["git", "-c", "user.name=t", "-c", "user.email=t@localhost"]
        pristine, tree = os.path.join(tmp, "pristine"), os.path.join(tmp, "tree")
        for d in (pristine, tree):
            os.makedirs(os.path.join(d, "bench", "mutations"))
            for f in ("x.sql", "y.sql"):
                with open(os.path.join(d, f), "w") as fh:
                    fh.write("line 1\nline 2\nline 3\n")
            subprocess.run(["git", "init", "-q", d], check=True)
        # the pristine side needs a catalogue module to import; this one is empty
        with open(os.path.join(pristine, "bench", "mutations", "mutate.py"), "w") as fh:
            fh.write("MUTATIONS = {}\nMUTATION_SRC = {}\nMUTATION_TRACK = {}\n")
        for d in (pristine, tree):
            subprocess.run(git + ["-C", d, "add", "-A"], check=True)
            subprocess.run(git + ["-C", d, "commit", "-q", "-m", "one"], check=True)
        patches = []
        for f in ("x.sql", "y.sql"):
            pp = os.path.join(tmp, f"{f}.patch")
            with open(pp, "w") as fh:
                fh.write(f"--- a/{f}\n+++ b/{f}\n@@ -1,3 +1,3 @@\n line 1\n-line 2\n+LINE 2\n line 3\n")
            patches.append(pp)
        effect = "freezes the monolith: every table converted on the tree reads as frozen"
        plan = {"seeds": [{"patch": patches[0], "lens": "x", "tier": 1, "file": "x.sql", "side_effects": effect},
                          {"patch": patches[1], "lens": "y", "tier": 2, "file": "y.sql"}]}
        sealed_path = os.path.join(tmp, "sealed.json")
        saved_path, saved_mod = list(sys.path), sys.modules.pop("mutate", None)
        try:
            plant(tree, pristine, plan, sealed_path,
                  run=lambda cmd, **kw: subprocess.run(cmd, **{"capture_output": True, **kw}))
        finally:
            sys.path[:] = saved_path
            sys.modules.pop("mutate", None)
            if saved_mod is not None:
                sys.modules["mutate"] = saved_mod
        with open(sealed_path) as fh:
            sealed = json.load(fh)
        s1, s2 = sealed["seeds"]
        assert s1["side_effects"] == effect, s1
        assert "side_effects" not in s2, s2
    fake = types.SimpleNamespace(
        MUTATIONS={"a": ("g.sh", "why a", []), "b": ("h.sh", "why b", [])},
        MUTATION_SRC={}, MUTATION_TRACK={}, SIDE_EFFECTS={"a": "disables the tick"})
    rows = {r["mutation"]: r for r in catalogue(fake)}
    assert rows["a"]["side_effects"] == "disables the tick" and "side_effects" not in rows["b"], rows
    del fake.SIDE_EFFECTS
    assert all("side_effects" not in r for r in catalogue(fake))
    assert catalogue_line(rows["a"]).endswith("\tside effects: disables the tick"), catalogue_line(rows["a"])
    assert "side effects" not in catalogue_line(rows["b"])


def selftest():
    # touched_lines: a literal pattern and a regex pattern, each at a known line
    text = "a\nb\nfoo(1)\nc\nfoo(2)\n"
    assert touched_lines(text, [("foo(", "", 2)]) == [3, 5]
    assert touched_lines(text, [(re.compile(r"foo\(2\)"), "", 1)]) == [5]
    # patch_lines: two hunks in one file, pristine-side numbering
    patch = "--- a/x.sql\n+++ b/x.sql\n@@ -10,3 +10,3 @@\n-old\n+new\n@@ -40 +40 @@\n-o\n+n\n"
    assert patch_lines(patch) == {"x.sql": [10, 11, 12, 40]}
    # the plan is validated before anything is touched: no source, both sources, missing lens/tier, empty
    for bad, word in (({"seeds": [{"lens": "x", "tier": 1}]}, "exactly one"),
                      ({"seeds": [{"mutation": "m", "patch": "p", "lens": "x", "tier": 1}]}, "exactly one"),
                      ({"seeds": [{"mutation": "m", "tier": 1}]}, "lens"),
                      ({"seeds": []}, "no seeds")):
        try:
            validate(bad)
        except SystemExit as e:
            assert word in str(e), (word, str(e))
        else:
            raise AssertionError(f"accepted a bad plan: {bad}")
    try:
        validate({"seeds": [{"mutation": "m", "lens": "x", "tier": 1, "side_effects": ["not", "a", "string"]}]})
    except SystemExit as e:
        assert "side_effects" in str(e), str(e)
    else:
        raise AssertionError("accepted a non-string side_effects")
    selftest_side_effects()
    selftest_suite()
    print("plant_seeds selftest: PASS")
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--tree")
    ap.add_argument("--pristine", default=os.path.join(os.path.dirname(__file__), "..", ".."))
    ap.add_argument("--plan")
    ap.add_argument("--sealed")
    ap.add_argument("--catalogue", action="store_true")
    ap.add_argument("--suite", action="store_true", help="plant each sealed seed alone and run its pgTAP suite; seals suite_caught")
    ap.add_argument("--seeds-dir", help="directory holding the novel seed patches (needed by --suite for patch seeds)")
    ap.add_argument("--only", help="comma-separated seed ids for --suite (default all)")
    ap.add_argument("--rebaseline", action="store_true", help="--suite: run the unseeded control again even when the sealed record has one")
    ap.add_argument("--work", help="scratch directory for the one-seed trees (default a temporary one)")
    ap.add_argument("--container", default=HARNESS_DEFAULTS["core"], help="the core harness (default pgpm_test-15)")
    ap.add_argument("--archive-container", default=HARNESS_DEFAULTS["archive"])
    ap.add_argument("--timescale-container", default=HARNESS_DEFAULTS["timescale"])
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args()
    if a.selftest:
        return selftest()
    pristine = os.path.abspath(a.pristine)
    if a.catalogue:
        for r in catalogue(load_mutate(pristine)):
            print(catalogue_line(r))
        return 0
    if a.suite:
        if not a.sealed:
            ap.error("--suite needs --sealed (the record plant_seeds.py wrote)")
        import tempfile
        with open(a.sealed) as fh:
            sealed = json.load(fh)
        work = os.path.abspath(a.work) if a.work else tempfile.mkdtemp(prefix="pgpm_seed_suite_")
        os.makedirs(work, exist_ok=True)
        runner = SuiteRunner({"core": a.container, "archive": a.archive_container, "timescale": a.timescale_container})
        rows = suite_check(sealed, pristine, os.path.abspath(a.seeds_dir) if a.seeds_dir else None, work, runner,
                           only=set(a.only.split(",")) if a.only else None, rebaseline=a.rebaseline)
        with open(a.sealed, "w") as fh:
            json.dump(sealed, fh, indent=2)
        for track, b in sorted(sealed.get("suite_baseline", {}).items()):
            print(baseline_line(track, b))
        for s in rows:
            print(suite_line(s))
        measured = [s for s in sealed["seeds"] if "suite_caught" in s]
        caught = [s for s in measured if s["suite_caught"]]
        print(f"suite-caught {len(caught)} of {len(measured)} measured seed(s); read-caught {len(measured) - len(caught)}"
              + (f"; {len(sealed['seeds']) - len(measured)} not yet measured" if len(measured) < len(sealed["seeds"]) else "")
              + f"; sealed record updated: {a.sealed}")
        return 0
    if not (a.tree and a.plan and a.sealed):
        ap.error("--tree, --plan and --sealed are required to plant")
    with open(a.plan) as fh:
        plan = json.load(fh)
    sealed = plant(os.path.abspath(a.tree), pristine, plan, a.sealed)
    print(f"planted {len(sealed['seeds'])} seed(s) into {a.tree}; sealed record: {a.sealed}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
