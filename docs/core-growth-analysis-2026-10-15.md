# Where the core's growth came from, revisited (analysis of 2026-10-15)

Companion to `docs/core-growth-analysis-2026-10-14.md`. The maintainer's objection to that note: a core that grows
almost 3x by "fixing bugs" with guards, preconditions and postconditions, and no new functionality, and yet has no
refactoring in it, is implausible. This note re-did the analysis from the file rather than from the earlier note,
with measures that are now committed (`scripts/core_growth.py`, with a `--selftest` the lint workflow runs), so the
next size question starts from a command. Everything below is `v0.6.0` against `main` at `b5eaebe` (2026-10-15).

## Outcome in five lines

1. The growth is not duplicated code. With identifiers wildcarded, so a block copied under new variable names
   counts, the added code is LESS self-similar than the 0.6.0 code was (section 3). The earlier note reached the
   same conclusion from a detector that could not have seen the duplication had it been there.
2. A quarter of the growth is error-message and log text: 87 KB of the 330 KB. The earlier note put it at 4%
   because it counted a `raise` by its first line (section 2). Strip every message and the ratio is still 2.9x.
3. "No new functionality" is the wrong frame. 0.6.0's `transmute` carried no trigger states, replica identity,
   publications, tablespace, deferrable keys, index storage parameters or sequence ownership; its regrain did not
   survive an `ALTER TABLE` on the parent mid-run; its retire had no concurrent-detach state machine. Each shipped
   under `fix:` because it was found as a bug, and each is the product doing something it did not do (section 5).
4. A behaviour-preserving refactor recovers about 30 KB (6 to 7% of the file, 10% of the growth): the earlier
   note's ceiling, reached by a different route. The structural carry it called unchecked already exists in
   `pgpm_hypertable` and is the lever worth taking first, for the fix rate rather than the bytes (section 6).
5. The rest is the price of the product's online promises against three PostgreSQL facts: no in-place conversion
   to a partitioned table, no lock that blocks DDL but allows DML across a `COMMIT`, and copies that span many
   transactions. 0.6.0 was smaller because it made the same promises without keeping them (section 8).

## 1. Method

`scripts/core_growth.py report v0.6.0:pgpm_core/install.sql pgpm_core/install.sql` prints every number in sections
2 to 4 and 6. It minifies each file with `scripts/minify_sql.py` (what the dbdev package ships) and measures:

- every byte as literal, trailing comment, whitespace or code;
- whole statements (`raise`, `insert into pgpm.log`, `execute format`) from the keyword to the `;` that ends them
  outside parentheses and literals, so a message's continuation lines count as message;
- functions by their dollar-quote tag, so a `$f$` nested in a `$$` body does not end the function early;
- function bytes by family of name, with the share that is message or log text;
- bytes outside every function body, by statement kind;
- the share of tokens that lie in a window of W tokens that ANOTHER function also contains, with identifiers,
  literals and numbers wildcarded;
- message text: count, length, and the bytes inside a 12-word phrase that two or more messages share;
- call shapes and queries written out in full at every site.

Its `--selftest` runs each measure on a fixture with known answers and on a re-broken copy, and requires each to
move: a statement counter that read only the `raise` line, a clone measure blind to a renamed copy, or a function
scanner a nested dollar quote ends early, fails there. The three readings of the code behind sections 5 to 8 are
not mechanised; the function names and line counts they cite are.

## 2. Corrections to the 2026-10-14 note

**Message text is 26% of the growth, not 4%.** Whole statements on the minified text:

| | v0.6.0 | main | growth |
| --- | --- | --- | --- |
| minified bytes | 151,048 | 481,301 | +330,253 |
| string-literal bytes | 29,173 (19%) | 130,040 (27%) | +100,867 |
| `raise exception` statements | 74, 16,388 bytes (11%), median 171 | 229, 85,934 bytes (18%), median 318 | +69,546 |
| `insert into pgpm.log` statements | 46, 6,762 bytes | 87, 22,340 bytes | +15,578 |
| message and log text together | 23,772 (16%) | 110,971 (23%) | +87,199 (26% of growth) |
| everything else | 127,276 | 370,330 | 2.91x |

The message text itself (what is inside the quotes) is 65,712 bytes over 269 messages, median 212, p90 504, longest
831; 16,842 of those bytes sit in a 12-word phrase that another message also contains ("the cutover's ATTACH would
fail on it after the bound had been committed, leaving the table rejecting every write past it" is written three
times, with variations). Half of the `refuse` and `contract` families is message. The earlier note's "error and
log message text 4%" counted the `raise` line alone; its "code 47%" is overstated by the same amount.

**The structural carry is not unchecked.** Section 9 of the earlier note says "whether the catalogs make a
structural carry easy is unchecked". `pgpm_hypertable/install.sql` has `_from_hypertable_carried_ddl(rel) returns
text[]`: it captures owner, ACL, row security, policies, the table comment, triggers, replica identity and
publication memberships as DDL statements naming the table, and `from_hypertable_cutover` replays them with
`foreach ... execute`. Core writes the same captures out by hand twice: in `_transmute`'s cutover (about 13 KB
from the `ACCESS EXCLUSIVE` lock to the `pgpm.config` insert) and in `untransmute` (5 KB of capture under the lock,
5 KB of replay after the detach), each with its own copy of the policy builder, the trigger-state replay, the
`pg_depend` walk for owned sequences, the identity re-add, the comment loop and the replica-identity cases. No
catalog capability is missing; the shared function is an extraction of what exists.

**The clone detector answered a different question.** Section 5 measured windows of normalised LINES. This
repository never duplicates a line verbatim; it duplicates a block with `v_pol` renamed `v_g` and `p_parent`
renamed `p_hypertable`. A line-window detector cannot see that, so "clone share fell" was true and uninformative.
Section 3 measures it properly, and the conclusion holds anyway.

## 3. The duplication test

Share of tokens that lie in a window of W tokens that another function also contains, identifiers wildcarded:

| window | v0.6.0 | main |
| --- | --- | --- |
| 12 tokens | 61.7% | 57.7% |
| 16 tokens | 46.4% | 37.7% |
| 20 tokens | 36.4% | 26.0% |

In absolute terms at 20 tokens: 7,942 shared tokens of 21,790 at 0.6.0; 16,396 of 62,942 on main. Of the 41,152
tokens added, 8,454 (21%) are in a window another function also has, against 36% of the base. The style of
extracting a small helper per fix (80 functions to 232, median 14 minified lines) did what it was meant to: the new
code repeats itself less than the old code did. What it could not do is make 150 distinct mechanisms share shape.

The repeated call shapes that remain are small and listed in section 6; the largest, `pgpm._encode` with its ten
arguments at 45 sites, is 8,680 bytes.

## 4. Where the 330 KB went

Function bytes by family of name (`report`'s `families` block; the first matching pattern wins, so
`_transmute_refuse_*` is counted with transmute and `_regrain_refuse_strict_isolation` with regrain):

| family | v0.6.0 | main | growth | message share on main |
| --- | --- | --- | --- | --- |
| regrain | 29,069 (12 fns) | 106,177 (41 fns) | +77 KB (23%) | 25% |
| transmute / untransmute | 40,687 (6) | 107,890 (22) | +67 KB (20%) | 30% |
| retire / retain / detach / adopt / disown | 15,151 (9) | 55,620 (24) | +40 KB (12%) | 21% |
| other (named by none of the patterns) | 3,793 (8) | 23,425 (30) | +20 KB | 18% |
| obtain / extend / maintain / schedule | 18,484 (14) | 36,989 (22) | +19 KB | 15% |
| `_contract` helpers | 0 | 14,680 (6) | +15 KB | 51% |
| text_time / uuid / encode | 9,830 (12) | 20,548 (26) | +11 KB | 18% |
| identity / sequence / acl | 0 | 10,439 (13) | +10 KB | 10% |
| archive hooks | 5,066 (5) | 14,732 (8) | +10 KB | 25% |
| `_surface_*` (reinstall survival) | 0 | 9,221 (6) | +9 KB | 20% |
| scratch | 0 | 8,653 (9) | +9 KB | 16% |
| `_refuse_*` (shared) | 0 | 7,828 (5) | +8 KB | 49% |
| `_snapshot_wait` | 0 | 7,483 (1) | +7 KB | 35% |
| fk | 7,789 (5) | 13,782 (9) | +6 KB | 14% |
| status / progress / impact | 7,112 (4) | 12,371 (5) | +5 KB | 3% |
| write_block | 3,195 (5) | 5,640 (5) | +2 KB | 30% |
| top level (outside every body) | 10,872 | 25,823 | +15 KB | |

Top level on main: 12.2 KB of tables, grants and views; 5.8 KB of `drop ... if exists` for retired signatures;
4.3 KB of `alter table ... add column if not exists`; 1.6 KB of install-time calls; 1.1 KB of data backfills.
Function boilerplate (`create or replace function ... language plpgsql as $$ ... $$;`) is about 100 bytes per
function, so 150 new helpers cost about 15 KB: the price of the per-fix extraction that keeps section 3's numbers
where they are, and not a lever.

The largest functions: `_transmute` 57.6 KB (33.3 KB at 0.6.0; about 37 KB of it is preflight before the
validation scan, 13 KB the cutover's carry), `regrain_step` 29.4 KB (429 lines), `untransmute` 16.8 KB,
`_regrain_step_shape` 13.9 KB (7.6 KB of it literal: the step-shape contracts are messages with a function around
them), `retire` 10.2 KB, `_regrain_reconcile` 10.5 KB, `adopt_partition` 9.4 KB.

## 5. What "no new functionality" misses

Grep 0.6.0's `_transmute` for the attributes main carries: `tgenabled` 0, `relreplident` 0, `pg_publication` 0,
`reltablespace` 0, `condeferrable` 0, `reloptions` 0, sequences `owned by` 0. Trigger enabled states, replica
identity, publication memberships, tablespace, deferrable keys, index storage parameters, sequence ownership and
names, grants replayed as their grantor: none were carried. `untransmute` was 97 lines; it is 294 because it now
hands all of that back.

Regrain went from 12 functions to 41. 0.6.0 had the trigger, the batched copy, the delta reconcile and the swap.
Main adds: drift detection on the copies against the parent, on the source's relfilenode and columns, and on the
capture's key, with a restart (`_regrain_*_drift`, `_regrain_source_mark`); the lock-budget projection before the
swap (`_regrain_swap_budget`, `_regrain_fine_count`, and the measured-after-two-attaches check inside the swap);
`_snapshot_wait` before the swap; the truncate guard; grant following on the delta; step-shape contracts; copies
and the delta found by recorded oid. Retire went from a drop to a state machine over a concurrent detach that runs
in a separate job and can die: dispatch record (`detach_dispatched_oid`), recall (`_retain_recall`), disown
(`_disown_retirement`, `_disown_unvouched_retirements`), adopt (`adopt_partition`), chunk marking. Transmute gained a
claim with session identity so a resume can tell its own dead session from a live one. Scratch ownership follows
the table's owner. Public function shapes can change across a reinstall under a dependent view.

Each of these is a fix in the sense that something was wrong before. Each is also the mechanism doing more.

## 6. What a behaviour-preserving refactor recovers

No message text changed; estimates from the measured sizes of what each lever replaces.

| lever | saving | note |
| --- | --- | --- |
| R1: one `_table_carried_ddl(rel, target)` in core, used by `_transmute`, `untransmute` and `from_hypertable` | about 7 KB core, 6 KB hypertable | the benefit is 4.8 fix issues per attribute (earlier note, section 9) becoming about one |
| R2: overloads taking the `pgpm.config` row for `_encode` (45 sites, 8.7 KB), `_decode`, `_grid_floor` (35 sites, 3.1 KB), `_grid_next` (38 sites, 2.5 KB), `_part_name` | about 10 KB | mechanical; the seven `cfg.text_time_*` columns are spelled out 30 times |
| R3: one `_exec_naming()` wrapper for the four naming statements in `_transmute` and `obtain`, three of which carry the identical `duplicate_table` / `tuple concurrently updated` scaffold | about 2 KB | |
| R4: `regrain_step` as prepare, restart, copy and swap phases with a `_regrain_sub_range()` helper (the sub-range arithmetic is written three times, the copies-in-range query eight times across the family) | about 4 KB | the point is that the function becomes readable |
| R5: one `_transmute_plan()` called before the validation scan and again under the cutover lock, in place of the per-read re-asks, the `_identity_options_locked` twin, `_identity_resume_at` and the key-shape fingerprint | about 5 KB | the lock order stays exactly as it is |
| R6: `_cfg(parent)` for the 36 identical config loads and `_qual(rel)` for the 12 schema-and-name lookups | about 3 KB | |
| total | about 30 KB | 6 to 7% of the file, 10% of the growth |

That is the earlier note's 10 to 16% ceiling. R1 and R2 are worth doing whatever is decided about size: R1 is where
the repeated re-hardening comes from, and R2 is free.

## 7. What only a policy change recovers

- **Message length.** The 65.7 KB of message text is the largest single lever for the dbdev cap: halved, it
  saves about 33 KB; replaced by a code and a `docs/` anchor instead of a restatement of the mechanism, more. It
  runs against a stated value of this repository (a message says what to do, so nobody is sent to read source),
  so it is the maintainer's call, recorded here as a number and not a recommendation.
- **In-place upgrade from every earlier install.** `_surface_*` (9.2 KB), the retired-signature drops (5.8 KB),
  the `add column if not exists` ladder (4.3 KB), the data backfills, and the in-function compatibility branches
  (`monolith_oid is null`, the 0.6.0 delta-function heuristics in the hypertable carry, `upgrade_adopted_anchor`)
  exist so one idempotent file upgrades any prior version. Roughly 25 KB. Versioned update paths (pg_tle has
  `install_update_path`) would move them out of the shipped core; a policy of never changing a public function's
  result shape in place would retire `_surface_*` on its own.

Refactor plus both policies is about 90 KB: 481 KB to roughly 390 KB, 3.2x to about 2.6x of 0.6.0, still over the
250 KB cap. There is no lever, found or imaginable from this reading, that takes the core back near 151 KB.

## 8. Why the rest is inherent

Three facts about PostgreSQL decide the shape of the growth, and no refactor moves them:

1. **A table cannot become partitioned in place.** The cutover creates a new relation and renames. Everything
   `CREATE TABLE ... LIKE` does not copy (owner, ACL, RLS, policies, triggers and their states, comments,
   publications, tablespace, replica identity, identity sequences and their options, names and grants, constraint
   names, deferrability and storage parameters, outgoing and incoming foreign keys, the array type's name) must be
   carried by hand, one catalog read per attribute, because there is no `pg_get_tabledef`. R1 writes each once
   instead of two or three times; it cannot write them zero times.
2. **No lock blocks DDL and allows DML across a `COMMIT`.** The conversion must commit after `ADD CONSTRAINT ...
   NOT VALID` (to release its `ACCESS EXCLUSIVE` before the scan) and after `VALIDATE` (to not hold `SHARE UPDATE
   EXCLUSIVE` while waiting for the cutover's lock). Between commits any session may alter the table, so every
   pre-scan read is a plan that must be checked again under the cutover lock. R5 makes that one function called
   twice; it cannot make it one call.
3. **A regrain's copies span many transactions.** The parent can be altered, the source rewritten, the key
   changed, the delta dropped, the lock table exhausted at the swap, between any two ticks. Each is a drift the run
   must detect and recover from, and each detection is a distinct catalog comparison.

0.6.0 did not pay for these because it did not check them; the review passes found what that cost.

## 9. What was decided and what is next

- `scripts/core_growth.py` is committed with the measures above and a `--selftest`; the lint workflow runs the
  selftest (`core-growth` job).
- Section 2 of the 2026-10-14 note carries a correction pointing here.
- Recommended next, in order: R1 (the shared carry, core and hypertable), R2 (the `cfg` overloads), then the
  maintainer's decision on section 7's two policies, which is what the earlier note's open question 1 (a ceiling)
  actually turns on. R3 to R6 are worth taking when the function they touch is open for another reason.
- The size-budget rule (PR #1326) stands; its `Size:` lines should quote `core_growth.py report` so the per-PR
  figure and this note's figures are the same measurement.

## Reproduce

```bash
python3 scripts/core_growth.py --selftest
python3 scripts/core_growth.py report v0.6.0:pgpm_core/install.sql pgpm_core/install.sql
python3 scripts/core_growth.py functions pgpm_core/install.sql --top 40
python3 scripts/core_growth.py clones pgpm_core/install.sql --window 20
python3 scripts/core_growth.py report pgpm_hypertable/install.sql
```

The section 5 greps: `git show v0.6.0:pgpm_core/install.sql | grep -c tgenabled` and so on. The section 4
figures for `_transmute`'s preflight and carry are the bytes between its `create` line and the first
`pgpm_monolith_bound` CHECK, and between its `lock table ... access exclusive` and its `insert into pgpm.config`,
on the minified text.
