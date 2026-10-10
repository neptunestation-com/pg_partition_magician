-- untransmute identifies the monolith by the identity transmute recorded, never by position, and refuses
-- when the original table is gone (issue #672).
--
-- untransmute used to take "the monolith" to be the attached partition with the smallest lo. That holds
-- only while the original table is still attached. Once retention has retired it, the smallest-lo
-- partition is one obtain minted; once a regrain's swap has replaced it, it is the first fine child. If the
-- rows left all sit inside that stand-in, the outside-rows door passes, and untransmute detached the stand-in,
-- dropped the parent and handed it back under the table's name as the restored original: a different
-- relation, with none of the table's grants (the application's role lost access), no comment, and indexes
-- carrying partition names. The documented contract is a one-way door, a refusal.
--
-- Now transmute records the original table's oid (pgpm.config.monolith_oid), untransmute resolves the
-- monolith through it (still an attached partition of this parent, still in pgpm.part), and refuses when
-- it is not. Both refusals are pinned by message and paired with LIVENESS witnesses that the stand-in was
-- there, held every remaining row, and so would have passed the old door; after each refusal the table is
-- asserted still managed, by WHICH rows it holds. Section C is the control: an intact monolith still
-- reverses, into the original relation.
create extension if not exists pgtap;
select plan(20);

-- ======================================================================================================
-- (A) retention retired the monolith; the one row left sits in a forward partition
-- ======================================================================================================
create table public.rt177 (id bigint primary key, body text);
insert into public.rt177 select g, 'b' || g from generate_series(1, 5) g;   -- monolith [0, 10)
create temp table orig177 as select 'public.rt177'::regclass::oid as oid;

call pgpm.transmute('public.rt177', 'id', 10::bigint, p_obtain => 3, p_retain => 10, p_paused => false);
select is((select monolith_oid from pgpm.config where parent_table = 'public.rt177'::regclass), (select oid from orig177),
  'transmute records the original table''s oid as the monolith');
insert into public.rt177 values (25, 'x'), (35, 'y');
call pgpm.maintain_all();   -- retention retires [0, 10) (the monolith) and [10, 20)
delete from public.rt177 where id = 35;

select ok(not exists (select 1 from pg_class where oid = (select oid from orig177)),
  'LIVENESS: (A) the original table (the monolith) has been retired by retention');
select is((select array_agg(id order by id) from public.rt177), array[25]::bigint[],
  'LIVENESS: (A) the one remaining row is 25');
select is(
  (select p.lo || '/' || p.hi from pgpm.part p
    where p.parent_table = 'public.rt177'::regclass and p.attached order by p.lo::numeric limit 1),
  '20/30',
  'LIVENESS: (A) the smallest-lo attached partition is now [20, 30), a forward partition obtain minted');
select is((select count(*)::int from public.rt177 where id >= 20 and id < 30), 1,
  'LIVENESS: (A) and it holds every remaining row, so the outside-rows door alone would let it through');

select throws_like($$ select pgpm.untransmute('public.rt177') $$,
  '%cannot untransmute %rt177 -- the original table%is no longer one of its partitions%',
  '(A) untransmute refuses: the original table is gone, and no forward partition stands in for it');
select is((select relkind::text from pg_class where oid = 'public.rt177'::regclass), 'p',
  '(A) the table is still the partitioned parent');
select is((select array_agg(id order by id) from public.rt177), array[25]::bigint[],
  '(A) and row 25 is still in it');
select ok(exists (select 1 from pgpm.config where parent_table = 'public.rt177'::regclass),
  '(A) and pgpm still manages it');
select is((select count(*)::int from pgpm.log where parent_table = 'public.rt177'::regclass and action = 'untransmute'), 0,
  '(A) and no untransmute was logged');

-- ======================================================================================================
-- (B) a regrain's swap replaced the monolith with fine children; the rows left all sit in the first
-- ======================================================================================================
create table public.rg177 (id bigint primary key, body text);
insert into public.rg177 values (1, 'a'), (2, 'b'), (3, 'c'), (150, 'wide');   -- monolith [0, 200)
create temp table orig177b as select 'public.rg177'::regclass::oid as oid;

call pgpm.transmute('public.rg177', 'id', 100::bigint, p_obtain => 3);
insert into public.rg177 values (250, 'frontier');   -- past B: the monolith is frozen and regrainable
select child_name as mon177b from pgpm.part
 where parent_table = 'public.rg177'::regclass and child_oid = (select oid from orig177b) \gset
select is(pgpm.regrain('public.rg177', :'mon177b', '50'), 4,
  'LIVENESS: (B) the regrain swapped the monolith for four fine children');
delete from public.rg177 where id in (150, 250);

select ok(not exists (select 1 from pg_class where oid = (select oid from orig177b)),
  'LIVENESS: (B) the original table (the monolith) is gone, dropped by the swap');
select is((select array_agg(id order by id) from public.rg177), array[1, 2, 3]::bigint[],
  'LIVENESS: (B) ids 1, 2 and 3 remain');
select is(
  (select p.lo || '/' || p.hi || '/' || (select count(*) from public.rg177 where id >= 0 and id < 50)
     from pgpm.part p
    where p.parent_table = 'public.rg177'::regclass and p.attached order by p.lo::numeric limit 1),
  '0/50/3',
  'LIVENESS: (B) the smallest-lo attached partition is the fine child [0, 50), holding all three rows');

select throws_like($$ select pgpm.untransmute('public.rg177') $$,
  '%cannot untransmute %rg177 -- the original table%is no longer one of its partitions%',
  '(B) untransmute refuses: the monolith was regrained away, and its first fine child does not stand in for it');
select is((select relkind::text from pg_class where oid = 'public.rg177'::regclass), 'p',
  '(B) the table is still the partitioned parent');
select is((select array_agg(id order by id) from public.rg177), array[1, 2, 3]::bigint[],
  '(B) and ids 1, 2 and 3 are still in it');

-- ======================================================================================================
-- (C) the control: an intact monolith still reverses, into the original relation
-- ======================================================================================================
create table public.ok177 (id bigint primary key, body text);
insert into public.ok177 values (1, 'a'), (2, 'b'), (7, 'c');
create temp table orig177c as select 'public.ok177'::regclass::oid as oid;
call pgpm.transmute('public.ok177', 'id', 10::bigint, p_obtain => 3);
delete from public.ok177 where id = 2;

select is(pgpm.untransmute('public.ok177')::oid, (select oid from orig177c),
  '(C) with the monolith intact untransmute goes through and hands back the original relation');
select is((select relkind::text from pg_class where oid = 'public.ok177'::regclass), 'r',
  '(C) the table is an ordinary table again');
select is((select array_agg(id order by id) from public.ok177), array[1, 7]::bigint[],
  '(C) holding ids 1 and 7');

select * from finish();
