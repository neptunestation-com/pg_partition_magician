-- A bare unique index that an incoming foreign key references is still a bare index: transmute refuses it with
-- the promote-it-to-a-constraint remedy (#792), not as a keyless table whose incoming keys cannot be kept
-- (issue #1333, bullets 4 and 5).
--
-- pgpm._transmute_bare_unique decided "backs no constraint" by asking whether any pg_constraint row carried the
-- index as its conindid, and an incoming FOREIGN KEY's row carries the referenced index there. So a keyless table
-- whose only key was a bare unique index on (id, ts) read as having no bare index once a foreign key referenced
-- it: transmute fell through as keyless and _transmute_incoming_gate refused with remedies that do not work
-- ('error' said re-run with 'preserve', and 'preserve' and 'drop' both said the parent's reused key is ()).
-- pgpm_hypertable's cutover asks the same function under its lock (_from_hypertable_check_key), where the same
-- read let the swap commit before transmute refused, leaving a plain unmanaged table (bullet 4). Now only a
-- primary key or unique constraint OF THE TABLE backs the index, the reading #1266 gave the hypertable copy.
--
-- Fixtures, asymmetric: e381 (rows 3, 9 and 21) is referenced through its bare index by r381; f381 (rows 4 and 6)
-- has the same index and no incoming key, the witness that the refusal is the one a bare index gets anyway.
-- bench/transmute_state_reads.sh runs this file against the mutant that reads the index alone again.
create extension if not exists pgtap;
set client_min_messages = warning;
select plan(9);

create table public.e381 (id bigint not null, ts timestamptz not null, body text);
create unique index e381_uq on public.e381 (id, ts);
insert into public.e381 values (3, now() - interval '3 days', 'c'), (9, now() - interval '2 days', 'i'),
                               (21, now() - interval '1 day', 'u');
create table public.r381 (eid bigint, ets timestamptz, foreign key (eid, ets) references public.e381 (id, ts));
insert into public.r381 select id, ts from public.e381 where id = 9;
create table public.f381 (id bigint not null, ts timestamptz not null, body text);
create unique index f381_uq on public.f381 (id, ts);
insert into public.f381 values (4, now() - interval '4 days', 'd'), (6, now() - interval '1 day', 'f');

select ok(exists (select 1 from pg_constraint where conrelid = 'public.r381'::regclass and contype = 'f'
                     and conindid = 'public.e381_uq'::regclass)
          -- not "no constraint of e381 at all": PostgreSQL 18 records each NOT NULL column as a pg_constraint row of
          -- contype 'n' (conindid 0), so the premise names what it means, no key of e381 and none on its index
          and not exists (select 1 from pg_constraint where conrelid = 'public.e381'::regclass
                             and (contype in ('p', 'u') or conindid = 'public.e381_uq'::regclass)),
  'LIVENESS: r381''s foreign key carries e381''s bare index as its conindid, and no key of e381 sits on it');

select throws_like(
  $$ call pgpm.transmute('public.f381', 'ts', interval '1 day') $$,
  'pg_partition_magician: cannot transmute f381 on ts -- the unique index f381_uq includes the control column but is a bare index, not a constraint%',
  'LIVENESS: a bare unique index with no incoming key is refused with the promote-it remedy');
select throws_like(
  $$ call pgpm.transmute('public.e381', 'ts', interval '1 day') $$,
  'pg_partition_magician: cannot transmute e381 on ts -- the unique index e381_uq includes the control column but is a bare index, not a constraint%',
  'an incoming foreign key on the bare index does not hide it: the default mode gets the promote-it remedy');
select throws_like(
  $$ call pgpm.transmute('public.e381', 'ts', interval '1 day', p_incoming_fks => 'preserve') $$,
  'pg_partition_magician: cannot transmute e381 on ts -- the unique index e381_uq includes the control column but is a bare index, not a constraint%',
  'p_incoming_fks => preserve gets the promote-it remedy, not "the parent''s reused key is ()"');
select throws_like(
  $$ call pgpm.transmute('public.e381', 'ts', interval '1 day', p_incoming_fks => 'drop') $$,
  'pg_partition_magician: cannot transmute e381 on ts -- the unique index e381_uq includes the control column but is a bare index, not a constraint%',
  'p_incoming_fks => drop gets the promote-it remedy, not a refusal naming the preserve mode');
select is(
  (select relkind::text from pg_class where oid = 'public.e381'::regclass)
  || '/' || (select string_agg(id::text, ',' order by id) from public.e381)
  || '/' || (select count(*) from pg_constraint where conrelid = 'public.r381'::regclass and contype = 'f'),
  'r/3,9,21/1', 'invariant: e381 is still the plain table holding 3,9,21, and r381 keeps its foreign key');

-- the remedy the refusal names, then the conversion it unblocks
alter table public.e381 add constraint e381_uq_key unique using index e381_uq;
call pgpm.transmute('public.e381', 'ts', interval '1 day', p_obtain => 1, p_incoming_fks => 'preserve',
                    p_paused => false);
select is((select relkind::text from pg_class where oid = 'public.e381'::regclass), 'p',
  'LIVENESS: promoted to a constraint, as the refusal says, the index lets e381 convert keeping its incoming key');
select is((select string_agg(id::text, ',' order by id) from public.e381), '3,9,21',
  'LIVENESS: the converted e381 holds 3,9,21');
select pgpm.restore_incoming_fks('public.e381');
select is((select string_agg(conname, ',') from pg_constraint where conrelid = 'public.r381'::regclass and contype = 'f'
             and confrelid = 'public.e381'::regclass), 'r381_eid_ets_fkey',
  'LIVENESS: preserved, r381''s foreign key is back, referencing the partitioned e381');

select * from finish();
