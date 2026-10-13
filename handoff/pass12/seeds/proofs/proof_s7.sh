#!/bin/bash
# proof_s7.sh <tree> <db>: the untransmute entry's remedy for an interrupted concurrent detach, typed as the document says
T=$1; DB=$2; P="docker exec -i pgpm_test-15 psql -U postgres"
$P -q -c "drop database if exists $DB" >/dev/null 2>&1; $P -q -c "create database $DB" >/dev/null
$P -d $DB -q -v ON_ERROR_STOP=1 -f - < $T/pgpm_core/install.sql >/dev/null 2>&1 || echo "INSTALL FAILED"
remedy=$(sed -n '/^It refuses, the same two ways, while a partition of the managed table is pending/,/then re-run/p' $T/docs/reference.md | grep -oE '`ALTER TABLE <table> DETACH PARTITION <partition>[^`]*`' | head -1 | tr -d '`')
echo "R remedy_text=$remedy"
stmt=$(echo "$remedy" | sed 's/<table>/public.t/; s/<partition>/public.c/')
$P -d $DB -tA -v ON_ERROR_STOP=1 -f - <<SQL
set client_min_messages = warning;
create extension if not exists dblink;
create table public.t (id int primary key) partition by range (id);
create table public.c partition of public.t for values from (0) to (10);
create table public.d partition of public.t for values from (10) to (20);
insert into public.t values (1), (11);
-- a reader holds a snapshot of the parent in another session, so the detach's second transaction waits; its wait is cut short, which leaves the partition pending
select dblink_connect('r', 'dbname=' || current_database());
select dblink_exec('r', 'begin isolation level repeatable read');
select * from dblink('r', 'select count(*) from public.t') as x(n bigint);
select dblink_connect('d', 'dbname=' || current_database());
select dblink_exec('d', 'set statement_timeout = 1500');
select 'R detach=' || coalesce((select dblink_exec('d', 'alter table public.t detach partition public.c concurrently')), 'null');
SQL
$P -d $DB -tA -f - <<SQL
select 'R pending=' || (select inhdetachpending from pg_inherits where inhrelid = 'public.c'::regclass);
SQL
echo "R typed=[$stmt]"
out=$($P -d $DB -tA -c "$stmt" 2>&1); echo "R remedy_result=$(echo "$out" | head -2 | tr '\n' ' ')"
$P -d $DB -tA -c "select 'R still_pending=' || coalesce((select inhdetachpending::text from pg_inherits where inhrelid = 'public.c'::regclass), 'detached')"
$P -q -c "drop database if exists $DB" >/dev/null 2>&1
