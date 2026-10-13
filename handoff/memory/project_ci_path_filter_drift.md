---
name: project-ci-path-filter-drift
description: "CI path filters drift behind what each test.sh track actually runs; all four track workflows fixed 2026-09-22; the finding script is worth making a lint job"
metadata: 
  node_type: memory
  type: project
  originSessionId: 0bfe9ec5-03bb-432c-aea6-f666d65e1065
  modified: 2026-09-22T23:31:25.907Z
---

GitHub Actions path filters in this repo are hand-maintained lists of what a workflow watches, and
they drift behind what the corresponding `test.sh` track actually invokes. Same defect class as
[[project_next_issue_417]], one level up: a list of what to check, falling behind what exists, with
nothing reporting it. Found and partly fixed 2026-09-22.

**Fixed:**

- **`perf.yml`** (PR #419, `0cb4476`): enumerated its guards and four of the thirteen `run_perf`
  runs were missing, including `bench/upgrade_in_place.sh`. Now `bench/*.sh`, which is an exact
  shape because every perf guard IS a top-level bench shell script.
- **`lockview.yml`** (PR #423, `c688247`): its seven lock-view file entries were already complete
  (verified, not assumed). The gap was `docker-compose.yml` and `Dockerfile`, which define and build
  the `locktrace` service the track runs in.
- **`archive.yml`** (PR #424, `30c13ba`): omitted all four `bench/archive_*.sh` guards
  `run_archive` runs. Now a `bench/archive_*.sh` glob, which IS an exact shape here (4 of 4, nothing
  else in `bench/` matches), unlike lockview's case. Deliberately not `bench/*.sh`: that would start
  the MinIO-and-pyarrow track on every unrelated bench edit.

**CLASS RETIRED (PR #425, `c4ce9c8`):** `scripts/check_track_filters.py` plus a `Track path filters`
job in `lint.yml` now enforces this on every push and PR. Deliberately unfiltered and cheap (~4 s,
no container): a check on path filters must not itself be path-filtered. Five workflows verify.
Stop hand-auditing filters; run the script.

**Two things worth not re-deriving:**

1. **A glob is not always the fix.** `lockview.yml` deliberately STAYS an enumeration:
   `bench/lock_view*` misses `plot_lock_view.py` and `lock_timeout_pairing_demo.sh`, two of seven,
   and a glob covering five of seven is worse than a list because it reads as a rule and is not one.
   The workflow header now says this, so the asymmetry with `perf.yml` does not invite a "fix".
2. **"Workflow B lists it" is never coverage.** `lockview.yml`'s header already records this being
   got wrong once for `test.sh` (locktrace.yml lists it, but its one step never runs the lockview
   track), and `docker-compose.yml`/`Dockerfile` were missing for the identical reason.

**The blind spot that nearly shipped in the checker itself, worth remembering as a pattern:** a
path regex over a track body CANNOT see the compose dependency. A track says `$DC --profile x up`
and never names `docker-compose.yml` or `Dockerfile`, so the first cut of `check_track_filters.py`
reproduced #419 and #424 and stayed GREEN on #423. Found only by running the new checker against
the three REAL historical defects instead of trusting its synthetic fixtures. **Do that whenever
building a checker for a class you have real instances of** -- the instances are the mutation set,
and they are free.

Two smaller design notes now encoded in the script: strip only FULL-LINE comments (over-stripping
hides an invocation silently, under-stripping is loud), and DERIVE the workflow-to-track map from
parsed `run:` steps rather than hardcoding it (a hardcoded map is the same rotting list; deriving it
turned up `observe.yml`, which the by-hand sweep had missed).
