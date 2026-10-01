-- transmute carries the table's REPLICA IDENTITY to the parent and to every partition minted after it
-- (issue #782).
--
-- The cutover carried publication membership (#566) but not the replica identity, and PostgreSQL neither
-- recurses ALTER TABLE ... REPLICA IDENTITY to partitions nor gives a new partition its parent's. So a
-- keyless REPLICA IDENTITY FULL table in a publication that publishes updates and deletes got forward
-- partitions with no replica identity at all, and every UPDATE and DELETE of a row past the monolith
-- failed with 55000; a keyed FULL table silently published key-only before-images instead. Now the
-- cutover gives the parent the table's identity (USING INDEX mapped to the parent's index the original
-- index is attached under), and every partition pgpm mints afterwards (obtain's, extend_to's, a regrain's
-- fine children) takes the parent's, the index form mapped to the partition's own index under it.
--
-- Fixtures, one per identity, each keyed differently so a mutant that carries one form and not another,
-- or invents an identity a table never had, fails a different assertion:
--   (A) rf: keyless, FULL, in a publication; the issue's reproduction, plus the partitions a later obtain
--       mints. A keyless DEFAULT table in the same publication (rc) is the witness that the publication
--       check is live here at all: its UPDATE fails with 55000;
--   (B) ri: a primary key AND a carried unique secondary ri_uk, identity USING INDEX ri_uk, so the
--       default (the primary key) is the wrong answer;
--   (C) rp: identity USING INDEX of its own primary key, which #789's rename gives the parent by name;
--   (D) rn: a primary key with identity NOTHING, so the default would publish the key;
--   (E) rd: a primary key with the default identity, which stays the default (nothing invented);
--   (F) rg: a primary key with FULL, regrained, so the fine children the swap attaches take FULL too.
-- bench/cutover_replica_identity.sh runs this file against a mutant whose cutover and minting carry no
-- identity (cutover_replica_identity_dropped), so it is also required to FAIL there.
create extension if not exists pgtap;
select plan(23);

set client_min_messages = warning;   -- CREATE PUBLICATION warns when wal_level is not logical

-- every partition of a parent with its identity, in bound order: 'name:identity'
create function pg_temp.idents(p regclass) returns text[] language sql as $$
  select array_agg(c.relname::text || ':' || c.relreplident::text order by c.relname)
    from pg_inherits h join pg_class c on c.oid = h.inhrelid where h.inhparent = p
$$;
-- the index that is p's replica identity, by name
create function pg_temp.ident_index(p regclass) returns text language sql as $$
  select c.relname::text from pg_index i join pg_class c on c.oid = i.indexrelid
   where i.indrelid = p and i.indisreplident
$$;

-- ==================== (A) keyless, REPLICA IDENTITY FULL, published ====================
create table public.rf (k int8 not null, v text);
alter table public.rf replica identity full;
insert into public.rf select g, 'r' || g from generate_series(1, 10) g;
create table public.rc (k int8 not null, v text);
insert into public.rc values (1, 'c');
create publication rf_pub for table public.rf, public.rc;
select throws_ok($$ update public.rc set v = 'x' where k = 1 $$, '55000', NULL,
  'A LIVENESS: the publication check is live: UPDATE on a published keyless table with no identity fails with 55000');
select lives_ok($$ update public.rf set v = 'pre' where k = 3 $$,
  'A LIVENESS: before the conversion UPDATE on the published FULL table succeeds');
call pgpm.transmute('public.rf', 'k', 100::bigint, p_obtain => 2);
select is((select relkind::text || ':' || relreplident::text from pg_class where oid = 'public.rf'::regclass), 'p:f',
  'A: the converted parent is REPLICA IDENTITY FULL');
select is(pg_temp.idents('public.rf'),
  array['rf_p0000000000000000000:f', 'rf_p0000000000000000100:f', 'rf_p0000000000000000200:f'],
  'A: the monolith and both forward partitions transmute minted are FULL');
insert into public.rf values (150, 'fwd'), (160, 'fwd'), (170, 'keep');
select is((select tableoid::regclass::text from public.rf where k = 150), 'rf_p0000000000000000100',
  'A LIVENESS: 150 lives in the forward partition [100, 200), past the monolith');
select lives_ok($$ update public.rf set v = 'upd' where k = 150 $$, 'A: UPDATE of a forward partition''s row succeeds');
select lives_ok($$ delete from public.rf where k = 160 $$, 'A: DELETE of a forward partition''s row succeeds');
select is((select array_agg(k || ':' || v order by k) from public.rf where k >= 100), array['150:upd', '170:keep'],
  'A: and they changed exactly those rows: 150 updated, 160 gone, 170 untouched');
update pgpm.config set obtain = 4 where parent_table = 'public.rf'::regclass;
select pgpm.obtain('public.rf');
select is(pg_temp.idents('public.rf'),
  array['rf_p0000000000000000000:f', 'rf_p0000000000000000100:f', 'rf_p0000000000000000200:f',
        'rf_p0000000000000000300:f', 'rf_p0000000000000000400:f', 'rf_p0000000000000000500:f'],
  'A: the partitions a later obtain mints take the parent''s FULL too');

-- ==================== (B) USING INDEX of a carried unique secondary ====================
create table public.ri (k int8 not null, u int8 not null, v text, primary key (k));
create unique index ri_uk on public.ri (u, k);
alter table public.ri replica identity using index ri_uk;
insert into public.ri select g, 1000 + g, 'i' || g from generate_series(1, 6) g;
select indexrelid as ri_uk_oid from pg_index where indexrelid = 'public.ri_uk'::regclass \gset
call pgpm.transmute('public.ri', 'k', 100::bigint, p_obtain => 2);
select is((select relreplident::text from pg_class where oid = 'public.ri'::regclass) || ':' || pg_temp.ident_index('public.ri'),
  'i:ri_uk_pgpm', 'B: the parent''s identity is USING INDEX ri_uk_pgpm, the partitioned copy of ri_uk');
select is((select inhparent::regclass::text from pg_inherits where inhrelid = :ri_uk_oid), 'ri_uk_pgpm',
  'B LIVENESS: ri_uk_pgpm is the index the original ri_uk is attached under');
select is(pg_temp.ident_index((select monolith_oid from pgpm.config where parent_table = 'public.ri'::regclass)::regclass),
  'ri_uk', 'B: the monolith keeps the original ri_uk as its identity');
select is(
  (select array_agg(c.relname::text || ':' || c.relreplident::text || ':'
                    || coalesce((select ix.relname::text from pg_index i join pg_class ix on ix.oid = i.indexrelid
                                   join pg_inherits h2 on h2.inhrelid = i.indexrelid
                                  where i.indrelid = c.oid and i.indisreplident
                                    and h2.inhparent = 'public.ri_uk_pgpm'::regclass), 'none')
                    order by c.relname)
     from pg_inherits h join pg_class c on c.oid = h.inhrelid
    where h.inhparent = 'public.ri'::regclass and c.oid <> (select monolith_oid from pgpm.config where parent_table = 'public.ri'::regclass)),
  array['ri_p0000000000000000100:i:ri_p0000000000000000100_u_k_idx', 'ri_p0000000000000000200:i:ri_p0000000000000000200_u_k_idx'],
  'B: each forward partition''s identity is its own index under ri_uk_pgpm, not its primary key');

-- ==================== (C) USING INDEX of the primary key itself ====================
create table public.rp (k int8 not null, v text, constraint rp_pkey primary key (k));
alter table public.rp replica identity using index rp_pkey;
insert into public.rp select g, 'p' || g from generate_series(1, 5) g;
call pgpm.transmute('public.rp', 'k', 100::bigint, p_obtain => 2);
select is((select relreplident::text from pg_class where oid = 'public.rp'::regclass) || ':' || pg_temp.ident_index('public.rp'),
  'i:rp_pkey', 'C: the parent''s identity is USING INDEX of its own key, rp_pkey');
select is(pg_temp.idents('public.rp'),
  array['rp_p0000000000000000000:i', 'rp_p0000000000000000100:i', 'rp_p0000000000000000200:i'],
  'C: and every partition''s identity is an index');
select is(pg_temp.ident_index('public.rp_p0000000000000000100'), 'rp_p0000000000000000100_pkey',
  'C: a forward partition''s identity is its own primary key, the one under rp_pkey');

-- ==================== (D) REPLICA IDENTITY NOTHING ====================
create table public.rn (k int8 not null, v text, primary key (k));
alter table public.rn replica identity nothing;
insert into public.rn select g, 'n' || g from generate_series(1, 4) g;
call pgpm.transmute('public.rn', 'k', 100::bigint, p_obtain => 2);
select is((select relreplident::text from pg_class where oid = 'public.rn'::regclass), 'n',
  'D: the converted parent is REPLICA IDENTITY NOTHING');
select is(pg_temp.idents('public.rn'),
  array['rn_p0000000000000000000:n', 'rn_p0000000000000000100:n', 'rn_p0000000000000000200:n'],
  'D: and so is every partition, which with its primary key would otherwise publish the key');

-- ==================== (E) the default stays the default ====================
create table public.rd (k int8 not null, v text, primary key (k));
insert into public.rd select g, 'd' || g from generate_series(1, 3) g;
call pgpm.transmute('public.rd', 'k', 100::bigint, p_obtain => 2);
select is((select relreplident::text from pg_class where oid = 'public.rd'::regclass), 'd',
  'E: a default-identity table''s parent keeps the default');
select is(pg_temp.idents('public.rd'),
  array['rd_p0000000000000000000:d', 'rd_p0000000000000000100:d', 'rd_p0000000000000000200:d'],
  'E: and so does every partition: nothing is invented');

-- ==================== (F) a regrain's fine children ====================
create table public.rg (k int8 not null, v text, primary key (k));
alter table public.rg replica identity full;
insert into public.rg values (10, 'a'), (20, 'b'), (150000, 'c'), (1999999, 'widen');
call pgpm.transmute('public.rg', 'k', 1000000);
insert into public.rg values (3500000, 'frontier');
select child_name as rg_src from pgpm.part
 where parent_table = 'public.rg'::regclass and attached order by lo::numeric limit 1 \gset
select is(pgpm.regrain('public.rg', :'rg_src', '500000'), 4,
  'F LIVENESS: the regrain swaps, four fine children attached over the source''s [0, 2000000)');
select is((select array_agg(k || ':' || v order by k) from public.rg where k < 2000000),
  array['10:a', '20:b', '150000:c', '1999999:widen'], 'F LIVENESS: the fine children hold exactly the source''s rows');
select is(
  (select array_agg(c.relname::text || ':' || c.relreplident::text order by c.relname)
     from pgpm.part p join pg_class c on c.oid = p.child_oid
    where p.parent_table = 'public.rg'::regclass and p.attached and p.hi::numeric <= 2000000),
  array['rg_p0000000000000000000:f', 'rg_p0000000000000500000:f', 'rg_p0000000000001000000:f', 'rg_p0000000000001500000:f'],
  'F: each fine child the swap attached is FULL, as the parent is');

select * from finish();
