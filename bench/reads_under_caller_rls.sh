#!/usr/bin/env bash
# Guard the reads-under-RLS lever (issue #873): pgpm never reads user rows under a caller's row-level
# security without saying so. pgpm._refuse_filtered_reads (#825) is asked of the relation each read actually
# reads (the parent, the monolith or source partition, a referencing table) at every entry point that reads
# user rows, before anything is written, and asked again under from_hypertable_cutover's lock.
#
# ONE GUARD, THREE MODULES. The lever's sites are in all three install files, and discriminate.sh hands a
# guard the container and the mutant of whichever file its mutation patches. So this script reads which
# module the install it was given is (by a routine only that module defines) and runs that module's half:
#   core       tests/241 (the conformance suite: every pgpm entry point classified from the catalog, each
#              reading one refused as a non-BYPASSRLS owner of FORCE'd tables) and tests/242 (regrain and
#              untransmute, by identity), through pg_prove, on the plain core image
#   archive    tests/archive/db/38 (the module's readers and its classification), on the archive image
#              with MinIO on the compose network (the bucket is made here too, as run_discriminate does not)
#   hypertable tests/timescale/db/46 (the online drains and the module's classification) and PART H below,
#              on the timescale track's fleet image, over TCP (it does not trust the local socket)
#
# PART H is #873 bullet 3, the verifier's reproduction made deterministic. The cutover asks the lever up
# front, from the committed catalog; a policy committed after that filtered its catch-up and its
# conservation check alike, on the append-only path they agreed, and the swap dropped the row the policy
# hid. The window is opened by a held lock, not a sleep (bench/hypertable_cutover_shape.sh's technique): a
# holder takes ACCESS EXCLUSIVE on the COPY, the cutover (p_predrain => false, so its first touch of the
# copy is the pre-lock baseline read, after the up-front checks) queues behind it holding nothing on the
# source, the owner's FORCE and policy commit on the source, and the holder is ended. Every one of those
# states is asserted while it holds. The contract: the cutover refuses under its lock, with the source
# whole, row 11 included.
#
# The mutations it is required to fail against (bench/mutations/mutate.py), one per site:
#   core:       rls_frontier_unchecked, rls_regrain_source_unchecked, rls_untransmute_unchecked,
#               rls_archive_step_parent_unchecked, rls_archive_step_child_unchecked,
#               rls_check_uuidv7_unchecked, rls_check_text_time_unchecked, rls_check_time_monotonic_unchecked,
#               rls_crossing_keys_unchecked, rls_fk_orphans_referencing_unchecked,
#               rls_fk_orphans_parent_unchecked
#   archive:    rls_to_s3_unchecked, rls_to_s3_parquet_unchecked, rls_archive_ndjson_unchecked,
#               rls_archive_parquet_unchecked
#   hypertable: rls_cutover_unchecked_under_lock (PART H), rls_drain_appends_step_unchecked,
#               rls_drain_appends_unchecked, rls_drain_delta_step_unchecked (tests/timescale/db/46)
#
# Usage: reads_under_caller_rls.sh <container> <db> [install.sql of the module under test]
# With no third argument the core is under test. The perf track runs the core half, run_archive and
# run_timescale the other two against their unmutated modules, so a harness that failed against
# everything could not read as discrimination. PGPM_TEST_NET names the archive half's compose network.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; INSTALL="${3:-/repo/pgpm_core/install.sql}"
NET="${PGPM_TEST_NET:-pgpm_test_net}"
fail=0

if docker exec "$C" grep -q 'procedure pgpm.from_hypertable_cutover' "$INSTALL" </dev/null 2>/dev/null; then MODE=hypertable
elif docker exec "$C" grep -q 'function archive.to_s3(' "$INSTALL" </dev/null 2>/dev/null; then MODE=archive
elif docker exec "$C" grep -q 'function pgpm._refuse_filtered_reads' "$INSTALL" </dev/null 2>/dev/null; then MODE=core
else printf 'FAIL  %-66s %s\n' "the install under test is one of the three modules" "$INSTALL"; exit 1
fi
echo "--- module under test: $MODE ($INSTALL)"

# prove <db> <test file>: pg_prove's verdict, and the count, which tells a run that never reached the
# database apart from one whose assertions failed (discriminate.sh reads any failure as discrimination).
prove() {
  local out rc ran
  out=$(docker exec "$C" sh -c "pg_prove -v -U postgres -d $1 $2" 2>&1 </dev/null); rc=$?
  echo "$out" | grep -E '^not ok [0-9]+ -' | sed 's/^/    /' | head -20
  ran=$(echo "$out" | grep -cE '^(not )?ok [0-9]+ -')
  if [ "$rc" = 0 ]; then printf 'PASS  %-66s %s\n' "${2##*/}" "$ran ran"
  else printf 'FAIL  %-66s %s\n' "${2##*/}" "$ran ran"; fail=1; fi
  if [ "$ran" -eq 0 ]; then
    printf 'FAIL  %-66s %s\n' "LIVENESS: the assertions were reached at all" "0 ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
  # A failure is only evidence against the code when the setup it depends on held: name any witness that
  # failed, so a run that failed for the fixture's sake reads as that.
  if echo "$out" | grep -qE '^not ok [0-9]+ - .*(LIVENESS|WITNESS)'; then
    printf 'FAIL  %-66s %s\n' "every LIVENESS and WITNESS assertion held" "no (see above)"
    fail=1
  fi
}

# ================================ core ================================
if [ "$MODE" = core ]; then
  q() { docker exec "$C" psql -U postgres "$@" </dev/null; }
  for t in 241_reads_under_caller_rls_conformance_test 242_regrain_untransmute_caller_rls_test; do
    db="${DB}_${t%%_*}"
    q -q -c "drop database if exists $db" >/dev/null 2>&1
    q -q -c "create database $db" >/dev/null 2>&1
    q -d "$db" -q -c "create extension if not exists pgtap" >/dev/null 2>&1
    if ! q -d "$db" -v ON_ERROR_STOP=1 -q --single-transaction -f "$INSTALL" >/dev/null 2>&1; then
      printf 'FAIL  %-66s %s\n' "the module under test installed" "$INSTALL"; fail=1
    else
      prove "$db" "/repo/tests/$t.sql"
    fi
    q -q -c "drop database if exists $db" >/dev/null 2>&1
  done
  exit "$fail"
fi

# ================================ archive ================================
if [ "$MODE" = archive ]; then
  q() { docker exec "$C" psql -U postgres "$@" </dev/null; }
  ready=""
  for _ in $(seq 1 60); do
    if docker run --rm --network "$NET" curlimages/curl -sf http://minio:9000/minio/health/cluster >/dev/null 2>&1 </dev/null; then ready=1; break; fi
    sleep 1
  done
  if [ -z "$ready" ]; then printf 'FAIL  %-66s %s\n' "MinIO reported ready (/minio/health/cluster)" "not within 60 s"; exit 1; fi
  code=$(docker run --rm --network "$NET" curlimages/curl -s -o /dev/null -w '%{http_code}' \
           --aws-sigv4 aws:amz:us-east-1:s3 -u minioadmin:minioadmin \
           -X PUT http://minio:9000/archive-test-bucket </dev/null) || code="curl exit $?"
  if [ "$code" != 200 ] && [ "$code" != 409 ]; then printf 'FAIL  %-66s %s\n' "the MinIO bucket exists" "PUT returned $code"; exit 1; fi
  q -q -c "drop database if exists $DB" >/dev/null 2>&1
  q -q -c "create database $DB" >/dev/null 2>&1
  q -d "$DB" -q -c "create extension if not exists http; create extension if not exists pgcrypto; create extension if not exists pgtap;" >/dev/null 2>&1
  if ! q -d "$DB" -v ON_ERROR_STOP=1 -q -f /repo/tests/archive/fixtures.sql >/dev/null 2>&1; then
    printf 'FAIL  %-66s %s\n' "the archive fixtures installed" "no"; fail=1
  elif ! q -d "$DB" -v ON_ERROR_STOP=1 -q --single-transaction -f /repo/pgpm_core/install.sql >/dev/null 2>&1; then
    printf 'FAIL  %-66s %s\n' "pgpm_core installed" "no"; fail=1
  elif ! q -d "$DB" -v ON_ERROR_STOP=1 -q -f "$INSTALL" >/dev/null 2>&1; then
    printf 'FAIL  %-66s %s\n' "the module under test installed" "$INSTALL"; fail=1
  else
    prove "$DB" /repo/tests/archive/db/38_archive_reads_under_caller_rls_test.sql
  fi
  q -q -c "drop database if exists $DB" >/dev/null 2>&1
  exit "$fail"
fi

# ================================ hypertable ================================
HT="$INSTALL"
TEST_FILE=/repo/tests/timescale/db/46_from_hypertable_reads_under_caller_rls_test.sql
LABEL="the online drains refuse a caller whose reads RLS filters"
HOLD=${HOLD:-60}
LOG=$(mktemp)
q() { docker exec -e PGPASSWORD=postgres "$C" psql -h 127.0.0.1 -U postgres "$@" </dev/null; }
v() { q -d "$DB" -qtA -c "$1" 2>&1; }
check() { # <label> <actual> <expected>
  if [ "$2" = "$3" ]; then printf 'PASS  %-78s %s\n' "$1" "$2"
  else printf 'FAIL  %-78s got %s, want %s\n' "$1" "'$2'" "'$3'"; fail=1; fi
}
end_session() { # <application_name>
  q -d postgres -qtA -c "select pg_terminate_backend(pid) from pg_stat_activity
      where datname = '$DB' and application_name = '$1'" >/dev/null 2>&1
}
fresh_db() {
  q -d postgres -q -c "drop database if exists $DB" >/dev/null 2>&1
  q -d postgres -q -c "create database $DB" >/dev/null 2>&1
  q -d postgres -q -c "alter database $DB set client_min_messages = warning" >/dev/null 2>&1
  q -d "$DB" -q -c "create extension if not exists timescaledb; create extension if not exists pgtap;" >/dev/null 2>&1
  if ! q -d "$DB" -v ON_ERROR_STOP=1 -q --single-transaction -f /repo/pgpm_core/install.sql >/dev/null 2>&1; then
    printf 'FAIL  %-78s %s\n' "pgpm_core installed" "/repo/pgpm_core/install.sql"; return 1
  fi
  if ! q -d "$DB" -v ON_ERROR_STOP=1 -q -f "$HT" >/dev/null 2>&1; then
    printf 'FAIL  %-78s %s\n' "the module under test installed" "$HT"; return 1
  fi
  if ! q -d "$DB" -v ON_ERROR_STOP=1 -q -f /repo/tests/timescale/fixtures.sql >/dev/null 2>&1; then
    printf 'FAIL  %-78s %s\n' "the timescale fixtures loaded" "tests/timescale/fixtures.sql"; return 1
  fi
}

echo "--- the online drains (tests/timescale/db/46)"
if fresh_db; then
  # >>> pgTAP verdict: the same in every timescale wrapper; bench/wrapper_tap_verdicts.sh evaluates it.
  out=$(q -d "$DB" -tAq -f "$TEST_FILE" 2>&1); rc=$?
  # grep -E, not a sed alternation: this half runs on the HOST, and BSD sed has no `\|`.
  echo "$out" | grep -E '^not ok [0-9]+' | sed 's/^/    /' | head -20
  planned=$(echo "$out" | sed -nE 's/^1\.\.([0-9]+)$/\1/p' | head -1)
  ran=$(echo "$out" | grep -cE '^(not )?ok [0-9]+( |$)')
  bad=$(echo "$out" | grep -cE '^not ok [0-9]+( |$)')
  # pg_prove's verdict, which this runner has to apply itself. Three ways a file fails with no `not ok`,
  # each reported apart from assertions that ran and failed (discriminate.sh reads any non-zero exit as
  # "the guard caught the defect", so a harness that fails everything must say why): a raw ERROR:; a
  # psql exit other than 0, which is how a session that died part-way (FATAL, no ERROR:) shows, since it
  # never reaches finish() to print "# Looks like you planned" (#795); and a count of assertions
  # that is not the 1..N plan's, which a silently skipped assertion leaves (#601, #712).
  # A file that reached no assertion failed on its fixture, whatever stopped it, so its setup lines are
  # premises then and discriminate.sh's starved() does not read them as a catch (#1177).
  unreached=""; [ "$ran" -gt 0 ] || unreached="fixture: "
  if echo "$out" | grep -qE '^ERROR:|^psql:.*ERROR:'; then
    printf 'FAIL  %-58s %s\n' "${unreached}the file ran without a raw error" "see below"
    echo "$out" | grep -E 'ERROR:' | head -5 | sed 's/^/      /'
    fail=1
  fi
  if [ "$rc" != 0 ]; then
    printf 'FAIL  %-58s %s\n' "${unreached}psql ran the file to its end" "exit $rc"
    echo "$out" | grep -E 'FATAL:|connection' | head -5 | sed 's/^/      /'
    fail=1
  fi
  if [ -z "$planned" ] || [ "$ran" != "$planned" ]; then
    printf 'FAIL  %-58s %s\n' "${unreached}the file ran every assertion it planned" "planned ${planned:-nothing}, $ran ran"
    echo "$out" | tail -20 | sed 's/^/      /'
    fail=1
  fi
  if [ "$bad" = 0 ] && [ "$fail" = 0 ]; then
    printf 'PASS  %-58s %s\n' "$LABEL" "$ran ran"
  else
    printf 'FAIL  %-58s %s\n' "$LABEL" "$ran ran, $bad failed"; fail=1
  fi
  # <<< pgTAP verdict
else
  fail=1
fi

# ============================ PART H: row-level security committed while the cutover prepares ============
echo "--- PART H: FORCE and a policy committed after the cutover's up-front check, before its lock"
if ! fresh_db; then
  rm -f "$LOG"; q -d postgres -q -c "drop database if exists $DB" >/dev/null 2>&1; exit 1
fi
# The owner: no superuser, no BYPASSRLS. Named, not CURRENT_USER, in the GRANT (the fleet image's hook).
v "do \$\$ begin if not exists (select 1 from pg_roles where rolname = 'trls_h_owner') then
     create role trls_h_owner nosuperuser nobypassrls; end if; end \$\$;
   grant trls_h_owner to postgres;
   grant create, usage on schema public to trls_h_owner;
   grant usage on schema pgpm to trls_h_owner;
   grant all on all tables in schema pgpm to trls_h_owner;
   grant all on all sequences in schema pgpm to trls_h_owner;" >/dev/null
# ASYMMETRIC: ten copied rows, tenant a; then row 11, tenant b, appended past the copy's watermark.
v "set role trls_h_owner;
   create table public.hrls (id bigint not null, ts timestamptz not null, tenant text not null, primary key (id, ts));
   select create_hypertable('public.hrls', 'ts', chunk_time_interval => interval '1 day');
   insert into public.hrls select g, now() - g * interval '8 hours', 'a' from generate_series(1, 10) g;" >/dev/null
# Separate -c's: one -c holding both is one transaction, which the copy's per-chunk COMMIT cannot end.
q -d "$DB" -qtA -c "set role trls_h_owner" -c "call pgpm.from_hypertable_copy('public.hrls', 'ts', p_track_changes => false)" >/dev/null
v "set role trls_h_owner; insert into public.hrls values (11, now(), 'b')" >/dev/null
check "LIVENESS: the source holds rows 1..10 (tenant a) and row 11 (tenant b), the copy 1..10" \
  "$(v "select string_agg(id || ':' || tenant, ',' order by id) from public.hrls")/$(v "select string_agg(id::text, ',' order by id) from public.hrls_pgpm_dest")" \
  "1:a,2:a,3:a,4:a,5:a,6:a,7:a,8:a,9:a,10:a,11:b/1,2,3,4,5,6,7,8,9,10"
check "LIVENESS: nothing filters the owner's reads yet (the up-front check will pass)" \
  "$(v "set role trls_h_owner; select row_security_active('public.hrls')")" "f"

# The holder: ACCESS EXCLUSIVE on the copy, tagged so the teardown ends exactly this backend.
q -d "$DB" -qtA -c "set application_name = 'trls_h_holder'" \
  -c "begin; lock table public.hrls_pgpm_dest in access exclusive mode; select pg_sleep($HOLD); commit;" >/dev/null 2>&1 &
HOLDER=$!
held=no
for _ in $(seq 1 100); do
  if [ "$(v "select count(*) from pg_locks l join pg_stat_activity a on a.pid = l.pid
             where a.application_name = 'trls_h_holder' and l.relation = 'public.hrls_pgpm_dest'::regclass
               and l.mode = 'AccessExclusiveLock' and l.granted")" = 1 ]; then held=yes; break; fi
  sleep 0.1
done
check "LIVENESS: the holder has ACCESS EXCLUSIVE on the copy" "$held" "yes"

q -d "$DB" -qtA -c "set application_name = 'trls_h_cutover'" -c "set role trls_h_owner" \
  -c "call pgpm.from_hypertable_cutover('public.hrls', 'ts', interval '1 day', p_paused => true,
                                        p_predrain => false, p_lock_timeout => '60s')" >"$LOG" 2>&1 &
CUT=$!
queued=no
for _ in $(seq 1 150); do
  if [ "$(v "select count(*) from pg_locks l join pg_stat_activity a on a.pid = l.pid
             where a.application_name = 'trls_h_cutover' and l.relation = 'public.hrls_pgpm_dest'::regclass
               and not l.granted")" = 1 ]; then queued=yes; break; fi
  sleep 0.1
done
check "LIVENESS: the cutover is queued on the copy, past its up-front checks" "$queued" "yes"
check "LIVENESS: and holds no lock on the source while it waits (the window is open)" \
  "$(v "select count(*) from pg_locks l join pg_stat_activity a on a.pid = l.pid
         where a.application_name = 'trls_h_cutover' and l.relation = 'public.hrls'::regclass")" "0"

# The owner's row-level security, in its own session, bounded so a source lock the cutover should not hold
# fails here rather than hangs.
ddl=$(q -d "$DB" -qtA -c "set lock_timeout = '20s'" -c "set role trls_h_owner" \
  -c "alter table public.hrls enable row level security" \
  -c "alter table public.hrls force row level security" \
  -c "create policy hrls_a on public.hrls using (tenant = 'a')" 2>&1)
check "LIVENESS: FORCE and the policy committed, and now filter the owner's reads of the source" \
  "$(echo "$ddl" | grep -c 'ERROR')/$(v "set role trls_h_owner; select row_security_active('public.hrls')")/$(v "set role trls_h_owner; select count(*) from public.hrls")" \
  "0/t/10"
check "LIVENESS: while the cutover was still queued on the copy" \
  "$(v "select count(*) from pg_locks l join pg_stat_activity a on a.pid = l.pid
         where a.application_name = 'trls_h_cutover' and l.relation = 'public.hrls_pgpm_dest'::regclass
           and not l.granted")" "1"

end_session trls_h_holder
wait "$HOLDER" 2>/dev/null
for _ in $(seq 1 300); do kill -0 "$CUT" 2>/dev/null || break; sleep 0.2; done
if kill -0 "$CUT" 2>/dev/null; then
  printf 'FAIL  %-78s %s\n' "the cutover finished once the holder was gone" "still running"; fail=1
  end_session trls_h_cutover
fi
wait "$CUT" 2>/dev/null

# THE CONTRACT: refused under the lock, with the source whole.
check "the cutover refused under its lock: row-level security came on after its first check" \
  "$(grep -c "pg_partition_magician: cannot swap in the copy of hypertable hrls as trls_h_owner -- row-level security is active on it for that role.*row-level security came on after the cutover's first check" "$LOG")" "1"
check "the source is still the hypertable, holding row 11 by identity" \
  "$(v "select (select count(*) from timescaledb_information.hypertables where hypertable_schema = 'public'
                 and hypertable_name = 'hrls') || '/' || (select relkind::text from pg_class where oid = 'public.hrls'::regclass)
            || '/' || (select string_agg(id || ':' || tenant, ',' order by id) from public.hrls)")" \
  "1/r/1:a,2:a,3:a,4:a,5:a,6:a,7:a,8:a,9:a,10:a,11:b"
if [ "$fail" != 0 ]; then sed 's/^/    cutover: /' "$LOG" | head -8; fi

rm -f "$LOG"
q -d postgres -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
