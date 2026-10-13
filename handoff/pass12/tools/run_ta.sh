#!/bin/bash
# usage: TREE=<tree> [CONTAINER=pgpm_test-15] run.sh <db> <repro.sql> [install files...]; prints the psql output and exit=N
T=${TREE:?}; DB=$1; R=$2; shift 2
C=${CONTAINER:-pgpm_test-15}
if [ "$C" = pgpm_test-timescale ]; then P=(docker exec -i -e PGPASSWORD=postgres $C psql -h 127.0.0.1 -U postgres); else P=(docker exec -i $C psql -U postgres); fi
"${P[@]}" -q -c "drop database if exists $DB" >/dev/null 2>&1
"${P[@]}" -q -c "create database $DB" >/dev/null
if [ "$C" = pgpm_test-archive ]; then "${P[@]}" -d $DB -q -c "create extension if not exists http; create extension if not exists pgcrypto; create extension if not exists pgtap;" >/dev/null; fi
if [ "$C" = pgpm_test-timescale ]; then "${P[@]}" -d $DB -q -c "create extension if not exists timescaledb; create extension if not exists pgtap;" >/dev/null 2>&1; fi
for f in ${@:-pgpm_core/install.sql}; do "${P[@]}" -d $DB -q -v ON_ERROR_STOP=1 -f - < $T/$f > /dev/null 2>&1 || echo "INSTALL FAILED $f"; done
"${P[@]}" -d $DB -tA -v ON_ERROR_STOP=1 -f - < $R; echo "exit=$?"
"${P[@]}" -q -c "drop database if exists $DB" >/dev/null 2>&1
