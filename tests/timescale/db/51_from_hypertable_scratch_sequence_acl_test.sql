-- The scratch-relation lever reaches the sequences a scratch relation owns, pgpm_hypertable's half (issue
-- #974, F3-04; tests/272 is the core's).
--
-- from_hypertable_copy(p_track_changes => true) mints its delta <rel>_pgpm_delta owner-only (_scratch_mint,
-- #949), and the delta's `pgpm_seq bigint generated always as identity` column OWNS a sequence,
-- <rel>_pgpm_delta_pgpm_seq_seq, the one the online drains batch by (a pgpm_seq watermark). It was born with
-- the migrating role's ALTER DEFAULT PRIVILEGES and never reset, so a role those name, holding nothing on the
-- hypertable, read the change counter and could setval the sequence, against docs/reference.md's "owned like
-- the hypertable, with no grant beyond the owner's ... from the moment they are created".
--
-- The migrating role (this session, postgres) holds ALTER DEFAULT PRIVILEGES granting ALL on new sequences to
-- w51_stranger, which holds nothing on the hypertable. After a tracking copy, the only sequence the copy
-- created must be the recorded delta's pgpm_seq sequence (a sequence any later scratch relation owns fails
-- here as an omission), owned like the hypertable and granting nothing beyond its owner's; the stranger is
-- refused reading it and refused setval. And the owner-only sequence costs the hypertable's writer nothing:
-- the identity column does not check sequence privileges, so the writer's two writes are captured, with
-- distinct pgpm_seq values, and the cutover carries both. LIVENESS: a sequence this session creates gets the
-- stranger's grant; the copy recorded its delta; the capture logged the writes; m51 was migrated.
--
-- ASYMMETRIC: 30 rows, the writer inserts one (31) and updates one (5), so the delta holds 31, 5, 5.
-- bench/scratch_sequences.sh runs this file against the mutation hypertable_delta_sequence_default_acl,
-- which it must FAIL.
select plan(11);

do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'w51_owner') then create role w51_owner; end if;
  if not exists (select 1 from pg_roles where rolname = 'w51_stranger') then create role w51_stranger; end if;
  if not exists (select 1 from pg_roles where rolname = 'w51_writer') then create role w51_writer; end if;
end $$;
-- by name, never `to current_user` (that segfaults a backend on the fleet image): the migrating role must be a
-- member of the hypertable's owner to give it the copy, and of the others to act as them below
grant w51_owner, w51_writer, w51_stranger to postgres;
grant usage, create on schema public to w51_owner;
grant usage on schema public to w51_stranger, w51_writer;

-- the caller's setval of p_seq back to 1: 'ok' when it went through, the SQLSTATE when it was refused
create function w51_setval(p_seq text) returns text language plpgsql as $f$
begin
  perform setval(p_seq::regclass, 1, false);
  return 'ok';
exception when insufficient_privilege then return sqlstate;
end $f$;
grant execute on function w51_setval(text) to w51_stranger;

-- CREATED as w51_owner rather than handed to it: ALTER ... OWNER on a hypertable re-owns its chunks, which needs
-- CREATE on _timescaledb_internal, which the fleet image's postgres cannot grant (tests/timescale/db/33)
set role w51_owner;
create table public.m51 (ts timestamptz not null, id bigint not null, v int, primary key (id, ts));
select create_hypertable('public.m51', 'ts', chunk_time_interval => interval '1 day');
insert into public.m51 select timestamptz '2024-01-01 00:00+00' + g * interval '2 hours', g, g from generate_series(1, 30) g;
grant insert, update, select on public.m51 to w51_writer;
reset role;

-- the migrating role's default privileges, from here on (Supabase's `grant all on sequences to anon` shape)
alter default privileges in schema public grant all on sequences to w51_stranger;
create sequence public.w51_witness_seq;
select ok(has_sequence_privilege('w51_stranger', 'public.w51_witness_seq', 'UPDATE')
          and not has_table_privilege('w51_stranger', 'public.m51', 'SELECT,INSERT,UPDATE,DELETE'),
  'LIVENESS: a sequence this session creates now grants w51_stranger UPDATE, and w51_stranger holds nothing on m51');
create temp table w51_before as
  select oid from pg_class where relnamespace = 'public'::regnamespace and relkind = 'S';

call pgpm.from_hypertable_copy('public.m51', 'ts', p_track_changes => true);

select s.obj as delta from pgpm.scratch s where s.parent_oid = 'public.m51'::regclass::oid and s.kind = 'hypertable_delta' \gset
select is(:'delta'::oid::regclass::text, 'm51_pgpm_delta',
  'LIVENESS: the tracking copy recorded its delta (hypertable_delta)');
select pg_get_serial_sequence(:'delta'::oid::regclass::text, 'pgpm_seq')::regclass::oid as seq \gset

select is((select array_agg(c.oid order by c.oid) from pg_class c
            where c.relnamespace = 'public'::regnamespace and c.relkind = 'S'
              and c.oid not in (select oid from w51_before)),
  array[:'seq'::oid],
  'the list is complete: the only sequence the copy created is the recorded delta''s pgpm_seq sequence');
select is((select pg_get_userbyid(relowner)::text from pg_class where oid = :'seq'::oid), 'w51_owner',
  'hypertable_delta''s pgpm_seq sequence: owned like the hypertable');
select is((select array_agg(s.oid::regclass::text || ':'
                            || coalesce((select string_agg(distinct pg_get_userbyid(a.grantee)::text, ',')
                                           from aclexplode(s.relacl) a where a.grantee <> s.relowner), '')
                            order by s.oid)
             from pg_depend d join pg_class s on s.oid = d.objid and s.relkind = 'S'
            where d.classid = 'pg_class'::regclass and d.refclassid = 'pg_class'::regclass and d.deptype in ('a', 'i')
              and d.refobjid in (select unnest(o.rels) from pgpm._scratch_objects('public.m51') o)),
  array['m51_pgpm_delta_pgpm_seq_seq:'],
  'every sequence a scratch relation of m51 owns grants nothing beyond its owner''s from the copy on');
select ok(not has_sequence_privilege('w51_stranger', :'seq'::oid, 'SELECT')
          and not has_sequence_privilege('w51_stranger', :'seq'::oid, 'USAGE'),
  'w51_stranger cannot read the delta''s change counter');
set role w51_stranger;
select w51_setval(:'seq'::oid::regclass::text) as setval_by_stranger \gset
reset role;
select is(:'setval_by_stranger'::text, '42501',
  'w51_stranger is refused setval on the sequence the drains batch by');

set role w51_writer;
select lives_ok($$ insert into public.m51 values (timestamptz '2024-01-03 01:00+00', 31, 310) $$,
  'the hypertable''s writer writes during the online window, the owner-only sequence numbering its capture');
update public.m51 set v = -5 where id = 5;
reset role;
select is((select array_agg(id || '@' || dense_rank order by id, dense_rank)
             from (select id, dense_rank() over (order by pgpm_seq) from public.m51_pgpm_delta) d),
  array['5@2', '5@3', '31@1'],
  'LIVENESS: the capture logged both writes, in order, each captured row under its own pgpm_seq');

call pgpm.from_hypertable_cutover('public.m51', 'ts', interval '1 day', p_paused => true);
select is((select relkind::text from pg_class where oid = 'public.m51'::regclass), 'p', 'LIVENESS: m51 was migrated');
select is((select array_agg(id || ':' || v order by id) from public.m51 where id in (4, 5, 6, 30, 31)),
  array['4:4', '5:-5', '6:6', '30:30', '31:310'], 'the migrated table holds the writer''s two writes, and its neighbours');

-- the roles are cluster-wide: leave none behind
alter default privileges in schema public revoke all on sequences from w51_stranger;
drop sequence public.w51_witness_seq;
drop owned by w51_owner, w51_stranger, w51_writer;
drop role w51_owner;
drop role w51_stranger;
drop role w51_writer;

select * from finish();
