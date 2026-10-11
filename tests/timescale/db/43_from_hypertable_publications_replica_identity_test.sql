-- from_hypertable dropped the hypertable's publication membership and its replica identity (issue #816,
-- F6-04, F10-04, F7-06, F8-05, F10-07). The cutover drops the hypertable, which takes it out of every
-- publication FOR TABLE it, and renames into its place a copy made by CREATE TABLE ... LIKE, which is in no
-- publication and has the DEFAULT replica identity. transmute carries both from a plain table onto its
-- parent and every partition (#566, #782), so it carried nothing and DEFAULT: a published hypertable's
-- subscribers silently stopped receiving its changes, and a keyless REPLICA IDENTITY FULL one under a
-- publication of updates refused every UPDATE and DELETE with 55000 after the migration. The swap now puts
-- both on the copy (_from_hypertable_carried_ddl), and the one membership shape transmute must refuse on a
-- partitioned table (a row filter or a column list in a publication with publish_via_partition_root = false)
-- is refused before the swap, by the preflight and by the cutover under its lock
-- (_from_hypertable_check_publications), rather than by transmute after it.
--
-- ASYMMETRIC FIXTURE. Three migrated hypertables, each with a DIFFERENT replica identity and a different set
-- of memberships: ha43 USING INDEX on its key and in two publications (one naming a bystander as well), hf43
-- keyless FULL and in one, hc43 NOTHING and in one that publishes via the root with a column list and a row
-- filter (carried as they are). hr43 holds the refused shape. A FOR ALL TABLES publication is not used: it
-- would cover every table whatever the swap did.
-- WITNESSES: each property on the hypertable before; each migration completed with every row by id;
-- transmute itself refuses the refused shape on a plain table; and the remedy the message names migrates hr43.
select plan(23);

create table public.bystander43 (k int primary key);
create table public.ha43 (id bigint not null, ts timestamptz not null, v int, primary key (id, ts));
select create_hypertable('public.ha43', 'ts', chunk_time_interval => interval '1 day');
insert into public.ha43 select g, now() - g * interval '3 hours', g from generate_series(1, 20) g;
alter table public.ha43 replica identity using index ha43_pkey;
create publication pub43_a for table public.ha43;
create publication pub43_b for table public.bystander43, public.ha43;

create table public.hf43 (ts timestamptz not null, v int not null);
select create_hypertable('public.hf43', 'ts', chunk_time_interval => interval '1 day');
insert into public.hf43 select now() - g * interval '2 hours', g from generate_series(1, 30) g;
alter table public.hf43 replica identity full;
create publication pub43_f for table public.hf43;

create table public.hc43 (id bigint not null, ts timestamptz not null, v int, note text, primary key (id, ts));
select create_hypertable('public.hc43', 'ts', chunk_time_interval => interval '1 day');
insert into public.hc43 select g, now() - g * interval '4 hours', g, 'n' || g from generate_series(1, 10) g;
alter table public.hc43 replica identity nothing;
create publication pub43_v for table public.hc43 (id, ts, v) where (v > 3) with (publish_via_partition_root = true);

select is((select string_agg(c.relname || ':' || c.relreplident::text, ',' order by c.relname) from pg_class c
            where c.oid in ('public.ha43'::regclass, 'public.hf43'::regclass, 'public.hc43'::regclass)),
          'ha43:i,hc43:n,hf43:f', 'LIVENESS: the three hypertables have three different replica identities');
select is((select string_agg(p.pubname || '=' || r.prrelid::regclass::text, ',' order by p.pubname, r.prrelid::regclass::text)
             from pg_publication_rel r join pg_publication p on p.oid = r.prpubid
            where r.prrelid in ('public.ha43'::regclass, 'public.hf43'::regclass, 'public.hc43'::regclass,
                                'public.bystander43'::regclass)),
          'pub43_a=ha43,pub43_b=bystander43,pub43_b=ha43,pub43_f=hf43,pub43_v=hc43',
          'LIVENESS: the hypertables'' memberships before the migration');
select lives_ok($$ update public.hf43 set v = v + 1000 where v = 7 $$,
          'LIVENESS: an UPDATE of the published keyless FULL hypertable runs before the migration');

call pgpm.from_hypertable('public.ha43', 'ts', interval '1 day', p_paused => true);
call pgpm.from_hypertable('public.hf43', 'ts', interval '1 day', p_paused => true);
call pgpm.from_hypertable('public.hc43', 'ts', interval '1 day', p_paused => true);

select is((select string_agg(c.relname || ':' || c.relkind::text, ',' order by c.relname) from pg_class c
            where c.oid in ('public.ha43'::regclass, 'public.hf43'::regclass, 'public.hc43'::regclass)),
          'ha43:p,hc43:p,hf43:p', 'LIVENESS: all three were migrated to partitioned tables');
select is((select string_agg(id::text, ',' order by id) from public.ha43),
          (select string_agg(g::text, ',' order by g) from generate_series(1, 20) g),
          'LIVENESS: ha43 holds ids 1..20');
select is((select string_agg(v::text, ',' order by v) from public.hf43),
          (select string_agg(g::text, ',' order by g) from generate_series(1, 30) g where g <> 7) || ',1007',
          'LIVENESS: hf43 holds its 30 rows, the updated one by its new value');

-- replica identity, on the parent and on every partition
select is((select string_agg(c.relname || ':' || c.relreplident::text, ',' order by c.relname) from pg_class c
            where c.oid in ('public.ha43'::regclass, 'public.hf43'::regclass, 'public.hc43'::regclass)),
          'ha43:i,hc43:n,hf43:f', 'each migrated parent keeps its hypertable''s replica identity');
select is((select pc.relname::text from pg_index i join pg_class pc on pc.oid = i.indexrelid
            where i.indrelid = 'public.ha43'::regclass and i.indisreplident),
          'ha43_pkey', 'and ha43''s identity is USING its key, ha43_pkey');
select is((select string_agg(distinct p.relname || ':' || c.relreplident::text, ',' order by p.relname || ':' || c.relreplident::text)
             from pg_class p join pg_inherits h on h.inhparent = p.oid join pg_class c on c.oid = h.inhrelid
            where p.oid in ('public.ha43'::regclass, 'public.hf43'::regclass, 'public.hc43'::regclass)),
          'ha43:i,hc43:n,hf43:f', 'and every partition of each takes the parent''s');
select ok((select bool_and(exists (select 1 from pg_index i where i.indrelid = h.inhrelid and i.indisreplident))
             from pg_inherits h where h.inhparent = 'public.ha43'::regclass),
          'and every partition of ha43 has an identity index');

-- publication membership, with the filter and the column list
select is((select string_agg(p.pubname || '=' || r.prrelid::regclass::text, ',' order by p.pubname, r.prrelid::regclass::text)
             from pg_publication_rel r join pg_publication p on p.oid = r.prpubid
            where r.prrelid in ('public.ha43'::regclass, 'public.hf43'::regclass, 'public.hc43'::regclass,
                                'public.bystander43'::regclass)),
          'pub43_a=ha43,pub43_b=bystander43,pub43_b=ha43,pub43_f=hf43,pub43_v=hc43',
          'each migrated parent is in the publications its hypertable was in, and the bystander stays');
select is((select pg_get_expr(r.prqual, r.prrelid) || ' / '
                  || (select string_agg(a.attname, ',' order by a.attnum) from pg_attribute a
                       where a.attrelid = r.prrelid and a.attnum = any(r.prattrs::int2[]))
             from pg_publication_rel r join pg_publication p on p.oid = r.prpubid
            where p.pubname = 'pub43_v' and r.prrelid = 'public.hc43'::regclass),
          '(v > 3) / id,ts,v', 'hc43''s membership kept its row filter and its column list');
select ok(exists (select 1 from pg_publication_tables t join pg_inherits h on h.inhrelid = format('%I.%I', t.schemaname, t.tablename)::regclass
                   where t.pubname = 'pub43_a' and h.inhparent = 'public.ha43'::regclass),
          'pub43_a now publishes ha43''s partitions');

-- and what the two carry together: a published keyless FULL table still takes UPDATE and DELETE
select lives_ok($$ update public.hf43 set v = v + 1000 where v = 8 $$,
          'an UPDATE of the migrated hf43 runs under its publication');
select lives_ok($$ delete from public.hf43 where v = 9 $$,
          'a DELETE of the migrated hf43 runs under its publication');
select is((select string_agg(v::text, ',' order by v) from public.hf43 where v > 1000 or v = 9), '1007,1008',
          'and the UPDATE changed row 8 and the DELETE removed row 9');

-- ======================= the shape transmute refuses, refused before the swap =======================
create table public.hr43 (id bigint not null, ts timestamptz not null, v int, primary key (id, ts));
select create_hypertable('public.hr43', 'ts', chunk_time_interval => interval '1 day');
insert into public.hr43 select g, now() - g * interval '3 hours', g from generate_series(1, 8) g;
create publication pub43_r for table public.hr43 where (v > 3);
create table public.pl43 (id bigint not null, ts timestamptz not null, v int, primary key (id, ts));
insert into public.pl43 values (1, now() - interval '1 hour', 1);
alter publication pub43_r add table public.pl43 where (v > 3);

select throws_like(
  $$ call pgpm.transmute('public.pl43', 'ts', interval '1 day') $$,
  '%the publication(s) (pub43_r) name it with a row filter or a column list and publish_via_partition_root = false%',
  'LIVENESS: transmute refuses the same membership on a plain table');
select throws_like(
  $$ call pgpm.from_hypertable('public.hr43', 'ts', interval '1 day') $$,
  'pg_partition_magician: cannot migrate hypertable hr43 -- refused before anything is changed%the publication(s) (pub43_r) name it with a row filter or a column list and publish_via_partition_root = false%',
  'from_hypertable refuses it before its copy');
select is(to_regclass('public.hr43_pgpm_dest'), null::regclass,
  'invariant: the refused call left no destination behind');
-- The cutover asks under its lock: a membership added after the copy (p_predrain => false, so nothing
-- commits ahead of the check for an unrelated reason).
alter publication pub43_r drop table public.hr43;
call pgpm.from_hypertable_copy('public.hr43', 'ts');
alter publication pub43_r add table public.hr43 where (v > 3);
select throws_like(
  $$ call pgpm.from_hypertable_cutover('public.hr43', 'ts', interval '1 day', p_predrain => false) $$,
  'pg_partition_magician: cannot migrate hypertable hr43 -- refused before anything is changed%the publication(s) (pub43_r) name it%',
  'from_hypertable_cutover refuses a membership added after the copy, before the swap');
select is((select count(*) from timescaledb_information.hypertables where hypertable_name = 'hr43')
          || '/' || (select string_agg(id::text, ',' order by id) from public.hr43),
          '1/1,2,3,4,5,6,7,8', 'invariant: hr43 is still a hypertable holding ids 1..8');

-- LIVENESS: the remedy the message names migrates the same table, filter carried.
alter publication pub43_r set (publish_via_partition_root = true);
call pgpm.from_hypertable_cutover('public.hr43', 'ts', interval '1 day');
select is((select relkind::text from pg_class where oid = 'public.hr43'::regclass), 'p',
          'LIVENESS: with publish_via_partition_root = true the same cutover migrates hr43');
select is((select pg_get_expr(r.prqual, r.prrelid) from pg_publication_rel r join pg_publication p on p.oid = r.prpubid
            where p.pubname = 'pub43_r' and r.prrelid = 'public.hr43'::regclass),
          '(v > 3)', 'and hr43 stays in pub43_r with its row filter');

select * from finish();
