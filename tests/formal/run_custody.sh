#!/usr/bin/env bash
# Run custody test files with the invariant oracle installed, and read what it judged (Phase 3 W3,
# docs/formal/phase3-design.md). Each file runs as its track runs it in test.sh, then, in the same database:
#   select * from pgpm_formal.check()     the violations no expect() declared, and the unused declarations
#   select * from pgpm_formal.judged()    per invariant: judged or not, over how many parents and identities
#
#   tests/formal/run_custody.sh <container> <core|archive|timescale> <outdir> [file ...]
#   default files: the track's entries in tests/formal/custody_files.txt (comments and blank lines skipped)
#
# The container mounts this repository at /repo:
#   core       docker run -d --name <c> --shm-size 1g -e POSTGRES_PASSWORD=postgres -v "$PWD":/repo:ro pgpm_test:17
#              (pg_cron is preloaded there: tests/78 runs on `postgres`, as test.sh runs it)
#   archive    pgpm_test:17-archive on a network where MinIO answers as `minio:9000` with the bucket
#              archive-test-bucket made (test.sh's run_archive shows how)
#   timescale  public.ecr.aws/supabase/postgres:15.14.1.127 (psql over 127.0.0.1, password postgres)
#
# Writes <outdir>/<file>.tap (the file's own output), <file>.check and <file>.judged (tab separated), and one
# summary row per file to <outdir>/summary.tsv and stdout:
#   file  result  violations  unused  NoLostRow  NoDuplicateRow  DropOnlyCovered  ArchiveNoClobber  ResolveByRecord  NoWedge
# where result is PASS or FAIL (the file's own verdict, as its track's runner reads it) and each invariant column is
# `<identities judged>` or `-` when it was not judged. Exit status is nonzero when any file FAILED its own
# assertions; violations are reported, never failed on (W6 judges them first: the design note's "report first").
set -uo pipefail

c="${1:?usage: run_custody.sh <container> <core|archive|timescale> <outdir> [file ...]}"
track="${2:?track: core, archive or timescale}"
out="${3:?outdir}"
shift 3
cd "$(dirname "$0")/../.." || exit 2
mkdir -p "$out"

# shellcheck source=tests/formal/lib.sh
source tests/formal/lib.sh
if [ "$track" = timescale ]; then
  q() { docker exec -i -e PGPASSWORD=postgres -e PGOPTIONS='-c client_min_messages=warning' "$c" psql -h 127.0.0.1 -U postgres -d "${DB:-postgres}" -v ON_ERROR_STOP=1 -qtA "$@"; }
fi

files=("$@")
if [ "${#files[@]}" -eq 0 ]; then
  case "$track" in
    core) pat='^tests/[0-9]' ;;
    archive) pat='^tests/archive/db/' ;;
    timescale) pat='^tests/timescale/db/' ;;
    *) echo "unknown track $track" >&2; exit 2 ;;
  esac
  while IFS= read -r f; do files+=("$f"); done < <(sed -E 's/[[:space:]]*#.*$//' tests/formal/custody_files.txt | grep -E "$pat" | sort -V)
fi

tmpl=pgpm_fx3_tmpl
case "$track" in
  core)
    build_template "$tmpl" 1 ;;
  archive)
    q -c "drop database if exists $tmpl" >/dev/null
    q -c "create database $tmpl" >/dev/null
    DB="$tmpl" q -c "create extension if not exists http; create extension if not exists pgcrypto; create extension if not exists pgtap;" >/dev/null
    DB="$tmpl" q -f /repo/tests/archive/fixtures.sql >/dev/null
    DB="$tmpl" q --single-transaction -f /repo/pgpm_core/install.sql >/dev/null
    DB="$tmpl" q -f /repo/pgpm_archive/install.sql >/dev/null
    DB="$tmpl" q -f /repo/tests/formal/oracle.sql >/dev/null ;;
esac

pg_ready=""
setup_postgres() {  # tests/78 runs on `postgres` (pg_cron's database), as test.sh runs it
  [ -n "$pg_ready" ] && return
  q -c "create extension if not exists pg_cron; create extension if not exists pgtap;" >/dev/null
  q --single-transaction -f /repo/pgpm_core/install.sql >/dev/null
  q -c "alter database postgres set poc.seed_count = 8000; alter database postgres set poc.events_count = 4000;" >/dev/null
  q -f /repo/fixtures/demo.sql >/dev/null
  q -f /repo/tests/formal/oracle.sql >/dev/null
  pg_ready=1
}

printf 'file\tresult\tviolations\tunused\tNoLostRow\tNoDuplicateRow\tDropOnlyCovered\tArchiveNoClobber\tResolveByRecord\tNoWedge\n' >"$out/summary.tsv"
rc_all=0
n=0
for f in "${files[@]}"; do
  n=$((n + 1)); b=$(basename "$f" .sql); db="pgpm_fx3_$n"
  case "$track" in
    core)
      if [ "$b" = 78_retain_detach_dispatch_test ]; then
        setup_postgres; db=postgres
      else
        q -c "drop database if exists $db" >/dev/null
        q -c "create database $db template $tmpl" >/dev/null
      fi ;;
    archive)
      q -c "drop database if exists $db" >/dev/null
      q -c "create database $db template $tmpl" >/dev/null ;;
    timescale)
      q -c "drop database if exists $db" -c "create database $db" -c "alter database $db set client_min_messages = warning" >/dev/null
      DB="$db" q -c "create extension if not exists timescaledb; create extension if not exists pgtap;" >/dev/null
      DB="$db" q --single-transaction -f /repo/pgpm_core/install.sql >/dev/null
      DB="$db" q -f /repo/pgpm_hypertable/install.sql >/dev/null
      DB="$db" q -f /repo/tests/timescale/fixtures.sql >/dev/null
      DB="$db" q -f /repo/tests/formal/oracle.sql >/dev/null ;;
  esac
  if [ "$track" = timescale ]; then
    # the timescale runner's verdict (test.sh run_timescale): psql -tAq, its exit status, the plan against what ran
    rc=0; tap=$(docker exec -i -e PGPASSWORD=postgres "$c" psql -h 127.0.0.1 -U postgres -d "$db" -tAq -f "/repo/$f" 2>&1) || rc=$?
    printf '%s\n' "$tap" >"$out/$b.tap"
    planned=$(printf '%s\n' "$tap" | sed -nE 's/^1\.\.([0-9]+)$/\1/p' | head -1 || true)
    ran=$(printf '%s\n' "$tap" | grep -cE '^(not )?ok [0-9]+( |$)' || true)
    if [ "$rc" != 0 ] || printf '%s\n' "$tap" | grep -qE '^not ok|^# Looks like you (failed|planned)|ERROR:' \
       || [ -z "$planned" ] || [ "$ran" != "$planned" ]; then res=FAIL; else res=PASS; fi
  else
    if docker exec "$c" pg_prove -v -U postgres -d "$db" "/repo/$f" >"$out/$b.tap" 2>&1; then res=PASS; else res=FAIL; fi
  fi
  [ "$res" = PASS ] || rc_all=1
  DB="$db" q -F $'\t' -c "select invariant, coalesce(parent_table::text, ''), identity, detail from pgpm_formal.check() order by 1, 3" \
    >"$out/$b.check" 2>&1 || echo "check() raised" >>"$out/$b.check"
  DB="$db" q -F $'\t' -c "select invariant, judged, parents, identities, expected, coalesce(note, '') from pgpm_formal.judged()" \
    >"$out/$b.judged" 2>&1 || echo "judged() raised" >>"$out/$b.judged"
  viol=$(grep -cvE '^UnusedExpectation|^$' "$out/$b.check" || true)
  unused=$(grep -c '^UnusedExpectation' "$out/$b.check" || true)
  cols=$(awk -F'\t' '{ v[$1] = ($2 == "t" ? $4 : "-") }
                     END { printf "%s\t%s\t%s\t%s\t%s\t%s", v["NoLostRow"], v["NoDuplicateRow"], v["DropOnlyCovered"],
                                  v["ArchiveNoClobber"], v["ResolveByRecord"], v["NoWedge"] }' "$out/$b.judged")
  printf '%s\t%s\t%s\t%s\t%s\n' "$f" "$res" "$viol" "$unused" "$cols" | tee -a "$out/summary.tsv"
  if [ "$db" != postgres ]; then q -c "drop database if exists $db" >/dev/null 2>&1 || true; fi
done
if [ "$track" != timescale ]; then q -c "drop database if exists $tmpl" >/dev/null 2>&1 || true; fi
exit "$rc_all"
