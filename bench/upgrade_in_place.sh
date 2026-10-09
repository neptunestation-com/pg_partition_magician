#!/usr/bin/env bash
# Guard the in-place upgrade: re-running install.sql over an OLDER install must leave a database
# structurally identical to a fresh install, with its managed tables and their data intact.
# Run by CI (`./test.sh perf`, and `./test.sh discriminate` proves it catches its defect).
#
# THE DEFECT. install.sql IS the upgrade path for the install.sql channel: operators re-run the file
# over a live database. Fresh installs get every column from the `create table` bodies, but an EXISTING
# database only gets a new column if install.sql also carries an
# `alter table ... add column if not exists` line for it. Those backfill lines are hand-maintained,
# and nothing enforces them. Add a column to a `create table` body, forget the backfill line, and every
# test in the suite still passes: the whole pgTAP suite installs FRESH, one database per file, so it
# never exercises an upgrade at all. The break lands only on an operator who already had pgpm
# installed, which is to say on the only people who are not evaluating it.
#
# WHY A SHELL HARNESS. Two separate databases (a fresh oracle and an upgraded one) and two runs of
# install.sql against one of them. pgTAP gives one database per file and wraps it in a transaction, and
# install.sql cannot be run from inside SQL at all.
#
# WHAT IT ASSERTS, and why each one is load-bearing:
#
#   1. LIVENESS WITNESS, and the one this guard would be worthless without: after the degrade step, the
#      columns really are gone. Every later assertion is of the form "the upgrade restored X", and all
#      of them pass trivially against a degrade that silently did nothing (a renamed column, a typo in
#      the DROP list). This asserts the conditions for the defect were present before looking for it.
#   2. The pgpm catalog after the upgrade is IDENTICAL to a fresh install of the same code: every
#      column of every table and view, with its type, nullability and default, and every constraint
#      (#1003). This is the assertion the mutation breaks. Then, by row, every row that predates the
#      upgrade holds a value in each backfilled column a fresh install declares NOT NULL: a backfill
#      line that lost its `not null default` leaves them NULL (mutation upgrade_backfill_drops_not_null).
#      And, separately and BY NAME, every routine in schema pgpm: name, identity arguments, kind and
#      result type. `create or replace` across a changed argument list creates a second overload
#      rather than replacing the first (issue #441), and when the new argument has a default the old
#      call shape matches both and fails with "is not unique". This origin, a degraded FRESH install,
#      can never carry an old signature to leave behind, so this comparison cannot catch a missed drop
#      line here; bench/upgrade_from_release.sh upgrades a real released artifact for that. It is
#      still made here so that any routine-level drift an upgrade does leave is a named difference in
#      this guard's output rather than something folded silently into the column hash.
#   3. A backfilled column's VALUE, where restoring the column empty is not good enough (issue #421).
#      pgpm.part.child_oid is what the archive step checks a candidate's name against, and a null one
#      reads as unanchored -- so an upgrade that recreated the column and populated nothing would
#      leave every partition an existing install already had permanently unprotected, with assertion
#      2 perfectly green. Checked BY IDENTITY: each row's child_oid must be the oid its OWN name
#      resolves to, so a backfill writing one plausible oid everywhere fails too. Likewise
#      pgpm.config.monolith_oid (issue #672), which untransmute resolves the monolith through and refuses
#      the table without: it must be the oid of the fixture's own monolith, taken before the degrade.
#      And pgpm.scratch (issue #955), the record of pgpm_hypertable's copies, which a release before it
#      did not have: the degrade drops the table, and the upgrade must record a legacy copy, its delta and
#      its function from the comment records that release kept on them, by identity, and nothing for an
#      operator's look-alike (mutation scratch_upgrade_fill_dropped).
#      And the regrain anchors only on PROOF that pgpm minted what holds the derived names (#969): a parent
#      that never regrained, beside an operator's own <rel>_pgpm_regrain_delta and a function of theirs
#      under the capture function's name, must have nothing recorded, and its next prepare must refuse the
#      table, which keeps its rows, rather than drop it (mutation scratch_upgrade_adopts_namesake). The
#      in-flight regrain above, and assertion 8's two runs minted by a real v0.6.0, are the witnesses that
#      the proof still takes what pgpm did mint.
#   4. Data survived BY IDENTITY, not by count. The fixture is asymmetric on purpose (3 inserted, 1
#      deleted, 2 surviving) so that a lost insert and a resurrected delete cannot cancel out into a
#      row count that still looks right.
#   5. Registration survived: the config row still names the same control column and step, so the
#      upgrade did not quietly reset the managed table's settings to defaults.
#   6. The upgrade was RECORDED: pgpm.installed holds two rows, the second one this version. Distinct
#      from 2: it separates "the file ran to the end" from "the schema happens to look right".
#   8. A regrain IN FLIGHT WITH COPIES across the upgrade that added config.regrain_source_mark (#878),
#      in its own database, from a REAL older artifact rather than a degrade: the degrade drops
#      regrain_cursor and pgpm.part.attached with everything else, so it can only ever produce a run
#      whose cursor and copies are already forgotten. The newest release without the column (v0.6.0,
#      fetched as bench/upgrade_from_release.sh fetches its origin) prepares a run, copies a sub-range
#      and then has the source rewritten under it by a same-type ALTER ... USING, which fires no row
#      trigger; the current install.sql is run over that. Right after the upgrade, before any tick, the
#      run must have been restarted: its copy gone BY OID, one regrain_restart naming the upgrade, the
#      cursor back at the source's lo and the mark recorded from the source as rewritten. A run in the
#      same database with no copy yet must only have its mark recorded, with no restart. Then the run is
#      driven to its swap, and the regrained range must hold the rewritten values, row by row. Without
#      the restart the swap attaches the copy made before the rewrite. LIVENESS witnesses first: the
#      origin really lacks the column, the run really has a copy, and the copy really holds the old
#      values while the source holds the new ones. (Numbered 8 but run last, in its own database.)
#      The same run carries the capture trigger v0.6.0 minted origin-only (#892): the first tick after the
#      upgrade must restart it once more and re-mint capture ENABLE ALWAYS, and a replica-role UPDATE and two
#      DELETEs made once the restarted run has copied their sub-range again must survive the swap. Without
#      the re-arm the replica-role DML is never captured (and the swap's own check refuses every swap).
#   7. LIVENESS WITNESS: the machine still runs afterwards. maintain_obtain() (issue #347 split obtain
#      out of maintain()/maintain_all(), so this is now the call that mints partitions) on the table
#      that existed BEFORE the upgrade mints a new partition, named. A structurally perfect install
#      that can no longer obtain is not an upgrade anyone wants, and every assertion above it is
#      satisfied by a database that merely sits there.
#
# AND TWO PRECONDITIONS ON DEGRADE_COLS ITSELF, before any of that, running in OPPOSITE directions.
# The list is hardcoded and has to be (see the comment on it below), so something has to stop it
# rotting, and one direction does not: "every listed column exists in a fresh install" catches the
# list naming a column the product has DROPPED, while "every backfilled column is in the list"
# catches the product GAINING one the list forgot. Drift only ever goes the second way -- every new
# column is an opportunity to forget -- and for a long time only the first check existed, which is
# how the list came to sit at 15 entries against 25 backfill lines with nothing reporting anything
# (issue #417). Ten backfill lines were exercised by nobody, including the two that carry #405's
# claim that a crashed transmute stays reapable.
#
# Usage: upgrade_in_place.sh <container> <db> [install.sql]
# The install path defaults to the real one; bench/discriminate.sh passes a MUTANT copy instead, to
# prove this guard actually fails when the defect is present.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
FRESH="${DB}_fresh"
fail=0

q()  { docker exec "$C" psql -U postgres -d "$1" -qtA -c "$2"; }
run() { docker exec -e PGOPTIONS='-c client_min_messages=warning' "$C" \
          psql -U postgres -d "$1" -qtA -v ON_ERROR_STOP=1 -c "$2"; }
install_into() { docker exec -e PGOPTIONS='-c client_min_messages=warning' "$C" \
                   psql -U postgres -q -d "$1" -v ON_ERROR_STOP=1 -f "$INSTALL"; }
check() { # <label> <actual> <expected>
  if [ "$2" = "$3" ]; then printf 'PASS  %-58s %s\n' "$1" "$2"
  else printf 'FAIL  %-58s got %s, want %s\n' "$1" "$2" "$3"; fail=1; fi
}

# The columns an older install lacks: every column install.sql backfills with `add column if not
# exists`. Hardcoded rather than parsed out of install.sql on purpose. Deriving it from the backfill
# lines would make the guard circular, since the mutation works by DELETING one of those lines: the
# derived list would lose the same entry, the degrade would not drop it, and the guard would pass
# against its own defect. The two preconditions below are what keep a hardcoded list from rotting.
# In install.sql's own order, so a new backfill line has an obvious place to go.
DEGRADE_COLS="
pgpm.config:partition_tz
pgpm.config:obtain_retry_after
pgpm.config:text_time_prefix
pgpm.config:text_time_width
pgpm.config:text_time_radix
pgpm.config:text_time_unit
pgpm.config:text_time_alphabet
pgpm.config:text_time_discard_bits
pgpm.config:text_time_epoch
pgpm.config:regrain_batch
pgpm.config:regrain_max_blocks
pgpm.config:regrain_to
pgpm.config:regrain_cursor
pgpm.config:regrain_delta_oid
pgpm.config:regrain_capture_fn_oid
pgpm.config:regrain_source_mark
pgpm.config:retain_batch
pgpm.config:archive_fn
pgpm.config:archive_byte_budget
pgpm.config:archive_probe_sample
pgpm.config:archive_batch
pgpm.config:sweep_turn_at
pgpm.config:monolith_oid
pgpm.part:attached
pgpm.part:retiring_at
pgpm.part:retiring_oid
pgpm.part:child_oid
pgpm.transmute_inflight:owner_pid
pgpm.transmute_inflight:owner_backend_start
pgpm.transmute_inflight:partition_tz
pgpm.transmute_inflight:control_attnum
pgpm.dropped_fk:restored_at
pgpm.dropped_fk:validated_at
pgpm.dropped_fk:validate_retry_after
pgpm.archive_ledger:retired_at
"
N_DEGRADE=$(echo "$DEGRADE_COLS" | grep -c ':')

# Every column of every table AND view in schema pgpm, with its type, its nullability and its default,
# and every constraint on a pgpm table, by name and definition. Views are included because a DROP
# COLUMN ... CASCADE below takes pgpm.partitions with it, so "the view came back" is part of the claim.
# Nullability and default are part of it too (#1003): a backfill line that lost its `not null default`
# restores a column of the right name and type, nullable, NULL on every row that predates the upgrade,
# and a catalog read of name and type alone calls that identical to a fresh install. Kept as a LIST, as
# the routines are, so a difference is reported by name rather than as two unequal hashes.
CATALOG_SQL="select 'column '||table_name||'.'||column_name||' '||data_type||' nullable='||is_nullable
                    ||' default='||coalesce(column_default, 'none')
             from information_schema.columns where table_schema = 'pgpm'
             union all
             select 'constraint '||conrelid::regclass::text||' '||conname||' '||contype::text||' '||pg_get_constraintdef(oid)
             from pg_constraint where connamespace = 'pgpm'::regnamespace"
catalog() { q "$1" "$CATALOG_SQL" | LC_ALL=C sort; }

# Every routine in schema pgpm, one line each: name, identity arguments, kind (f/p) and result type. Kept
# as a LIST rather than a hash so a difference is reported by name (a stale overload reads as
# `schedule(p_every text) f bigint`, only after upgrade). prokind is "char", which `||` will not take
# without the cast; the cast is not decoration, an uncast version of this query errors and returns
# nothing, and nothing-equals-nothing is a pass.
ROUTINES_SQL="select proname||'('||pg_get_function_identity_arguments(oid)||') '||prokind::text||' '||coalesce(pg_get_function_result(oid), '')
              from pg_proc where pronamespace = 'pgpm'::regnamespace"
routines() { q "$1" "$ROUTINES_SQL" | LC_ALL=C sort; }

# ---------------------------------------------------------------------------- fresh oracle
docker exec "$C" psql -U postgres -q -c "drop database if exists $FRESH" >/dev/null 2>&1
docker exec "$C" psql -U postgres -q -c "create database $FRESH" >/dev/null 2>&1
if ! install_into "$FRESH" >/tmp/up_fresh.log 2>&1; then
  echo "FAIL  the fresh oracle install did not complete"; sed 's/^/      /' /tmp/up_fresh.log; exit 1
fi
catalog "$FRESH" > /tmp/up_fresh_catalog.txt
# The catalog oracle must have read columns AND constraints, and some NOT NULL column among them, or the
# comparison below is empty-equals-empty in the half that went unread.
N_CATALOG=$(grep -c . /tmp/up_fresh_catalog.txt)
if ! grep -q '^column .* nullable=NO ' /tmp/up_fresh_catalog.txt || ! grep -q '^constraint ' /tmp/up_fresh_catalog.txt; then
  echo "FAIL  the fresh catalog oracle read no NOT NULL column or no constraint: the catalog comparison would compare nothing"
  sed 's/^/      /' /tmp/up_fresh_catalog.txt | head -5; exit 1
fi
routines "$FRESH" > /tmp/up_fresh_routines.txt
# The routine oracle must have read SOMETHING, or the identity comparison below is empty-equals-empty.
N_ROUTINES=$(grep -c . /tmp/up_fresh_routines.txt)
if [ "$N_ROUTINES" -lt 1 ]; then
  echo "FAIL  the fresh oracle lists no routines at all: the routine comparison would compare nothing"; exit 1
fi

# PRECONDITION: every column this guard intends to drop must exist in a fresh install. If the product
# drops one for real, this list is stale and the guard is quietly testing less than it claims. Fail
# loudly instead, exactly as bench/mutations/mutate.py refuses a pattern whose site count is off.
present=$(echo "$DEGRADE_COLS" | grep ':' | while IFS=: read -r t c; do
  q "$FRESH" "select 1 from information_schema.columns
               where table_schema='pgpm' and table_name='${t#pgpm.}' and column_name='$c'"
done | grep -c 1)
check "precondition: all degrade-list columns exist when fresh" "$present" "$N_DEGRADE"
if [ "$present" != "$N_DEGRADE" ]; then
  echo "      the DEGRADE_COLS list is stale; fix it before trusting anything below"; exit 1
fi

# PRECONDITION, the other direction (issue #417). The one above catches the list naming a column the
# product has DROPPED. It cannot catch the product GAINING a backfilled column the list does not
# name -- and that is the direction drift actually goes, so for a long time it reported nothing while
# ten of twenty-five backfill lines went unexercised. So: read the backfill lines out of the install
# file that is about to be run, and fail when one of them is not in the list.
#
# This does NOT make the guard circular, and the asymmetry is exactly why. The mutation deletes a
# backfill line, and a missing backfill LINE is not a missing LIST entry: this check still passes
# under the mutant, the degrade still drops the column, and the catalog assertion below is
# still what fails. The check that would be circular is the converse -- "every list entry has a
# backfill line" -- which would fail under the mutant for a reason that is not the defect, and it is
# deliberately absent.
#
# Parse the file being INSTALLED, not the repo's copy, so this describes the run that is happening.
BACKFILL_RAW=$(docker exec "$C" grep -i 'add column if not exists' "$INSTALL" | grep -v '^[[:space:]]*--')
N_LOOSE=$(printf '%s\n' "$BACKFILL_RAW" | grep -c .)
if [ "$N_LOOSE" -lt 1 ]; then
  echo "FAIL  found no backfill lines at all in $INSTALL: this precondition is reading nothing"; exit 1
fi
# The loose match above is case-insensitive and this strict parse is not, on purpose: a backfill line
# written in a style this regex cannot read shows up as a count mismatch and fails loudly, rather than
# as a line the check silently does not cover. Comparing the two counts is the liveness witness for
# the parse -- without it, a regex that had quietly stopped matching would report nothing unlisted.
BACKFILLED=$(printf '%s\n' "$BACKFILL_RAW" \
  | sed -nE 's/^[[:space:]]*alter table ([a-z_]+\.[a-z_]+) add column if not exists ([a-z_]+).*/\1:\2/p')
N_BACKFILL=$(printf '%s\n' "$BACKFILLED" | grep -c ':')
check "precondition: every backfill line parsed" "$N_BACKFILL" "$N_LOOSE"
if [ "$N_BACKFILL" != "$N_LOOSE" ]; then
  echo "      a backfill line this parser cannot read is a column it cannot check for; fix the regex"; exit 1
fi

unlisted=$(printf '%s\n' "$BACKFILLED" | grep ':' | while read -r col; do
  printf '%s\n' "$DEGRADE_COLS" | grep -qxF "$col" || printf '%s ' "$col"
done)
unlisted="${unlisted% }"
check "precondition: every backfilled column is degraded" "${unlisted:-none}" "none"
if [ -n "$unlisted" ]; then
  echo "      add them to DEGRADE_COLS; their backfill lines are exercised by nothing until you do"; exit 1
fi

# The backfilled columns a fresh install declares NOT NULL, read from the fresh oracle (#1003). The
# upgrade must leave a value in each on every row that predates it, as the constraint would have.
NOTNULL_COLS=$(echo "$DEGRADE_COLS" | grep ':' | while IFS=: read -r t c; do
  grep -qE "^column ${t#pgpm.}\\.$c .* nullable=NO default=" /tmp/up_fresh_catalog.txt && echo "$t:$c"
done | tr '\n' ' ')
NOTNULL_COLS="${NOTNULL_COLS% }"

# ---------------------------------------------------------------------------- an older install, with state
docker exec "$C" psql -U postgres -q -c "drop database if exists $DB" >/dev/null 2>&1
docker exec "$C" psql -U postgres -q -c "create database $DB" >/dev/null 2>&1
if ! install_into "$DB" >/tmp/up_old.log 2>&1; then
  echo "FAIL  the initial install did not complete"; sed 's/^/      /' /tmp/up_old.log; exit 1
fi

# A managed table with real rows, created BEFORE the upgrade. Asymmetric: 3 in, 1 out, so a lost
# insert and a resurrected delete cannot cancel into a plausible count.
# An ID-kind table, not a time one, and the choice is load-bearing for assertion 6. obtain measures a
# time table against the CLOCK, so nothing the harness inserts can give it work to do; for an id table
# the frontier is max(control), which the harness can move on purpose.
run "$DB" "create table public.up_t (
             id bigint not null,
             body text,
             primary key (id))" >/dev/null
run "$DB" "insert into public.up_t (id, body) values (10, 'keep-a'), (20, 'doomed'), (30, 'keep-b')" >/dev/null
run "$DB" "delete from public.up_t where body = 'doomed'" >/dev/null
run "$DB" "call pgpm.transmute('public.up_t', 'id', 1000::bigint, p_obtain => 1)" >/dev/null
run "$DB" "select pgpm.resume('public.up_t')" >/dev/null
run "$DB" "call pgpm.maintain_obtain('public.up_t')" >/dev/null
run "$DB" "call pgpm.maintain('public.up_t')" >/dev/null

# A regrain IN FLIGHT across the upgrade (#496). Before the two anchor columns existed, its capture relations
# were found by the parent's name alone; the upgrade must record their oids, or the rename hazard is back for
# exactly the regrain the operator had running. Move the frontier into the forward partition so the monolith
# freezes, then ONE tick: 'prepared' is the tick that mints the capture. Asserted, because everything the
# anchor assertion below says is also true of a run that never had a regrain in flight.
run "$DB" "insert into public.up_t (id, body) values (1500, 'freeze')" >/dev/null
MONO=$(q "$DB" "select child_name from pgpm.part where parent_table = 'public.up_t'::regclass and attached
                 order by lo::numeric limit 1")
# By oid, now: the regrain's first pass may rename it (#266), and the name is not what #672's anchor records.
MONO_OID=$(q "$DB" "select to_regclass(format('public.%I', '$MONO'))::oid")
check "LIVENESS: a regrain is in flight before the degrade" \
  "$(q "$DB" "select pgpm.regrain_step('public.up_t', '$MONO', '100', 50)")" "prepared"

# A from_hypertable copy made before pgpm.scratch existed (#955), as such a release left one: a tracking copy
# <rel>_pgpm_dest commented `pgpm from_hypertable copy of <oid>`, its delta <rel>_pgpm_delta commented
# `pgpm from_hypertable horizon <xid>`, the function <rel>_pgpm_delta_fn() beside them. A plain table stands in
# for the hypertable (this image has no TimescaleDB; the upgrade reads the catalog alone). Beside it, an
# operator's look-alike: up_x_pgpm_dest, whose comment is not the module's record, which must NOT be recorded.
run "$DB" "create table public.up_h (ts timestamptz not null, v int);
           create table public.up_h_pgpm_dest (like public.up_h);
           create table public.up_h_pgpm_delta (ts timestamptz, pgpm_seq bigint generated always as identity);
           create function public.up_h_pgpm_delta_fn() returns trigger language plpgsql as 'begin return null; end';
           create table public.up_x (ts timestamptz);
           create table public.up_x_pgpm_dest (note text);
           comment on table public.up_x_pgpm_dest is 'staging copy of up_x, kept by the application';
           comment on table public.up_h_pgpm_delta is 'pgpm from_hypertable horizon 777';
           do \$\$ begin execute format('comment on table public.up_h_pgpm_dest is %L',
                     'pgpm from_hypertable copy of ' || 'public.up_h'::regclass::oid); end \$\$;" >/dev/null
SCRATCH_WANT=$(q "$DB" "select 'public.up_h'::regclass::oid || ':' || 'public.up_h_pgpm_delta'::regclass::oid || ','
                             || 'public.up_h'::regclass::oid || ':' || 'public.up_h_pgpm_delta_fn()'::regprocedure::oid || ','
                             || 'public.up_h'::regclass::oid || ':' || 'public.up_h_pgpm_dest'::regclass::oid")

# #969: a managed parent that has never regrained, beside an operator's own table under its delta's derived
# name and a function of the operator's under its capture function's (one that writes nothing of the delta).
# The upgrade must record neither, and the next prepare refuse the table, as on a fresh install. Asymmetric:
# the operator's table holds 3 rows.
ns_setup() {
  run "$DB" "create table public.up_ns (id bigint not null, body text, primary key (id))" &&
  run "$DB" "insert into public.up_ns select g, 'ns' || g from generate_series(1, 30) g" &&
  run "$DB" "call pgpm.transmute('public.up_ns', 'id', 1000::bigint, p_obtain => 1)" &&
  run "$DB" "select pgpm.obtain('public.up_ns')" &&
  run "$DB" "insert into public.up_ns values (1500, 'freeze')" &&
  run "$DB" "create table public.up_ns_pgpm_regrain_delta (note text);
             insert into public.up_ns_pgpm_regrain_delta values ('op-a'), ('op-b'), ('op-c');
             create function public.up_ns_pgpm_regrain_capture() returns trigger language plpgsql
               as 'begin insert into public.up_ns_audit values (1); return null; end'"
}
if ! ns_setup >/tmp/up_ns_setup.log 2>&1; then
  echo "FAIL  the up_ns namesake fixture did not load"; sed 's/^/      /' /tmp/up_ns_setup.log; exit 1
fi
NS_DELTA=$(q "$DB" "select 'public.up_ns_pgpm_regrain_delta'::regclass::oid")
NS_FN=$(q "$DB" "select 'public.up_ns_pgpm_regrain_capture()'::regprocedure::oid")
NS_MONO=$(q "$DB" "select child_name from pgpm.part where parent_table = 'public.up_ns'::regclass and attached
                    order by lo::numeric limit 1")
check "LIVENESS: up_ns never regrained, beside the operator's namesakes" \
  "$(q "$DB" "select coalesce(regrain_delta_oid::text, 'null') || '/' || (select count(*) from public.up_ns_pgpm_regrain_delta)
                from pgpm.config where parent_table = 'public.up_ns'::regclass")/${NS_FN:+fn}/${NS_MONO:+mono}" "null/3/fn/mono"

BODIES_BEFORE=$(q "$DB" "select string_agg(body, ',' order by body) from public.up_t")
CONFIG_BEFORE=$(q "$DB" "select control_column||'/'||partition_step from pgpm.config
                          where parent_table = 'public.up_t'::regclass")
CHILDREN_BEFORE=$(q "$DB" "select string_agg(child_name, ',' order by child_name) from pgpm.part
                            where parent_table = 'public.up_t'::regclass")

# ---------------------------------------------------------------------------- degrade to an older shape
# CASCADE because pgpm.partitions selects pgpm.part.attached; install.sql recreates the view.
echo "$DEGRADE_COLS" | grep ':' | while IFS=: read -r t c; do
  docker exec "$C" psql -U postgres -d "$DB" -qtA \
    -c "alter table $t drop column if exists $c cascade" >/dev/null 2>&1
done

# ...and the release before pgpm.scratch had no such table at all (#955), so it goes too.
docker exec "$C" psql -U postgres -d "$DB" -qtA -c "drop table if exists pgpm.scratch" >/dev/null 2>&1
check "LIVENESS: the degrade really removed pgpm.scratch" "$(q "$DB" "select to_regclass('pgpm.scratch') is null")" "t"

# ASSERTION 1, the liveness witness. Everything below asserts the upgrade put something back; all of it
# passes against a degrade that did nothing at all.
still=$(echo "$DEGRADE_COLS" | grep ':' | while IFS=: read -r t c; do
  q "$DB" "select 1 from information_schema.columns
            where table_schema='pgpm' and table_name='${t#pgpm.}' and column_name='$c'"
done | grep -c 1)
check "the degrade really removed all $N_DEGRADE columns" "$still" "0"

# ---------------------------------------------------------------------------- the upgrade
if ! install_into "$DB" >/tmp/up_upgrade.log 2>&1; then
  echo "FAIL  the in-place upgrade did not complete"; sed 's/^/      /' /tmp/up_upgrade.log; fail=1
fi

catalog "$DB" > /tmp/up_catalog.txt
if cmp -s /tmp/up_fresh_catalog.txt /tmp/up_catalog.txt; then
  printf 'PASS  %-58s %s\n' "the pgpm catalog matches a fresh install exactly" "$N_CATALOG columns and constraints"
else
  printf 'FAIL  %-58s\n' "the pgpm catalog differs from a fresh install"
  comm -23 /tmp/up_fresh_catalog.txt /tmp/up_catalog.txt | sed 's/^/      only in fresh:      /'
  comm -13 /tmp/up_fresh_catalog.txt /tmp/up_catalog.txt | sed 's/^/      only after upgrade: /'
  fail=1
fi

# ASSERTION 2b (#1003), by row. Right after the upgrade, before anything below writes, so every row read
# here predates it. A column the upgrade restored nullable is in the catalog difference above; this says
# what that costs the operator: the rows it left NULL where a fresh install has a value. LIVENESS first:
# the fresh oracle has NOT NULL backfilled columns at all, and each was read over rows (pgpm.config and
# pgpm.part both hold the fixture's), or "no NULLs" would be true of an empty table.
nn_read=""; nn_null=""
for col in $NOTNULL_COLS; do
  t="${col%%:*}"; c="${col#*:}"
  r=$(q "$DB" "select count(*) filter (where $c is null) || '/' || count(*) from $t" 2>/dev/null)
  case "$r" in
    0/0) ;;
    0/*) nn_read="$nn_read $col" ;;
    */*) nn_read="$nn_read $col"; nn_null="$nn_null $col(${r%%/*} of ${r#*/} rows)" ;;
    *)   nn_null="$nn_null $col(unreadable)" ;;
  esac
done
nn_read="${nn_read# }"
check "LIVENESS: each NOT NULL backfilled column read over existing rows" "${nn_read:-none}" "${NOTNULL_COLS:-a non-empty list}"
nn_null="${nn_null# }"
check "no existing row left NULL in a NOT NULL backfilled column" "${nn_null:-none}" "none"

# ASSERTION 2, the routine half (#441). Named differences, not a hash: `only after upgrade` is what a
# stale overload looks like, `only in fresh` what a routine the upgrade failed to create looks like.
routines "$DB" > /tmp/up_routines.txt
if cmp -s /tmp/up_fresh_routines.txt /tmp/up_routines.txt; then
  printf 'PASS  %-58s %s\n' "the pgpm routines match a fresh install exactly" "$N_ROUTINES routines"
else
  printf 'FAIL  %-58s\n' "the pgpm routines differ from a fresh install"
  comm -23 /tmp/up_fresh_routines.txt /tmp/up_routines.txt | sed 's/^/      only in fresh:      /'
  comm -13 /tmp/up_fresh_routines.txt /tmp/up_routines.txt | sed 's/^/      only after upgrade: /'
  fail=1
fi

# ASSERTION 3 (#421). Reported as anchored/total so "0 rows examined" cannot read as success: the
# expectation is built from the children this fixture actually had before the degrade, not from the
# same query that produces the answer.
NPARTS=$(echo "$CHILDREN_BEFORE" | tr ',' '\n' | grep -c .)
ANCHORED=$(q "$DB" "select count(*) filter (where p.child_oid is not null
                                              and p.child_oid = to_regclass(format('%I.%I', n.nspname, p.child_name))::oid)
                           || '/' || count(*)
                      from pgpm.part p
                      join pg_class c on c.oid = p.parent_table
                      join pg_namespace n on n.oid = c.relnamespace
                     where p.parent_table = 'public.up_t'::regclass")
check "the upgrade backfilled child_oid, to each child's own oid" "$ANCHORED" "$NPARTS/$NPARTS"
# ASSERTION 3c (#672), by identity: the monolith anchor is the fixture's own monolith, whose oid was read
# before the degrade. A backfill that wrote nothing reads null; one that adopted another partition, false.
check "the upgrade backfilled monolith_oid, to the monolith's own oid" \
  "$(q "$DB" "select coalesce((monolith_oid = '${MONO_OID:-0}'::oid)::text, 'null')
                from pgpm.config where parent_table = 'public.up_t'::regclass")" "true"
# ASSERTION 3b (#496), by identity: each anchor must be the relation its own derived name resolves to. A
# backfill that wrote nothing reads null/null, one that wrote a plausible oid somewhere else reads false.
check "the upgrade anchored the in-flight regrain's capture (delta/fn)" \
  "$(q "$DB" "select coalesce((regrain_delta_oid = to_regclass('public.up_t_pgpm_regrain_delta')::oid)::text, 'null')
                || '/' || coalesce((regrain_capture_fn_oid = to_regprocedure('public.up_t_pgpm_regrain_capture()')::oid)::text, 'null')
                from pgpm.config where parent_table = 'public.up_t'::regclass")" "true/true"
# ASSERTION 3e (#969), by identity: nothing recorded for up_ns, whose derived names the operator holds; the
# next prepare refuses the operator's table by name (it used to DROP it as "the previous regrain's delta"), and
# the table is the same relation with its 3 rows, the function the same function.
check "the upgrade recorded no capture for up_ns beside the operator's namesakes" \
  "$(q "$DB" "select coalesce(regrain_delta_oid::text, 'null') || '/' || coalesce(regrain_capture_fn_oid::text, 'null')
                from pgpm.config where parent_table = 'public.up_ns'::regclass")" "null/null"
NS_STEP=$(q "$DB" "select pgpm.regrain_step('public.up_ns', '$NS_MONO', '100', 50)" 2>&1)
check "up_ns's next prepare refuses the operator's table by name" \
  "$(echo "$NS_STEP" | grep -c "public.up_ns_pgpm_regrain_delta, and that name is held by relation")" "1"
check "the operator's namesakes survive, by identity (table rows / function)" \
  "$(q "$DB" "select string_agg(note, ',' order by note) from public.up_ns_pgpm_regrain_delta where tableoid = '${NS_DELTA:-0}'::oid")/$(q \
     "$DB" "select count(*) from pg_proc where oid = '${NS_FN:-0}'::oid")" "op-a,op-b,op-c/1"
# ASSERTION 3d (#955), by identity: the upgrade recorded the legacy copy, its delta and its function in
# pgpm.scratch from the module's comment records, each under the hypertable it names, and recorded nothing for
# the operator's look-alike. An upgrade that filled nothing reads empty; one that recorded by name, the
# look-alike too.
check "the upgrade recorded a legacy copy by its comment record, and only it" \
  "$(q "$DB" "select coalesce(string_agg(parent_oid || ':' || obj, ',' order by kind), 'none') from pgpm.scratch")" "$SCRATCH_WANT"
check "rows survived, by identity"                       "$(q "$DB" "select string_agg(body, ',' order by body) from public.up_t")" "$BODIES_BEFORE"
check "registration survived (control column / step)"    "$(q "$DB" "select control_column||'/'||partition_step from pgpm.config where parent_table = 'public.up_t'::regclass")" "$CONFIG_BEFORE"
check "the upgrade run was recorded"                     "$(q "$DB" "select count(*)||'/'||max(version) from pgpm.installed")" "2/$(q "$FRESH" "select pgpm.version()")"

# ASSERTION 7, liveness. The pre-existing managed table must still be maintainable. Move the frontier
# to the top of the covered range so the next tick has real work: one id below the last bound, since
# `hi` is exclusive. It cannot be moved PAST that bound -- with no DEFAULT partition (#288) an insert
# beyond the last one is rejected rather than extending the grid, so the frontier is always inside it.
FRONTIER=$(q "$DB" "select max(hi)::bigint - 1 from pgpm.part where parent_table = 'public.up_t'::regclass")
run "$DB" "insert into public.up_t (id, body) values ($FRONTIER, 'post-upgrade')" >/dev/null
run "$DB" "call pgpm.maintain_obtain('public.up_t')" >/dev/null
CHILDREN_AFTER=$(q "$DB" "select string_agg(child_name, ',' order by child_name) from pgpm.part
                           where parent_table = 'public.up_t'::regclass")
new=$(comm -13 <(echo "$CHILDREN_BEFORE" | tr ',' '\n' | sort) \
               <(echo "$CHILDREN_AFTER"  | tr ',' '\n' | sort) | tr '\n' ' ')
if [ -n "${new// /}" ]; then
  printf 'PASS  %-58s %s\n' "maintain_obtain() still mints partitions after the upgrade" "new: ${new% }"
else
  printf 'FAIL  %-58s %s\n' "maintain_obtain() minted nothing after the upgrade" "children: $CHILDREN_AFTER"
  fail=1
fi

# ---------------------------------------------------------------------------- a regrain in flight, from a release (#878)
# ASSERTION 8. A real origin, not a degrade (see the header). v0.6.0 is the newest release whose install.sql
# has no config.regrain_source_mark; asserted below rather than assumed, so a stale choice fails loudly.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/bench/results"        # gitignored
IDB="${DB}_inflight"
ORIGIN_TAG="v0.6.0"
ORIGIN_SQL="$OUT/upgrade-in-place-origin-$ORIGIN_TAG.sql"
mkdir -p "$OUT"
if ! git -C "$ROOT" rev-parse -q --verify "refs/tags/$ORIGIN_TAG^{commit}" >/dev/null 2>&1; then
  if ! out=$(git -C "$ROOT" fetch --no-tags --depth=1 origin tag "$ORIGIN_TAG" 2>&1); then
    echo "FAIL  could not fetch tag $ORIGIN_TAG; the in-flight regrain stage has no origin and verifies nothing"
    printf '%s\n' "$out" | sed 's/^/      /'; exit 1
  fi
fi
if ! git -C "$ROOT" show "$ORIGIN_TAG:pgpm_core/install.sql" > "$ORIGIN_SQL" 2>/tmp/up_inflight_show.err \
   || [ ! -s "$ORIGIN_SQL" ]; then
  echo "FAIL  git show $ORIGIN_TAG:pgpm_core/install.sql produced nothing; the in-flight regrain stage verifies nothing"
  sed 's/^/      /' /tmp/up_inflight_show.err; exit 1
fi
docker exec "$C" psql -U postgres -q -c "drop database if exists $IDB" >/dev/null 2>&1
docker exec "$C" psql -U postgres -q -c "create database $IDB" >/dev/null 2>&1
if ! docker exec -i -e PGOPTIONS='-c client_min_messages=warning' "$C" \
       psql -U postgres -q -d "$IDB" -v ON_ERROR_STOP=1 -f - < "$ORIGIN_SQL" >/tmp/up_inflight_origin.log 2>&1; then
  echo "FAIL  the origin install ($ORIGIN_TAG) did not complete"; sed 's/^/      /' /tmp/up_inflight_origin.log; exit 1
fi
check "LIVENESS: the $ORIGIN_TAG origin has no regrain_source_mark" \
  "$(q "$IDB" "select count(*) from information_schema.columns
                where table_schema = 'pgpm' and table_name = 'config' and column_name = 'regrain_source_mark'")" "0"

# Two id-kind tables, both regraining their monolith [0, 1000) toward 100 under the origin. up_r has a copy
# of [0, 100) (99 rows) when the upgrade runs; up_n is prepared only. Asymmetric sizes (130 and 70 rows).
for spec in up_r:130 up_n:70; do
  t="${spec%%:*}"; n="${spec#*:}"
  run "$IDB" "create table public.$t (id bigint not null, note text, primary key (id))" >/dev/null
  run "$IDB" "insert into public.$t select g, 'old' || g from generate_series(1, $n) g" >/dev/null
  run "$IDB" "call pgpm.transmute('public.$t', 'id', 1000::bigint, p_obtain => 1)" >/dev/null
  run "$IDB" "select pgpm.resume('public.$t')" >/dev/null
  run "$IDB" "call pgpm.maintain_obtain('public.$t')" >/dev/null
  run "$IDB" "insert into public.$t values (1500, 'freeze')" >/dev/null
done
# The source by its range, re-read each time: the prepare renames it onto the target grid (#266).
src_name() { q "$IDB" "select child_name from pgpm.part where parent_table = 'public.$1'::regclass
                        and attached and lo = '0'"; }
step() { docker exec -e PGOPTIONS='-c client_min_messages=warning' "$C" psql -U postgres -d "$IDB" -qtA \
           -c "select pgpm.regrain_step('public.$1', '$(src_name "$1")', '100', 1000)"; }
R_PREP=$(step up_r); R_COPY=$(step up_r); N_PREP=$(step up_n)
COPY_OID=$(q "$IDB" "select child_oid from pgpm.part where parent_table = 'public.up_r'::regclass
                      and not attached and lo = '0' and hi = '100'")
COPY_REL=$(q "$IDB" "select '${COPY_OID:-0}'::oid::regclass::text")
check "LIVENESS: up_r mid-regrain with a copy of [0, 100), up_n prepared" \
  "$R_PREP/$R_COPY/$N_PREP/$(q "$IDB" "select string_agg(regrain_cursor, ',' order by parent_table::text)
                                         from pgpm.config")/$(q "$IDB" "select count(*) from pg_class where oid = '${COPY_OID:-0}'::oid")" \
  "prepared/copied:99/prepared/0,100/1"
# The rewrite, BEFORE the upgrade: the origin cannot see it, and a rewrite fires no row trigger.
run "$IDB" "alter table public.up_r alter column note type text using upper(note)" >/dev/null
check "LIVENESS: the source holds OLD10, the copy made before it old10" \
  "$(q "$IDB" "select note from public.up_r where id = 10")/$(q "$IDB" "select note from $COPY_REL where id = 10" 2>/dev/null)" \
  "OLD10/old10"

# #892: and the origin minted up_r's capture origin-only (CREATE TRIGGER alone, before #450), the state a
# session_replication_role = replica writer skips.
check "LIVENESS: the $ORIGIN_TAG origin minted up_r's capture trigger origin-only" \
  "$(q "$IDB" "select string_agg(tgenabled::text, ',') from pg_trigger
                where tgname = 'pgpm_regrain_capture' and tgrelid = 'public.$(src_name up_r)'::regclass")" "O"

if ! install_into "$IDB" >/tmp/up_inflight_upgrade.log 2>&1; then
  echo "FAIL  the upgrade over the in-flight regrain did not complete"; sed 's/^/      /' /tmp/up_inflight_upgrade.log; fail=1
fi
# #969: the upgrade anchored both runs' capture, which v0.6.0 minted, on the proof that pgpm minted it (the
# witness that the proof assertion 3e leans on still takes what pgpm did make).
check "the upgrade anchored each $ORIGIN_TAG run's capture, by identity" \
  "$(q "$IDB" "select string_agg(parent_table::text || ' '
                 || coalesce((regrain_delta_oid = to_regclass(parent_table::text || '_pgpm_regrain_delta')::oid)::text, 'null') || '/'
                 || coalesce((regrain_capture_fn_oid = to_regprocedure(parent_table::text || '_pgpm_regrain_capture()')::oid)::text, 'null'),
                 ',' order by parent_table::text) from pgpm.config")" "up_n true/true,up_r true/true"
# Before any tick: the upgrade itself restarted up_r, and only recorded up_n's mark.
check "the upgrade discarded up_r's pre-upgrade copy, by its oid" \
  "$(q "$IDB" "select count(*) from pg_class where oid = '${COPY_OID:-0}'::oid")" "0"
check "the upgrade logged up_r's restart, and no restart of up_n" \
  "$(q "$IDB" "select coalesce(string_agg(parent_table::text || ' ' || lo || '/' || hi || '/' || rows || '/'
                 || (method like 'the run was in flight across the upgrade that added regrain_source_mark%')::text,
                 ',' order by id), 'none')
                from pgpm.log where action = 'regrain_restart'")" "up_r 0/1000/1/true"
check "the upgrade recorded each run's mark from its source as it is now" \
  "$(q "$IDB" "select string_agg(g.parent_table::text || ' ' || g.regrain_cursor || ' '
                 || coalesce((g.regrain_source_mark = pgpm._regrain_source_mark(p.child_oid::regclass))::text, 'null'),
                 ',' order by g.parent_table::text)
                from pgpm.config g join pgpm.part p on p.parent_table = g.parent_table and p.attached and p.lo = '0'")" \
  "up_n 0 true,up_r 0 true"

# #892: the upgrade keeps that origin-only trigger, so the first tick must restart the run once more (its copy
# is already gone, so it discards none) and re-mint capture ENABLE ALWAYS; then, once the run has copied
# [0, 100) again, a replica-role UPDATE and two DELETEs into it are captured like any other change.
UP_FIRST=$(step up_r 2>&1)
check "the first tick re-armed up_r's capture ENABLE ALWAYS, restarting the run" \
  "$UP_FIRST/$(q "$IDB" "select string_agg(tgenabled::text, ',') from pg_trigger
                         where tgname = 'pgpm_regrain_capture' and tgrelid = 'public.$(src_name up_r)'::regclass")/$(q "$IDB" \
     "select count(*) from pgpm.log where parent_table = 'public.up_r'::regclass and action = 'regrain_restart'
         and method like '%pgpm_regrain_capture%is origin-only, not ENABLE ALWAYS%'")" "restarted:0/A/1"
for _ in $(seq 1 4); do
  [ "$(q "$IDB" "select regrain_cursor from pgpm.config where parent_table = 'public.up_r'::regclass")" = 100 ] && break
  step up_r >/dev/null 2>&1
done
run "$IDB" "set session_replication_role = replica;
            update public.up_r set note = 'new10' where id = 10; delete from public.up_r where id in (20, 21);" >/dev/null
check "LIVENESS: up_r re-copied [0, 100) before the replica-role DML, which committed" \
  "$(q "$IDB" "select regrain_cursor from pgpm.config where parent_table = 'public.up_r'::regclass")/$(q "$IDB" \
     "select note from public.up_r where id = 10")/$(q "$IDB" "select count(*) from public.up_r where id in (20, 21)")" "100/new10/0"

# Then the run to its swap, and the values it attached, row by row.
for _ in $(seq 1 12); do
  case "$(step up_r 2>/dev/null)" in swapped:*) break ;; esac
done
check "LIVENESS: up_r's regrain swapped [0, 1000)" \
  "$(q "$IDB" "select count(*) from pgpm.log where parent_table = 'public.up_r'::regclass
                and action = 'regrain' and method = 'copy_swap_drop' and lo = '0' and hi = '1000'")" "1"
check "up_r's regrained range holds the rewritten values" \
  "$(q "$IDB" "select string_agg(id || '=' || note, ',' order by id) from public.up_r where id in (1, 50, 99, 100, 130)")" \
  "1=OLD1,50=OLD50,99=OLD99,100=OLD100,130=OLD130"
check "up_r's replica-role UPDATE survives the swap and its DELETEs are not resurrected (#892)" \
  "$(q "$IDB" "select string_agg(id || '=' || note, ',' order by id) from public.up_r where id in (9, 10, 19, 20, 21, 22)")" \
  "9=OLD9,10=new10,19=OLD19,22=OLD22"
docker exec "$C" psql -U postgres -q -c "drop database if exists $IDB" >/dev/null 2>&1

docker exec "$C" psql -U postgres -q -c "drop database if exists $FRESH" >/dev/null 2>&1
exit "$fail"
