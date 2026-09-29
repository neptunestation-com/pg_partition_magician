-- Issue #573: transmute left a serial column's sequence OWNED BY the original table, which the cutover
-- renames into the monolith child, while the new parent's column default (copied by CREATE TABLE ... LIKE
-- INCLUDING DEFAULTS) goes on calling nextval on it. DROP TABLE of the aged-out monolith then fails with
-- "other objects depend on it" (the parent's default needs the sequence the monolith would take with it),
-- so retention logged fail_retain_drop on every tick and the monolith could never be retired. The cutover
-- now moves every sequence owned by a column of the table onto the same column of the new parent, and
-- untransmute moves it back before it drops the parent (dropping the parent would otherwise drop the
-- sequence the restored table's default still calls).
--
-- Fixture asymmetry: TWO serial columns (the key and a second counter) so that moving only the first,
-- or only the one pg_get_serial_sequence happens to be asked about, fails by name; and a third sequence
-- the table's default calls but does NOT own, which must stay unowned (the move is of ownership the table
-- had, not of every sequence its defaults touch). Every claim about the monolith being dropped comes with
-- a witness that retention really reached past it.
create extension if not exists pgtap;

select plan(16);

create sequence public.free573_seq;
create table public.s573 (id bigserial primary key, n serial, f bigint not null default nextval('public.free573_seq'), v text);
insert into public.s573 (v) select 'old' from generate_series(1, 15);   -- ids 1..15 -> monolith [0, 20)

-- ============================================== before: what there is to move
select is(
  (select array_agg(s.relname || ':' || a.attname order by s.relname) from pg_depend d
     join pg_class s on s.oid = d.objid and s.relkind = 'S'
     join pg_attribute a on a.attrelid = d.refobjid and a.attnum = d.refobjsubid
    where d.classid = 'pg_class'::regclass and d.refclassid = 'pg_class'::regclass
      and d.refobjid = 'public.s573'::regclass and d.deptype = 'a'),
  array['s573_id_seq:id', 's573_n_seq:n'],
  'LIVENESS: before the conversion the table owns exactly its two serial sequences');

call pgpm.transmute('public.s573', 'id', 10::bigint, p_retain => 1::bigint, p_obtain => 3);

select is((select relkind::text from pg_class where oid = 'public.s573'::regclass), 'p',
  'LIVENESS: the table really was converted');
select ok(to_regclass('public.s573_p0000000000000000000_to_0000000000000000020') is not null,
  'LIVENESS: the conversion made the monolith s573_p..0_to_..20');

-- ============================================== after the cutover: the parent owns them
select is(
  (select array_agg(s.relname || ':' || a.attname order by s.relname) from pg_depend d
     join pg_class s on s.oid = d.objid and s.relkind = 'S'
     join pg_attribute a on a.attrelid = d.refobjid and a.attnum = d.refobjsubid
    where d.classid = 'pg_class'::regclass and d.refclassid = 'pg_class'::regclass
      and d.refobjid = 'public.s573'::regclass and d.deptype = 'a'),
  array['s573_id_seq:id', 's573_n_seq:n'],
  'the new parent owns both serial sequences, each through the same column');
select ok(
  not exists (select 1 from pg_depend d join pg_class s on s.oid = d.objid and s.relkind = 'S'
               where d.classid = 'pg_class'::regclass and d.refclassid = 'pg_class'::regclass
                 and d.refobjid = 'public.s573_p0000000000000000000_to_0000000000000000020'::regclass
                 and d.deptype = 'a'),
  'the monolith owns no sequence');
select is(
  (select count(*)::int from pg_depend d where d.classid = 'pg_class'::regclass
      and d.objid = 'public.free573_seq'::regclass and d.deptype = 'a'),
  0, 'the sequence the table only calls, and never owned, is still owned by nothing');
select is(pg_get_serial_sequence('public.s573', 'id'), 'public.s573_id_seq',
  'pg_get_serial_sequence resolves the key''s sequence through the parent');

-- ============================================== retention: the monolith can now be retired
insert into public.s573 (v) select 'new' from generate_series(1, 20);   -- ids 16..35: frontier to 35
select is((select array_agg(id order by id) from public.s573 where v = 'new'),
  array(select generate_series(16, 35)::bigint),
  'LIVENESS: the parent''s default kept issuing ids from the carried sequence, 16..35 with no gap or reuse');
select pgpm.obtain('public.s573');
select pgpm.retain('public.s573');

select ok(to_regclass('public.s573_p0000000000000000020') is null
          and exists (select 1 from pgpm.log where parent_table = 'public.s573'::regclass and action = 'retain_drop'),
  'LIVENESS: retention reached past the monolith (the newer partition [20,30) was dropped)');
select ok(to_regclass('public.s573_p0000000000000000000_to_0000000000000000020') is null,
  'the aged-out monolith was dropped by retention');
select ok(not exists (select 1 from pgpm.log where action = 'fail_retain_drop'),
  'retention logged no fail_retain_drop');
select is((select array_agg(c.relname::text order by c.relname) from pg_class c
            where c.relname in ('s573_id_seq', 's573_n_seq', 'free573_seq') and c.relkind = 'S'),
  array['free573_seq', 's573_id_seq', 's573_n_seq'],
  'all three sequences outlived the monolith');
insert into public.s573 (v) values ('after');
select is((select id from public.s573 where v = 'after'), 36::bigint,
  'the next id after the drop continues the sequence');

-- ============================================== untransmute hands ownership back
create table public.u573 (id bigserial primary key, v text);
insert into public.u573 (v) select 'x' from generate_series(1, 5);
call pgpm.transmute('public.u573', 'id', 10::bigint, p_obtain => 2);
select lives_ok($$ select pgpm.untransmute('public.u573') $$,
  'untransmute of a table whose parent owns its serial sequence goes through');
select is(
  (select s.relname || ':' || a.attname from pg_depend d
     join pg_class s on s.oid = d.objid and s.relkind = 'S'
     join pg_attribute a on a.attrelid = d.refobjid and a.attnum = d.refobjsubid
    where d.classid = 'pg_class'::regclass and d.refclassid = 'pg_class'::regclass
      and d.refobjid = 'public.u573'::regclass and d.deptype = 'a'
      and (select relkind from pg_class where oid = d.refobjid) = 'r'),
  'u573_id_seq:id', 'the restored plain table owns its serial sequence again');
insert into public.u573 (v) values ('after');
select is((select id from public.u573 where v = 'after'), 6::bigint,
  'the restored table keeps issuing ids from the same sequence');

select * from finish();
