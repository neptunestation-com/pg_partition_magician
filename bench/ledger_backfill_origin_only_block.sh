#!/usr/bin/env bash
# ledger_backfill_origin_only_block.sh <container> <db> [install.sql]
#
# Guard the upgrade that adds pgpm.archive_ledger.child_oid (pgpm._backfill_chunk_oids, issue #1160) against an
# ARBITRARY copy of pgpm_core/install.sql, so that bench/discriminate.sh can show it catches the defects its
# mutations put back. The backfill attributes a pre-existing chunk on IDENTITY: the oid pgpm recorded when it
# created the partition, still held by the name, and never an oid the same upgrade's #421 backfill adopted from
# whatever held the name (pgpm.upgrade_adopted_anchor). Under such an anchor a block that is ALWAYS, origin-only
# (every release through v0.6.0) or absent (v0.6.0's own lift) attributes; disabled or replica-only (a hand edit)
# retires. Attributing only under an ALWAYS block held every archived partition of a v0.6.0 install for good;
# attributing under an adopted anchor archived a hand-re-created successor over the only copy of the dropped rows.
#
# TWO PARTS, because the backfill reads what install.sql recorded before it ran:
#   1. tests/314_ledger_backfill_origin_only_block_test.sql, the acceptance test, one partition per block state and
#      an adopted successor; it records the adopted anchor itself, as install.sql would.
#   2. A real round trip through install.sql: a database installed from the copy under test is put back into the
#      shape an older install leaves (the two ledger columns dropped, one partition's block origin-only, another's
#      lifted, a hand-re-created successor's pgpm.part anchor nulled as before #421) and install.sql is re-run over
#      it, so the recording of adopted anchors, the backfill and the drop of the record are the copy's own.
#
# Mutations (bench/mutations/mutate.py): archive_ledger_backfill_origin_only_retired,
# archive_ledger_backfill_lifted_retired, archive_ledger_backfill_hand_state_attributed,
# archive_ledger_backfill_adopted_blocked_attributed, archive_ledger_upgrade_adoption_unrecorded.
#
# Runs on the plain core image (pgtap and pg_prove). TAP_GUARD_TEST_FILE overrides the test file's path inside
# the container, for a worktree mounted somewhere other than /repo.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
TEST_FILE="${TAP_GUARD_TEST_FILE:-/repo/tests/314_ledger_backfill_origin_only_block_test.sql}"
UP="${DB}_up"
fail=0

q() { docker exec "$C" psql -U postgres "$@"; }
v() { docker exec "$C" psql -U postgres -d "$UP" -qtAX -c "$1" 2>&1; }
check() { # <label> <actual> <expected>
  if [ "$2" = "$3" ]; then printf 'PASS  %-58s %s\n' "$1" "$2"
  else printf 'FAIL  %-58s got %s, want %s\n' "$1" "$2" "$3"; fail=1; fi
}

# ---------------------------------------------------------------------------- part 1: tests/314
q -q -c "drop database if exists $DB" >/dev/null 2>&1
q -q -c "create database $DB" >/dev/null 2>&1
q -d "$DB" -q -c "create extension if not exists pgtap;" >/dev/null 2>&1

# A mutant that will not even install is NOT a pass: say which happened.
if ! q -d "$DB" -v ON_ERROR_STOP=1 -q --single-transaction -f "$INSTALL" >/dev/null 2>&1; then
  printf 'FAIL  %-58s %s\n' "the module under test installed" "$INSTALL"
  fail=1
fi

if [ "$fail" = 0 ]; then
  out=$(docker exec "$C" sh -c "pg_prove -v -U postgres -d $DB $TEST_FILE" 2>&1)
  rc=$?
  echo "$out" | grep -E '^not ok [0-9]+ -' | sed 's/^/    /' | head -20
  # the count is asserted separately: a run that never reached the database must not read as a catch
  ran=$(echo "$out" | grep -cE '^(not )?ok [0-9]+ -')
  if [ "$rc" = 0 ]; then printf 'PASS  %-58s %s\n' "the backfill attributes a chunk on identity, per block state" "$ran ran"
  else printf 'FAIL  %-58s %s\n' "the backfill attributes a chunk on identity, per block state" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-58s %s\n' "the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
fi
q -q -c "drop database if exists $DB" >/dev/null 2>&1

# ---------------------------------------------------------------------------- part 2: install.sql round trip
q -q -c "drop database if exists $UP" >/dev/null 2>&1
q -q -c "create database $UP" >/dev/null 2>&1
if ! q -d "$UP" -v ON_ERROR_STOP=1 -q --single-transaction -f "$INSTALL" >/dev/null 2>&1; then
  printf 'FAIL  %-58s %s\n' "the module under test installed (round trip)" "$INSTALL"
  q -q -c "drop database if exists $UP" >/dev/null 2>&1
  exit 1
fi
# a: [0, 100) ids 1..9 a<id> (its block left origin-only), [100, 200) ids 101..104 b<id> (its block lifted by
# pgpm's own _remove_write_block). s: [0, 100) ids 1..3 old<id>, archived, dropped by hand and re-created with ids
# 5..6 new<id>, blocked origin-only, its anchor nulled as an install before #421 leaves it.
docker exec -i "$C" psql -U postgres -d "$UP" -q -v ON_ERROR_STOP=1 >/dev/null 2>&1 <<'SQL'
set client_min_messages = warning;
create schema g330;
create table g330.objects (key text primary key, body text);
create function g330.strat(p_parent regclass, p_child name, p_lo text, p_hi text)
returns pgpm.archive_result language plpgsql as $$
declare v_body text; v_n bigint; v_key text := p_parent::text || '/' || p_lo; v_r pgpm.archive_result;
begin
  execute format('select string_agg(id || '':'' || payload, '','' order by id), count(*) from %s where id >= %L and id < %L',
                 p_parent, p_lo, p_hi) into v_body, v_n;
  insert into g330.objects values (v_key, coalesce(v_body, '')) on conflict (key) do update set body = excluded.body;
  v_r.covered_hi := p_hi; v_r.rows_archived := v_n; v_r.s3_key := v_key;
  return v_r;
end $$;
create procedure g330.mk(p_rel text) language plpgsql as $$
begin
  execute format('create table g330.%I (id bigint primary key, payload text not null)', p_rel);
  call pgpm.transmute('g330.' || p_rel, 'id', 100, p_retain => 100::bigint, p_paused => false);
  perform pgpm.extend_to(('g330.' || p_rel)::regclass, '500');
  execute format('insert into g330.%I values (450, ''frontier'')', p_rel);
  update pgpm.config set retain_batch = 0, archive_batch = null where parent_table = ('g330.' || p_rel)::regclass;
  perform pgpm.set_archive_fn(('g330.' || p_rel)::regclass, 'g330.strat(regclass,name,text,text)'::regprocedure);
end $$;
call g330.mk('a');
insert into g330.a select g, 'a' || g from generate_series(1, 9) g;
insert into g330.a select g, 'b' || g from generate_series(101, 104) g;
call pgpm.maintain('g330.a');
call g330.mk('s');
insert into g330.s select g, 'old' || g from generate_series(1, 3) g;
call pgpm.maintain('g330.s');
do $$
declare a0 name; a1 name; s0 name;
begin
  select child_name into a0 from pgpm.part where parent_table = 'g330.a'::regclass and lo = '0';
  select child_name into a1 from pgpm.part where parent_table = 'g330.a'::regclass and lo = '100';
  select child_name into s0 from pgpm.part where parent_table = 'g330.s'::regclass and lo = '0';
  execute format('alter table g330.%I enable trigger pgpm_write_block', a0);
  perform pgpm._remove_write_block('g330.a', a1);
  execute format('drop table g330.%I', s0);
  execute format('create table g330.%I partition of g330.s for values from (0) to (100)', s0);
  insert into g330.s values (5, 'new5'), (6, 'new6');
  update pgpm.part set child_oid = to_regclass(format('g330.%I', s0))::oid
   where parent_table = 'g330.s'::regclass and child_name = s0;
  perform pgpm._install_write_block('g330.s', s0);
  execute format('alter table g330.%I enable trigger pgpm_write_block', s0);
  update pgpm.part set child_oid = null where parent_table = 'g330.s'::regclass and child_name = s0;
end $$;
alter table pgpm.archive_ledger drop column retired_at, drop column child_oid;
SQL
check "LIVENESS: the older shape: blocks O, none, O; s unanchored" \
  "$(v "select string_agg(format('%s/%s:%s', p.parent_table, p.lo, coalesce(t.tgenabled::text, 'none')), ' ' order by p.parent_table::text, p.lo::int)
          from pgpm.part p left join pg_trigger t on t.tgrelid = to_regclass(format('g330.%I', p.child_name)) and t.tgname = 'pgpm_write_block'
         where (p.parent_table = 'g330.a'::regclass and p.lo in ('0', '100')) or (p.parent_table = 'g330.s'::regclass and p.lo = '0')")|$(v "select child_oid is null from pgpm.part where parent_table = 'g330.s'::regclass and lo = '0'")" \
  "g330.a/0:O g330.a/100:none g330.s/0:O|t"
check "LIVENESS: the ledger lost its two columns, the chunks recorded" \
  "$(v "select count(*) from pg_attribute where attrelid = 'pgpm.archive_ledger'::regclass and attname in ('retired_at', 'child_oid') and not attisdropped")|$(v "select string_agg(format('%s/%s', parent_table, lo), ' ' order by parent_table::text, lo::int) from pgpm.archive_ledger where (parent_table = 'g330.a'::regclass and lo::int < 200) or (parent_table = 'g330.s'::regclass and lo = '0')")" \
  "0|g330.a/0 g330.a/100 g330.s/0"

if ! q -d "$UP" -v ON_ERROR_STOP=1 -q -f "$INSTALL" >/dev/null 2>&1; then
  printf 'FAIL  %-58s %s\n' "LIVENESS: install.sql re-ran over the older shape" "$INSTALL"; fail=1
fi
check "LIVENESS: the upgrade re-added the columns and adopted s's successor" \
  "$(v "select count(*) from pg_attribute where attrelid = 'pgpm.archive_ledger'::regclass and attname in ('retired_at', 'child_oid') and not attisdropped")|$(v "select child_oid = to_regclass(format('g330.%I', child_name))::oid from pgpm.part where parent_table = 'g330.s'::regclass and lo = '0'")" \
  "2|t"
check "the upgrade leaves no adopted-anchor record behind" "$(v "select to_regclass('pgpm.upgrade_adopted_anchor') is null")" "t"
check "the backfill attributes a's chunks, and retires s's under the adopted anchor" \
  "$(v "select string_agg(format('%s/%s:%s:%s', l.parent_table, l.lo, case when l.child_oid = p.child_oid then 'own' when l.child_oid is null then 'none' else 'other' end,
                                 case when l.retired_at is null then 'live' else 'retired' end), ' ' order by l.parent_table::text, l.lo::int)
          from pgpm.archive_ledger l join pgpm.part p on p.parent_table = l.parent_table and p.child_name = l.child_name
         where (l.parent_table = 'g330.a'::regclass and l.lo::int < 200) or (l.parent_table = 'g330.s'::regclass and l.lo = '0')")" \
  "g330.a/0:own:live g330.a/100:own:live g330.s/0:none:retired"

v "update pgpm.config set retain_batch = null where parent_table = 'g330.a'::regclass" >/dev/null
for _ in 1 2; do v "call pgpm.maintain('g330.a')" >/dev/null; v "call pgpm.maintain('g330.s')" >/dev/null; done
check "LIVENESS: the ticks reached s's successor and held it" \
  "$(v "select string_agg(lo, ',') from pgpm.log where parent_table = 'g330.s'::regclass and action = 'skip_archive_retired_range'")" "0"
check "s's object still holds the dropped rows, the only copy" "$(v "select body from g330.objects where key = 'g330.s/0'")" "1:old1,2:old2,3:old3"
check "a's two partitions were archived again and dropped" \
  "$(v "select string_agg(format('%s|%s', lo, hi), ' ' order by lo::int) from pgpm.log where parent_table = 'g330.a'::regclass and action = 'retain_drop' and lo::int < 200")|$(v "select string_agg(format('%s=%s', key, body), ' ' order by key) from g330.objects where key in ('g330.a/0', 'g330.a/100')")" \
  "0|100 100|200|g330.a/0=1:a1,2:a2,3:a3,4:a4,5:a5,6:a6,7:a7,8:a8,9:a9 g330.a/100=101:b101,102:b102,103:b103,104:b104"

q -q -c "drop database if exists $UP" >/dev/null 2>&1
exit "$fail"
