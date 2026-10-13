-- P1-01: the review tree ships adopt_partition's isolation refusal as dead code (`if false then raise ...`,
-- pgpm_core/install.sql:14022), the exact shape the PR body describes for its own mutation
-- adopt_partition_strict_isolation_admitted. The body, CHANGELOG and docs/reference.md all say the call
-- "refuses any transaction stricter than READ COMMITTED as its first statement". It does not: a SERIALIZABLE
-- caller is admitted, and a REPEATABLE READ caller whose snapshot predates a committed DETACH records the
-- detached table in pgpm.part as a partition of the parent (the #1262 defect, F4-03/F11-03, unfixed).
-- Asymmetric: y holds 1010 and 1020 and is detached; z holds 1111 alone and is untouched.
create extension if not exists pgtap;
create extension if not exists dblink;
set client_min_messages = warning;
select plan(8);

create table public.p101 (id bigint primary key, payload text);
insert into public.p101 values (150, 'a');
call pgpm.transmute('public.p101', 'id', 100::bigint, p_obtain => 1, p_paused => false);
create table public.p101_y partition of public.p101 for values from (1000) to (1100);
create table public.p101_z partition of public.p101 for values from (1100) to (1200);
insert into public.p101 values (1010, 'y'), (1020, 'y'), (1111, 'z');
select 'public.p101_y'::regclass::oid as y_oid, 'public.p101_z'::regclass::oid as z_oid \gset
select is((select string_agg(child_name, ',') from pgpm.part where child_oid in (:y_oid, :z_oid)), null,
  'LIVENESS: pgpm.part records neither y nor z');
select dblink_connect('o101', 'dbname=' || current_database()) as o101 \gset

-- (1) SERIALIZABLE, nothing concurrent: the documented refusal, before any lock
begin isolation level serializable;
select is(current_setting('transaction_isolation'), 'serializable', 'LIVENESS: this transaction is serializable');
select throws_like($$ select pgpm.adopt_partition('public.p101', 'public.p101_z') $$,
  '%must run in a READ COMMITTED transaction%',
  'a SERIALIZABLE caller is refused, naming the remedy');
commit;
select is((select string_agg(child_name, ',') from pgpm.part where child_oid = :z_oid), null,
  'nothing is recorded for z by a refused call');

-- (2) REPEATABLE READ, a DETACH of y committed after this snapshot: the consequence of admitting the level
begin isolation level repeatable read;
select count(*) as snap from pgpm.config \gset
select dblink_exec('o101', 'alter table public.p101 detach partition public.p101_y') as detached \gset
select ok(exists (select 1 from pg_inherits where inhrelid = :y_oid)
          and (select x from dblink('o101', format('select count(*)::int from pg_inherits where inhrelid = %s', :y_oid)) as t(x int)) = 0,
  'LIVENESS: the detach committed and this transaction''s snapshot still shows y attached');
select throws_like($$ select pgpm.adopt_partition('public.p101', 'public.p101_y') $$,
  '%must run in a READ COMMITTED transaction%',
  'a REPEATABLE READ caller is refused, naming the remedy');
commit;
select is((select string_agg(child_name || ' attached=' || attached, ',') from pgpm.part where child_oid = :y_oid), null,
  'pgpm.part records nothing for y, which is not a partition of p101');
select is((select string_agg(id::text, ',' order by id) from public.p101_y), '1010,1020',
  'LIVENESS: the detached table keeps 1010 and 1020 outside the parent');
select dblink_disconnect('o101') as gone \gset
select * from finish();
