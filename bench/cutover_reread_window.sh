#!/usr/bin/env bash
# Guard that the transmute cutover carries what the table has when its ACCESS EXCLUSIVE is granted, not
# what an earlier read saw (issues #630 and #656). Run by CI (`./test.sh perf`).
#
# THE BAR: the converted parent carries every secondary index, outgoing key and comment the table had at
# the rename, and its identity sequence resumes past every id handed out before it. Before the fix the
# index and key lists and the identity reseed were read in the preflight and the comments at the start of
# phase 3, under nothing stronger than ACCESS SHARE, and CREATE INDEX (SHARE), ADD FOREIGN KEY (SHARE ROW
# EXCLUSIVE), COMMENT (SHARE UPDATE EXCLUSIVE) and every writer's nextval are compatible with it. So an
# index or key committed in that window stayed on the monolith, where only the rows routed there were
# checked; a comment was lost; and the ids a writer took were handed out again by the reseeded sequence,
# the next inserts failing with a duplicate key. The fix reads each under the cutover's explicit ACCESS
# EXCLUSIVE (the lock #593 took for the triggers).
#
# WHAT THIS DRIVES. Three sessions, in the order the race needs, with no timing guesses (the shape of
# bench/cutover_trigger_window.sh, which drives #593's window):
#
#   a first transmute  fails in the cutover (a blocker holds ACCESS SHARE on the REFERENCING table, and
#                      the incoming-FK drop times out), leaving a claim and a VALIDATED bound, so the
#                      resume below requests no lock on the table before phase 3.
#   session B          begins, takes ROW EXCLUSIVE, creates a unique index, adds an outgoing key and sets
#                      both comments (all granted: nothing conflicts yet), then parks in a server-side
#                      loop polling a gate table, so all of it stays UNCOMMITTED.
#   the resume         runs its preflight (B's DDL is invisible to it), then phase 3: its staging LIKE
#                      takes ACCESS SHARE (compatible with B), and it blocks on ACCESS EXCLUSIVE behind B.
#   this script        polls pg_locks until it sees the resume waiting, records the witnesses below in one
#                      statement, then opens the gate. B inserts three sequence-issued ids and one
#                      explicit one past them (it already holds ROW EXCLUSIVE, so its inserts do not queue
#                      behind the pending lock) and commits; the resume gets its lock, and what the parent
#                      carries is the property under test.
#
# THE LIVENESS WITNESSES. "Nothing was lost" is equally satisfied by a run in which B committed before
# the resume ever began (then any read sees it, and the fix is not exercised). So the guard asserts, BEFORE
# releasing B: the resume is waiting (granted = false) for AccessExclusiveLock on the table; it already
# HOLDS AccessShareLock on it, which in a resume with a validated bound only phase 3's staging LIKE takes,
# so it is past every pre-fix read point; B holds its SHARE (the index) and SHARE ROW EXCLUSIVE (the key)
# on the table, granted; and B still has an open xid. Afterwards, that B's ids really are in the table
# and in the monolith, and that its index and key really enforce there.
#
# THE INSTRUMENT'S COST. A `docker exec` sample costs 40-80 ms, which is fine: the window is not a
# duration, the resume stays parked on its lock wait until this script opens the gate. No sampling
# session reads public.cw while the resume waits (a new ACCESS SHARE queues behind a pending ACCESS
# EXCLUSIVE and would deadlock the guard against the wait it is witnessing).
#
# Asymmetric fixture: the table has one carried index and one outgoing key before B, and B adds one of
# each, so the parent's lists say which read was carried. B's ids are 6, 7, 8 and 40, so the right reseed
# (41) is neither the sequence's next value alone (9) nor the pre-lock one (6).
#
# The mutations it is required to fail against (bench/mutations/mutate.py):
#   transmute_identity_reseed_preflight  -- the reseed value is read in the preflight again: the
#                                           parent's sequence resumes at 6 and the next insert collides
#   transmute_carried_indexes_preflight  -- 9b carries the preflight's index list: cw_email_id_uq
#                                           stays on the monolith and a forward duplicate goes in
#   transmute_outgoing_fks_preflight     -- 7a re-adds the preflight's key list: cw_cust_fk stays on
#                                           the monolith and a forward orphan goes in
#   transmute_comments_before_lock       -- the comments are read and replayed before the lock again:
#                                           the parent has neither of B's comments
#
# Usage: cutover_reread_window.sh <container> <db> [install.sql]
# The install path defaults to the real one; bench/discriminate.sh passes a MUTANT copy instead.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
fail=0

q() { docker exec "$C" psql -U postgres -d "$DB" -qtA -c "$1"; }
qraw() { docker exec "$C" psql -U postgres -d "$DB" -qtA -v ON_ERROR_STOP=1 -c "$1"; }
check() { # <label> <actual> <expected>
  if [ "$2" = "$3" ]; then printf 'PASS  %-72s %s\n' "$1" "$2"
  else printf 'FAIL  %-72s got %s, want %s\n' "$1" "$2" "$3"; fail=1; fi
}
# the SQLSTATE a statement fails with, or "ok"
sqlstate() {
  q "do \$x\$ begin execute \$s\$ $1 \$s\$; raise exception using errcode = 'P0001', message = 'ok';
     exception when others then raise notice 'STATE:%', case when sqlerrm = 'ok' then 'ok' else sqlstate end;
     end \$x\$" 2>&1 | sed -n 's/.*STATE:\([A-Za-z0-9]*\).*/\1/p' | head -1
}

docker exec "$C" psql -U postgres -qtA -c "select pg_terminate_backend(pid) from pg_stat_activity where datname = '$DB'" >/dev/null 2>&1
docker exec "$C" psql -U postgres -q -v ON_ERROR_STOP=1 -c "drop database if exists $DB" >/dev/null 2>&1 \
  || { echo "FAIL  could not drop database $DB (stale connection?)"; exit 1; }
docker exec "$C" psql -U postgres -q -v ON_ERROR_STOP=1 -c "create database $DB" >/dev/null 2>&1 \
  || { echo "FAIL  could not create database $DB"; exit 1; }
docker exec "$C" psql -U postgres -d "$DB" -qv ON_ERROR_STOP=1 -f "$INSTALL" >/dev/null 2>&1 \
  || { echo "FAIL  could not install $INSTALL"; exit 1; }
check "pgpm installed into $DB, with _transmute defined" \
  "$(q "select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
         where n.nspname = 'pgpm' and p.proname = '_transmute'")" "1"

# ---- the fixture ----
# shellcheck disable=SC2016  # $f$ is a dollar-quote, not a shell variable
qraw 'create table public.region (id int primary key);
      insert into public.region values (1), (2);
      create table public.cust (id bigint primary key);
      insert into public.cust values (1), (2);
      create table public.cw (
        id     bigint generated by default as identity,
        tenant int    not null,
        region int    not null references public.region (id),
        cust   bigint not null,
        email  text   not null,
        primary key (id, tenant));
      create index cw_email_idx on public.cw (email);
      insert into public.cw (tenant, region, cust, email) select 1, 1, 1, $$e$$ || g from generate_series(1, 5) g;
      create table public.ref (id int primary key, cw_id bigint, cw_tenant int,
                               foreign key (cw_id, cw_tenant) references public.cw (id, tenant));
      insert into public.ref values (1, 3, 1);
      create table public.gate (x int);
      create function public.gate_wait() returns void language plpgsql as $f$
      begin
        for i in 1 .. 1200 loop
          exit when exists (select 1 from public.gate);
          perform pg_sleep(0.05);
        end loop;
      end $f$;' >/dev/null \
  || { echo "FAIL  fixture: could not create public.cw"; exit 1; }

# ---- the first attempt: fails in the cutover, leaving a claim and a validated bound ----
docker exec "$C" psql -U postgres -d "$DB" -qtA \
  -c "set application_name = 'crw_blocker'" -c "begin" -c "lock table public.ref in access share mode" \
  -c "select public.gate_wait()" -c "commit" >/dev/null 2>&1 &
BLK=$!
BSESS=""; RES=""
trap 'kill $BLK $BSESS $RES 2>/dev/null' EXIT
for _ in $(seq 1 100); do
  [ "$(q "select count(*) from pg_locks l join pg_stat_activity a on a.pid = l.pid
           where a.application_name = 'crw_blocker' and l.relation = 'public.ref'::regclass and l.granted")" = "1" ] && break
  sleep 0.1
done
q "call pgpm.transmute('public.cw', 'id', 100::bigint, p_obtain => 2, p_incoming_fks => 'preserve', p_lock_timeout => '300ms')" >/dev/null 2>&1
q "select pg_terminate_backend(pid) from pg_stat_activity where application_name = 'crw_blocker'" >/dev/null
wait "$BLK" 2>/dev/null
check "LIVENESS: the first attempt left a claim with a VALIDATED bound" \
  "$(q "select count(*) from pgpm.transmute_inflight i join pg_constraint c
          on c.conrelid = i.parent_table and c.conname = 'pgpm_monolith_bound' and c.convalidated
         where i.parent_table = 'public.cw'::regclass")" "1"
check "LIVENESS: and the table is still the plain table" \
  "$(q "select relkind from pg_class where oid = 'public.cw'::regclass")" "r"

# ---- session B: index, key and comments now, held uncommitted; its ids once the gate opens ----
docker exec "$C" psql -U postgres -d "$DB" -qtA -v ON_ERROR_STOP=1 \
  -c "set application_name = 'crw_b'" -c "begin" \
  -c "lock table public.cw in row exclusive mode" \
  -c "create unique index cw_email_id_uq on public.cw (email, id)" \
  -c "alter table public.cw add constraint cw_cust_fk foreign key (cust) references public.cust (id)" \
  -c "comment on table public.cw is 'b table comment'" \
  -c "comment on column public.cw.email is 'b column comment'" \
  -c "select public.gate_wait()" \
  -c "insert into public.cw (tenant, region, cust, email) values (1, 1, 1, 'b6'), (1, 1, 1, 'b7'), (1, 1, 1, 'b8')" \
  -c "insert into public.cw (id, tenant, region, cust, email) values (40, 1, 1, 1, 'b40')" \
  -c "commit" >/dev/null 2>&1 &
BSESS=$!
b_holds=0
for _ in $(seq 1 100); do
  b_holds=$(q "select count(*) from pg_locks l join pg_stat_activity a on a.pid = l.pid
                where a.application_name = 'crw_b' and l.relation = 'public.cw'::regclass
                  and l.mode in ('ShareLock', 'ShareRowExclusiveLock') and l.granted")
  [ "${b_holds:-0}" = "2" ] && [ "$(q "select count(*) from pg_stat_activity
                                      where application_name = 'crw_b' and wait_event = 'PgSleep'")" = "1" ] && break
  sleep 0.1
done
check "LIVENESS: B holds SHARE and SHARE ROW EXCLUSIVE on cw, its DDL uncommitted" "${b_holds:-0}" "2"

# ---- the resume ----
RLOG=$(mktemp)
docker exec "$C" psql -U postgres -d "$DB" -qtA -v ON_ERROR_STOP=1 \
  -c "set application_name = 'crw_resume'" \
  -c "call pgpm.transmute('public.cw', 'id', 100::bigint, p_obtain => 2, p_incoming_fks => 'preserve', p_lock_timeout => '60s')" \
  >"$RLOG" 2>&1 &
RES=$!

r_wait=0; r_share=0; b_open=0
for _ in $(seq 1 300); do
  IFS='|' read -r r_wait r_share b_open < <(q "
    select
      (select count(*) from pg_locks l join pg_stat_activity a on a.pid = l.pid
        where a.application_name = 'crw_resume' and l.locktype = 'relation'
          and l.relation = 'public.cw'::regclass and l.mode = 'AccessExclusiveLock' and not l.granted),
      (select count(*) from pg_locks l join pg_stat_activity a on a.pid = l.pid
        where a.application_name = 'crw_resume' and l.locktype = 'relation'
          and l.relation = 'public.cw'::regclass and l.mode = 'AccessShareLock' and l.granted),
      (select count(*) from pg_stat_activity where application_name = 'crw_b' and backend_xid is not null)")
  [ "${r_wait:-0}" = "1" ] && break
  sleep 0.1
done
check "LIVENESS: the resume is waiting for ACCESS EXCLUSIVE on cw" "${r_wait:-0}" "1"
check "LIVENESS: holding the ACCESS SHARE its staging LIKE took (past every old read)" "${r_share:-0}" "1"
check "LIVENESS: while B's DDL is still uncommitted (open xid)" "${b_open:-0}" "1"

# ---- open the gate ----
q "insert into public.gate values (1)" >/dev/null
wait "$BSESS"; B_RC=$?
wait "$RES"; R_RC=$?
BSESS=""; RES=""
check "B's inserts and commit went through" "$B_RC" "0"
check "the resume completed" "$R_RC" "0"
[ "$R_RC" = 0 ] || sed 's/^/      /' "$RLOG"
rm -f "$RLOG"
check "LIVENESS: the resume converted cw (transmute_resume logged, relkind p)" \
  "$(q "select (select count(*) from pgpm.log where parent_table = 'public.cw'::regclass and action = 'transmute_resume')
               || ':' || (select relkind::text from pg_class where oid = 'public.cw'::regclass)")" "1:p"
MON=$(q "select child_name from pgpm.part where parent_table = 'public.cw'::regclass order by lo::bigint limit 1")
check "LIVENESS: B's ids 6, 7, 8 and 40 are in the table, in the monolith" \
  "$(q "select string_agg(t.id::text || '@' || (c.relname = '$MON')::text, ',' order by t.id)
          from public.cw t join pg_class c on c.oid = t.tableoid where t.id > 5")" "6@true,7@true,8@true,40@true"
check "LIVENESS: B's index and key enforce in the monolith (duplicate, orphan)" \
  "$(sqlstate "insert into public.cw (id, tenant, region, cust, email) values (50, 1, 1, 1, 'd'), (50, 2, 1, 1, 'd')"):$(sqlstate "insert into public.cw (id, tenant, region, cust, email) values (51, 1, 1, 999, 'o')")" \
  "23505:23503"

# ---- the property under test ----
check "the parent carries the index it had AND the one B committed mid-cutover" \
  "$(q "select string_agg(c.relname, ',' order by c.relname) from pg_index i join pg_class c on c.oid = i.indexrelid
         where i.indrelid = 'public.cw'::regclass and not i.indisprimary")" "cw_email_id_uq_pgpm,cw_email_idx_pgpm"
check "the parent carries the key it had AND the one B committed mid-cutover" \
  "$(q "select string_agg(conname, ',' order by conname) from pg_constraint
         where conrelid = 'public.cw'::regclass and contype = 'f'")" "cw_cust_fk,cw_region_fkey"
check "the parent carries B's table and column comments" \
  "$(q "select obj_description('public.cw'::regclass, 'pg_class') || '|' ||
               col_description('public.cw'::regclass, (select attnum from pg_attribute
                 where attrelid = 'public.cw'::regclass and attname = 'email'))")" "b table comment|b column comment"
check "a duplicate (email, id) routed to a forward partition is refused" \
  "$(sqlstate "insert into public.cw (id, tenant, region, cust, email) values (150, 1, 1, 1, 'f'), (150, 2, 1, 1, 'f')")" "23505"
check "an orphan customer routed to a forward partition is refused" \
  "$(sqlstate "insert into public.cw (id, tenant, region, cust, email) values (151, 1, 1, 999, 'f')")" "23503"
check "the first sequence-issued id after the conversion is 41, past B's 40 and 8" \
  "$(q "insert into public.cw (tenant, region, cust, email) values (1, 1, 1, 'after') returning id" 2>&1 | head -1)" "41"

exit "$fail"
