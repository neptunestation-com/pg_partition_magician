-- transmute's parent carries the reused key under the table's own constraint name (issue #789).
--
-- Step 8 declared the parent's key anonymously (ADD PRIMARY KEY (cols) / ADD UNIQUE (cols)) while the
-- monolith kept the original index and its name, so the managed table's key came back auto-named: a
-- default t_pkey as t_pkey1, an explicitly named ev_pk as ev_pkey. Every statement that names the key
-- then failed with 42704 on the converted table: INSERT ... ON CONFLICT ON CONSTRAINT <name>, and the
-- migrations that ALTER or DROP the constraint by name. reference.md says the key is reused in place.
--
-- The fix renames the monolith's copy first, to pgpm_key_<its index oid> (whole at any key length, so a
-- 63-byte key name converts where a <name>_pgpm suffix would not fit), and declares the parent's key
-- under the original name; untransmute recognises that name by the index oid it embeds and hands the
-- original back. Fixtures, each a different shape so a mutant that names one and not another fails a
-- different assertion:
--   (A) kn: a default-named PRIMARY KEY kn_pkey, 20 rows;
--   (B) kc: an explicitly named PRIMARY KEY kc_pk, 13 rows;
--   (C) ku: no primary key, a reused UNIQUE constraint ku_uq, 7 rows;
--   (D) a 63-byte primary key name, DEFERRABLE INITIALLY DEFERRED (so #731's clause is carried with the
--       name; ON CONFLICT takes no deferrable arbiter, which is why A to C are immediate), 4 rows;
--   (E) untransmute of kn hands the restored table its key under kn_pkey again, the same index;
--   (F) a relation squatting on the name the monolith's copy needs is refused up front, naming it.
-- bench/cutover_key_name.sh runs this file against a mutant whose step 8 declares the key anonymously
-- again (cutover_key_anonymous), so it is also required to FAIL there.
create extension if not exists pgtap;
select plan(31);

-- ==================== (A) a default-named primary key ====================
create table public.kn (k int8 not null, v text, primary key (k));
insert into public.kn select g, 'r' || g from generate_series(1, 20) g;
select conindid as kn_idx from pg_constraint where conrelid = 'public.kn'::regclass and contype = 'p' \gset
insert into public.kn values (5, 'dup') on conflict on constraint kn_pkey do nothing;
select is((select v from public.kn where k = 5), 'r5',
  'A LIVENESS: before the conversion the upsert names kn_pkey and keeps the existing row');
call pgpm.transmute('public.kn', 'k', 100::bigint, p_obtain => 2);
select is((select relkind::text from pg_class where oid = 'public.kn'::regclass), 'p', 'A LIVENESS: kn is converted');
select is((select array_agg(conname::text) from pg_constraint where conrelid = 'public.kn'::regclass and contype = 'p'),
  array['kn_pkey'], 'A: the parent''s primary key is named kn_pkey, as the table''s was');
select is(
  (select c.conname::text || ' ' || (c.conindid = :kn_idx)::text || ' ' || (p.conname = 'kn_pkey')::text
     from pg_constraint c join pg_constraint p on p.oid = c.conparentid
    where c.conrelid = (select monolith_oid from pgpm.config where parent_table = 'public.kn'::regclass) and c.contype = 'p'),
  'pgpm_key_' || :kn_idx || ' true true',
  'A: the monolith''s key is the original index, adopted in place under the parent''s kn_pkey, renamed pgpm_key_<index oid>');
select lives_ok($$ insert into public.kn values (150, 'fwd'), (150, 'dup') on conflict on constraint kn_pkey do nothing $$,
  'A: the upsert naming kn_pkey runs on the converted table');
select is((select tableoid::regclass::text || ':' || v from public.kn where k = 150), 'kn_p0000000000000000100:fwd',
  'A: ON CONFLICT ON CONSTRAINT kn_pkey works on the converted table: 150 lands in the forward partition once, as fwd');
select lives_ok($$ insert into public.kn values (7, 'dup') on conflict on constraint kn_pkey do update set v = 'upd' $$,
  'A: so does an ON CONFLICT ON CONSTRAINT kn_pkey DO UPDATE');
select is((select tableoid::regclass::text || ':' || v from public.kn where k = 7),
  (select child_name::text from pgpm.part where parent_table = 'public.kn'::regclass
      and child_oid = (select monolith_oid from pgpm.config where parent_table = 'public.kn'::regclass)) || ':upd',
  'A: and a conflict on a monolith row is found through kn_pkey too, updating it in place');

-- ==================== (B) an explicitly named primary key ====================
create table public.kc (k int8 not null, v text, constraint kc_pk primary key (k));
insert into public.kc select g, 'c' || g from generate_series(1, 13) g;
call pgpm.transmute('public.kc', 'k', 100::bigint, p_obtain => 2);
select is((select relkind::text from pg_class where oid = 'public.kc'::regclass), 'p', 'B LIVENESS: kc is converted');
select is((select array_agg(conname::text) from pg_constraint where conrelid = 'public.kc'::regclass and contype = 'p'),
  array['kc_pk'], 'B: the parent''s primary key is named kc_pk, not an auto-name');
select is((select relname::text from pg_class
            where oid = (select conindid from pg_constraint where conrelid = 'public.kc'::regclass and contype = 'p')),
  'kc_pk', 'B: and so is the parent''s key index');
select lives_ok($$ insert into public.kc values (160, 'fwd'), (160, 'dup') on conflict on constraint kc_pk do nothing $$,
  'B: the upsert naming kc_pk runs on the converted table');
select is((select v from public.kc where k = 160), 'fwd', 'B: ON CONFLICT ON CONSTRAINT kc_pk works on the converted table');
select lives_ok($$ comment on constraint kc_pk on public.kc is 'the key' $$,
  'B: a migration naming the key (COMMENT ON CONSTRAINT kc_pk ON kc) finds it');
select is((select obj_description(oid, 'pg_constraint') from pg_constraint where conrelid = 'public.kc'::regclass and contype = 'p'),
  'the key', 'B: and acts on the parent''s key');

-- ==================== (C) a reused UNIQUE constraint ====================
create table public.ku (k int8 not null, v text, constraint ku_uq unique (k));
insert into public.ku select g, 'u' || g from generate_series(1, 7) g;
select conindid as ku_idx from pg_constraint where conrelid = 'public.ku'::regclass and contype = 'u' \gset
call pgpm.transmute('public.ku', 'k', 100::bigint, p_obtain => 2);
select is((select relkind::text from pg_class where oid = 'public.ku'::regclass), 'p', 'C LIVENESS: ku is converted');
select is(
  (select array_agg(conname::text || ' ' || condeferrable::text || ' ' || condeferred::text)
     from pg_constraint where conrelid = 'public.ku'::regclass and contype = 'u'),
  array['ku_uq false false'], 'C: the parent''s unique constraint is named ku_uq, immediate as the table''s was');
select is(
  (select c.conname::text from pg_constraint c
    where c.conrelid = (select monolith_oid from pgpm.config where parent_table = 'public.ku'::regclass)
      and c.contype = 'u' and c.conindid = :ku_idx and c.conparentid <> 0),
  'pgpm_key_' || :ku_idx, 'C: the monolith''s copy is the original index under pgpm_key_<index oid>, adopted by the parent');
select lives_ok($$ insert into public.ku values (170, 'fwd') $$, 'C fixture: a row past the monolith');
select is((select tableoid::regclass::text || ':' || v from public.ku where k = 170), 'ku_p0000000000000000100:fwd',
  'C LIVENESS: 170 lives in the forward partition');
select lives_ok($$ insert into public.ku values (170, 'dup') on conflict on constraint ku_uq do update set v = 'upd' $$,
  'C: the upsert naming ku_uq runs on the converted table');
select is((select array_agg(v) from public.ku where k = 170), array['upd'],
  'C: ON CONFLICT ON CONSTRAINT ku_uq works on the converted table');

-- ==================== (D) a 63-byte key name ====================
select rpad('kl_key_', 63, 'k') as kl63 \gset
create table public.kl (k int8 not null, v text, constraint :"kl63" primary key (k) deferrable initially deferred);
insert into public.kl select g, 'l' || g from generate_series(1, 4) g;
select is(octet_length(:'kl63'), 63, 'D LIVENESS: the key name is 63 bytes, so no suffix fits beside it');
call pgpm.transmute('public.kl', 'k', 100::bigint, p_obtain => 2);
select is(
  (select array_agg(conname::text || ' ' || condeferrable::text || ' ' || condeferred::text)
     from pg_constraint where conrelid = 'public.kl'::regclass and contype = 'p'),
  array[:'kl63' || ' true true'],
  'D: the 63-byte key converts, and the parent carries it under its whole name, still DEFERRABLE INITIALLY DEFERRED (#731)');

-- ==================== (E) untransmute hands the original name back ====================
delete from public.kn where k >= 100;   -- every row back inside the monolith, so the door is open
select is(pgpm.untransmute('public.kn')::text, 'kn', 'E LIVENESS: kn is restored');
select is((select relkind::text from pg_class where oid = 'public.kn'::regclass), 'r', 'E LIVENESS: kn is a plain table again');
select is(
  (select conname::text || ' ' || (conindid = :kn_idx)::text from pg_constraint
    where conrelid = 'public.kn'::regclass and contype = 'p'),
  'kn_pkey true', 'E: the restored table''s key is named kn_pkey again, on the same index');
select lives_ok($$ insert into public.kn values (9, 'dup') on conflict on constraint kn_pkey do nothing $$,
  'E: the upsert naming kn_pkey runs on the restored table');
select is((select v from public.kn where k = 9), 'r9', 'E: and the upsert naming kn_pkey works on it');

-- ==================== (F) the monolith's name for the key is taken ====================
create table public.ks (k int8 not null, v text, primary key (k));
insert into public.ks select g, 's' || g from generate_series(1, 3) g;
select conindid as ks_idx, 'pgpm_key_' || conindid as ks_squat
  from pg_constraint where conrelid = 'public.ks'::regclass and contype = 'p' \gset
create table public.:"ks_squat" (x int);
select throws_like(
  $$ call pgpm.transmute('public.ks', 'k', 100::bigint, p_obtain => 2) $$,
  'pg_partition_magician: cannot transmute ks -- the name pgpm_key_' || :ks_idx || ' is already taken%',
  'F: transmute refuses up front when the name the monolith''s copy of the key needs is taken, naming it');
select is((select relkind::text || ' ' || (select count(*) from public.ks)::text from pg_class where oid = 'public.ks'::regclass),
  'r 3', 'F: and the table is left as it was, a plain table holding its 3 rows');

select * from finish();
