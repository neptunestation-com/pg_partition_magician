#!/usr/bin/env bash
# A direct archive_fn call that races a tick archiving the same chunk is refused, not written over it
# (issue #1069, review V-01).
#
# THE DEFECT. pgpm._archive_step calls the strategy and inserts the chunk's pgpm.archive_ledger row afterwards,
# in the same transaction. archive._refuse_recorded_chunk_overwrite looked the key up in the ledger without
# ordering itself against that transaction, so a direct pgpm.archive_to_s3_ndjson call for a SHORTER range at
# the chunk's key, made while the tick had PUT the chunk but not yet committed, found no ledger row, was
# admitted, and PUT its rows over the chunk once the tick had committed: the ledger recorded [0, 180) of 179 rows
# at a key holding [0, 50), and retire() dropped the rest. The fix locks the key's claim row before the lookup,
# so the direct call waits for the tick's commit and then reads the chunk it recorded.
#
# WHY A SHELL HARNESS. The contract needs two sessions, a tick held open inside its archive step and a direct call
# issued into that window, which one pgTAP file cannot give. The window is held STRUCTURALLY, not by timing: a
# BEFORE UPDATE trigger on archive.object_key_claim sleeps when the tick's backend writes the key's claim row, so
# the tick sits inside the refusal, its ledger lookup made, the claim row locked, its PUT and its ledger row not yet
# made, for as long as the sleep lasts. (A BEFORE ROW trigger fires with the row already locked, so that lock is
# the tick's whatever the code under test does first.) pg_sleep is not a lock wait, so maintain()'s 200 ms
# lock_timeout does not cut it short. A direct call issued into the window looks the key up before the tick has
# recorded anything: without the lock taken before the lookup it is admitted and PUTs after the tick commits; with
# it, it waits for the tick and then reads the chunk. Every observation is its own docker exec, so its own
# transaction, and holds nothing the two sessions need.
#
# WITNESSES (a failure of only these says the race was never set up, not that the code is right or wrong):
#   LIVENESS: the tick is inside its archive step, before its PUT and uncommitted (its backend sleeps, the object
#             at the key still holds what the earlier direct call wrote, and no ledger row is visible yet)
#   LIVENESS: the direct call reached the key while the tick was still uncommitted (it waits on a lock, and the
#             tick is still asleep in the same observation)
#   LIVENESS: the tick recorded [0, 180) of 179 rows at the key
#   GUARD:    the tick was not deferred: no pgpm.log row with action exactly skip_archive
# THE CONTRACT:
#   the direct call for [0, 50) was refused, naming the chunk [0, 180) the tick recorded
#   the object at the key holds exactly ids 1..179 (identity, not a count)
#
# The mutation it is required to fail against (bench/mutations/mutate.py):
#   archive_recorded_chunk_claim_unlocked -- the claim row is not locked before the ledger lookup
#
# Usage: archive_recorded_chunk_tick_race.sh <container> <db> [archive install.sql]
# Needs the archive image and MinIO on the same network, created here idempotently as in
# bench/archive_recorded_chunk.sh.
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; ARCHIVE_INSTALL="${3:-/repo/pgpm_archive/install.sql}"
NET="${PGPM_TEST_NET:-pgpm_test_net}"
HOLD_S="${PGPM_RACE_HOLD_S:-6}"   # how long the tick sleeps inside its refusal
fail=0
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT

q() { docker exec "$C" psql -U postgres "$@"; }
v() { docker exec "$C" psql -U postgres -d "$DB" -qtAX -c "$1" 2>&1; }
check() { # <label> <actual> <expected>
  if [ "$2" = "$3" ]; then printf 'PASS  %-58s %s\n' "$1" "$2"
  else printf 'FAIL  %-58s %s (want %s)\n' "$1" "$2" "$3"; fail=1; fi
}

# --- MinIO: ready, and the bucket exists ---------------------------------------------------------
ready=""
for _ in $(seq 1 60); do
  if docker run --rm --network "$NET" curlimages/curl -sf http://minio:9000/minio/health/cluster >/dev/null 2>&1; then ready=1; break; fi
  sleep 1
done
if [ -z "$ready" ]; then
  printf 'FAIL  %-58s %s\n' "fixture: MinIO reported ready (/minio/health/cluster)" "not within 60 s"; exit 1
fi
code=$(docker run --rm --network "$NET" curlimages/curl -s -o /dev/null -w '%{http_code}' \
         --aws-sigv4 aws:amz:us-east-1:s3 -u minioadmin:minioadmin \
         -X PUT http://minio:9000/archive-test-bucket) || code="curl exit $?"
if [ "$code" != 200 ] && [ "$code" != 409 ]; then
  printf 'FAIL  %-58s %s\n' "fixture: the MinIO bucket exists" "PUT returned $code"; exit 1
fi

# --- the database: fixtures, core, and the archive module under test ------------------------------
q -q -c "drop database if exists $DB" >/dev/null 2>&1
if ! q -v ON_ERROR_STOP=1 -q -c "create database $DB" >/dev/null 2>&1 \
   || ! q -d "$DB" -v ON_ERROR_STOP=1 -q -c "create extension if not exists http; create extension if not exists pgcrypto;" >/dev/null 2>&1 \
   || ! q -d "$DB" -v ON_ERROR_STOP=1 -q -f /repo/tests/archive/fixtures.sql >/dev/null 2>&1 \
   || ! q -d "$DB" -v ON_ERROR_STOP=1 -q --single-transaction -f /repo/pgpm_core/install.sql >/dev/null 2>&1; then
  printf 'FAIL  %-58s %s\n' "fixture: the database, its extensions, the fixtures and pgpm_core were set up" "no"; exit 1
fi
if ! q -d "$DB" -v ON_ERROR_STOP=1 -q -f "$ARCHIVE_INSTALL" >/dev/null 2>&1; then
  printf 'FAIL  %-58s %s\n' "fixture: the archive module under test installed" "$ARCHIVE_INSTALL"; exit 1
fi

# One id grid of step 60, retention 60: the transmute monolith [0, 180) holds ids 1..179 once the frontier
# moves past it, and is the oldest partition, so the first tick archives it as one chunk.
prefix="$DB/race/$(date +%s%N)/"
if ! docker exec -i "$C" psql -U postgres -d "$DB" -v ON_ERROR_STOP=1 -qX >/dev/null 2>"$work/setup.err" <<SQL
set client_min_messages = warning;
create table public.race (id bigint primary key, payload text not null);
insert into public.race select g, 'r' || g from generate_series(1, 150) g;
call pgpm.transmute('public.race', 'id', 60::bigint, p_retain => 60::bigint, p_paused => false);
select archive.configure('public.race', 'archive-test-bucket', p_endpoint => 'http://minio:9000', p_prefix => '$prefix');
insert into public.race select g, 'r' || g from generate_series(151, 400) g;
select pgpm.set_archive_fn('public.race', 'pgpm.archive_to_s3_ndjson(regclass,name,text,text)'::regprocedure);
-- the lever: the tick's write of a claim row sleeps, inside the tick's transaction, with the row locked
create function public.race_hold() returns trigger language plpgsql as \$f\$
begin
  if current_setting('application_name') = 'race_tick' then perform pg_sleep($HOLD_S); end if;
  return new;
end \$f\$;
create trigger race_hold before update on archive.object_key_claim for each row execute function public.race_hold();
-- an object's NDJSON rows as their ids, in order (null when there is no object)
create function public.race_ids(p_key text) returns text language plpgsql as \$f\$
declare v record;
begin
  v := archive.s3_signed_request('GET', 'http://minio:9000', 'archive-test-bucket', 'us-east-1', p_key, '',
                                 'text/plain', '', 'minioadmin', 'minioadmin');
  if v.status <> 200 then return null; end if;
  return (select string_agg(l::jsonb ->> 'id', ',' order by (l::jsonb ->> 'id')::bigint)
            from regexp_split_to_table(v.content, e'\n') l where l <> '');
end \$f\$;
SQL
then
  printf 'FAIL  %-58s %s\n' "fixture: the race fixture was built" "no"; sed 's/^/      /' "$work/setup.err" | head -5; exit 1
fi
child=$(v "select child_name from pgpm.part where parent_table = 'public.race'::regclass and lo = '0'")
# A direct call at the chunk's key before the ledger records anything there (documented: admitted), so the key's
# claim row exists before the tick and the racing call below reaches the ledger lookup without waiting to insert it.
key=$(v "select (pgpm.archive_to_s3_ndjson('public.race', '$child', '0', '50')).s3_key")
want_all=$(v "select string_agg(g::text, ',' order by g) from generate_series(1, 179) g")
want_49=$(v "select string_agg(g::text, ',' order by g) from generate_series(1, 49) g")
check "fixture: an earlier direct call wrote [0, 50) at the chunk's key" "$(v "select public.race_ids('$key') = '$want_49'")" "t"

# --- session A: the tick -----------------------------------------------------------------------------
docker exec "$C" psql -U postgres -d "$DB" -qtAX -c "set application_name = 'race_tick'" \
  -c "call pgpm.maintain('public.race')" >"$work/tick.out" 2>&1 &
tick_pid=$!

in_step=""
for _ in $(seq 1 300); do
  if [ "$(v "select count(*) from pg_stat_activity where application_name = 'race_tick' and wait_event = 'PgSleep'")" = 1 ]; then
    in_step=1; break
  fi
  sleep 0.05
done
held=$(v "select (select count(*) from pg_stat_activity where application_name = 'race_tick' and wait_event = 'PgSleep') = 1
              and not exists (select 1 from pgpm.archive_ledger where s3_key = '$key')
              and public.race_ids('$key') = '$want_49'")
check "LIVENESS: the tick is in its refusal, before its PUT, uncommitted" "${in_step:-never}/$held" "1/t"

# --- session B: the direct call, into the tick's window ---------------------------------------------
docker exec "$C" psql -U postgres -d "$DB" -qtAX -c "set application_name = 'race_direct'" \
  -c "select 'rows=' || (pgpm.archive_to_s3_ndjson('public.race', '$child', '0', '50')).rows_archived" >"$work/direct.out" 2>&1 &
direct_pid=$!
raced=""
for _ in $(seq 1 100); do
  r=$(v "select (select count(*) from pg_stat_activity where application_name = 'race_direct' and wait_event_type = 'Lock')
             || '/' || (select count(*) from pg_stat_activity where application_name = 'race_tick' and wait_event = 'PgSleep')")
  if [ "$r" = "1/1" ]; then raced=1; break; fi
  sleep 0.05
done
check "LIVENESS: the direct call waits on a lock while the tick is open" "${raced:-no}" "1"

wait "$tick_pid"; wait "$direct_pid"
check "LIVENESS: the tick recorded [0, 180) of 179 rows at the key" \
  "$(v "select string_agg(lo || '-' || hi || ':' || rows_archived, ';') from pgpm.archive_ledger where parent_table = 'public.race'::regclass and s3_key = '$key'")" "0-180:179"
check "GUARD: the tick was not deferred (no skip_archive row)" \
  "$(v "select count(*) from pgpm.log where parent_table = 'public.race'::regclass and action = 'skip_archive'")" "0"

refused=no
# the parent renders as the session's search_path reaches it (race, from this one), so the message is matched
# on either side of it
if grep -qF "archive_to_s3_ndjson refuses to write [0, 50) of " "$work/direct.out" \
   && grep -qF " to the object key $key: pgpm.archive_ledger records the chunk [0, 180) of 179 row(s) there" "$work/direct.out"; then
  refused=yes
fi
check "the direct call for [0, 50) was refused, naming the chunk [0, 180)" "$refused" "yes"
[ "$refused" = yes ] || sed 's/^/      direct call: /' "$work/direct.out" | head -3
check "the object at the key holds exactly ids 1..179" "$(v "select public.race_ids('$key') = '$want_all'")" "t"

q -q -c "drop database if exists $DB" >/dev/null 2>&1
exit "$fail"
