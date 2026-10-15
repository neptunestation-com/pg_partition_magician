# Where the core's growth came from (analysis of 2026-10-14)

Handoff note for a new session. Question from the maintainer: `pgpm_core/install.sql` has grown almost 3x since
`v0.6.0` with no new functionality; where did the growth come from, and what could be done about it? This file
records every measurement, the method behind it, what each result does and does not show, and what was decided.

Everything below was measured on `main` as of 2026-10-14 (`f3a2b639`, then `e60771a7`), against `v0.6.0`.
Figures marked "(carried)" come from the earlier part of the session and were not re-run when this file was
written; the rest were re-run or computed in the final stretch of the session.

## Outcome in five lines

1. The growth is real code, not comments: executable lines 2,900 to 8,205 (2.8x), minified 151 KB to 477 KB (3.2x).
2. It is not copy-paste, and it is not features: 246 commits, all `fix`, `perf` or `docs` bar one `feat`
   (`pgpm.progress()`, +176 lines), about five lines added for each removed.
3. It is many small distinct guards, records and carries. In the conversion path about 66% of the added lines answer
   defects one session reaches with some table shape, argument or prior state; about 15% answer a race.
4. Consolidation (a shared re-ask mechanism, one identity layer) has a ceiling of roughly 10 to 16% of the growth.
   No lever found takes the core back near its old size; 2.8x could become about 2.4x at best.
5. What changed: PR #1326 (merged as `58c8a592`) added a "Size budget" section to `docs/adversarial-review.md`,
   wired into the fixer agent and `/pr-verify`. It reports and asks; it never blocks on size, and sets no ceiling.

## What the user said, in order (so the next session keeps the frame)

- First worry: code growth, then "growing by 2.83x to fix bugs without adding features". Minified size is the better
  estimate of logic growth.
- The concern is growth in the core most of all. Archive (`pgpm_archive`) and hypertable (`pgpm_hypertable`) are
  already separate modules. **Regrain lives in `pgpm_core` and is fundamental: there is zero chance it becomes its own
  module.** A proposal to measure splitting out optional modules was wrong and was withdrawn.
- Not interested in guard coverage per se; interested in why the size grew.

## Measurements

### 1. Size over passes (carried)

Line counts at each pass pin (p1 = `v0.6.0`, p2 `581e87a`, p3 `db64096e`, p4 `b52a0d97`, p5 `47a293a7`, p6 `ae5dddc0`,
p7 `4060f6b5`, p8 `ddf130c4`, p9 `06643c8a`, p10 `0654e1ea`, p11 `0c38aae5`, p12 `bd55f840`):

| area | pass 1 | pass 12 | factor |
| --- | --- | --- | --- |
| core `install.sql` lines | 5,429 | 15,085 | 2.8x |
| `tests/` | 8.8k | 67.8k | 7.7x |
| `bench/` | 29k | 73k | 2.5x |
| `scripts/` | 2.9k | 13k | 4.5x |
| docs | 9.8k | 24.3k | 2.5x |

Minified with `scripts/minify_sql.py` (the dbdev build's definition of what counts): core 151k to 442k at the pass-12
pin; all three install files together 268k to 647k (2.4x). Core crossed dbdev's 250,000-character cap between pass 4
and pass 6. **Re-measured 2026-10-14 on `main` at `f3a2b639`: core 477,214, archive 127,648, hypertable 86,619.**
Core kept growing after pass 12's pin (+35 KB in 48 commits, the pass-12 fix phase).

### 2. What kind of line was added (re-run)

Of the 11,874 lines `v0.6.0..origin/main` added to `pgpm_core/install.sql` (classified on the final file by a
lexical scan: comment lines, `RAISE` statements, everything else):

| kind | added | share |
| --- | --- | --- |
| code | 5,608 | 47% |
| comments | 5,571 | 47% |
| error and log message text | 433 | 4% |
| blank | 262 | 2% |

Half of the raw line growth is comments, which the minifier strips. The executable-line growth (2,900 to 8,125 at the
time, 8,205 after the last pull) matches the minified growth, so the 2.8x is not comment inflation.

**Correction (2026-10-15).** The 4% figure for message text counts the `raise` LINE alone. A message in this file
runs over the lines that follow it, so those lines were counted as code. Measured as whole statements on the
minified text, `raise exception` is 86 KB (18% of the file, 11% at `v0.6.0`), and with `pgpm.log` inserts and
notices, message text is 111 KB and accounts for 87 KB (26%) of the growth. The "47% code" row above is
overstated by about the same amount. See `docs/core-growth-analysis-2026-10-15.md`, section 2, and
`scripts/core_growth.py report`, which measures it. The same note revisits section 5 (the clone detector could not
see a block copied under new variable names; measured so, the growth is LESS self-similar than the original code)
and section 9 (the structural carry it calls unchecked exists in `pgpm_hypertable`).

New versus existing functions (5,608 added code lines): 3,262 (58%) in about 150 new functions, 2,346 (42%) inside
functions that already existed. Public functions went 36 to 39 (`adopt_partition`, `hand_over_scratch`,
`set_partition_tz`), internal helpers 45 to 181, tables 7 to 11. Functions overall: 79 to 229 (re-run).

### 3. Commit history (re-run)

246 non-merge commits touched the core since `v0.6.0`; all `fix`, `perf` or `docs` except
`a72c5bf9 feat(observe): pgpm.progress() and status().regrain_to` (#438, 2026-09-24, +176). Added 13,307 lines,
removed 2,714 across those commits (about 5:1; per-commit sums, not the net diff). An earlier
"215 commits, none feat" figure was wrong in both numbers; use these.

Of 142 PR merges (first-parent) that touched the core, measured as the change in minified core size from the merge's
first parent to the merge: **140 grew it, 2 shrank it**. Net minified delta per PR: median +1,266, 75th percentile
+2,387, 90th +4,704, max +10,152, min -64, sum +260,679.

### 4. Where the growth is, by function (re-run)

Net growth in core function code lines by function name, 5,319 total (a function counted from `create ... function`
to its last line, comments and blanks excluded):

| area | growth | share |
| --- | --- | --- |
| transmute, untransmute, preflight, identity, grid and key helpers | +1,571 | 30% |
| regrain | +1,249 | 23% |
| retire, retain, detach, adopt, scratch, disown, chunk marking | +934 | 18% |
| other (snapshot wait, timezone, time-unit contracts) | +652 | 12% |
| status, progress, install-surface check | +359 | 7% |
| obtain, extend, maintain, schedule, write block | +231 | 4% |
| archive hooks in core (`_archive_step`, ledger readers) | +186 | 3.5% |
| grants, ACLs, owners | +137 | 2.6% |

By function name there is no hypertable code in core, and archive hooks are 3.5% of growth, so about 96% of core's
growth is core's own logic. **A first version of this table, built from commit subjects, put archive and timescale at
about 30% of growth. It was wrong: a commit that mentions "archive" or "cutover" often only touched the hooks or the
transmute cutover in core.** Use the function-based table.

Largest single growers: `_transmute` +320, `untransmute` +207, `_identity_reseed` +89, `_control_bound_contract` +75,
`_transmute_carried_indexes` +67, `_snapshot_wait` +118, `adopt_partition` +117 (new), `_retain_recall` +100 (new).

### 5. Is it duplication? (carried)

Strict clone detector (window of 6 normalised lines, literals normalised): clone share fell from 13.3% at `v0.6.0` to
7.4% now; loose (identifiers wildcarded, window 5) from 20.0% to 13.1%. 70% of the growth is in 190 new functions (median
14.5 lines, 149 of them 30 lines or shorter), 34% inside existing functions. Conclusion: not copy-paste.

### 6. The 15 largest fix commits, tagged (re-run, from commit messages and diffs)

About 2,630 net lines, roughly a quarter of the growth. Tags: a = a guard or re-ask repeated across statements or entry
points; b = recovery or state-record machinery; c = new logic.

| commit | net | what | tag |
| --- | --- | --- | --- |
| 126190ed cutover refuses held names, publications, strict isolation | 248 | each naming statement re-asks from its own failure | a |
| c45e9a1a EXCLUDE and publication refusals, owner and comments carried back | 202 | up-front refusals, legibility | a |
| 2f0ec382 one shared preflight | 193 | null refusal across 38 routines, control-type contract, key gates | a |
| e1e7e8e5 read grants and keys under the lock | 172 | re-read after the lock | a |
| 27d8a368 archive hold asked again | 133 | one more re-ask | a |
| 37b2ded6 scratch relations by record | 252 | `pgpm.scratch` table, mint and resolve | b |
| 2fc07f4f retire vs a pending detach | 210 | witness record `detach_dispatched_oid` | b |
| ed5d73df `adopt_partition` | 159 | new repair entry point | b |
| b7a58cf6 retain recall | 153 | recall an armed detach, re-attach one that landed | b |
| e22991d6 ledger rows survive retire | 139 | `retired_at` marker, backfill | b |
| c4f15bd7 regrain capture by identity | 139 | oid anchors instead of names | b |
| b4486516 views survive reinstall | 129 | surface declaration and settle check | b |
| 31f61403 grid in a recorded timezone | 198 | recorded zone, rewritten grid | c |
| 8d3c97f8 index names and identity options | 132 | carry real identity options | c |
| a72c5bf9 `progress()` | 173 | the one `feat` | c |

Totals: a about 950 (36%), b about 1,180 (45%), c about 500 (19%). Caveat: these 15 are a quarter of the growth; no
extrapolation to the rest is supported, and the tags are the authors' own account in the commit messages plus a skim of
each diff, not a line-by-line read.

### 7. The identity-record hypothesis (re-run, partly supported)

Five of the class-b commits are one move: 0.6.0 found its own objects by name or comment string; review passes showed
that breaks under rename, restore and lookalikes; each fix then added its own oid record. Eight oid-anchor columns now
exist: `part.child_oid`, `part.retiring_oid`, `part.detach_dispatched_oid`, `archive_ledger.child_oid`,
`config.regrain_delta_oid`, `config.regrain_capture_fn_oid`, `config.monolith_oid`, `scratch.obj`. Mentions of `_oid`
went 47 to 282. `pgpm.part` carries three oids that all hold the same partition's oid in the normal case (they differ
in when written and in what null means, which is an upgrade-compatibility rule): the one clear merge candidate.

The functions whose job is to mint, record, resolve or vouch for an object by oid (scratch family, `_disown_*`, chunk
marking and backfill, regrain capture helpers, `_part_built`, and similar) total 838 lines, 10% of all function code,
about 760 of them growth. One identity layer might save a third to a half: 250 to 400 lines. The five mechanisms record
different things (partition row, retirement, archive chunk, regrain apparatus, scratch relation), so a shared layer would
unify the resolve-to-exactly-this-oid step, not the record shapes. **Hypothesis, not tested: nobody has compared the
five mechanisms for actual code overlap or prototyped a layer.**

### 8. What the conversion path's added code is for (re-run, a proxy)

Method: six functions (`_transmute`, `untransmute`, `_identity_reseed`, `_control_bound_contract`,
`_transmute_carried_indexes`, `retire`), 1,055 added code lines. Each added line was attached to the nearest `#NNN`
reference above it in the same contiguous added block (about 125 issues; titles pulled with `gh issue view`), then each
issue classified from its title. 18% of lines have no nearby reference.

By what it takes to hit the defect: one session with some table shape, argument or state 66%; another session committing
during the call 15% (13% concurrent-only plus 2% mixed); unattributed 18%; lock duration only 1%.

By purpose: carrying one more table attribute across the cutover 39%; up-front refusals for shapes the cutover cannot
convert 16%; unattributed 18%; other 13%; held names and type squatters 9%; grid, time and unit arithmetic 5%; lock
duration 1%. (Concurrency-flavoured attribute reads such as #656 and #732 were filed under "carry an attribute"; the
first cut is the better measure of concurrency.)

Caveats: classification is by me from titles, not from reproductions; multi-attribute issues were split evenly in the
next table; the dependent-views row is undercounted (#779's fix has no reference-bearing lines).

### 9. Attribute-by-attribute fidelity, the count asked for (re-run)

Twelve table attributes the cutover must reproduce, mapped by hand from issue titles to the issues that hardened each:

| attribute | issues | forward lines | reverse lines | total | lines per issue |
| --- | --- | --- | --- | --- | --- |
| keys (PK and UNIQUE: names, deferrable, shape) | 9 | 106 | 32 | 138 | 15 |
| grants, ACLs, owners | 10 | 66 | 37 | 103 | 10 |
| foreign keys (incoming and outgoing) | 9 | 90 | 7 | 97 | 11 |
| identity and sequences | 6 | 48 | 34 | 82 | 14 |
| publications | 4 | 52 | 24 | 76 | 19 |
| comments | 3 | 43 | 8 | 51 | 17 |
| row security and policies | 5 | 40 | 4 | 45 | 9 |
| replica identity | 2 | 20 | 10 | 30 | 15 |
| triggers | 3 | 17 | 6 | 23 | 8 |
| secondary indexes | 4 | 20 | 0 | 20 | 5 |
| tablespace | 1 | 12 | 0 | 12 | 12 |
| dependent views and row types | 2 | 1 | 1 | 2 | 1 |

679 lines, average 57 lines and 4.8 fix issues per attribute; the reverse path (`untransmute`) is 23% of the lines.

What it implies for the two options put to the maintainer:

- **Refuse rare shapes up front instead of carrying them: weak.** The big attributes (keys, grants, foreign keys,
  identity) are on every real table and cannot be refused. The small ones (tablespace, replica identity, RLS,
  publications, triggers) total about 190 lines, under 4% of core growth, and RLS and publications are common on
  Supabase.
- **One shared carry mechanism: ceiling about 680 lines (13% of core growth), realistically 5 to 7%.** Its stronger
  argument is 4.8 issues per attribute (grants and keys nine or ten each), which fits one hand-written mechanism being
  re-hardened repeatedly: fewer defects, not far fewer lines. Not prototyped; whether the catalogs make a structural
  carry easy is unchecked.

Combined with section 7 and the re-ask class in section 6, no lever found takes more than about 15% off the growth.

### 10. Defect density and age (carried)

T1 findings per pass, 1 to 12: 26, 7, 9, 7, 2, 5, 6, 4, 5, 2, 3, 4. Per 100 KB of minified code: 9.69, 2.26, 2.72, 2.02,
0.52, 1.20, 1.36, 0.84, 0.96, 0.36, 0.50, 0.62. Density fell until pass 5, then plateaued; the absolute count is flat at
about 4 per pass while tokens per T1 rose from about 0.5M to 2.8 to 3.7M. Caveats: finder budgets rose from 10 to 19,
lenses rotate, pass 1 used a different method.

Git-blame age of 45 T1 root causes (passes 2 to 11): 23 in original code, 13 in older fix-era code, 9 in code written
since the previous pass's pin. Base-rate expectation 30.8 / 10.5 / 3.7: **young code is over-represented 2.4x (p about
0.014)**, original code 0.75x. Caveat: exposure bias (new code has had no review pass yet). Pass 12 is not in the blame
data because its fixes had not merged.

### 11. Entry-point guard trace and REPEATABLE READ reproductions (carried, with one correction)

A call graph over the three install files (342 functions, 58 public entry points; scanner tracks comments, quoted strings
and dollar quotes) shows the fixes were added per entry point, not at a shared choke point. **Correction to an earlier
table:** a naive parser counted names inside string literals as calls. The real direct callers are:
`_refuse_strict_isolation`: `_transmute`, `from_hypertable`, `from_hypertable_cutover` (`untransmute` has its own inline
copy); `_refuse_detach_pending`: only `untransmute`; `_refuse_oid_bound_dependants`: `_transmute`, `untransmute`;
`_snapshot_wait`: `_regrain_snapshot_wait`, `from_hypertable_cutover`; `_enforce_write_blocks`: only `maintain`.
Ten functions set `lock_timeout` inline (16 sites now; 11 in 0.6.0). "Unreached" does not mean "vulnerable".

REPEATABLE READ reproductions on a throwaway container (a caller's snapshot predating another session's commit, with a
liveness witness each, and a READ COMMITTED control): only `adopt_partition` diverges silently (the known #1262,
reproduced for a pending and a hand detach); `retire`, `retain`, `obtain`, `extend_to` show no divergence beyond a log
action (`skip_retain` vs `fail_retain_drop` for a hand-detached partition, a Tier 3 or 4 note); `set_regrain` fails loudly
(`40001`). Not covered: `maintain` under a role default of REPEATABLE READ, `set_retain`, `untransmute`, the archive and
hypertable entry points, a late user row into a partition that `retire`/`retain` drops with an `archive_fn`, FK crossing
keys. The scripts lived in the session scratchpad and were not committed.

## What was decided and done

- PR #1308 (formal-methods context pack) landed earlier in the session.
- PR #1326, merged as `58c8a592`: "Size budget" section in `docs/adversarial-review.md` (Contents entry, a `size:` line
  in the pass-record template), a step in `.claude/agents/fixer.md`, a step 4b in `.claude/skills/pr-verify/SKILL.md`.
  The rule: every fix PR touching an install file reports a `Size:` line (net minified delta per install file, loop in the
  doc); a core delta above +4,700 minified characters needs a `Why this size:` paragraph (reachable by one session or
  only a concurrent one, a refusal in place of a carry, which helper was considered); the third fix to one mechanism is a
  proposal (shared mechanism or a `repeat site` adjacent observation), not a patch; pass records carry the minified size
  and its change. It never blocks on size alone and sets no ceiling.
- The +4,700 trigger was derived from past PRs (section 3) and is **not validated against real use**. Nothing enforces
  the rule mechanically; it relies on fixers and the coordinator.

## Reproduce the headline numbers

```bash
# minified size of each install file on main
for f in pgpm_core pgpm_archive pgpm_hypertable; do
  echo "$f $(python3 scripts/minify_sql.py $f/install.sql | wc -c)"
done

# the same at v0.6.0 (pass 1's pin)
git show v0.6.0:pgpm_core/install.sql | python3 scripts/minify_sql.py /dev/stdin | wc -c

# commits touching the core since v0.6.0, and their types
git log --no-merges --format=%s v0.6.0..origin/main -- pgpm_core/install.sql | wc -l
git log --no-merges --format=%s v0.6.0..origin/main -- pgpm_core/install.sql | grep -vcE '^(fix|perf|docs)'
```

The per-function, per-issue and per-attribute tables came from throwaway Python scripts (a function-boundary scanner over
the file, `git diff -U0 v0.6.0 origin/main` hunk line numbers for "added", `#NNN` reference carry-forward, and
`gh issue view` for titles). They were not committed; section 4 to 9's method paragraphs are enough to rebuild them, and
a session that wants them kept should put them under `scripts/` with a selftest rather than rebuild them again.

## Open questions for the maintainer, and next steps

1. **A ceiling.** The core is 477 KB minified against dbdev's 250 KB cap. What to refuse, move or accept is a
   maintainer decision; the size-budget section records it when made.
2. **Validate the trigger.** After the next fix phase, compare how many PRs crossed +4,700 and what their `Why this size:`
   paragraphs said.
3. **The identity layer.** Compare `pgpm.scratch`, `part.child_oid`, `part.retiring_oid`, `part.detach_dispatched_oid`,
   `archive_ledger.child_oid`/`retired_at` and the config oid columns for real overlap; merge `retiring_oid` and
   `detach_dispatched_oid` if the upgrade rule allows. A prototype would turn the 250 to 400 line estimate into a number.
4. **Structural carry for table attributes.** Check whether the catalogs allow rebuilding a parent from definitions
   instead of one hand-written step per attribute; the ceiling is about 680 lines and the main benefit is fewer
   re-hardening rounds (4.8 issues per attribute).
5. **Pass 13's record** should carry the first `size:` line (core 442 KB at pass 12's pin).
6. Unfinished RR coverage (section 11) if the isolation class is worth another look.
