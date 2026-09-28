-- Issue #566: transmute's #277 carry-over (owner, grants, RLS, policies, comments, triggers) omitted
-- publication membership. pg_publication_rel records a table by oid, and the cutover renames that oid into
-- the monolith child, so a publication FOR TABLE ev went on naming the monolith alone: the new parent and
-- every forward partition obtain created were in no publication, and every row written past the monolith
-- was silently not replicated (logical subscribers, Supabase Realtime) while the rows routed to the
-- monolith still were. The cutover now adds the new parent to every publication the table was named in,
-- with the same row filter and column list, and refuses UP FRONT the one shape PostgreSQL cannot put on a
-- partitioned table: a row filter or column list in a publication with publish_via_partition_root = false.
--
-- Fixture asymmetry: the table is in TWO publications of different shapes (a plain one, and one publishing
-- via the root with a row filter and a column list), and a THIRD publication that names a different table
-- must NOT gain the parent. So "the parent is in the publications" cannot pass by the parent being added
-- to every publication, nor by it being added to the first one only; the membership is asserted as the
-- exact set of publication names. Every post-conversion claim has a pre-conversion witness.
create extension if not exists pgtap;
set client_min_messages = error;   -- wal_level is not logical on the test image; the warning is noise

select plan(17);

create table public.ev566 (id bigint primary key, body text, secret text);
insert into public.ev566 select g, 'old ' || g, 's' || g from generate_series(1, 15) g;   -- monolith [0, 20)
create table public.other566 (id bigint primary key);
create publication pub566_plain for table public.ev566;
create publication pub566_root  for table public.ev566 (id, body) where (id > 5) with (publish_via_partition_root = true);
create publication pub566_other for table public.other566;

-- ============================================== before: what there is to carry
select is(
  (select array_agg(p.pubname::text order by p.pubname) from pg_publication_rel r
     join pg_publication p on p.oid = r.prpubid where r.prrelid = 'public.ev566'::regclass),
  array['pub566_plain', 'pub566_root'],
  'LIVENESS: before the conversion the table is named in exactly two publications');
select is(
  (select pg_get_expr(r.prqual, r.prrelid) from pg_publication_rel r join pg_publication p on p.oid = r.prpubid
    where p.pubname = 'pub566_root' and r.prrelid = 'public.ev566'::regclass),
  '(id > 5)', 'LIVENESS: pub566_root carries a row filter on the table');

-- ============================================== transmute: the parent takes the table's place
call pgpm.transmute('public.ev566', 'id', 10::bigint, p_obtain => 3);
insert into public.ev566 values (25, 'new, past the monolith', 's25');

select is((select relkind::text from pg_class where oid = 'public.ev566'::regclass), 'p',
  'LIVENESS: the table really was converted, not refused');
select is((select tableoid::regclass::text from public.ev566 where id = 25), 'ev566_p0000000000000000020',
  'LIVENESS: the new row was routed to the forward partition, not the monolith');

select is(
  (select array_agg(p.pubname::text order by p.pubname) from pg_publication_rel r
     join pg_publication p on p.oid = r.prpubid where r.prrelid = 'public.ev566'::regclass),
  array['pub566_plain', 'pub566_root'],
  'the new parent is named in exactly the publications the table was, and in no other');
select is(
  (select pg_get_expr(r.prqual, r.prrelid) from pg_publication_rel r join pg_publication p on p.oid = r.prpubid
    where p.pubname = 'pub566_root' and r.prrelid = 'public.ev566'::regclass),
  '(id > 5)', 'the row filter rode across with the membership');
select is(
  (select array_agg(a.attname::text order by a.attname) from pg_publication_rel r
     join pg_publication p on p.oid = r.prpubid
     join pg_attribute a on a.attrelid = r.prrelid and a.attnum = any(r.prattrs::int2[])
    where p.pubname = 'pub566_root' and r.prrelid = 'public.ev566'::regclass),
  array['body', 'id'], 'the column list rode across with the membership (secret is still not published)');
select is(
  (select p.pubname::text from pg_publication_rel r join pg_publication p on p.oid = r.prpubid
    where r.prrelid = 'public.other566'::regclass),
  'pub566_other', 'LIVENESS: the unrelated publication still names its own table');
select ok(
  not exists (select 1 from pg_publication_tables where pubname = 'pub566_other' and tablename like 'ev566%'),
  'the unrelated publication gained nothing');

-- What a subscriber actually receives. pub566_plain publishes leaves, so the forward partition holding the
-- new row must be among them; pub566_root publishes through the root under the parent's own name.
select ok(
  exists (select 1 from pg_publication_tables where pubname = 'pub566_plain' and schemaname = 'public'
             and tablename = 'ev566_p0000000000000000020'),
  'the forward partition holding the new row is published by pub566_plain');
select ok(
  exists (select 1 from pg_publication_tables where pubname = 'pub566_plain' and schemaname = 'public'
             and tablename = 'ev566_p0000000000000000000_to_0000000000000000020'),
  'LIVENESS: the monolith is still published by pub566_plain');
select is(
  (select array_agg(tablename::text order by tablename) from pg_publication_tables where pubname = 'pub566_root'),
  array['ev566'], 'pub566_root publishes the table once, through the parent, under its own name');

-- The monolith keeps its own membership: an untransmute hands the original table back, and it has to
-- come back in its publications. A second table, so the first one's forward row does not shut the door.
create table public.rv566 (id bigint primary key);
insert into public.rv566 select generate_series(1, 5);
create publication pub566_rv for table public.rv566;
call pgpm.transmute('public.rv566', 'id', 10::bigint, p_obtain => 2);
select is((select relkind::text from pg_class where oid = 'public.rv566'::regclass), 'p',
  'LIVENESS: rv566 was converted');
select pgpm.untransmute('public.rv566');
select is(
  (select array_agg(p.pubname::text) from pg_publication_rel r join pg_publication p on p.oid = r.prpubid
    where r.prrelid = 'public.rv566'::regclass and (select relkind from pg_class where oid = r.prrelid) = 'r'),
  array['pub566_rv'], 'after untransmute the restored plain table is back in its publication');

-- ============================================== refused up front: the shapes a partitioned table cannot take
create table public.fl566 (id bigint primary key, v text);
insert into public.fl566 select generate_series(1, 5);
create publication pub566_filtered for table public.fl566 where (id > 2);
select throws_like($$ call pgpm.transmute('public.fl566', 'id', 10::bigint) $$,
  '%cannot transmute%pub566_filtered%publish_via_partition_root%',
  'a row filter in a publication that publishes leaves is refused, naming the publication');
create table public.cl566 (id bigint primary key, v text, w text);
create publication pub566_cols for table public.cl566 (id, v);
select throws_like($$ call pgpm.transmute('public.cl566', 'id', 10::bigint) $$,
  '%cannot transmute%pub566_cols%publish_via_partition_root%',
  'a column list in a publication that publishes leaves is refused, naming the publication');
select is(
  (select array_agg(relkind::text order by relname) from pg_class
    where oid in ('public.fl566'::regclass, 'public.cl566'::regclass)),
  array['r', 'r'], 'both refused tables are untouched, still plain tables');

select * from finish();
