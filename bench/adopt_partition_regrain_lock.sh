#!/usr/bin/env bash
# adopt_partition_regrain_lock.sh <container> <db> [install.sql]
#
# Guard pgpm.adopt_partition's per-parent regrain lock: it takes pgpm._regrain_lock(parent) FIRST and holds it
# to the end of its transaction, so a regrain step cannot swap partitions under its judgement (issue #1082's
# "Locks" paragraph, above the function). Pass 11 planted the lock's removal as a novel seed and no test caught
# it: tests/303 runs adopt_partition in a session nothing else touches, where taking the lock and not taking it
# look the same. Catalogued after the pass (#1226) with this guard.
#
# THE CONTRACT. While another transaction holds the parent's regrain lock, adopt_partition waits for it: under
# a 500 ms lock_timeout it gives up with 55P03 and records nothing. Once the holder rolls back, the same call
# records the partition by its oid.
#
# THE PROBE, one psql session (every statement its own transaction) with two dblink sessions beside it:
#   b  holds the lock: BEGIN, then pgpm._regrain_lock(parent), left open;
#   c  probes the lock's row FOR UPDATE NOWAIT, once while b holds it and once after b rolled back.
# The fixture is tests/303 part B's path: a partition restored from a dump under its own name (a new oid, rows
# 3, 4 and 16) and its stale pgpm.part row deleted, so adopt_partition has a partition to record afresh.
#
# LIVENESS, the premises the verdict rests on: the restored partition has no pgpm.part row (by oid or by name)
# before the call; the lock's row exists, committed, before b takes it (so b's hold is a row lock, not an
# uncommitted insert); b's backend holds its row-share lock on pgpm.regrain_lock, granted; c's NOWAIT is refused
# on the row while b holds it and granted once b rolled back (so the probe can tell held from free); and, once
# b rolled back, adopt_partition accepts the partition and records it by oid over [0, 20). That last one is the
# positive direction: a refusal for any reason other than the lock would not lift when b lets go.
#
# The mutation it is required to fail against (bench/mutations/mutate.py):
#   adopt_partition_regrain_unlocked  -- adopt_partition without its `perform pgpm._regrain_lock(p_parent)`:
#                                        the call returns at once while b holds the lock and records the row,
#                                        and the positive direction then finds it already recorded.
#
# Runs on the plain core image (dblink). The install path defaults to the real one; bench/discriminate.sh
# passes a MUTANT copy instead.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
fail=0

q() { docker exec -i "$C" psql -U postgres -X "$@"; }
check() { # <label> <actual> <expected>
  if [ "$2" = "$3" ]; then printf 'PASS  %-66s %s\n' "$1" "$2"
  else printf 'FAIL  %-66s got %s, want %s\n' "$1" "${2:-<nothing>}" "$3"; fail=1; fi
}

q -q -c "drop database if exists $DB" </dev/null >/dev/null 2>&1
q -q -c "create database $DB" </dev/null >/dev/null 2>&1
# A mutant that will not even install is NOT a pass: say which happened.
if ! q -d "$DB" -v ON_ERROR_STOP=1 -q --single-transaction -f "$INSTALL" </dev/null >/dev/null 2>&1; then
  printf 'FAIL  %-66s %s\n' "fixture: the module under test installed" "$INSTALL"
  q -q -c "drop database if exists $DB" </dev/null >/dev/null 2>&1
  exit 1
fi

# Every observation is a `select 'R <key>=' || ...` line; nothing else the session prints starts with "R ".
out=$(q -d "$DB" -v ON_ERROR_STOP=1 -qtA -f - 2>&1 <<'SQL'
set client_min_messages = warning;
create extension if not exists dblink;
-- 'ok', or the SQLSTATE and message a statement raised: one call, one transaction
create function pg_temp.try(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'ok';
exception when others then
  return sqlstate || ' ' || sqlerrm;
end;
$$;

create table public.arl (id bigint primary key, payload text);
insert into public.arl values (3, 'a'), (4, 'b'), (16, 'c');
call pgpm.transmute('public.arl', 'id', 10::bigint);
select pgpm.extend_to('public.arl', '60') is not null as extended \gset
insert into public.arl values (27, 'd'), (52, 'frontier');
select child_name as p_old from pgpm.part where parent_table = 'public.arl'::regclass and lo = '0' \gset
-- restored from a dump under its own name: same rows, a new oid; then the old repair, the stale row deleted
alter table public.arl detach partition public.:"p_old";
create table public.arl_r (like public.:"p_old" including all);
insert into public.arl_r select * from public.:"p_old";
drop table public.:"p_old";
alter table public.arl_r rename to :"p_old";
alter table public.arl attach partition public.:"p_old" for values from ('0') to ('20');
delete from pgpm.part where parent_table = 'public.arl'::regclass and child_name = :'p_old';
select to_regclass('public.' || :'p_old')::oid as p_oid \gset
select 'R restored=' || (select string_agg(id::text, ',' order by id) from public.:"p_old");
select 'R unrecorded=' || (select count(*) from pgpm.part where parent_table = 'public.arl'::regclass
                             and (child_oid = :p_oid or child_name = :'p_old'));
-- the lock's row, created and committed by its first use, so b's hold below is a row lock
select pgpm._regrain_lock('public.arl'::regclass);
select 'R lockrow=' || (select count(*) from pgpm.regrain_lock where parent_table = 'public.arl'::regclass);

select dblink_connect('b', 'dbname=' || current_database()) as b \gset
select dblink_connect('c', 'dbname=' || current_database()) as c \gset
select dblink_exec('b', 'begin') as b_begin \gset
select b_pid from dblink('b', 'select pg_backend_pid()') as t(b_pid int) \gset
select x as b_locked from dblink('b', $$select pgpm._regrain_lock('public.arl'::regclass)::text$$) as t(x text) \gset
select 'R b_holds=' || exists (select 1 from pg_locks where pid = :b_pid and locktype = 'relation'
                                 and relation = 'pgpm.regrain_lock'::regclass and mode = 'RowShareLock' and granted);
select 'R probe_held=' || pg_temp.try($$select x from dblink('c',
  'select 1 from pgpm.regrain_lock where parent_table = ''public.arl''::regclass for update nowait') as t(x int)$$);

-- the call under test, while b holds the lock
set lock_timeout = '500ms';
select 'R attempt=' || pg_temp.try(format('select pgpm.adopt_partition(%L, %L)', 'public.arl', 'public.' || :'p_old'));
reset lock_timeout;
select 'R while_held=' || coalesce((select string_agg(child_name, ',') from pgpm.part
                                     where parent_table = 'public.arl'::regclass and child_oid = :p_oid), 'none');

-- b lets go: the lock is free, and the same call records the partition
select dblink_exec('b', 'rollback') as b_rollback \gset
select 'R probe_free=' || pg_temp.try($$select x from dblink('c',
  'select 1 from pgpm.regrain_lock where parent_table = ''public.arl''::regclass for update nowait') as t(x int)$$);
set lock_timeout = '500ms';
select 'R after=' || pg_temp.try(format('select pgpm.adopt_partition(%L, %L)', 'public.arl', 'public.' || :'p_old'));
reset lock_timeout;
select 'R recorded=' || coalesce((select string_agg(format('%s|%s|%s', (child_name = :'p_old')::text, lo, hi), ',')
                                   from pgpm.part where parent_table = 'public.arl'::regclass
                                    and child_oid = :p_oid), 'none');
select dblink_disconnect('b') as b_gone \gset
select dblink_disconnect('c') as c_gone \gset
select 'R end=1';
SQL
)
get() { sed -n "s/^R $1=//p" <<<"$out" | head -1; }

check "fixture: the probe ran to its end" "$(get end)" "1"
if [ "$(get end)" != 1 ]; then grep -E 'ERROR|FATAL' <<<"$out" | head -5 | sed 's/^/      /'; fi
check "LIVENESS: the restored partition holds its rows 3, 4 and 16" "$(get restored)" "3,4,16"
check "LIVENESS: no pgpm.part row records it, by oid or by name" "$(get unrecorded)" "0"
check "LIVENESS: the regrain lock's row exists, committed, before b takes it" "$(get lockrow)" "1"
check "LIVENESS: b's backend holds its row-share lock on pgpm.regrain_lock" "$(get b_holds)" "true"
probe=$(get probe_held)
check "LIVENESS: c's FOR UPDATE NOWAIT on the lock's row is refused while b holds" \
      "$([[ "$probe" == "55P03 "*"could not obtain lock on row"* ]] && echo refused || echo "$probe")" "refused"
check "adopt_partition waits on b's regrain lock (55P03 at its 500 ms lock_timeout)" \
      "$(get attempt)" "55P03 canceling statement due to lock timeout"
check "adopt_partition recorded nothing while b held the regrain lock" "$(get while_held)" "none"
check "LIVENESS: c's FOR UPDATE NOWAIT is granted once b rolled back" "$(get probe_free)" "ok"
check "LIVENESS: once b rolled back, adopt_partition accepts the partition" "$(get after)" "ok"
check "LIVENESS: and records it by its oid over [0, 20)" "$(get recorded)" "true|0|20"

q -q -c "drop database if exists $DB" </dev/null >/dev/null 2>&1
exit "$fail"
