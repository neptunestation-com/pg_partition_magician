-- from_hypertable migrates a hypertable whose columns own sequences, and keeps those sequences (issue #839).
--
-- THE BUG. from_hypertable_copy builds the copy with CREATE TABLE ... LIKE INCLUDING DEFAULTS, so a serial
-- column's default on the copy is nextval() of the sequence the SOURCE's column owns. Nothing moved that
-- ownership, so the cutover's DROP TABLE of the source failed with "cannot drop table ... because other
-- objects depend on it" after the whole online copy, every time: a hypertable with a serial column could
-- not be migrated at all. A sequence owned through a column that no default names was dropped with the
-- source, silently. The swap now lets go of every sequence the source owns before the DROP and hands each
-- to the same column of the table renamed into its place, once the swap has carried the source's owner.
--
-- ASYMMETRIC FIXTURE. Three owned sequences, each told apart by its column and its position: id serial,
-- issued past the rows kept (23 issued, 21 to 23 deleted, so a fresh sequence would give 1 and max(id) + 1
-- would give 21, and only the source's own gives 24); n bigserial, moved to 1000 (next 1001); and s39_aux,
-- OWNED BY v and named by no default. The table belongs to a third role, t39_owner, not to the migrating
-- one, because OWNED BY needs the sequence and the table to share an owner, and the copy need not share the
-- source's until the swap carries it: a hand-over made before that is refused. The copy is minted owned like
-- the hypertable (#949), but a hypertable handed to a new owner during the online window leaves the copy with
-- the old one; the fleet image cannot re-own a hypertable as postgres, so the copy is given to the migrating
-- role between the two phases instead, which is the same shape at the cutover.
-- IDENTITY, not cardinality: the sequences are compared by oid before and after, and the rows by value.
--
-- Autocommit, disposable-db: the copy and the cutover commit, so each is called as a bare statement. On a tree with
-- the defect it raises the raw 2BP01, which the harness fails on, and the assertions after it fail too.
select plan(10);

do $$ begin
  if not exists (select 1 from pg_roles where rolname = 't39_owner') then create role t39_owner; end if;
end $$;
-- The migrating role (postgres) is not a superuser on the fleet image; it migrates a table t39_owner owns as
-- a member of that role, as tests/timescale/db/33 does. Named, not CURRENT_USER: the fleet image's GRANT
-- hook crashes the backend on that role spec. Created as t39_owner, because ALTER ... OWNER on a hypertable
-- re-owns its chunks, which needs CREATE on _timescaledb_internal.
grant t39_owner to postgres;
grant create on schema public to t39_owner;

set role t39_owner;
create table public.s39 (id serial, ts timestamptz not null, n bigserial, v int, primary key (id, ts));
select create_hypertable('public.s39', 'ts', chunk_time_interval => interval '1 day');
create sequence public.s39_aux owned by public.s39.v;
insert into public.s39 (ts, v)
select timestamptz '2026-09-01 00:00+00' + g * interval '3 hours', g from generate_series(1, 23) g;
reset role;
delete from public.s39 where id > 20;
select setval(pg_get_serial_sequence('public.s39', 'n'), 1000);

-- The sequences by oid, kept in a table so the comparison after the migration is by identity.
create table public.s39_before as
select a.attname::text as col, d.objid as seq
  from pg_depend d
  join pg_class s on s.oid = d.objid and s.relkind = 'S'
  join pg_attribute a on a.attrelid = d.refobjid and a.attnum = d.refobjsubid
 where d.classid = 'pg_class'::regclass and d.refclassid = 'pg_class'::regclass
   and d.refobjid = 'public.s39'::regclass and d.refobjsubid > 0 and d.deptype = 'a';

-- ================= WITNESSES: the shape the defect needs =================
select is(
  (select string_agg(col || ':' || seq::regclass::text, ',' order by col) from public.s39_before),
  'id:s39_id_seq,n:s39_n_seq,v:s39_aux',
  'WITNESS: the hypertable owns three sequences, through id, n and v');
select is(
  (select string_agg(c.relname || ':' || pg_get_userbyid(c.relowner), ',' order by c.relname) from pg_class c
    where c.oid in ('public.s39'::regclass, 'public.s39_id_seq'::regclass)),
  's39:t39_owner,s39_id_seq:t39_owner',
  'WITNESS: the table and its sequences belong to t39_owner, not to the migrating role');
select is(
  (select string_agg(sequencename || ':' || coalesce(last_value::text, 'unused'), ',' order by sequencename)
     from pg_sequences where schemaname = 'public' and sequencename like 's39%'),
  's39_aux:unused,s39_id_seq:23,s39_n_seq:1000',
  'WITNESS: id issued 23 with 20 kept, n stands at 1000, s39_aux was never used');

call pgpm.from_hypertable_copy('public.s39', 'ts');
alter table public.s39_pgpm_dest owner to postgres;   -- the copy's owner drifts from the source's (see the header)
select is((select pg_get_userbyid(relowner)::text from pg_class where oid = 'public.s39_pgpm_dest'::regclass), 'postgres',
  'WITNESS: at the cutover the copy belongs to another role than the source and its sequences');
call pgpm.from_hypertable_cutover('public.s39', 'ts', interval '1 day', p_paused => true);

-- ================= THE CONTRACT =================
select is(
  (select relkind::text || ':' || pg_get_userbyid(relowner) from pg_class where oid = 'public.s39'::regclass)
    || ' ' || (select count(*) from pgpm.config where parent_table = 'public.s39'::regclass),
  'p:t39_owner 1', 'the hypertable was migrated: a partitioned table, still t39_owner''s, registered with pgpm');
select is(
  (select string_agg(id || ':' || n || ':' || v, ',' order by id) from public.s39),
  (select string_agg(g || ':' || g || ':' || g, ',' order by g) from generate_series(1, 20) g),
  'every row came across, by value');
select is(
  (select relkind::text from pg_class where oid = 'public.s39'::regclass) || ' '
    || (select string_agg(a.attname || ':' || d.objid, ',' order by a.attname)
          from pg_depend d
          join pg_class s on s.oid = d.objid and s.relkind = 'S'
          join pg_attribute a on a.attrelid = d.refobjid and a.attnum = d.refobjsubid
         where d.classid = 'pg_class'::regclass and d.refclassid = 'pg_class'::regclass
           and d.refobjid = 'public.s39'::regclass and d.refobjsubid > 0 and d.deptype = 'a'),
  'p ' || (select string_agg(col || ':' || seq, ',' order by col) from public.s39_before),
  'the same three sequences, by oid, are owned through the same columns of the migrated table');
select is(
  (select pg_get_serial_sequence('public.s39', 'id')::regclass::oid) || ',' || (select pg_get_serial_sequence('public.s39', 'n')::regclass::oid),
  (select string_agg(seq::text, ',' order by col) from public.s39_before where col in ('id', 'n')),
  'and the defaults of id and n still call them');

insert into public.s39 (ts, v) values (timestamptz '2026-09-02 07:00+00', 99);
select is(
  (select id || ':' || n from public.s39 where v = 99), '24:1001',
  'the migrated table issues the source''s next values: id 24 (not 1, not max(id) + 1) and n 1001');
select is(
  (select pg_get_userbyid(c.relowner) from pg_class c where c.oid = to_regclass('public.s39_aux')),
  't39_owner', 's39_aux, which no default names, was not dropped with the source');

select * from finish();
-- no teardown: the harness runs each db/ test in a throwaway database (disposable-db).
