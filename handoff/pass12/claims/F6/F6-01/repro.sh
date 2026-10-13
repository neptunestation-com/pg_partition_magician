#!/usr/bin/env bash
# F6-01: scripts/archive_partition_whole.sql hands a partition the operator DETACHed by hand to the
# archive strategy and records [lo, hi) as covered, though its header and its own comments say the
# candidate query leaves such a table out (pgpm._part_detached_by_hand, #705/#1159) and that it holds
# the parent (pgpm._archive_hold_partition). Once the operator attaches the table back, retire()'s drop
# gate (_archive_fully_covered) is open over rows nothing archived.
# Fixture: [0,100) holds ids 7, 42, 88 and is detached by hand; [100,200) holds 150, 160 and stays attached.
set -u
q() { $PSQL -v ON_ERROR_STOP=1 -tAc "$1"; }
fail=0
check() {  # $1 = description, $2 = 't' when the check holds
  if [ "$2" = "t" ]; then echo "ok - $1"; else echo "not ok - $1"; fail=1; fi
}

q "$(cat "$TREE/scripts/archive_partition_whole.sql")" >/dev/null || { echo "not ok - fixture: script loads"; exit 1; }
q "create schema f601;
   create table f601.calls (n serial primary key, p_child name, p_lo text, p_hi text, seen text);
   create function f601.via_parent(p_parent regclass, p_child name, p_lo text, p_hi text)
   returns pgpm.archive_result language plpgsql as \$\$
   declare v pgpm.archive_result; v_seen text; v_n bigint;
   begin
     execute format('select string_agg(id::text, '','' order by id), count(*) from %s where id >= %L::bigint and id < %L::bigint',
                    p_parent, p_lo, p_hi) into v_seen, v_n;
     insert into f601.calls (p_child, p_lo, p_hi, seen) values (p_child, p_lo, p_hi, coalesce(v_seen, 'none'));
     v.covered_hi := p_hi; v.rows_archived := v_n; v.s3_key := 'f601/' || p_lo;
     return v;
   end \$\$;
   create table public.f601_ev (id bigint primary key, payload text);
   insert into public.f601_ev values (7, 'a'), (42, 'b'), (88, 'c');" >/dev/null || { echo "not ok - fixture: setup"; exit 1; }
q "call pgpm.transmute('public.f601_ev', 'id', 100, p_obtain => 6, p_retain => 300, p_paused => false)" >/dev/null \
  || { echo "not ok - fixture: transmute"; exit 1; }
q "insert into public.f601_ev values (150, 'd'), (160, 'e'), (500, 'frontier');
   select pgpm._enforce_write_blocks('public.f601_ev');
   select pgpm.set_archive_fn('public.f601_ev', 'f601.via_parent(regclass,name,text,text)'::regprocedure);" >/dev/null \
  || { echo "not ok - fixture: blocks and strategy"; exit 1; }
P0=$(q "select child_name from pgpm.part where parent_table = 'public.f601_ev'::regclass and lo = '0'")
P100=$(q "select child_name from pgpm.part where parent_table = 'public.f601_ev'::regclass and lo = '100'")
check "LIVENESS: [0,100) and [100,200) are write-blocked and uncovered candidates" \
  "$(q "select pgpm._is_write_blocked('public.f601_ev', '$P0') and pgpm._is_write_blocked('public.f601_ev', '$P100')
          and not pgpm._archive_fully_covered('public.f601_ev', '$P0') and not pgpm._archive_fully_covered('public.f601_ev', '$P100')")"

q "alter table public.f601_ev detach partition public.\"$P0\"" >/dev/null
check "LIVENESS: [0,100) is detached by hand: attached pgpm.part row, _part_detached_by_hand true" \
  "$(q "select p.attached and pgpm._part_detached_by_hand(p.parent_table, p.child_oid, p.retiring_at)
          from pgpm.part p where p.parent_table = 'public.f601_ev'::regclass and p.child_name = '$P0'")"
check "LIVENESS: the detached table holds ids 7, 42, 88" \
  "$(q "select string_agg(id::text, ',' order by id) = '7,42,88' from public.\"$P0\"")"

M1=$(q "select pgpm_archive_next_partition_whole('public.f601_ev'::regclass)")
M2=$(q "select pgpm_archive_next_partition_whole('public.f601_ev'::regclass)")
echo "# call 1: $M1"
echo "# call 2: $M2"
check "LIVENESS: the script ran and archived [100,200), reading ids 150 and 160" \
  "$(q "select exists (select 1 from f601.calls where p_lo = '100' and p_hi = '200' and seen = '150,160')")"

check "the strategy was never handed the detached table's range [0,100)" \
  "$(q "select not exists (select 1 from f601.calls where p_lo = '0')")"
check "no archive_ledger coverage is recorded for the table detached by hand" \
  "$(q "select not exists (select 1 from pgpm.archive_ledger where parent_table = 'public.f601_ev'::regclass and child_name = '$P0')")"
check "retire()'s drop gate stays shut on [0,100)" \
  "$(q "select not pgpm._archive_fully_covered('public.f601_ev', '$P0')")"
# The consequence: the operator attaches the table back (docs' remedy for a hand detach) and retention runs.
q "alter table public.f601_ev attach partition public.\"$P0\" for values from (0) to (100)" >/dev/null
check "LIVENESS: [0,100) is attached back with ids 7, 42, 88" \
  "$(q "select string_agg(id::text, ',' order by id) = '7,42,88' from public.f601_ev where id < 100")"
q "select pgpm.retain('public.f601_ev')" >/dev/null 2>&1
check "LIVENESS: retention ran (it retired the archived [100,200))" \
  "$(q "select to_regclass('public.\"$P100\"') is null")"
check "rows 7, 42, 88, which no strategy call ever read, are still in the table after retention" \
  "$(q "select coalesce(string_agg(id::text, ',' order by id), '') = '7,42,88' from public.f601_ev where id < 100")"
exit $fail
