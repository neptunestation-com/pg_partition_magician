#!/bin/bash
# usage: TREE=<tree> [CONTAINER=pgpm_test-15] run_sh.sh <db> <repro.sh> [install files...]: runs a repro.sh with PSQL, TREE, DB, CONTAINER set
T=${TREE:?}; DB=$1; R=$2; shift 2
C=${CONTAINER:-pgpm_test-15}
if [ "$C" = pgpm_test-timescale ]; then P="docker exec -i -e PGPASSWORD=postgres $C psql -h 127.0.0.1 -U postgres"; else P="docker exec -i $C psql -U postgres"; fi
$P -q -c "drop database if exists $DB" >/dev/null 2>&1; $P -q -c "create database $DB" >/dev/null
if [ "$C" = pgpm_test-archive ]; then $P -d $DB -q -c "create extension if not exists http; create extension if not exists pgcrypto; create extension if not exists pgtap;" >/dev/null; fi
for f in ${@:-pgpm_core/install.sql}; do $P -d $DB -q -v ON_ERROR_STOP=1 -f - < $T/$f > /dev/null 2>&1 || echo "INSTALL FAILED $f"; done
PSQL="$P -d $DB" TREE=$T DB=$DB CONTAINER=$C bash $R; echo "exit=$?"
$P -q -c "drop database if exists $DB" >/dev/null 2>&1
