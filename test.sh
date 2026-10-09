#!/usr/bin/env bash
# Channel test matrix for pg_partition_magician.
#
# For each PostgreSQL version, install the module through each distribution
# channel, load the demo migrations as fixtures, run the pgTAP suite, and verify
# a clean uninstall.
#
#   ./test.sh [15|16|17|18|all] [--channel=psql|bundle|dbdev|all]
#       PGPM_JOBS=N runs the pgTAP files N at a time, each in its own clone (default 4; 1 is serial)
#   ./test.sh timescale                  # the from_hypertable track (TimescaleDB 2.16.1 / PG15)
#   ./test.sh observe                    # the pg_flight_recorder observability track (PG15)
#   ./test.sh archive                    # the pgpm_archive track (PG17 + pgsql-http + MinIO)
#   ./test.sh perf                       # the data-coupled lock and work guards (PG17); --shard=I/N runs one interleaved slice
#   ./test.sh discriminate               # prove each of those guards fails when its defect is present
#   ./test.sh locktrace                  # eBPF lock-boundary observation (PG17, Linux only)
#   ./test.sh lockview                   # the lock-sequence renderer's eBPF capture (PG17, Linux only)
#   ./test.sh ci                         # EVERY track CI runs, in one go
#
# `all` means all four PostgreSQL VERSIONS, not all tracks. The timescale, observe, archive, perf,
# discriminate, locktrace and lockview tracks each need their own image or service, so `./test.sh all` deliberately skips them
# and a green run of it does NOT mean CI will be green. That gap is real: a change to
# pgpm_core/install.sql broke the archive track's fixture while `./test.sh all` stayed green from end
# to end, and only the PR's archive job caught it. Use `./test.sh ci` before pushing anything that
# touches pgpm_core, which every one of these tracks installs.
#
# Channels:
#   psql    pgpm_core/install.sql via psql -f         (the source)
#   bundle  scripts/build_install_bundle.sh output            (dashboard SQL editor)
#   dbdev   scripts/build_dbdev_package.sh output (minified)  (dbdev / TLE / CREATE EXTENSION)
#
# The `timescale` track is a separate invocation (it needs TimescaleDB on its own image and is PG15-only, so
# `./test.sh` with no args does not run it), but CI's default Test Suite calls it on every push/PR via the
# reusable .github/workflows/timescale.yml. It exercises pgpm.from_hypertable against real hypertables
# (tests/timescale/).
#
# The `observe` track is also separate: pgpm_core ships pg_flight_recorder (PGFR) correlation functions
# (observe_window/impact_report) that are always present but only do anything
# useful with PGFR installed (the PGFR-absent gate is a plain test in the main suite,
# tests/65_observe_no_pgfr_test.sql). This track installs the vendored PGFR and asserts the
# impact_report correlation against its telemetry (tests/observe/). PGFR is
# vendored under bench/vendor/ and needs only pg_cron, so the track runs on the stock pgpm_test:15 image.
#
# The `archive` track is also separate: it installs the OPTIONAL pgpm_archive module on top of the
# core and exercises it against a real MinIO container standing in for S3 (tests/archive/). Its own
# image (pgpm_test:17-archive) adds pgsql-http on top of the stock pg17 image. Like the default matrix,
# it runs every tests/archive/db/*.sql via pg_prove in ONE DATABASE PER FILE, each one cloned from a
# template (pgpm_arch_tmpl) that carries the fixtures and both modules. These files used to isolate
# themselves with BEGIN/ROLLBACK against one shared database, which stopped being possible once the
# fixture's pgpm.transmute became a committing PROCEDURE (#275): transaction control is illegal inside
# an explicit transaction block. Cloning gives back the isolation the rollback provided, and gives it
# for real, since a rollback never undid anything these tests pushed to MinIO. After the pgTAP
# suite, it also runs scripts/verify_parquet.py/verify_parquet_range.py (a venv-installed Python
# step, not psql) against the same running instance: independent-reader (pyarrow + DuckDB)
# verification of archive._pq_to_parquet/_range, ported into this repo proper from a standalone
# prototype (prototypes/parquet-writer/, removed) once that prototype's code was fully absorbed
# into pgpm_archive/install.sql.
# It is a standalone, path-filtered CI workflow (like `observe`'s), not wired into the default Test
# Suite or the release gate.
set -euo pipefail

cd "$(dirname "$0")"

VERSION="all"
CHANNEL="all"
TRACK="matrix"
# --shard=I/N runs the I-th of N interleaved slices of the perf or discriminate track (1-based), so CI
# can spread one 27-minute sequential job over N runners. Each guard already runs in its own database,
# and the shard's guards are printed before anything runs, so a slice that would run nothing fails
# instead of passing vacuously. --list prints the slice and exits without touching Docker.
SHARD_I=1
SHARD_N=1
LIST_ONLY=""
for arg in "$@"; do
  case "$arg" in
    --channel=*) CHANNEL="${arg#--channel=}" ;;
    --shard=*)
      SHARD_I="${arg#--shard=}"; SHARD_N="${SHARD_I#*/}"; SHARD_I="${SHARD_I%/*}"
      if ! [[ "$SHARD_I" =~ ^[0-9]+$ && "$SHARD_N" =~ ^[0-9]+$ ]] || [ "$SHARD_I" -lt 1 ] || [ "$SHARD_I" -gt "$SHARD_N" ]; then
        echo "usage: --shard=I/N with 1 <= I <= N (got ${arg#--shard=})"; exit 2
      fi ;;
    --list) LIST_ONLY=1 ;;
    15|16|17|18|all) VERSION="$arg" ;;
    timescale) TRACK="timescale" ;;
    observe) TRACK="observe" ;;
    archive) TRACK="archive" ;;
    perf) TRACK="perf" ;;
    discriminate) TRACK="discriminate" ;;
    locktrace) TRACK="locktrace" ;;
    lockview) TRACK="lockview" ;;
    ci) TRACK="ci" ;;
    *) echo "usage: ./test.sh [15|16|17|18|all] [--channel=psql|bundle|dbdev|all] | timescale | observe | archive | perf [--shard=I/N] [--list] | discriminate [--shard=I/N] [--list] | locktrace | lockview | ci"; exit 1 ;;
  esac
done

if command -v docker-compose &>/dev/null; then DC="docker-compose"; else DC="docker compose"; fi
[ "$CHANNEL" = "all" ] && CHANNELS=(psql bundle dbdev) || CHANNELS=("$CHANNEL")
[ -n "${CI:-}" ] && BUILD_PROGRESS="--progress=plain" || BUILD_PROGRESS=""

VER=$(awk -F"'" '/default_version/ {print $2}' pgpm_core/extension.control)
DBDEV_PKG="dist/pg_partition_magician--${VER}.sql"
BUNDLE="dist/pg_partition_magician-bundle.sql"

# Build the channel artifacts on the host (version-independent).
echo ">>> Building install artifacts..."
scripts/build_install_bundle.sh pgpm_core/install.sql "$BUNDLE"
# warn, do not fail, over database.dev's 250,000-char column: the dbdev channel below installs the
# file through psql, where its size does not matter, and the strict check has its own CI job
PGPM_DBDEV_CAP=warn scripts/build_dbdev_package.sh pgpm_core/install.sql "$DBDEV_PKG"
if grep -nE '^\\' "$BUNDLE" "$DBDEV_PKG"; then
  echo "ERROR: a packaged artifact still contains psql metacommands"; exit 1
fi

# Wait for the REAL server, over TCP (#317).
#
# The postgres entrypoint starts a TEMPORARY init server to run its init scripts, then shuts it down and
# starts the real one. That temporary server listens on the UNIX SOCKET ONLY. So a socket probe can
# succeed against it and hand back a connection that dies moments later -- the next command fails with
# `No such file or directory` on the socket, or `the database system is shutting down`, one or two
# seconds after compose reported the container Started. A TCP probe cannot see the init server at all, so
# it succeeds only once the real one is accepting connections.
#
# The timescale track hit this first and fixed it there (supabase/postgres's heavier init widens the
# window). The matrix and the observe/archive tracks raced it too, just rarely enough to look like bad
# luck: it surfaced as one PG17 job of four failing while the other three passed the same commit.
#
# `up -d --wait` is NOT the fix, which is why it is not used here: the compose healthcheck is
# `pg_isready -U postgres`, which also goes over the socket and so is satisfied by the very init server
# this is trying to see past.
#
# Fails LOUDLY on exhaustion. The loops this replaces fell through to the first real command, which then
# reported the same confusing connection error -- so a genuinely dead container looked identical to a
# slow one, and the log pointed at the wrong statement.
wait_pg() {  # <profile> <service> [seconds]
  local prof="$1" svc="$2" n="${3:-90}"
  for _ in $(seq 1 "$n"); do
    $DC --profile "$prof" exec -T -e PGPASSWORD=postgres "$svc" \
       psql -h 127.0.0.1 -U postgres -tAc 'select 1' >/dev/null 2>&1 && return 0
    sleep 1
  done
  echo "ERROR: $svc did not accept TCP connections within ${n}s (container up but never ready)" >&2
  return 1
}

# Build a compose service's image only when the local one was not built from these inputs. The key is
# scripts/image_build_key.sh's (the Dockerfile and compose file hashed, plus the ISO week, so the floating
# postgres:<major> base is refreshed weekly), and the Dockerfile stamps it into the image as a label. CI
# restores each matrix image from the Actions cache under the same key (test.yml), so a hit here is also
# "do not touch Docker Hub"; a developer's image built by hand carries `dev` and is rebuilt once. Say which
# way it went: a cache that silently never hits reads exactly like one that works. PGPM_FORCE_BUILD=1
# rebuilds regardless.
build_image() {  # <profile> <service>
  local prof="$1" svc="$2" img key have
  img=$($DC --profile "$prof" config --images "$svc")
  key=$(bash "$(dirname "$0")/scripts/image_build_key.sh")
  have=$(docker image inspect --format '{{ index .Config.Labels "org.pg_partition_magician.build_key" }}' "$img" 2>/dev/null || true)
  if [ "${PGPM_FORCE_BUILD:-}" != 1 ] && [ -n "$have" ] && [ "$have" = "$key" ]; then
    echo "  $img carries build key $key; not rebuilding"
    return 0
  fi
  echo "  building $img (build key $key; local image: ${have:-absent})"
  PGPM_BUILD_KEY="$key" $DC --profile "$prof" build $BUILD_PROGRESS "$svc"
}

psql_run() { $DC --profile "$1" exec -T "$2" psql -U postgres -d postgres -v ON_ERROR_STOP=1 "${@:3}"; }
# same, but against an arbitrary database: the pgTAP suite now runs one database PER FILE
psql_db()  { $DC --profile "$1" exec -T "$2" psql -U postgres -d "$3" -v ON_ERROR_STOP=1 "${@:4}"; }

install_channel() {  # <channel> <profile> <service> [db]
  local db="${4:-postgres}"
  case "$1" in
    psql)   psql_db "$2" "$3" "$db" --single-transaction -f /repo/pgpm_core/install.sql >/dev/null ;;
    bundle) psql_db "$2" "$3" "$db" -f "/repo/$BUNDLE" >/dev/null ;;
    dbdev)  psql_db "$2" "$3" "$db" --single-transaction -f "/repo/$DBDEV_PKG" >/dev/null ;;
    *) echo "unknown channel $1"; exit 1 ;;
  esac
}

load_fixtures() {  # <profile> <service> [db] -- build the demo tables for the pgTAP suite
  local p="$1" s="$2" db="${3:-postgres}"
  psql_db "$p" "$s" "$db" -c "ALTER DATABASE \"$db\" SET poc.seed_count = 8000; ALTER DATABASE \"$db\" SET poc.events_count = 4000;" >/dev/null
  psql_db "$p" "$s" "$db" -f /repo/fixtures/demo.sql >/dev/null
}

uninstall_and_verify() {  # <profile> <service>
  local p="$1" s="$2" result mon
  # Stage regrain's change capture so the uninstall has something OUTSIDE pgpm to remove (#442). The delta
  # table, its trigger function and the row trigger all live in the PARENT's schema, so `drop schema pgpm
  # cascade` cannot reach them; before the fix all three survived uninstall, with the trigger still firing
  # into a delta table nothing would ever drain. Transmute an id table, freeze its monolith with one row
  # past hi, and run ONE regrain_step: the 'prepared' tick is the one that installs the trigger. Paused, so
  # no maintenance tick can touch the fixture between here and the uninstall (regrain_step does not
  # consult paused).
  psql_run "$p" "$s" -q <<'SQL' >/dev/null
create table public.uninst_ev (id bigint primary key, body text);
insert into public.uninst_ev select g, 'b'||g from generate_series(1, 5000) g;
call pgpm.transmute('public.uninst_ev', 'id', 1000, p_obtain => 2, p_retain => '2500', p_paused => true);
insert into public.uninst_ev values (7500, 'sentinel');
SQL
  mon=$($DC --profile "$p" exec -T "$s" psql -U postgres -d postgres -tA -c "
    select child_name from pgpm.part where parent_table = 'public.uninst_ev'::regclass and attached
     order by lo::numeric limit 1")
  result=$($DC --profile "$p" exec -T "$s" psql -U postgres -d postgres -tA -c "
    select pgpm.regrain_step('public.uninst_ev', '$mon', '1000', 100)")
  if [ "$result" != "prepared" ]; then
    echo "ERROR: regrain_step on the frozen monolith $mon returned '$result', expected 'prepared'"; return 1
  fi
  # The liveness witness: the trigger is on the monolith and the function and delta table exist. Without
  # this, "nothing left behind" is also true of a run that never installed anything.
  result=$($DC --profile "$p" exec -T "$s" psql -U postgres -d postgres -tA -c "
    select (select count(*) from pg_trigger where tgname = 'pgpm_regrain_capture' and tgrelid = 'public.$mon'::regclass),
           (select count(*) from pg_proc where pronamespace = 'public'::regnamespace and proname = 'uninst_ev_pgpm_regrain_capture'),
           (select count(*) from pg_class where oid = to_regclass('public.uninst_ev_pgpm_regrain_delta'))")
  if [ "$result" != "1|1|1" ]; then
    echo "ERROR: regrain capture was not installed before uninstall (trigger|function|delta='$result', expected 1|1|1)"; return 1
  fi

  psql_run "$p" "$s" --single-transaction -f /repo/pgpm_core/uninstall.sql >/dev/null

  result=$($DC --profile "$p" exec -T "$s" psql -U postgres -d postgres -tA -c "
    select (select count(*) from pg_namespace where nspname='pgpm'),
           (select count(*) from cron.job where jobname like 'pgpm%')")
  if [ "$result" != "0|0" ]; then
    echo "ERROR: uninstall left state behind (schemas|cron='$result', expected 0|0)"; return 1
  fi
  # #442: nothing of regrain's capture may survive in the parent's schema: no relation (the delta table,
  # its identity sequence, its index), no function, and no trigger on any table.
  result=$($DC --profile "$p" exec -T "$s" psql -U postgres -d postgres -tA -c "
    select (select count(*) from pg_class where relnamespace = 'public'::regnamespace and relname like '%pgpm_regrain%'),
           (select count(*) from pg_proc where pronamespace = 'public'::regnamespace and proname like '%pgpm_regrain%'),
           (select count(*) from pg_trigger where tgname like '%pgpm_regrain%')")
  if [ "$result" != "0|0|0" ]; then
    echo "ERROR: uninstall left regrain capture behind (relations|functions|triggers='$result', expected 0|0|0)"; return 1
  fi
  # A write to the former source child must go through (a surviving trigger whose function was dropped
  # would raise here, and ON_ERROR_STOP fails the run) and must have no delta table left to land in. What
  # the guide promises stays, stays: the partitioned table under its own name with the rows it had, the
  # sentinel and this write among them.
  psql_run "$p" "$s" -q -c "insert into public.$mon values (5500, 'after uninstall')" >/dev/null
  result=$($DC --profile "$p" exec -T "$s" psql -U postgres -d postgres -tA -c "
    select (select to_regclass('public.uninst_ev_pgpm_regrain_delta') is null),
           (select string_agg(id::text, ',' order by id) from public.uninst_ev where id > 5000),
           (select count(*) from public.uninst_ev)")
  if [ "$result" != "t|5500,7500|5002" ]; then
    echo "ERROR: after uninstall (no delta|rows past 5000|row count='$result', expected t|5500,7500|5002)"; return 1
  fi
  psql_run "$p" "$s" -q -c "drop table public.uninst_ev cascade" >/dev/null
}

# One test file in its own clone of the template: clone, prove, drop. pg_prove's output goes to <log>,
# because the files run several at a time (run_version) and the record is printed in file order
# afterwards. The exit status is pg_prove's; a clone that could not be made is a failure with a line
# in the log, never a file that silently did not run.
prove_one() {  # <profile> <service> <db> <file basename> <log>
  local p="$1" s="$2" db="$3" b="$4" log="$5" rc=0
  if ! { psql_run "$p" "$s" -c "drop database if exists $db" && psql_run "$p" "$s" -c "create database $db template pgpm_tmpl"; } >/dev/null 2>>"$log"; then
    echo "not ok - could not clone $db from pgpm_tmpl for $b (see above)" >>"$log"
    return 1
  fi
  $DC --profile "$p" exec -T "$s" sh -c "pg_prove --timer -U postgres -d $db /repo/tests/$b" >>"$log" 2>&1 || rc=1
  psql_run "$p" "$s" -c "drop database if exists $db" >/dev/null 2>&1 || true
  return $rc
}

reset_demo() {  # <profile> <service> -- drop fixture tables so the next channel is clean
  psql_run "$1" "$2" -c "
    drop table if exists public.messages, public.events_id, public.events_uuid cascade;
    drop table if exists public.events_id_seeded, public.events_uuid_seeded;
    drop function if exists public.generate_messages(int, int);" >/dev/null
}

run_version() {  # <pg_version>
  local v="$1" s="postgres$1" p="pg$1"
  echo; echo "========================================="
  echo "PostgreSQL $v -- channels: ${CHANNELS[*]}"
  echo "========================================="
  $DC --profile "$p" down -v 2>/dev/null || true
  build_image "$p" "$s"
  $DC --profile "$p" up -d

  wait_pg "$p" "$s" 60
  psql_run "$p" "$s" -c "create extension if not exists pg_cron; create extension if not exists pgtap;" >/dev/null

  for ch in "${CHANNELS[@]}"; do
    echo "--- channel: $ch ---"
    # The pgTAP suite runs ONE DATABASE PER FILE. It used to run every file against `postgres`, isolated
    # by wrapping each in BEGIN/ROLLBACK -- but a committing PROCEDURE cannot be called inside a
    # transaction block ("invalid transaction termination"), and transmute/maintain/drain_all are
    # procedures now. Isolation therefore has to come from the database, not from a transaction.
    #
    # Installing the channel and loading the fixtures per file would cost ~0.5 s each; building one
    # template and cloning it costs ~0.1 s (measured), so the suite stays fast enough to keep running on
    # every push.
    psql_run "$p" "$s" -c "drop database if exists pgpm_tmpl" >/dev/null
    psql_run "$p" "$s" -c "create database pgpm_tmpl" >/dev/null
    psql_db "$p" "$s" pgpm_tmpl -c "create extension if not exists pgtap;" >/dev/null
    install_channel "$ch" "$p" "$s" pgpm_tmpl
    load_fixtures "$p" "$s" pgpm_tmpl

    # The files run PGPM_JOBS at a time (4 by default: a GitHub runner has four cores, and a channel's
    # 272 files are a second each of mostly idle waiting on docker exec, psql and pg_prove start-up), each
    # in its own clone, its pg_prove output kept in a log and printed in file order once the channel is
    # done, so the record reads the same whatever the workers' order; one line per file as it finishes
    # keeps the run legible while it runs. Measured 2026-10-07: a channel took 449 s one file at a time
    # on a runner and 253 s on a laptop. The two pg_cron files run after the others, alone, on
    # `postgres`, as they always have (see below). PGPM_JOBS=1 is the old serial run.
    local n=0 failed=0 pg_ready="" jobs="${PGPM_JOBS:-4}" logdir
    logdir=$(mktemp -d)
    local -a parallel=() serial=()
    for f in tests/*.sql; do
      local b; b="$(basename "$f")"; n=$((n + 1))
      if [ "$b" = "31_schedule_test.sql" ] || [ "$b" = "78_retain_detach_dispatch_test.sql" ]; then
        # pg_cron can only be created in the database named by cron.database_name (postgres on these
        # images: "can only create extension in database postgres"), so these files cannot run in a
        # per-file clone. They get `postgres`, which the uninstall check below installs into anyway.
        # 31 covers schedule()/unschedule(); 78 covers retire() dispatching a concurrent detach to the
        # standing pgpm_detach job (#268). Both leave the cron state clean for the next file.
        serial+=("$b")
        continue
      fi
      parallel+=("$n:$b")
      # bash 3.2 (macOS) has no `wait -n`: poll the running job count instead
      while [ "$(jobs -rp | wc -l)" -ge "$jobs" ]; do sleep 0.2; done
      (
        if prove_one "$p" "$s" "pgpm_t$n" "$b" "$logdir/$n.log"; then echo 0 > "$logdir/$n.rc"; else echo 1 > "$logdir/$n.rc"; fi
        # [[:space:]], not \s: BSD sed reads \s as a literal s and strips the letter from "Tests"
        printf '    %-58s %s  %s\n' "$b" "$(grep -m1 -oE '^Files=1, Tests=[0-9]+,[[:space:]]+[0-9]+ wallclock secs' "$logdir/$n.log" | sed -E 's/Files=1, //; s/[[:space:]]+/ /g')" "$(grep -m1 -E '^Result: ' "$logdir/$n.log" || echo 'Result: ERROR (no verdict)')"
      ) &
    done
    wait
    local e nn
    for e in "${parallel[@]}"; do
      nn="${e%%:*}"
      echo; echo "### ${e#*:}"
      cat "$logdir/$nn.log"
      [ "$(cat "$logdir/$nn.rc" 2>/dev/null)" = 0 ] || failed=$((failed + 1))
    done
    rm -rf "$logdir"
    for b in "${serial[@]}"; do
      # Set `postgres` up ONCE per channel, however many files land here. fixtures/demo.sql CREATEs
      # its tables, so a second load fails on "relation messages already exists" -- and with
      # ON_ERROR_STOP under `set -e` that takes the whole version down, which is exactly what adding
      # a second file to this branch did.
      if [ "$pg_ready" != "$ch" ]; then
        install_channel "$ch" "$p" "$s"
        load_fixtures "$p" "$s"
        pg_ready="$ch"
      fi
      echo; echo "### $b (on postgres)"
      if ! $DC --profile "$p" exec -T "$s" sh -c "pg_prove --timer -U postgres -d postgres /repo/tests/$b"; then
        failed=$((failed + 1))
      fi
    done
    psql_run "$p" "$s" -c "drop database if exists pgpm_tmpl" >/dev/null
    [ "$failed" -eq 0 ] || { echo "PG $v / $ch: FAIL ($failed file(s))"; return 1; }

    # the uninstall check still needs a database with the channel installed
    install_channel "$ch" "$p" "$s"
    uninstall_and_verify "$p" "$s"
    reset_demo "$p" "$s"
    echo "PG $v / $ch: PASS"
  done
  $DC --profile "$p" down -v
  echo "PostgreSQL $v: PASS"
}

# Pull the third-party image a compose service runs (supabase/postgres for timescale, MinIO for the
# archive profile), unless it is already here. The reference is read from compose itself, so it is
# exactly the one `up` would pull: TS_PG_TAG interpolated into the supabase/postgres tag, and MinIO's
# digest pin (or PGPM_MINIO_IMAGE, the CI cache's local alias for it) as docker-compose.yml states it.
#
# An image that is already present is never pulled. CI restores both images from the Actions cache
# (timescale.yml, archive.yml, perf.yml) because a registry's anonymous DATA quota is not a rate limit:
# once a burst of PRs has spent it ("toomanyrequests: Data limit exceeded", 2026-09-26, #558) it does
# not come back within any backoff this loop could afford, so the only pull that cannot fail is the
# one that is not made. The backoff below is for the other failure, the anonymous RATE limit
# ("toomanyrequests: Rate exceeded"), which runners sharing source IPs trip often and which clears in
# seconds. A pull that still fails falls through rather than aborting under `set -e` (left operand of
# `&&`): `up` then tries once more and fails loudly if the image really is unavailable.
pull_third_party() {  # <profile> <service>
  local ref attempt
  ref=$($DC --profile "$1" config --images "$2")
  if docker image inspect "$ref" >/dev/null 2>&1; then
    echo "  $ref is already present; not pulling it"
    return 0
  fi
  for attempt in 1 2 3 4 5; do
    $DC --profile "$1" pull "$2" && return 0
    echo "  pull attempt $attempt for $ref failed (usually a rate limit); backing off $((attempt * 15))s..."
    sleep $((attempt * 15))
  done
}

# The from_hypertable track. PG15 + Apache TimescaleDB, run on the Supabase fleet image
# (public.ecr.aws/supabase/postgres -- the Apache edition the migration actually targets; it ships
# timescaledb, pgTAP, and the timescaledb shared_preload preloaded, so there is no image build). Each
# tests/timescale/db/*.sql runs against a fresh throwaway database (disposable-db) because from_hypertable
# commits (per chunk and at cutover) and so cannot be wrapped in a rolled-back transaction. We drive psql
# over TCP (with PGPASSWORD, since the managed image does not trust the local socket) and scan the TAP
# output for failures (the runner does not need pg_prove). To exercise a second fleet TimescaleDB version,
# add the supabase/postgres:15 tag that bundles it to TS_PG_TAGS (e.g. an older tag for the 2.9.x cluster).
run_timescale() {
  local prof="timescale" svc="timescale" fail=0 f db out rc tag planned ran
  local px=( --profile "$prof" exec -T -e PGPASSWORD=postgres "$svc" psql -h 127.0.0.1 -U postgres )
  for tag in ${TS_PG_TAGS:-15.14.1.127}; do
    export TS_PG_TAG="$tag"   # docker-compose interpolates this into the supabase/postgres image tag
    echo; echo "========================================="
    echo "Apache TimescaleDB via supabase/postgres:$tag / pg15 -- from_hypertable"
    echo "========================================="
    $DC --profile "$prof" down -v 2>/dev/null || true
    pull_third_party "$prof" "$svc"
    $DC --profile "$prof" up -d
    # This track is where the TCP-probe rule was learned; wait_pg now carries it for every track.
    wait_pg "$prof" "$svc" 120
    echo "  edition: timescaledb $($DC "${px[@]}" -d postgres -tAc "select default_version||' ('||current_setting('timescaledb.license')||')' from pg_available_extensions where name='timescaledb'" 2>/dev/null | tr -d '\r')"

    for f in tests/timescale/db/*.sql; do
      db="t_$(basename "$f" .sql | tr -cd 'a-z0-9_')"
      echo "--- ${f##*/} (db: $db) ---"
      $DC "${px[@]}" -d postgres -v ON_ERROR_STOP=1 -q \
        -c "drop database if exists $db" -c "create database $db" \
        -c "alter database $db set client_min_messages = warning" >/dev/null
      $DC "${px[@]}" -d "$db" -v ON_ERROR_STOP=1 -q \
        -c "create extension if not exists timescaledb; create extension if not exists pgtap;" >/dev/null
      $DC "${px[@]}" -d "$db" -v ON_ERROR_STOP=1 -q \
        --single-transaction -f /repo/pgpm_core/install.sql >/dev/null
      $DC "${px[@]}" -d "$db" -v ON_ERROR_STOP=1 -q -f /repo/pgpm_hypertable/install.sql >/dev/null
      $DC "${px[@]}" -d "$db" -v ON_ERROR_STOP=1 -q -f /repo/tests/timescale/fixtures.sql >/dev/null
      # -tA gives clean TAP (no table chrome); no ON_ERROR_STOP so every assertion reports. psql's exit
      # status is kept, not left to `set -e` (which would end the track there with no verdict and no
      # teardown): a session lost part-way exits 2 and is judged below.
      rc=0; out=$($DC "${px[@]}" -d "$db" -tAq -f "/repo/$f" 2>&1) || rc=$?
      echo "$out" | grep -E '^(ok|not ok|1\.\.|# )' || true
      # pg_prove's verdict, which this runner does not use: a failed assertion, an error, a file that
      # ran a different number of assertions than it planned, or one psql did not run to its end. The
      # third is counted here, the assertions that ran against the 1..N plan line, as pg_prove and the
      # timescale wrappers count it: pgTAP's own "# Looks like you planned N tests but ran M" is printed
      # by finish() alone, so reading only that line passed a file that never calls finish() (#918), as
      # missing it once passed a file whose assertion silently never ran (#601). A session that dies
      # part-way (FATAL, no ERROR:) shows as psql's exit (#819).
      # Both counts end in `|| true`: grep -c exits 1 when it counts nothing, and under this script's
      # `set -euo pipefail` that would end the track at a file that ran no assertion at all, unjudged.
      # bench/tap_verdict.sh reads this region back out and holds it to real pgTAP output.
      planned=$(echo "$out" | sed -nE 's/^1\.\.([0-9]+)$/\1/p' | head -1 || true)
      ran=$(echo "$out" | grep -cE '^(not )?ok [0-9]+( |$)' || true)
      if [ "$rc" != 0 ] || echo "$out" | grep -qE '^not ok|^# Looks like you (failed|planned)|ERROR:' \
         || [ -z "$planned" ] || [ "$ran" != "$planned" ]; then
        echo "FAIL ($tag): $f (psql exit $rc)"; fail=1
      fi
      $DC "${px[@]}" -d postgres -q -c "drop database if exists $db" >/dev/null
    done

    # #422's cutover-identity guard proves itself the way every other guard does -- by being run
    # against a mutant that puts its defect back -- but it needs a real TimescaleDB, so its
    # mutations are registered under MUTATION_TRACK=timescale rather than the default track. Same
    # reasoning as locktrace: `./test.sh discriminate` has to stay runnable on a laptop without this
    # image. Run here, inside the tag loop, because this is where the container is already up.
    # #653's conservation-by-identity guard re-runs tests/timescale/db/22, which the loop above already
    # ran: this is the harness discriminate.sh drives that file through against its mutant, and a harness
    # only ever pointed at mutants would stay green there even if it failed against everything.
    echo "--- cutover conservation by identity guard (issue #653) ---"
    bash "$(dirname "$0")/bench/hypertable_cutover_conservation.sh" pgpm_test-timescale pgpm_perf86 || fail=1
    # The same reasoning for #735/#707's index-name harness and #736's empty-copy-watermark harness: each
    # re-runs a file the loop above ran, so it is proven against the real install, not only against mutants.
    echo "--- index names by identity, whole temp names, handoff names up front (issues #735, #707) ---"
    bash "$(dirname "$0")/bench/hypertable_index_names.sh" pgpm_test-timescale pgpm_perf136 || fail=1
    echo "--- empty-copy watermark guard (issue #736) ---"
    bash "$(dirname "$0")/bench/hypertable_empty_copy_watermark.sh" pgpm_test-timescale pgpm_perf137 || fail=1
    # #640's and #738's guards, against the unmodified module, for the same reason. #738's PART B (DDL that
    # lands while the cutover prepares, from a second session) is run nowhere else on correct code.
    echo "--- cutover identity kind and options guard (issue #640) ---"
    bash "$(dirname "$0")/bench/hypertable_cutover_identity_options.sh" pgpm_test-timescale pgpm_perf134 || fail=1
    echo "--- cutover shape guard (issue #738) ---"
    bash "$(dirname "$0")/bench/hypertable_cutover_shape.sh" pgpm_test-timescale pgpm_perf135 || fail=1
    # #787's and #792's harnesses, against the unmodified module, the clean-code half of their mutants' pairs.
    echo "--- the swap carries the source's access and triggers (issue #787) ---"
    bash "$(dirname "$0")/bench/hypertable_cutover_carries_access.sh" pgpm_test-timescale pgpm_perf167 || fail=1
    echo "--- the migrated table holds exactly the hypertable's grants (issue #838) ---"
    bash "$(dirname "$0")/bench/hypertable_grant_carry_resets_acl.sh" pgpm_test-timescale pgpm_perf201 || fail=1
    echo "--- transmute's key and frontier refusals before the swap (issue #792) ---"
    bash "$(dirname "$0")/bench/hypertable_handoff_refusals.sh" pgpm_test-timescale pgpm_perf168 || fail=1
    # #842's, #816's and #768's (F6-09) harnesses, the same way: the clean-code half of their mutants' pairs.
    echo "--- the swap knows its own capture by its record (issue #842) ---"
    bash "$(dirname "$0")/bench/hypertable_carry_capture_by_record.sh" pgpm_test-timescale pgpm_perf205 || fail=1
    # #988's, the same way: it re-runs tests/timescale/db/55 against the real install.
    echo "--- the swap knows a 0.6.0 capture by its own name, whatever the table is called now (issue #988) ---"
    bash "$(dirname "$0")/bench/hypertable_carry_capture_by_provenance.sh" pgpm_test-timescale pgpm_perf274 || fail=1
    echo "--- the swap carries publication membership and replica identity (issue #816) ---"
    bash "$(dirname "$0")/bench/hypertable_carry_publications_replica_identity.sh" pgpm_test-timescale pgpm_perf206 || fail=1
    echo "--- the copy and the cutover adopt only a key index on their destination (issues #768, #872) ---"
    bash "$(dirname "$0")/bench/hypertable_key_index_on_destination.sh" pgpm_test-timescale pgpm_perf207 || fail=1
    # #737's uninstall guard, the same way: the clean-code half of the pairs discriminate.sh completes with
    # its two mutants of uninstall.sql.
    echo "--- uninstall sweeps from_hypertable's change capture guard (issue #737) ---"
    bash "$(dirname "$0")/bench/uninstall_hypertable_capture.sh" pgpm_test-timescale pgpm_perf153 || fail=1
    # #773's, the same way: the clean-code half of the pairs discriminate.sh completes with its four mutants.
    echo "--- uninstall drops from_hypertable's abandoned copies guard (issue #773) ---"
    bash "$(dirname "$0")/bench/uninstall_hypertable_copy.sh" pgpm_test-timescale pgpm_perf242 || fail=1
    # #791's and #793's time-rendering guard, the same way: it re-runs tests/timescale/db/35 and 36 against
    # the real install, the clean-code half of the pairs discriminate.sh completes with its three mutants.
    echo "--- bounds and watermarks independent of the session's DateStyle and TimeZone guard (issues #791, #793) ---"
    bash "$(dirname "$0")/bench/hypertable_time_rendering.sh" pgpm_test-timescale pgpm_perf172 || fail=1
    # #825's guard, the same way: it re-runs tests/timescale/db/37 against the real install, the clean-code
    # half of the pairs discriminate.sh completes with its two mutants.
    echo "--- a caller whose reads row-level security filters is refused (issue #825) ---"
    bash "$(dirname "$0")/bench/hypertable_reads_caller_rls.sh" pgpm_test-timescale pgpm_perf181 || fail=1
    # #839's, #840's and #841's harnesses, against the unmodified module, the clean-code half of their mutants'
    # pairs. #841's PART B (a constraint that lands while the cutover prepares) is run nowhere else on correct code.
    echo "--- the swap keeps the sequences the source owns (issue #839) ---"
    bash "$(dirname "$0")/bench/hypertable_cutover_serial_sequences.sh" pgpm_test-timescale pgpm_perf202 || fail=1
    echo "--- the cutover refuses outgoing keys changed since the copy (issue #840) ---"
    bash "$(dirname "$0")/bench/hypertable_cutover_foreign_keys.sh" pgpm_test-timescale pgpm_perf203 || fail=1
    echo "--- the cutover asks the exclusion check again under its lock (issue #841) ---"
    bash "$(dirname "$0")/bench/hypertable_cutover_exclusion_window.sh" pgpm_test-timescale pgpm_perf204 || fail=1
    # #873's guard, the hypertable module's half: tests/timescale/db/46 and PART H (row-level security that
    # lands while the cutover prepares), which is run nowhere else on correct code.
    echo "--- the drains, and the cutover under its lock, refuse a caller whose reads RLS filters (issue #873) ---"
    bash "$(dirname "$0")/bench/reads_under_caller_rls.sh" pgpm_test-timescale pgpm_perf212 /repo/pgpm_hypertable/install.sql || fail=1
    # #894's guard, the same way: it re-runs tests/timescale/db/47 against the real install, the clean-code
    # half of the pairs discriminate.sh completes with its three mutants.
    echo "--- the drains and the cutover name their scratch tables in pg_temp (issue #894) ---"
    bash "$(dirname "$0")/bench/hypertable_scratch_tables_in_pg_temp.sh" pgpm_test-timescale pgpm_perf220 || fail=1
    # The shared-preflight lever's guard (#966: #951, #959), the same way: it re-runs tests/timescale/db/50 against
    # the real install, the clean-code half of the pairs discriminate.sh completes with its twelve mutants.
    echo "--- every from_hypertable entry point refuses up front what the core refuses (lever #966) ---"
    bash "$(dirname "$0")/bench/hypertable_shared_preflight.sh" pgpm_test-timescale pgpm_perf252 || fail=1
    # #966 W1's scratch-relation guard, its module half: it re-runs tests/timescale/db/49 against the real
    # install (run_perf runs its core half, tests/267), the clean-code half of the pairs discriminate.sh
    # completes with its sixteen timescale-track mutants.
    echo "--- scratch relations minted owner-only and resolved by record (issues #949, #955) ---"
    bash "$(dirname "$0")/bench/scratch_relations.sh" pgpm_test-timescale pgpm_perf250 || fail=1
    # #974's guard, its module half: it re-runs tests/timescale/db/51 against the real install (run_perf runs its
    # core half, tests/272), the clean-code half of the pair discriminate.sh completes with
    # hypertable_delta_sequence_default_acl.
    echo "--- the sequences a scratch relation owns are minted owner-only too (issue #974) ---"
    bash "$(dirname "$0")/bench/scratch_sequences.sh" pgpm_test-timescale pgpm_perf257 || fail=1
    # #979's and #986's guards, the same way: they re-run tests/timescale/db/52 and 53 against the real install,
    # the clean-code half of the pairs discriminate.sh completes with their mutants.
    echo "--- every drain and the cutover re-sync the delta's writer grants (issue #979) ---"
    bash "$(dirname "$0")/bench/hypertable_delta_writer_grants.sh" pgpm_test-timescale pgpm_perf263 || fail=1
    echo "--- every drain and the cutover follow the hypertable's owner or refuse up front (issue #986) ---"
    bash "$(dirname "$0")/bench/hypertable_scratch_owner_follow.sh" pgpm_test-timescale pgpm_perf264 || fail=1
    # #985's guard, the same way: it re-runs tests/timescale/db/54 against the real install, the clean-code half of
    # the pair discriminate.sh completes with its timescale-track mutant (run_perf runs its core half, tests/282).
    echo "--- uninstall drops every recorded scratch object by oid, whatever it is called now (issue #985) ---"
    bash "$(dirname "$0")/bench/uninstall_hypertable_scratch_by_record.sh" pgpm_test-timescale pgpm_perf273 || fail=1
    # #917: five wrappers whose mutants discriminate.sh drives here had no clean-code run anywhere, so a
    # wrapper broken enough to fail against everything (a missing file: exit 1, "0 ran") was scored as
    # catching each of its mutants. These are their clean-code halves. bench/guards_run_on_clean_code.sh
    # fails the perf track on any guard with a mutation that no track runs.
    echo "--- the cutover verifies both halves of the swap (tests/timescale/db/17) ---"
    bash "$(dirname "$0")/bench/hypertable_cutover_identity.sh" pgpm_test-timescale pgpm_htcutident || fail=1
    echo "--- the cutover conserves every row or refuses to swap (tests/timescale/db/20) ---"
    bash "$(dirname "$0")/bench/hypertable_late_appends.sh" pgpm_test-timescale pgpm_htlate || fail=1
    echo "--- from_hypertable refuses working names over 63 bytes (tests/timescale/db/23) ---"
    bash "$(dirname "$0")/bench/hypertable_derived_names.sh" pgpm_test-timescale pgpm_htnames || fail=1
    echo "--- no untracked write is reverted by the swap (tests/timescale/db/25) ---"
    bash "$(dirname "$0")/bench/hypertable_replica_capture.sh" pgpm_test-timescale pgpm_htreplica || fail=1
    echo "--- every entry point refuses an exclusion constraint (tests/timescale/db/26) ---"
    bash "$(dirname "$0")/bench/hypertable_exclusion_refusal.sh" pgpm_test-timescale pgpm_htexcl || fail=1
    # pass 9 G17: #996's guard, the clean-code half of the pair discriminate.sh completes with its mutant.
    echo "--- the keyless catch-up is judged by its rows, not its count (issue #996) ---"
    bash "$(dirname "$0")/bench/hypertable_catchup_identity.sh" pgpm_test-timescale pgpm_perf280 || fail=1
    # #1037 bullet 1's guard, the same way: it re-runs tests/timescale/db/56 against the real install, the clean-code
    # half of the pair discriminate.sh completes with hypertable_capture_delta_by_name.
    echo "--- the change capture writes the delta it recorded, renamed or not (issue #1037) ---"
    bash "$(dirname "$0")/bench/hypertable_capture_delta_by_record.sh" pgpm_test-timescale pgpm_perf283 || fail=1
    # #1057 bullet 3's guard, the same way: it re-runs tests/timescale/db/57 against the real install, the clean-code
    # half of the pair discriminate.sh completes with hypertable_capture_fast_path_unlocked.
    echo "--- the change capture writes its delta only while it holds it (issue #1057) ---"
    bash "$(dirname "$0")/bench/hypertable_capture_delta_held.sh" pgpm_test-timescale pgpm_perf295 || fail=1
    # #1085's guard, the same way: it re-runs tests/timescale/db/58 against the real install, the clean-code half
    # of the pairs discriminate.sh completes with its three mutants.
    echo "--- from_hypertable and the cutover ask transmute's argument rules before the swap (issue #1085) ---"
    bash "$(dirname "$0")/bench/hypertable_argument_rules.sh" pgpm_test-timescale pgpm_perf110 || fail=1
    # #1083's guard, the same way: it re-runs tests/timescale/db/60 against the real install, the clean-code half
    # of the pair discriminate.sh completes with the hypertable_copy_rerun_*_by_name mutations.
    echo "--- a re-run copy replaces the recorded copy, wherever it lives (issue #1083) ---"
    bash "$(dirname "$0")/bench/hypertable_copy_rerun_by_record.sh" pgpm_test-timescale pgpm_perf116 || fail=1
    # #1105's hypertable guard, the same way: it re-runs tests/timescale/db/63 against the real install, the
    # clean-code half of the pair discriminate.sh completes with its two isolation mutants.
    echo "--- from_hypertable refuses a stricter isolation level before the copy and the swap (issue #1105) ---"
    bash "$(dirname "$0")/bench/hypertable_isolation_refused.sh" pgpm_test-timescale pgpm_tsiso || fail=1
    # #1091's guard, the same way: tests_fail_on_defect.sh judges tests/timescale/db/33 only when named, so the
    # clean-code half of the pair discriminate.sh completes with hypertable_cutover_capture_fn_drop_concatenated
    # runs here, on this container.
    echo "--- tests/timescale/db/33 fails when the cutover keeps the capture function (issue #1091) ---"
    bash "$(dirname "$0")/bench/tests_fail_on_defect.sh" pgpm_test-timescale pgpm_perf121 \
      /repo/tests/timescale/db/33_from_hypertable_cutover_carries_access_test.sql || fail=1

    echo "--- discriminate (timescale-scoped mutations) ---"
    bash "$(dirname "$0")/bench/discriminate.sh" --track=timescale pgpm_test-timescale || fail=1

    $DC --profile "$prof" down -v
  done
  if [ "$fail" -ne 0 ]; then echo "TimescaleDB track: FAIL"; return 1; fi
  echo "TimescaleDB track: PASS"
}

run_observe() {  # pg_flight_recorder observability track: impact_report correlation
                 # against a real PGFR install (the PGFR-absent gate is tests/65 in the main suite)
  local prof="pg15" svc="postgres15" fail=0 out
  local px=( --profile "$prof" exec -T "$svc" psql -U postgres )
  local pgfr="/repo/bench/vendor/pg_flight_recorder"          # container path (repo mounted at /repo)
  local pgfr_host="bench/vendor/pg_flight_recorder"           # host path (bench/vendor is gitignored)
  local pgfr_repo="https://github.com/dventimisupabase/pg_flight_recorder"
  local pgfr_sha="34517280f70b67ae8c8f99d18515550b629c9cd2"   # pin for reproducible CI
  # Clone-on-demand: PGFR is a vendored external repo (bench/vendor is gitignored), so it is absent on a
  # fresh checkout / in CI. Pull it at the pinned SHA when missing; a full clone so the SHA is reachable.
  if [ ! -f "$pgfr_host/pgfr_record/install.sql" ]; then
    echo ">>> cloning pg_flight_recorder@${pgfr_sha:0:7} into $pgfr_host"
    rm -rf "$pgfr_host"; mkdir -p "$(dirname "$pgfr_host")"
    git clone --quiet "$pgfr_repo" "$pgfr_host"
    git -C "$pgfr_host" checkout --quiet "$pgfr_sha"
  fi
  echo; echo "========================================="
  echo "pg_flight_recorder correlation track (pg15)"
  echo "========================================="
  $DC --profile "$prof" down -v 2>/dev/null || true
  $DC --profile "$prof" up -d
  wait_pg "$prof" "$svc" 90

  run_observe_file() {  # <db> <test-file> -- run one pgTAP file, collect TAP, flag failures
    local db="$1" f="$2" rc planned ran
    echo "--- ${f##*/} (db: $db) ---"
    rc=0; out=$($DC "${px[@]}" -d "$db" -tAq -f "$f" 2>&1) || rc=$?
    echo "$out" | grep -E '^(ok|not ok|1\.\.|# )' || true
    # The same verdict as run_timescale's, the plan counted against the assertions that ran and psql's
    # exit included (#601, #819, #918; bench/tap_verdict.sh).
    planned=$(echo "$out" | sed -nE 's/^1\.\.([0-9]+)$/\1/p' | head -1 || true)
    ran=$(echo "$out" | grep -cE '^(not )?ok [0-9]+( |$)' || true)
    if [ "$rc" != 0 ] || echo "$out" | grep -qE '^not ok|^# Looks like you (failed|planned)|ERROR:' \
       || [ -z "$planned" ] || [ "$ran" != "$planned" ]; then echo "FAIL: $f (psql exit $rc)"; fail=1; fi
  }

  # pg_flight_recorder requires pg_cron, which lives only in cron.database_name (postgres), so this runs in
  # the postgres db. The test wraps itself in BEGIN/ROLLBACK, so it leaves no state. disable() unschedules
  # PGFR's cron so the synthetic snapshots in the test stay deterministic.
  $DC "${px[@]}" -d postgres -v ON_ERROR_STOP=1 -q \
    -c "create extension if not exists pg_cron; create extension if not exists pgtap;" >/dev/null
  # The vendored PGFR install is best-effort (|| true): without pg_stat_statements preloaded (the test image
  # does not) its statement collector errors, and psql then exits non-zero even though the schema is fully
  # built -- which would otherwise trip `set -e`. We verify the schema actually landed with the guard below.
  $DC "${px[@]}" -d postgres -q -f "$pgfr/pgfr_record/install.sql"  >/dev/null 2>&1 || true
  $DC "${px[@]}" -d postgres -q -f "$pgfr/pgfr_analyze/install.sql" >/dev/null 2>&1 || true
  if [ "$($DC "${px[@]}" -d postgres -tAc "select count(*) from pg_namespace where nspname='pgfr_analyze'" | tr -d '[:space:]')" != "1" ]; then
    echo "FAIL: pg_flight_recorder (pgfr_analyze) did not install"; $DC --profile "$prof" down -v; return 1
  fi
  $DC "${px[@]}" -d postgres -q -c "select pgfr_record.disable()" >/dev/null 2>&1 || true
  $DC "${px[@]}" -d postgres -v ON_ERROR_STOP=1 -q --single-transaction -f /repo/pgpm_core/install.sql >/dev/null
  run_observe_file postgres /repo/tests/observe/db/with_pgfr_test.sql

  $DC --profile "$prof" down -v
  if [ "$fail" -ne 0 ]; then echo "observe track: FAIL"; return 1; fi
  echo "observe track: PASS"
}

# The pgpm_archive track: PG17 + pgsql-http against a real MinIO container standing in for S3.
# Builds one template database (pgpm_arch_tmpl) carrying the fixtures and both modules, then runs
# every tests/archive/db/*.sql via pg_prove against its OWN clone of it -- the same one-database-per-file
# pattern the default matrix uses, for the same reason (the clone loop below states it in full). Bucket
# setup is a one-off `docker run` of curlimages/curl against the network name pinned in
# docker-compose.yml (pgpm_test_net) rather than a compose-managed service: a SigV4-signed PUT, so it
# needs no MinIO client image at all (issue #436: the `mc` image vanished along with the server's).
run_archive() {
  local prof="archive" svc="archive" fail=0
  local px=( --profile "$prof" exec -T "$svc" psql -U postgres )
  local net="pgpm_test_net"
  echo; echo "========================================="
  echo "Archive track: pgpm_archive against MinIO (pg17 + pgsql-http)"
  echo "========================================="
  $DC --profile "$prof" down -v 2>/dev/null || true
  build_image "$prof" archive
  pull_third_party "$prof" minio
  $DC --profile "$prof" up -d

  wait_pg "$prof" "$svc" 60
  # /minio/health/cluster, not /minio/health/live: `live` answers 200 as soon as the process listens,
  # while `cluster` is MinIO's readiness probe and stays 503 until the server has finished initializing
  # -- the window in which a PUT gets `XMinioServerNotInitialized`. Loud on timeout: a silent fall-through
  # here used to surface later as an unexplained pgTAP failure inside a database this script then dropped.
  local ready=""
  for _ in $(seq 1 60); do
    if docker run --rm --network "$net" curlimages/curl -sf http://minio:9000/minio/health/cluster >/dev/null 2>&1; then ready=1; break; fi
    sleep 1
  done
  if [ -z "$ready" ]; then
    echo "archive track: FAIL -- MinIO never reported ready (/minio/health/cluster) within 60 s"
    docker logs pgpm_test-archive-minio 2>&1 | tail -20
    $DC --profile "$prof" down -v; return 1
  fi
  # Create the bucket with a SigV4-signed PUT from the same curl image the health wait already uses,
  # instead of the `mc` client (its image went away with MinIO's server image, issue #436). 200 is
  # created, 409 is "already exists" from an earlier run; anything else is a real failure. Then READ
  # the bucket back and require 200: a missing bucket answers 404 here, so this is a witness that the
  # setup actually happened, not just that the PUT returned.
  local s3=( docker run --rm --network "$net" curlimages/curl -s -o /dev/null -w '%{http_code}'
             --aws-sigv4 aws:amz:us-east-1:s3 -u minioadmin:minioadmin )
  local code
  code=$("${s3[@]}" -X PUT http://minio:9000/archive-test-bucket) || code="curl exit $?"
  if [ "$code" != 200 ] && [ "$code" != 409 ]; then
    echo "archive track: FAIL -- creating the MinIO bucket returned $code"
    $DC --profile "$prof" down -v; return 1
  fi
  code=$("${s3[@]}" http://minio:9000/archive-test-bucket/) || code="curl exit $?"
  if [ "$code" != 200 ]; then
    echo "archive track: FAIL -- the MinIO bucket is not readable after creation ($code)"
    $DC --profile "$prof" down -v; return 1
  fi

  $DC "${px[@]}" -d postgres -v ON_ERROR_STOP=1 -q \
    -c "create extension if not exists http; create extension if not exists pgcrypto; create extension if not exists pgtap;" >/dev/null
  # One database PER FILE, cloned from a template, exactly as the main suite does. These tests used to
  # isolate themselves with begin/rollback, which stopped being possible once the fixture's
  # pgpm.transmute became a committing PROCEDURE (#275): transaction control is illegal inside an
  # explicit transaction block. Cloning gives back the isolation the rollback provided, and gives it
  # for real -- a rollback never undid anything the tests pushed to MinIO anyway.
  $DC "${px[@]}" -d postgres -v ON_ERROR_STOP=1 -q -c "drop database if exists pgpm_arch_tmpl" >/dev/null
  $DC "${px[@]}" -d postgres -v ON_ERROR_STOP=1 -q -c "create database pgpm_arch_tmpl" >/dev/null
  $DC "${px[@]}" -d pgpm_arch_tmpl -v ON_ERROR_STOP=1 -q \
    -c "create extension if not exists http; create extension if not exists pgcrypto; create extension if not exists pgtap;" >/dev/null
  $DC "${px[@]}" -d pgpm_arch_tmpl -v ON_ERROR_STOP=1 -q -f /repo/tests/archive/fixtures.sql >/dev/null
  $DC "${px[@]}" -d pgpm_arch_tmpl -v ON_ERROR_STOP=1 -q --single-transaction -f /repo/pgpm_core/install.sql >/dev/null
  $DC "${px[@]}" -d pgpm_arch_tmpl -v ON_ERROR_STOP=1 -q -f /repo/pgpm_archive/install.sql >/dev/null

  local an=0
  for af in tests/archive/db/*.sql; do
    local ab adb; ab="$(basename "$af")"; an=$((an + 1)); adb="pgpm_a$an"
    $DC "${px[@]}" -d postgres -v ON_ERROR_STOP=1 -q -c "drop database if exists $adb" >/dev/null
    $DC "${px[@]}" -d postgres -v ON_ERROR_STOP=1 -q -c "create database $adb template pgpm_arch_tmpl" >/dev/null
    if ! $DC --profile "$prof" exec -T "$svc" sh -c "pg_prove --timer -U postgres -d $adb /repo/tests/archive/db/$ab"; then
      fail=1
      # A pgTAP assertion can only say WHAT is missing (a ledger row, a covered range). maintain()'s
      # per-step handlers swallow the WHY into pgpm.log as skip_*/fail_* rows, and the drop below takes
      # them with it, so a red run on a runner nobody can log into explains nothing. Print them first.
      echo "--- $ab: pgpm.log skip_*/fail_* rows in $adb (why maintain()'s steps did nothing) ---"
      $DC "${px[@]}" -d "$adb" -v ON_ERROR_STOP=1 -At -c "select to_char(at, 'HH24:MI:SS.MS') || '  ' || action || '  ' || coalesce(method, '') from pgpm.log where action like 'skip\_%' or action like 'fail\_%' order by at" || true
      echo "--- $ab: pgpm.part in $adb (attached, write-blocked, archive-covered) and pgpm.archive_ledger ---"
      $DC "${px[@]}" -d "$adb" -v ON_ERROR_STOP=1 -At -c "select parent_table || '.' || child_name || '  [' || lo || ', ' || hi || ')  attached=' || attached || '  write_blocked=' || pgpm._is_write_blocked(parent_table, child_name) || '  covered=' || pgpm._archive_fully_covered(parent_table, child_name) from pgpm.part order by parent_table::text, lo::numeric" || true
      $DC "${px[@]}" -d "$adb" -v ON_ERROR_STOP=1 -At -c "select 'ledger  ' || parent_table || '  [' || lo || ', ' || hi || ')  ' || child_name || '  key=' || coalesce(s3_key, '<null>') || '  rows=' || coalesce(rows_archived::text, '<null>') from pgpm.archive_ledger order by parent_table::text, lo::numeric" || true
    fi
    $DC "${px[@]}" -d postgres -v ON_ERROR_STOP=1 -q -c "drop database if exists $adb" >/dev/null
  done
  $DC "${px[@]}" -d postgres -v ON_ERROR_STOP=1 -q -c "drop database if exists pgpm_arch_tmpl" >/dev/null

  # The independent-reader verification below connects to `postgres`, so that database still needs the
  # extensions and both installers.
  $DC "${px[@]}" -d postgres -v ON_ERROR_STOP=1 -q \
    -c "create extension if not exists http; create extension if not exists pgcrypto; create extension if not exists pgtap;" >/dev/null
  $DC "${px[@]}" -d postgres -v ON_ERROR_STOP=1 -q -f /repo/tests/archive/fixtures.sql >/dev/null
  $DC "${px[@]}" -d postgres -v ON_ERROR_STOP=1 -q --single-transaction -f /repo/pgpm_core/install.sql >/dev/null
  $DC "${px[@]}" -d postgres -v ON_ERROR_STOP=1 -q -f /repo/pgpm_archive/install.sql >/dev/null

  # Independent-reader verification (pyarrow + DuckDB, scripts/verify_parquet*.py): runs on the
  # host against the archive service's published port (5520), not inside the container like the
  # pgTAP suite above -- these are plain psycopg2 scripts, not psql. Reuses a venv across runs
  # (installs requirements the first time, and again whenever one of them will not import, so a venv
  # built before a requirement was added picks it up) since pyarrow/DuckDB are not instant to
  # install; safe to delete .venv-verify to force a clean reinstall.
  echo "--- independent-reader verification (pyarrow + DuckDB) ---"
  if ! .venv-verify/bin/python -c 'import psycopg2, pyarrow, duckdb, pytz' >/dev/null 2>&1; then
    [ -d .venv-verify ] || python3 -m venv .venv-verify
    .venv-verify/bin/pip install -q -r scripts/requirements-verify.txt
  fi
  .venv-verify/bin/python scripts/verify_parquet.py "postgresql://postgres:postgres@localhost:5520/postgres" \
    || fail=1
  .venv-verify/bin/python scripts/verify_parquet_range.py "postgresql://postgres:postgres@localhost:5520/postgres" \
    || fail=1

  echo "--- LZ77 match-finder memory guard (issue #366) ---"
  bash "$(dirname "$0")/bench/archive_lz77_memory.sh" pgpm_test-archive pgpm_lz77mem || fail=1

  echo "--- column encode memory guard (issue #368) ---"
  bash "$(dirname "$0")/bench/archive_encode_memory.sh" pgpm_test-archive pgpm_encodemem || fail=1

  echo "--- DEFLATE encoder memory guard (issue #370) ---"
  bash "$(dirname "$0")/bench/archive_deflate_memory.sh" pgpm_test-archive pgpm_deflatemem || fail=1

  # The encode boundary guard (#408) re-runs a pgTAP file the suite above ALREADY ran, which looks
  # redundant and is not: what runs here is the harness bench/discriminate.sh drives that file
  # through, and a harness only ever pointed at mutants would be green in `discriminate` even if it
  # were broken enough to fail against everything. This is the clean-code half of that pair.
  echo "--- encode parameter boundary guard (issue #408) ---"
  bash "$(dirname "$0")/bench/archive_encode_boundary.sh" pgpm_test-archive pgpm_encbound || fail=1

  # The single-snapshot guard (#462) re-runs tests/archive/db/15 for the same reason, and adds the
  # half that file cannot do from inside the database: pyarrow reading the racy files it produced and
  # asserting id = tag on every row. Needs the venv the independent-reader step above just built.
  echo "--- Parquet single-snapshot guard (issue #462) ---"
  bash "$(dirname "$0")/bench/archive_parquet_snapshot.sh" pgpm_test-archive pgpm_pqsnap || fail=1

  # The partition_tz guard (#501) re-runs tests/archive/db/16 for the same reason as the boundary
  # guard above: it is the harness discriminate.sh drives that file through, and this is the
  # clean-code half of that pair.
  echo "--- chunk literals rendered in partition_tz guard (issue #501) ---"
  bash "$(dirname "$0")/bench/archive_encode_partition_tz.sh" pgpm_test-archive pgpm_enctz || fail=1
  # The object-key identity guard (#502) re-runs tests/archive/db/16 for the same reason as #408 and
  # #462 above: this is the harness discriminate.sh drives that file through against its mutant, and
  # the clean-code half of that pair has to run somewhere too.
  echo "--- archive object key identity guard (issue #502) ---"
  bash "$(dirname "$0")/bench/archive_object_key.sh" pgpm_test-archive pgpm_objkey || fail=1
  # The session-independent key guard (#551) re-runs tests/archive/db/26 for the same reason: the
  # clean-code half of the pair discriminate.sh completes with the search_path and session-zone mutants.
  echo "--- archive object key names the parent and lo the same in every session guard (issue #551) ---"
  bash "$(dirname "$0")/bench/archive_object_key_session.sh" pgpm_test-archive pgpm_perf108 || fail=1

  # The archive.to_s3 compress guard (#520) re-runs tests/archive/db/16_to_s3_compress for the same
  # reason, and adds the half that file cannot do from inside the database: Python's gzip inflating the
  # objects it left in t16.obj and asserting the rows by identity, since this module has no gzip
  # decoder of its own.
  echo "--- archive.to_s3 compress guard (issue #520) ---"
  bash "$(dirname "$0")/bench/archive_to_s3_compress.sh" pgpm_test-archive pgpm_tos3gz || fail=1

  # The SigV4 wall-clock guard (#520) re-runs tests/archive/db/17 for the same reason as the ones
  # above: this is the clean-code half of the pair bench/discriminate.sh completes with the mutant.
  echo "--- SigV4 wall-clock stamp guard (issue #520) ---"
  bash "$(dirname "$0")/bench/archive_sigv4_wall_clock.sh" pgpm_test-archive pgpm_sigv4clock || fail=1

  # The four Parquet column-type guards re-run tests/archive/db/18 to 21 for the same reason, and add
  # the half those files cannot do from inside the database: pyarrow and DuckDB reading back the files
  # each one left behind (a negative-scale numeric, infinite timestamps, a numeric scale above its
  # precision, a keyless parent) and asserting the values by identity.
  echo "--- Parquet negative numeric scale guard (issue #567) ---"
  bash "$(dirname "$0")/bench/archive_parquet_negative_scale.sh" pgpm_test-archive pgpm_perf47 || fail=1
  echo "--- Parquet infinite timestamp guard (issue #586) ---"
  bash "$(dirname "$0")/bench/archive_parquet_timestamp_infinity.sh" pgpm_test-archive pgpm_perf48 || fail=1
  # tests/archive/db/27 is the finite half of #586's boundary, and its guard has the same two halves.
  echo "--- Parquet timestamp past the int64 microsecond range guard (issue #664) ---"
  bash "$(dirname "$0")/bench/archive_parquet_timestamp_range.sh" pgpm_test-archive pgpm_perf112 || fail=1
  echo "--- Parquet numeric scale above precision guard (issue #596) ---"
  bash "$(dirname "$0")/bench/archive_parquet_scale_above_precision.sh" pgpm_test-archive pgpm_perf49 || fail=1
  echo "--- Parquet keyless parent guard (issue #597) ---"
  bash "$(dirname "$0")/bench/archive_parquet_keyless.sh" pgpm_test-archive pgpm_perf50 || fail=1
  # The GZIP encoder's lock-table guard (#587) re-runs tests/archive/db/22 for the same reason: the
  # clean-code half of the pair bench/discriminate.sh completes with the per-call temp table put back.
  echo "--- GZIP encode lock-table entries guard (issue #587) ---"
  bash "$(dirname "$0")/bench/archive_huffman_lock_entries.sh" pgpm_test-archive pgpm_perf72 || fail=1
  # The part_bytes bound guard (#594) and the cancel-abort guard (#595) re-run tests/archive/db/23 and
  # 24 for the same reason: the clean-code halves of the pairs bench/discriminate.sh completes with
  # their mutants.
  echo "--- archive.to_s3 part_bytes bound guard (issue #594) ---"
  bash "$(dirname "$0")/bench/archive_to_s3_part_bytes.sh" pgpm_test-archive pgpm_perf75 || fail=1
  echo "--- archive.to_s3 cancel aborts multipart guard (issue #595) ---"
  bash "$(dirname "$0")/bench/archive_to_s3_cancel_abort.sh" pgpm_test-archive pgpm_perf76 || fail=1
  # The conservation-by-identity guard (#673) re-runs tests/archive/db/25 for the same reason: the
  # clean-code half of the pair bench/discriminate.sh completes with the count-only check put back.
  echo "--- archive.to_s3 conservation by identity guard (issue #673) ---"
  bash "$(dirname "$0")/bench/archive_to_s3_conservation.sh" pgpm_test-archive pgpm_perf87 || fail=1
  # The loud-edges guard (#636) re-runs tests/archive/db/28 for the same reason: the clean-code half of
  # the pairs bench/discriminate.sh completes with its three mutants.
  echo "--- archive.to_s3 loud edges guard (issue #636) ---"
  bash "$(dirname "$0")/bench/archive_to_s3_loud_edges.sh" pgpm_test-archive pgpm_perf122 || fail=1
  # The non-UTF8 signer guard (#728), the pass-5 edges guard (#711) and the decimal NaN guard (#635)
  # re-run tests/archive/db/29, 30 and 31 for the same reason; the last two add the readers' half
  # (DuckDB and pyarrow on the files those tests leave behind).
  echo "--- archive signer in a non-UTF8 database guard (issue #728) ---"
  bash "$(dirname "$0")/bench/archive_signer_non_utf8.sh" pgpm_test-archive pgpm_perf131 || fail=1
  echo "--- archive sync keys, tstz annotation and paged orphan sweep guard (issue #711) ---"
  bash "$(dirname "$0")/bench/archive_edges_pass5.sh" pgpm_test-archive pgpm_perf132 || fail=1
  echo "--- Parquet numeric NaN guard (issue #635) ---"
  bash "$(dirname "$0")/bench/archive_parquet_decimal_nan.sh" pgpm_test-archive pgpm_perf133 || fail=1
  # The float-digits guard (#781) re-runs tests/archive/db/32 for the same reason: the clean-code half
  # of the pairs bench/discriminate.sh completes with each encoder's extra_float_digits pin taken out.
  echo "--- archive floats under extra_float_digits = 0 guard (issue #781) ---"
  bash "$(dirname "$0")/bench/archive_float_digits_pinned.sh" pgpm_test-archive pgpm_perf160 || fail=1
  # The row-alias guard (#821) re-runs tests/archive/db/33 for the same reason: the clean-code half of the
  # pairs bench/discriminate.sh completes with each NDJSON render site put back to row_to_json(t).
  echo "--- NDJSON whole row over a column named t guard (issue #821) ---"
  bash "$(dirname "$0")/bench/archive_ndjson_row_alias.sh" pgpm_test-archive pgpm_perf175 || fail=1
  # The object-key identity guards (#822, #823) re-run tests/archive/db/34 and 35 for the same reason: the
  # clean-code halves of the pairs bench/discriminate.sh completes with the reusable-name, unseeded-claims
  # and era-dropping mutants.
  echo "--- archive object key never reused by another relation guard (issue #822) ---"
  bash "$(dirname "$0")/bench/archive_key_reused_name.sh" pgpm_test-archive pgpm_perf176 || fail=1
  echo "--- archive object key keeps a BC chunk's era guard (issue #823) ---"
  bash "$(dirname "$0")/bench/archive_stem_era.sh" pgpm_test-archive pgpm_perf177 || fail=1
  # The to_s3 cursor guard (#834) and the Parquet snapshot lock-entries guard (#632, F5-04) re-run
  # tests/archive/db/36 and 37 for the same reason: the clean-code halves of the pairs
  # bench/discriminate.sh completes with the session-rendered cursor and the per-encode snapshot table.
  echo "--- archive.to_s3 cursor in a non-ISO DateStyle guard (issue #834) ---"
  bash "$(dirname "$0")/bench/archive_to_s3_cursor_session.sh" pgpm_test-archive pgpm_perf195 || fail=1
  echo "--- Parquet snapshot lock-table entries guard (issue #632, F5-04) ---"
  bash "$(dirname "$0")/bench/archive_parquet_snapshot_locks.sh" pgpm_test-archive pgpm_perf196 || fail=1
  # The object-key lever guard (#872) re-runs tests/archive/db/39 for the same reason: the clean-code half of
  # the pairs bench/discriminate.sh completes with one mutant per path that takes its key from the one
  # function that assembles and claims it.
  echo "--- archive object key names one relation on every path guard (issue #872) ---"
  bash "$(dirname "$0")/bench/archive_key_owner_every_path.sh" pgpm_test-archive pgpm_perf213 || fail=1
  # The static half of that lever (#914): scripts/check_archive_object_keys.py on the module, the clean-code
  # half of the pairs bench/discriminate.sh completes with a second key assembled from a scalar subquery and
  # through a parameter of another name.
  echo "--- archive object key assembled in one function, followed by data flow guard (issue #914) ---"
  bash "$(dirname "$0")/bench/archive_object_keys_static.sh" pgpm_test-archive pgpm_perf246 || fail=1
  # #873's guard, the archive module's half (tests/archive/db/38): the clean-code half of the pairs
  # bench/discriminate.sh completes with the four archive readers' mutants.
  echo "--- the archive readers refuse a caller whose reads row-level security filters (issue #873) ---"
  bash "$(dirname "$0")/bench/reads_under_caller_rls.sh" pgpm_test-archive pgpm_perf216 /repo/pgpm_archive/install.sql || fail=1
  # The whole-key guard (#890) re-runs tests/archive/db/40 for the same reason: the clean-code half of the
  # pairs bench/discriminate.sh completes with the base-only claim, the `.gz` outside the claim and the
  # unseeded install.
  echo "--- an export and a chunk never write one object key guard (issue #890) ---"
  bash "$(dirname "$0")/bench/archive_key_full_claim.sh" pgpm_test-archive pgpm_perf240 || fail=1
  # The null-argument and empty-range guard (#969) re-runs tests/archive/db/41 for the same reason: the
  # clean-code half of the pairs bench/discriminate.sh completes with each public routine's null check
  # neutralised and each strategy's range refusal taken out.
  echo "--- pgpm_archive refuses null arguments and empty ranges guard (issue #969) ---"
  bash "$(dirname "$0")/bench/archive_null_arguments.sh" pgpm_test-archive pgpm_perf255 || fail=1
  # The export-key-by-relation guard (#976) re-runs tests/archive/db/43 for the same reason: the clean-code
  # half of the pairs bench/discriminate.sh completes with the claim checked by parent and kind only and with
  # the install's relation backfill taken out.
  echo "--- another relation never exports over an export guard (issue #976) ---"
  bash "$(dirname "$0")/bench/archive_export_key_by_relation.sh" pgpm_test-archive pgpm_perf259 || fail=1
  # The recorded-chunk guard (#975) re-runs tests/archive/db/42 for the same reason: the clean-code half of the
  # pairs bench/discriminate.sh completes with each encoder's refusal taken out and each of its two rules dropped.
  echo "--- no archive_fn strategy writes over a recorded chunk it does not reproduce guard (issue #975) ---"
  bash "$(dirname "$0")/bench/archive_recorded_chunk.sh" pgpm_test-archive pgpm_perf258 || fail=1
  # The extension-resolution guard (#984) re-runs tests/archive/db/44 for the same reason: the clean-code half
  # of the pairs bench/discriminate.sh completes with the signers' search_path pin taken out, HMAC called
  # through it, and the NDJSON upload naming the http types again.
  echo "--- pgpm_archive reaches pgcrypto and http in their own schemas, never through search_path guard (issue #984) ---"
  bash "$(dirname "$0")/bench/archive_extension_resolution.sh" pgpm_test-archive pgpm_perf271 || fail=1
  # The child-held guard (#1030) re-runs tests/archive/db/45 for the same reason: the clean-code half of the
  # pairs bench/discriminate.sh completes with the resolved child left unheld, read by name, and both.
  echo "--- a synchronous export reads the relation it resolved and claimed guard (issue #1030) ---"
  bash "$(dirname "$0")/bench/archive_to_s3_child_held.sh" pgpm_test-archive pgpm_perf281 || fail=1
  # The read-by-regclass guard (#1055) re-runs tests/archive/db/46 for the same reason: the clean-code half of the
  # pairs bench/discriminate.sh completes with the read by an earlier name, the regclass rendered alone, rendered
  # before the snapshot table's lock, the check of what a read reached made inert, admitting a descendant named
  # like the parent, sampled after the read, and left out of the NDJSON strategy.
  echo "--- a Parquet export reads the relation it was handed, never a namesake guard (issue #1055) ---"
  bash "$(dirname "$0")/bench/archive_parquet_read_by_regclass.sh" pgpm_test-archive pgpm_perf292 || fail=1
  # The one-snapshot guard (#1062) re-runs tests/archive/db/47 for the same reason: the clean-code half of the
  # pair bench/discriminate.sh completes with the child resolved in two statements again.
  echo "--- archive._resolve_child resolves the child under one snapshot guard (issue #1062) ---"
  bash "$(dirname "$0")/bench/archive_resolve_child_one_snapshot.sh" pgpm_test-archive pgpm_perf297 || fail=1
  # The recorded-chunk rows guard (#1069) re-runs tests/archive/db/48 for the same reason: the clean-code half of
  # the pairs bench/discriminate.sh completes with the rows' digest never compared, never recorded, and
  # rendered in the caller's time zone or under the caller's search_path, or taken of a column named like its
  # row alias.
  echo "--- no archive_fn strategy writes other rows over a recorded chunk guard (issue #1069) ---"
  bash "$(dirname "$0")/bench/archive_recorded_chunk_rows_identity.sh" pgpm_test-archive pgpm_perf100 || fail=1
  # The recorded-chunk race guard (#1069) holds a tick inside its refusal and sends a direct call into the window,
  # which one pgTAP file cannot do: the clean-code half of the pair bench/discriminate.sh completes with the
  # claim row left unlocked before the ledger lookup.
  echo "--- a direct archive_fn call racing a tick on the same chunk is refused guard (issue #1069) ---"
  bash "$(dirname "$0")/bench/archive_recorded_chunk_tick_race.sh" pgpm_test-archive pgpm_g1race || fail=1
  # The read-back guard (#1093) re-runs tests/archive/db/08 for the same reason: the clean-code half of the pair
  # bench/discriminate.sh completes with archive_fn_parquet_readback_trusted.
  echo "--- tests/archive/db/08 reads its Parquet objects back guard (issue #1093) ---"
  bash "$(dirname "$0")/bench/archive_fn_s3_readback.sh" pgpm_test-archive pgpm_perf123 || fail=1
  # The key-by-resolved-oid guard (#1064) re-runs tests/archive/db/49 for the same reason, and runs
  # scripts/check_archive_child_by_oid.py on the module: the clean-code half of the pair bench/discriminate.sh
  # completes with archive._owned_key looking the export's relation up by name again.
  echo "--- a synchronous export keys and claims the relation it resolved, by oid guard (issue #1064) ---"
  bash "$(dirname "$0")/bench/archive_key_by_resolved_oid.sh" pgpm_test-archive pgpm_perf323 || fail=1

  $DC --profile "$prof" down -v
  if [ "$fail" -ne 0 ]; then echo "archive track: FAIL"; return 1; fi
  echo "archive track: PASS"
}

# ------------------------------------------------------------------------------------------------------
# The `perf` track: guard against data-coupled locks and data-coupled work (issues #267, #275).
#
# NOT part of the pgTAP suite, and deliberately so, for two reasons that outlive any one isolation scheme.
# The lock guards need a SECOND SESSION observing a first one mid-operation (a reader under a short
# lock_timeout while the O(rows) scan runs), and a pgTAP file is one session, so the regression they exist
# to catch would be invisible written as one. The work guards read pg_stat_all_tables scan counters, which
# are flushed at TRANSACTION END: measured, a seq scan of 20000 rows reports growth of 0 when read inside
# the same transaction and 20000 across transactions, so the sample has to be taken in a later transaction
# than the work it measures. Every tick in the harness runs in its own transaction, which is also how
# maintain drives it in production.
run_perf() {
  local prof="pg17" svc="postgres17" c="pgpm_test-17"
  # One guard per line: script, its database, optional extra argument. The list is data so that
  # --shard can slice it; scripts/check_track_filters.py still reads every bench/*.sh reference here.
  local guards=(
    "bench/regrain_perf.sh pgpm_perf /repo/pgpm_core/install.sql"
    "bench/transmute_lock.sh pgpm_perf2"
    "bench/transmute_cutover_order.sh pgpm_perf11"
    "bench/transmute_lock_timeout.sh pgpm_perf7"
    "bench/maintain_lock.sh pgpm_perf3"
    "bench/restore_fk_lock.sh pgpm_perf5"
    "bench/retire_detach_lock.sh pgpm_perf6"
    "bench/upgrade_in_place.sh pgpm_perf8"
    "bench/upgrade_from_release.sh pgpm_perf18"
    "bench/frontier_drought.sh pgpm_perf9"
    "bench/regrain_outgoing_fk_lock.sh pgpm_perf10"
    "bench/obtain_backoff_headroom.sh pgpm_perf12"
    "bench/transmute_claim_squat.sh pgpm_perf13"
    "bench/untransmute_race.sh pgpm_perf16"
    "bench/retire_detach_substitution.sh pgpm_perf14"
    "bench/regrain_swap_reconcile.sh pgpm_perf15"
    "bench/grid_timezone.sh pgpm_perf17"
    "bench/set_regrain_off_midflight.sh pgpm_perf24"
    "bench/regrain_reconcile_snapshot.sh pgpm_perf19"
    "bench/set_archive_fn_return_type.sh pgpm_perf41"
    "bench/cutover_trigger_state.sh pgpm_perf20"
    "bench/datestyle_bounds.sh pgpm_perf25"
    "bench/dropped_fk_identity.sh pgpm_perf26"
    "bench/regrain_capture_identity.sh pgpm_perf27"
    "bench/maintain_regrain_lock_timeout.sh pgpm_perf28"
    "bench/quoted_schema.sh pgpm_perf29"
    "bench/regrain_candidate_subdivides.sh pgpm_perf30"
    "bench/part_name_length.sh pgpm_perf31"
    "bench/untransmute_residue.sh pgpm_perf32"
    "bench/transmute_preconditions.sh pgpm_perf33"
    "bench/uuidv7_regrain_archive.sh pgpm_perf34"
    "bench/archive_ledger_identity.sh pgpm_perf35"
    "bench/day_label_utc.sh pgpm_perf36"
    "bench/day_label_utc.sh pgpm_perf37"
    "bench/naive_column_utc_grid.sh pgpm_perf21"
    "bench/month_step_dst_gap.sh pgpm_perf22"
    "bench/transmute_resume_zone.sh pgpm_perf23"
    "bench/archive_chunk_ties.sh pgpm_perf38"
    "bench/archive_chunk_uuidv7_ties.sh pgpm_perf54"
    "bench/retire_regrain_source.sh pgpm_perf39"
    "bench/regrain_writer_waits.sh pgpm_perf66"
    "bench/throws_pinned.sh pgpm_perf40"
    "bench/retain_interval_sign.sh pgpm_perf44"
    "bench/transmute_publication_membership.sh pgpm_perf45"
    "bench/transmute_serial_sequence_owner.sh pgpm_perf46"
    "bench/text_time_numeric_collation.sh pgpm_perf51"
    "bench/retire_unguarded_coverage.sh pgpm_perf43"
    "bench/regrain_restart_null_cursor.sh pgpm_perf52"
    "bench/regrain_reconcile_datestyle.sh pgpm_perf53"
    "bench/hypertable_swap_order.sh pgpm_perf42"
    "bench/obtain_int_ceiling.sh pgpm_perf63"
    "bench/legacy_day_labels.sh pgpm_perf55"
    "bench/cutover_partitioned_referencer.sh pgpm_perf59"
    "bench/carried_index_name_length.sh pgpm_perf60"
    "bench/cutover_trigger_window.sh pgpm_perf61"
    "bench/set_partition_tz_every_bound.sh pgpm_perf68"
    "bench/month_floor_doubled_midnight.sh pgpm_perf69"
    "bench/maintain_all_sweep_turns.sh pgpm_perf64"
    "bench/regrain_candidate_lock_race.sh pgpm_perf65"
    "bench/untransmute_fk_validate_lock.sh pgpm_perf62"
    "bench/transmute_resume_lattice.sh pgpm_perf56"
    "bench/transmute_reap_identity.sh pgpm_perf57"
    "bench/transmute_step_preflight.sh pgpm_perf58"
    "bench/regrain_parent_rename_midcopy.sh pgpm_perf70"
    "bench/regrain_step_positive.sh pgpm_perf71"
    "bench/part_name_labels_injective.sh pgpm_perf67"
    "bench/uninstall_residue.sh pgpm_perf73"
    "bench/extend_to_lock_budget.sh pgpm_perf74"
    "bench/keep_both_diff3.sh pgpm_perf77"
    "bench/doc_env_knobs.sh pgpm_perf78"
    "bench/doc_retain_unit.sh pgpm_perf120"
    "bench/doc_archive_identity_recovery.sh pgpm_perf142"
    "bench/doc_fks_suspended_meaning.sh pgpm_perf143"
    "bench/doc_monolith_retention.sh pgpm_perf144"
    "bench/doc_remedy_and_symptom.sh pgpm_perf243"
    "bench/doc_transmute_no_default.sh pgpm_perf278"
    "bench/release_assets_over_cap.sh pgpm_perf307"
    "bench/doc_maintain_does_not_obtain.sh pgpm_perf118"
    "bench/doc_install_stops_on_error.sh pgpm_perf119"
    "bench/classify_claims_tap.sh pgpm_perf79"
    "bench/lint_value_not_spelling.sh pgpm_perf125"
    "bench/tap_verdict.sh pgpm_perf80"
    "bench/retire_straddle.sh pgpm_perf81"
    "bench/archive_overclaim.sh pgpm_perf82"
    "bench/transmute_abort_owner.sh pgpm_perf83"
    "bench/set_retain_horizon.sh pgpm_perf84"
    "bench/text_time_default_collation.sh pgpm_perf85"
    "bench/regrain_truncate_guard_upgrade.sh pgpm_perf103"
    "bench/retire_detached_unreferenced.sh pgpm_perf105"
    "bench/retain_nan.sh pgpm_perf102"
    "bench/regrain_copy_name_clash.sh pgpm_perf107"
    "bench/write_block_enabled_state.sh pgpm_perf104"
    "bench/regrain_capture_name_fits.sh pgpm_perf91"
    "bench/obtain_explicit_name_too_long.sh pgpm_perf92"
    "bench/obtain_plain_name_too_long.sh pgpm_perf301"
    "bench/config_stamp_lock.sh pgpm_perf101"
    "bench/transmute_reap_lock_timeout.sh pgpm_perf99"
    "bench/hypertable_cutover_lock_timeout.sh pgpm_perf300"
    "bench/grid_floor_exact.sh pgpm_perf308"
    "bench/regrain_drivers_serialize.sh pgpm_perf94"
    "bench/set_partition_tz_midflight.sh pgpm_perf95"
    "bench/set_partition_tz_grid_lock.sh pgpm_perf146"
    "bench/cutover_reread_window.sh pgpm_perf88"
    "bench/reread_under_lock_tap.sh pgpm_perf89"
    "bench/reread_under_lock_remaining_tap.sh pgpm_perf319"
    "bench/frontier_malformed_max.sh pgpm_perf111"
    "bench/transmute_resume_control_column.sh pgpm_perf320"
    "bench/dropped_fk_reconcile.sh pgpm_perf109"
    "bench/regrain_target_shape.sh pgpm_perf97"
    "bench/regrain_target_integral.sh pgpm_perf98"
    "bench/carried_index_quoted_name.sh pgpm_perf312"
    "bench/transmute_identity_options.sh pgpm_perf117"
    "bench/transmute_type_squatter.sh pgpm_perf317"
    "bench/transmute_future_maximum.sh pgpm_perf115"
    "bench/untransmute_security_state.sh pgpm_perf113"
    "bench/untransmute_monolith_identity.sh pgpm_perf114"
    "bench/transmute_uncarriable_shapes.sh pgpm_perf127"
    "bench/transmute_key_deferrability.sh pgpm_perf128"
    "bench/maintain_sweep_reads_tap.sh pgpm_perf138"
    "bench/regrain_reconcile_identity.sh pgpm_perf321"
    "bench/regrain_child_oid_sites.sh pgpm_perf124"
    "bench/retain_recall_armed_detach.sh pgpm_perf145"
    "bench/moved_parent_lifecycle.sh pgpm_perf148"
    "bench/orphan_guard_id_labels.sh pgpm_perf147"
    "bench/reap_and_abort_lock_timeout.sh pgpm_perf149"
    "bench/hypertable_handoff_fk_lock_timeout.sh pgpm_perf150"
    "bench/transmute_refusal_edges.sh pgpm_perf129"
    "bench/reverse_legibility_edges.sh pgpm_perf130"
    "bench/check_newest_skips_nulls.sh pgpm_perf152"
    "bench/time_literal_era.sh pgpm_perf151"
    "bench/doc_log_actions.sh pgpm_perf140"
    "bench/tests_fail_on_defect.sh pgpm_perf141"
    "bench/transmute_type_squatter_other_schema.sh pgpm_perf154"
    "bench/schedule_without_pg_cron.sh pgpm_perf155"
    "bench/untransmute_acl_capture_under_lock.sh pgpm_perf156"
    "bench/retain_recall_moved_parent.sh pgpm_perf157"
    "bench/untransmute_publication_membership.sh pgpm_perf159"
    "bench/transmute_oid_bound_dependants.sh pgpm_perf158"
    "bench/regrain_target_step_spelling.sh pgpm_perf164"
    "bench/regrain_target_column_scale.sh pgpm_perf226"
    "bench/regrain_target_time_precision.sh pgpm_perf266"
    "bench/regrain_survives_parent_ddl.sh pgpm_perf165"
    "bench/ts_text_archive_chunk_transmute_min.sh pgpm_perf169"
    "bench/obtain_lock_budget.sh pgpm_perf166"
    "bench/regrain_clamped_subrange_names.sh pgpm_perf163"
    "bench/cutover_replica_identity.sh pgpm_perf161"
    "bench/cutover_key_name.sh pgpm_perf162"
    "bench/unbuilt_cell_type_holder.sh pgpm_perf170"
    "bench/orphan_type_guard_id_labels.sh pgpm_perf171"
    "bench/wrapper_tap_verdicts.sh pgpm_perf174"
    "bench/transmute_reads_caller_rls.sh pgpm_perf180"
    "bench/regrain_drift_values.sh pgpm_perf178"
    "bench/regrain_capture_follows_key.sh pgpm_perf179"
    "bench/control_column_rename.sh pgpm_perf182"
    "bench/untransmute_drop_dependants.sh pgpm_perf186"
    "bench/transmute_row_type_dependants.sh pgpm_perf187"
    "bench/restore_fk_adopts_live_key.sh pgpm_perf190"
    "bench/untransmute_moved_parent.sh pgpm_perf183"
    "bench/untransmute_index_names.sh pgpm_perf184"
    "bench/untransmute_replica_identity.sh pgpm_perf185"
    "bench/cutover_secondary_unique_constraint.sh pgpm_perf188"
    "bench/cutover_tablespace.sh pgpm_perf189"
    "bench/check_text_time_alphabet_syntax.sh pgpm_perf197"
    "bench/grid_floor_across_era.sh pgpm_perf198"
    "bench/fine_child_label_bc_wide_year.sh pgpm_perf199"
    "bench/archive_step_child_isolation.sh pgpm_perf191"
    "bench/retire_one_step_disarm.sh pgpm_perf192"
    "bench/extend_to_edge_cell_count.sh pgpm_perf193"
    "bench/crossing_keys_datestyle.sh pgpm_perf194"
    "bench/canonical_tz_pseudo_zones.sh pgpm_perf306"
    "bench/transmute_grant_carry_resets_acl.sh pgpm_perf200"
    "bench/regrain_capture_source_grantees.sh pgpm_perf208"
    "bench/regrain_moved_parent_identity.sh pgpm_perf209"
    "bench/regrain_names_fit_clamped_cell.sh pgpm_perf210"
    "bench/regrain_null_source_mark.sh pgpm_perf214"
    "bench/recorded_identity.sh pgpm_perf211"
    "bench/reads_under_caller_rls.sh pgpm_perf215"
    "bench/transmute_non_finite_id_key.sh pgpm_perf221"
    "bench/crossing_keys_control_collation.sh pgpm_perf227"
    "bench/regrain_capture_enabled_always.sh pgpm_perf217"
    "bench/regrain_capture_origin_only_upgrade.sh pgpm_perf218"
    "bench/forget_missing_disarms_detach.sh pgpm_perf219"
    "bench/regrain_fk_drift_swap_scan.sh pgpm_perf225"
    "bench/null_arguments_refused.sh pgpm_perf222"
    "bench/transmute_self_naming_policy.sh pgpm_perf224"
    "bench/retire_crossing_parent_rls.sh pgpm_perf241"
    "bench/regrain_retarget_in_flight.sh pgpm_perf235"
    "bench/regrain_capture_owner_grant.sh pgpm_perf236"
    "bench/untransmute_primary_key_name.sh pgpm_perf231"
    "bench/identity_sequence_name.sh pgpm_perf232"
    "bench/identity_sequence_grants.sh pgpm_perf310"
    "bench/incoming_fk_orphans_match_type.sh pgpm_perf239"
    "bench/regrain_calendar_clamped_name.sh pgpm_perf234"
    "bench/obtain_rebuilds_dropped_cell.sh pgpm_perf238"
    "bench/retain_loop_per_child_isolation.sh pgpm_perf237"
    "bench/acl_grantor_owner_partitions.sh pgpm_perf228"
    "bench/incoming_not_valid_refused.sh pgpm_perf233"
    "bench/write_block_identity.sh pgpm_wbident"
    "bench/retire_identity_unreferenced.sh pgpm_retident"
    "bench/coverage_reset_identity.sh pgpm_covreset"
    "bench/archive_identity_substitution.sh pgpm_archident"
    "bench/guards_run_on_clean_code.sh pgpm_perf249"
    "bench/shared_preflight_conformance.sh pgpm_perf251"
    "bench/scratch_relations.sh pgpm_perf253"
    "bench/replica_identity_index_dropped.sh pgpm_perf262"
    "bench/text_time_collation_proof.sh pgpm_perf261"
    "bench/archive_covered_hi_canonical.sh pgpm_perf260"
    "bench/scratch_sequences.sh pgpm_perf256"
    "bench/hand_over_scratch_reports.sh pgpm_perf265"
    "bench/install_keeps_dependent_views.sh pgpm_perf270"
    "bench/transmute_uncarried_shapes_under_lock.sh pgpm_perf275"
    "bench/text_time_anchor_unit.sh pgpm_perf276"
    "bench/text_time_radix_lower_bound.sh pgpm_perf277"
    "bench/upgrade_unanchored_cell.sh pgpm_perf267"
    "bench/progress_write_child_built.sh pgpm_perf268"
    "bench/obtain_rebuilds_detached_cell.sh pgpm_perf269"
    "bench/uninstall_scratch_by_record.sh pgpm_perf272"
    "bench/transmute_step_precision.sh pgpm_perf284"
    "bench/archive_partition_whole_contract.sh pgpm_perf282"
    "bench/regrain_capture_delta_by_record.sh pgpm_perf289"
    "bench/archive_partition_whole_follows_step.sh pgpm_perf290"
    "bench/regrain_capture_delta_held.sh pgpm_perf294"
    "bench/regrain_children_tablespace.sh pgpm_perf106"
    "bench/regrain_target_encoded_unit.sh pgpm_perf298"
    "bench/regrain_reconcile_judged_rows.sh pgpm_perf299"
    "bench/date_key_anchor_midnight.sh pgpm_perf126"
    "bench/regrain_delta_seq_name.sh pgpm_perf302"
    "bench/archive_covered_hi_column_type.sh pgpm_perf303"
    "bench/regrain_capture_view_writer.sh pgpm_perf304"
    "bench/obtain_backoff_hole.sh pgpm_perf305"
    "bench/check_text_time_contract.sh pgpm_perf309"
    "bench/hypertable_handoff_remedy.sh pgpm_perf311"
    "bench/transmute_cutover_names_held.sh pgpm_perf313"
    "bench/transmute_publication_change_refused.sh pgpm_perf314"
    "bench/adopt_partition.sh pgpm_perf315"
    "bench/write_block_skips_hand_detached.sh pgpm_perf316"
    "bench/bound_contract_remedy.sh pgpm_perf318"
    "bench/liveness_witness_labels.sh pgpm_perf322"
    "bench/transmute_claim_owner_under_set_role.sh pgpm_perf325"
    "bench/retain_horizon_ambiguous_wall_time.sh pgpm_perf326"
  )
  local selected=()
  local n=${#guards[@]} idx
  for ((idx = 0; idx < n; idx++)); do
    if (( idx % SHARD_N == SHARD_I - 1 )); then selected+=("${guards[$idx]}"); fi
  done
  echo ">>> perf track shard ${SHARD_I}/${SHARD_N}: ${#selected[@]} of ${n} guard(s)"
  if [ "${#selected[@]}" -eq 0 ]; then echo "perf track: FAIL (shard ${SHARD_I}/${SHARD_N} selects no guard; a slice that runs nothing verifies nothing)"; return 1; fi
  printf '    %s\n' "${selected[@]}"
  [ -n "$LIST_ONLY" ] && return 0
  $DC --profile "$prof" up -d --wait "$svc"
  psql_run "$prof" "$svc" -q -f /repo/pgpm_core/install.sql >/dev/null
  local rc=0 entry
  for entry in "${selected[@]}"; do
    # shellcheck disable=SC2086  # the entry is three whitespace-separated words by construction
    set -- $entry; bash "$1" "$c" "${@:2}" || rc=1
  done
  $DC --profile "$prof" down -v
  if [ "$rc" -ne 0 ]; then echo "perf track: FAIL"; return 1; fi
  echo "perf track: PASS"
}

# The `discriminate` track: prove the guards above actually catch what they exist for.
#
# A green guard is not evidence -- it is green when the defect is absent, and just as green when the
# guard never observed anything. This repo has shipped the second kind six times. bench/discriminate.sh
# rebuilds install.sql with each defect put back and requires the matching guard to FAIL. It is a
# separate track because it runs every guard a second time and so costs about double the perf track.
run_discriminate() {
  local prof="pg17" svc="postgres17" c="pgpm_test-17"
  # The one archive-scoped mutation (#366) needs the archive track's own image (pgsql-http isn't
  # in the plain core image postgres17 uses) -- brought up alongside, the same way run_archive
  # does. MinIO comes up with it (both share profiles: ["archive"] in docker-compose.yml) but
  # goes unused: the LZ77 memory guard never touches S3.
  local aprof="archive" asvc="archive" ca="pgpm_test-archive"
  # --list needs no container: bringing them up here collided with another harness run on the same
  # machine (the container names are fixed) for a listing that touches no database.
  if [ -n "$LIST_ONLY" ]; then
    bash "$(dirname "$0")/bench/discriminate.sh" "--shard=${SHARD_I}/${SHARD_N}" --list "$c" "$ca"
    return
  fi
  $DC --profile "$prof" up -d --wait "$svc"
  build_image "$aprof" "$asvc"
  pull_third_party "$aprof" minio
  $DC --profile "$aprof" up -d
  wait_pg "$aprof" "$asvc" 60
  local rc=0
  # The instrument first (#601): discriminate.sh must refuse a mutant that does not install and must run
  # every mutation it lists, or every PASS below is suspect. Its own guard runs here rather than in the
  # perf track because it is a check of this track's machinery; once, on the first shard, since each run
  # of it is the same. Its mutations are in the listing like every other guard's.
  if [ "$SHARD_I" = 1 ]; then
    bash "$(dirname "$0")/bench/discriminate_installs.sh" "$c" pgpm_discself || rc=1
  fi
  bash "$(dirname "$0")/bench/discriminate.sh" "--shard=${SHARD_I}/${SHARD_N}" ${LIST_ONLY:+--list} "$c" "$ca" || rc=1
  $DC --profile "$aprof" down -v
  $DC --profile "$prof" down -v
  return "$rc"
}

# The `locktrace` track: OBSERVE a maintenance tick's lock boundaries with eBPF rather than inferring
# them from a reader probe's timeout (issue #383, phases 1 and 2).
#
# Self-contained on purpose: it runs the guard AND its mutation, rather than adding the mutation to
# the shared `discriminate` track. The guard needs eBPF, which needs a privileged container and the
# host's kernel headers -- fine on Linux and on GitHub's runners, structurally impossible on Docker
# Desktop for Mac. Folding it into `discriminate` would make that track, and so `ci`, unrunnable on a
# laptop, which #383 explicitly rules out: the deterministic pg_locks technique stays the local tool
# and tracing is a CI-time confirmation layer. Keeping the mutation in bench/mutations/ and selecting
# it with --track means it is still built, run and required to fail by the same machinery as every
# other guard's -- separated, not exempted.
#
# Not part of `ci` for the same reason. Its own workflow is #383's phase 3.
run_locktrace() {
  local prof="locktrace" svc="locktrace" c="pgpm_test-locktrace"
  echo; echo "========================================="
  echo "Lock-trace track: eBPF lock boundaries (pg17 + bench/lock_probe.py)"
  echo "========================================="
  $DC --profile "$prof" down -v 2>/dev/null || true
  build_image "$prof" "$svc"
  $DC --profile "$prof" up -d
  wait_pg "$prof" "$svc" 60
  local rc=0
  bash "$(dirname "$0")/bench/lock_trace.sh" "$c" pgpm_lt || rc=1
  # Green on correct code is not evidence -- the standing lesson of this repo. Build the same
  # commit-boundary defect maintain_lock.sh's mutant models, and require THIS guard to fail on it.
  bash "$(dirname "$0")/bench/discriminate.sh" --track=locktrace "$c" || rc=1
  $DC --profile "$prof" down -v
  if [ "$rc" -ne 0 ]; then echo "locktrace track: FAIL"; return 1; fi
  echo "locktrace track: PASS"
}

# The `lockview` track: gate the lock-sequence renderer's eBPF CAPTURE half (issue #398).
#
# DIFFERENT IN KIND from `locktrace`, which sits next to it and shares its container. That track
# gates pgpm's own commit boundaries, using bench/lock_probe.py as its instrument. This one asserts
# nothing about pgpm at all -- it gates the INSTRUMENT: that bench/lock_view.py still attaches, still
# filters catalogs in the kernel, still produces a capture the consumer will agree to draw, and --
# the half that matters -- still pairs an aborted lock wait with its OWN request instead of leaving
# it for the next catalog return to steal.
#
# WHY IT EXISTS AT ALL, given the renderer gates no merge and its design spec listed "No CI job"
# among its non-goals. That reasoning holds for the figure and not for the probe. Nothing ships on
# the figure, but an instrument that fabricates a grant tells its reader the confident opposite of
# the truth, and until this track there was nothing between a simplification of those twenty lines
# of BPF C and the defect coming back. The spec's Non-goals section has been amended with this
# reasoning rather than silently contradicted.
#
# Steps 3 and 4 were added after the track first shipped, and the gap they close is worth naming:
# both demos were ALREADY in this workflow's path filter, so editing either one FIRED this job,
# which then went green having never executed the file that changed. That is worse than no gate at
# all -- an absent check is visibly absent, while a green one that ran nothing reads as assurance.
# Every demo named in the filter is now actually run by the track.
#
# FOUR STEPS, and they cover different failures:
#
#   1. bench/lock_view.sh end to end over a real maintain_all() tick. Covers attach, in-kernel
#      filtering, the name snapshots and the format contract. These failures are already loud on
#      their own (an attach error is fatal and named, a missing catalog filter shows up as tens of
#      thousands of events, a malformed capture is refused outright by plot_lock_view.py), so this
#      step's value is running the whole pipeline the way a human actually would, not novel coverage.
#   2. bench/lock_timeout_pairing_demo.sh. THIS is the step that gates the silent defect, and the
#      only step here that would have caught it: the fabricated grant reported
#      {"dropped": 0, "unmatched": 0}, loaded cleanly through the consumer, and was refused by
#      nothing. Measured against a hand-reverted probe (the mutation the demo's own header
#      describes): 2 lock events instead of 1, a fabricated wait_ns of 100541273 against a 100 ms
#      lock_timeout, and unmatched 0 instead of 1 -- three of its six checks flip, while BOTH its
#      liveness witnesses stay green, so the failure is attributable to the defect rather than to a
#      fixture that quietly did nothing.
#   3. bench/lock_view_prefix_demo.sh. Gates the enlistment primer. lock_view.py enlists a backend
#      only on its FIRST touch of a target oid, so a lock that same backend took earlier in the
#      traced statement is invisible, and a truncated prefix renders as a complete sequence with no
#      refusal anywhere to catch it. It needs no mutation because it is self-discriminating by
#      construction: its case 1 runs UNPRIMED and REQUIRES the defect to reproduce against the
#      unmodified probe, so the two cases cannot both pass unless the primer is what made the
#      difference.
#   4. bench/lock_view_names_scope_demo.sh. Gates the schema-scoped managed_parent join in
#      bench/sql/lockview_names.sql: two managed parents sharing a bare relname in different schemas
#      used to fold their children onto whichever parent's row happened to read last,
#      nondeterministically. The one step here needing no eBPF -- it is a plain SQL correctness
#      check -- but it belongs in THIS track regardless, because this is the track whose path filter
#      fires when that query changes. Measured against the join reverted to bare-name-only: both
#      row-count checks go to "got 2, want 1".
#
# THE FIXTURE has to survive plot_lock_view.py's `strong` refusal, which rejects any capture carrying
# no ShareRowExclusive/Exclusive/AccessExclusive mark, on the grounds that "a tick that did nothing
# renders as a calm, correct-looking figure". So it is built to make the MEASURED tick actually drop
# a partition: retain's DROP takes ACCESS EXCLUSIVE on the parent, and that is the strong mark. This
# is deliberate, not incidental -- a fixture with nothing to do would make this track fail on its own
# setup, which is the failure shape hardest to tell apart from a real defect.
run_lockview() {
  local prof="locktrace" svc="locktrace" c="pgpm_test-locktrace" db="lv_ci"
  echo; echo "========================================="
  echo "Lock-view track: eBPF capture for the lock-sequence renderer (pg17 + bench/lock_view.py)"
  echo "========================================="
  $DC --profile "$prof" down -v 2>/dev/null || true
  build_image "$prof" "$svc"
  $DC --profile "$prof" up -d
  wait_pg "$prof" "$svc" 60
  local rc=0

  # matplotlib for bench/plot_lock_view.py, in its own venv (Ruling 8a). A venv rather than a bare
  # pip install because the runner's python may be PEP 668 externally-managed, where installing into
  # it is refused outright. Reused across runs; delete .venv-lockview to force a clean reinstall.
  if [ ! -d .venv-lockview ]; then
    python3 -m venv .venv-lockview
    .venv-lockview/bin/pip install -q matplotlib
  fi

  docker exec "$c" psql -U postgres -q -c "drop database if exists $db" >/dev/null
  docker exec "$c" psql -U postgres -q -c "create database $db" >/dev/null
  docker exec "$c" psql -U postgres -d "$db" -q -v ON_ERROR_STOP=1 -f /repo/pgpm_core/install.sql >/dev/null

  local lvq=(docker exec "$c" psql -U postgres -d "$db" -qtA -c)

  # A managed table whose retention will have something to drop in the measured tick. Small on
  # purpose: unlike bench/lock_trace.sh's fixture, nothing here needs a WIDE window for a probe to
  # land inside -- a trace either contains the strong mark or it does not.
  "${lvq[@]}" "create table public.lv (id bigint primary key, v text)" >/dev/null
  "${lvq[@]}" "insert into public.lv select g, 'x' from generate_series(1,100) g" >/dev/null
  "${lvq[@]}" "call pgpm.transmute('public.lv','id',100000::bigint, p_retain => 100000::bigint, p_paused => false)" >/dev/null

  # One warm-up tick, with nothing yet eligible for retention, so the MEASURED tick below is the
  # first one that drops anything.
  "${lvq[@]}" "call pgpm.maintain_all()" >/dev/null

  # Now advance the frontier past the oldest partition, so retention has a drop to make. The ceiling
  # is read back rather than assumed, since transmute builds the grid during the cutover.
  local hi
  hi=$("${lvq[@]}" "select max(hi::bigint) from pgpm.part where parent_table='public.lv'::regclass")
  "${lvq[@]}" "insert into public.lv values ($((hi-1)), 'advances past the oldest partition')" >/dev/null

  # --- step 1: the whole pipeline, end to end -----------------------------------------------------
  local out
  if out=$(bash "$(dirname "$0")/bench/lock_view.sh" "$c" "$db" 'public.lv' "call pgpm.maintain_all()" ci 2>&1); then
    echo "$out"
    case "$out" in
      *"dropped=0"*) echo "PASS  the capture reports dropped=0" ;;
      *) echo "FAIL  the capture did not report dropped=0"; rc=1 ;;
    esac
    case "$out" in
      *"unmatched=0"*) echo "PASS  the capture reports unmatched=0" ;;
      *) echo "FAIL  the capture did not report unmatched=0"; rc=1 ;;
    esac
  else
    echo "$out"
    echo "FAIL  bench/lock_view.sh did not complete; see the refusal or error above"
    rc=1
  fi

  # --- step 2: the pairing proof, which is the half that discriminates ----------------------------
  if bash "$(dirname "$0")/bench/lock_timeout_pairing_demo.sh" "$c" "$db"; then
    echo "PASS  the request/return pairing proof holds"
  else
    echo "FAIL  the request/return pairing proof did not hold"
    rc=1
  fi

  # --- step 3: the enlistment primer, against a live capture --------------------------------------
  if bash "$(dirname "$0")/bench/lock_view_prefix_demo.sh" "$c" "$db"; then
    echo "PASS  the enlistment primer closes the prefix-loss gap"
  else
    echo "FAIL  the enlistment primer proof did not hold"
    rc=1
  fi

  # --- step 4: the schema-scoped name fold (plain SQL; the one step needing no eBPF) ---------------
  # Given its OWN database, never $db: this demo creates and DROPS the database it is handed, so
  # passing it the track's fixture database would destroy what steps 1 to 3 depend on.
  if bash "$(dirname "$0")/bench/lock_view_names_scope_demo.sh" "$c" lv_scope_ci; then
    echo "PASS  the managed_parent join stays scoped by the parent's own schema"
  else
    echo "FAIL  the schema-scoped name fold proof did not hold"
    rc=1
  fi

  $DC --profile "$prof" down -v
  if [ "$rc" -ne 0 ]; then echo "lockview track: FAIL"; return 1; fi
  echo "lockview track: PASS"
}

if [ "$TRACK" = "perf" ]; then
  run_perf
  echo; echo "All requested tests passed."
  exit 0
fi

if [ "$TRACK" = "locktrace" ]; then
  run_locktrace
  echo; echo "All requested tests passed."
  exit 0
fi

if [ "$TRACK" = "lockview" ]; then
  run_lockview
  echo; echo "All requested tests passed."
  exit 0
fi

if [ "$TRACK" = "discriminate" ]; then
  run_discriminate
  echo; echo "All requested tests passed."
  exit 0
fi

if [ "$TRACK" = "timescale" ]; then
  run_timescale
  echo; echo "All requested tests passed."
  exit 0
fi

if [ "$TRACK" = "observe" ]; then
  run_observe
  echo; echo "All requested tests passed."
  exit 0
fi

if [ "$TRACK" = "archive" ]; then
  run_archive
  echo; echo "All requested tests passed."
  exit 0
fi

# `ci`: everything the CI workflows run, in one invocation, so "green locally" can mean the same thing
# as "green in CI". Every track runs to completion rather than stopping at the first failure, because
# when a core change breaks several you want the whole list.
#
# Each track is a CHILD INVOCATION of this script, not a direct call to its run_* function. Two reasons.
# `cmd || handler` disables errexit for the whole of cmd, including inside a function it calls, and
# several of these functions rely on `set -e` to abort on a failed install step -- so calling them
# directly under `||` would let a broken install run on and report a worse failure, or none. A child
# process re-runs `set -euo pipefail` for itself and keeps that intact. It is also exactly how CI
# invokes them, one track per job, which is the behaviour this target exists to reproduce.
if [ "$TRACK" = "ci" ]; then
  # A string, not an array: macOS ships bash 3.2, where expanding an EMPTY array under `set -u` is an
  # "unbound variable" error -- so the all-passed path would be the one that broke.
  ci_failed=""
  ci_skipped=""
  for v in 15 16 17 18; do "$0" "$v" || ci_failed="$ci_failed pg$v"; done
  for t in timescale observe archive perf discriminate; do
    "$0" "$t" || ci_failed="$ci_failed $t"
  done

  # locktrace needs eBPF: a privileged container AND the host's own kernel headers. That is fine on
  # Linux and on GitHub's runners, and structurally impossible on Docker Desktop for Mac, whose
  # linuxkit VM publishes no headers for its bespoke kernel (#383, confirmed structurally rather than
  # as a missing package). So it runs wherever it can run, and anywhere else it is reported SKIPPED --
  # never silently, and never as passed.
  #
  # The condition is the KERNEL ALONE, deliberately: not a probe for debugfs, headers or privileged
  # containers. A Linux box that cannot actually trace should FAIL here, loudly, because "a guard this
  # never actually ran is unverified" is the rule the rest of this harness already runs on, and a
  # prerequisite check would quietly convert a broken setup into a green run -- the precise failure
  # this repo keeps shipping. Non-Linux is the one case where the track is impossible rather than
  # broken, so it is the one case that skips.
  if [ "$(uname -s)" = "Linux" ]; then
    "$0" locktrace || ci_failed="$ci_failed locktrace"
    "$0" lockview  || ci_failed="$ci_failed lockview"
  else
    ci_skipped=" locktrace and lockview (need Linux; eBPF cannot run on $(uname -s))"
  fi

  echo; echo "========================================="
  if [ -z "$ci_failed" ]; then
    if [ -n "$ci_skipped" ]; then
      # Deliberately NOT folded into the PASS line's meaning: this run did not verify that track, and
      # saying so plainly is the whole point of reporting a skip at all.
      echo "ci: PASS, except SKIPPED --$ci_skipped"
      echo "    Those tracks were NOT verified on this machine. CI does run them on Linux"
      echo "    (.github/workflows/locktrace.yml and lockview.yml), so a PR still covers them."
    else
      echo "ci: PASS (every track CI runs)"
    fi
    echo; echo "All requested tests passed."
    exit 0
  fi
  echo "ci: FAIL --$ci_failed"
  exit 1
fi

if [ "$VERSION" = "all" ]; then
  for v in 15 16 17 18; do run_version "$v"; done
else
  run_version "$VERSION"
fi
echo; echo "All requested tests passed."
