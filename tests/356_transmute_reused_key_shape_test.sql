-- transmute carries the reused key with its whole definition (issue #766, bullets 1 and 2).
--
-- Step 8 of the cutover declared the reused key on the parent from its column list (plus its deferrability,
-- #731): `primary key (cols)` / `unique (cols)`. What else the key's definition carried was dropped:
--   * a PRIMARY KEY ... INCLUDE (...) then matched no index of the monolith, so ADD PRIMARY KEY tried to build
--     a second primary key on it and the cutover died with "multiple primary keys", after phases 1 and 2 had
--     committed the validated, write-rejecting bound and the claim, on every retry;
--   * a UNIQUE NULLS NOT DISTINCT key was not adopted: a second, NULLS DISTINCT unique index was built on the
--     monolith under the cutover's ACCESS EXCLUSIVE, and the parent and every forward partition accepted the
--     duplicate (NULL, k) rows the table's key refused.
-- The fix declares the key with pgpm._transmute_key_ddl's definition (pg_get_constraintdef's, with the index's
-- storage parameters) on ONLY the parent and attaches the monolith's index under it, so the original index is
-- adopted in place and nothing is built. Fixtures, each a different shape so a mutant that carries one
-- property and not another fails a different assertion:
--   (A) k356a: PRIMARY KEY (k, id) INCLUDE (payload), 7 rows, one payload NULL;
--   (B) k356b: no primary key, UNIQUE NULLS NOT DISTINCT (tenant, k), 5 rows, every tenant NULL;
--   (C) k356c: PRIMARY KEY (k, id) INCLUDE (payload, note) WITH (fillfactor = 70) DEFERRABLE INITIALLY
--       DEFERRED, 4 rows, then untransmuted: the key comes back whole, under its name, on the same index;
--   (D) k356a again: a regrain of its monolith runs to its swap and its fine children carry the parent's
--       whole key: regrain takes the key's KEY columns (indnkeyatts), so a nullable INCLUDE column is neither
--       refused as a nullable key column nor joined on;
--   (E) k356e: PRIMARY KEY (k, id) INCLUDE (payload), 4 rows in one fine sub-range and one past it: two of them are updated
--       (an INCLUDE value set to NULL, and a NULL one set) after the regrain copied them, and the swap
--       carries both changes: the change capture is keyed by the KEY columns, not the INCLUDE one.
-- bench/transmute_reused_key_shape.sh runs this file against a mutant whose step 8 declares the key from its
-- column list again (transmute_key_redeclared_from_columns), so it is also required to FAIL there. The file
-- runs with ON_ERROR_STOP off, so a cutover that fails (and the writes its bound then rejects) is an assertion
-- that fails, not a file that stops; plan() counts every assertion, so none can go missing unnoticed.
create extension if not exists pgtap;
select plan(32);
\set ON_ERROR_STOP 0

-- ==================== (A) a primary key with INCLUDE columns ====================
create table public.k356a (id bigint not null, k bigint not null, payload text, primary key (k, id) include (payload));
insert into public.k356a select g, g * 300, case when g <> 3 then 'p' || g end from generate_series(1, 7) g;   -- row 3's payload NULL
select conindid as a_idx, (select relfilenode from pg_class where oid = conindid) as a_fn, pg_get_constraintdef(oid) as a_def
  from pg_constraint where conrelid = 'public.k356a'::regclass and contype = 'p' \gset
create table pg_temp.a_before as select array_agg(indexrelid order by indexrelid) as idx from pg_index where indrelid = 'public.k356a'::regclass;
select is(:'a_def'::text, 'PRIMARY KEY (k, id) INCLUDE (payload)', 'LIVENESS: (A) k356a''s primary key carries INCLUDE (payload)');

call pgpm.transmute('public.k356a', 'k', 1000, p_obtain => 2);

select is((select relkind::text from pg_class where oid = 'public.k356a'::regclass), 'p',
  'A: the PRIMARY KEY ... INCLUDE table is converted');
select ok(not exists (select 1 from pg_constraint c join pg_class r on r.oid = c.conrelid
                       where r.relname like 'k356a%' and c.conname = 'pgpm_monolith_bound')
          and not exists (select 1 from pgpm.transmute_inflight where rel = 'k356a'),
  'A: no write-rejecting bound and no claim is left behind');
select is((select r.relkind::text || ' ' || c.conname || ' ' || pg_get_constraintdef(c.oid)
             from pg_constraint c join pg_class r on r.oid = c.conrelid
            where c.conrelid = 'public.k356a'::regclass and c.contype = 'p'),
  'p k356a_pkey ' || :'a_def', 'A: the parent''s key has the original name and the whole definition, INCLUDE (payload) with it');
select is(
  (select (c.conindid = :a_idx)::text || ' ' || ((select relfilenode from pg_class where oid = c.conindid) = :a_fn)::text
          || ' ' || p.conname::text
     from pg_constraint c join pg_constraint p on p.oid = c.conparentid
    where c.conrelid = (select monolith_oid from pgpm.config where parent_table = 'public.k356a'::regclass)
      and c.contype = 'p'),
  'true true k356a_pkey',
  'A: the monolith''s key is the original index, adopted in place (same oid, same relfilenode) under the parent''s k356a_pkey');
select is((select array_agg(indexrelid order by indexrelid) from pg_index
            where indrelid = (select monolith_oid from pgpm.config where parent_table = 'public.k356a'::regclass)),
  (select idx from pg_temp.a_before),
  'A: the monolith''s indexes are exactly the ones it came with: the cutover built none');
insert into public.k356a values (8, 3400, 'fwd');
select ok((select tableoid <> (select monolith_oid from pgpm.config where parent_table = 'public.k356a'::regclass)
             from public.k356a where id = 8),
  'LIVENESS: (A) row 8 (k = 3400) landed in a forward partition');
select ok((select pg_get_indexdef(i.indexrelid) from pg_index i join pg_class t on t.oid = i.indrelid
            where i.indisprimary and t.oid = (select tableoid from public.k356a where id = 8))
          like '% USING btree (k, id) INCLUDE (payload)',
  'A: the forward partition''s key carries INCLUDE (payload)');

-- ==================== (B) a UNIQUE NULLS NOT DISTINCT key ====================
create table public.k356b (tenant int, k bigint not null, v int, constraint k356b_u unique nulls not distinct (tenant, k));
insert into public.k356b select null, g * 500, g from generate_series(1, 5) g;
select conindid as b_idx, pg_get_constraintdef(oid) as b_def
  from pg_constraint where conrelid = 'public.k356b'::regclass and conname = 'k356b_u' \gset
create table pg_temp.b_before as select array_agg(indexrelid order by indexrelid) as idx from pg_index where indrelid = 'public.k356b'::regclass;
select throws_ok($$insert into public.k356b values (null, 1500, 99)$$, '23505', null,
  'LIVENESS: (B) before the conversion k356b refuses a second (NULL, 1500)');

call pgpm.transmute('public.k356b', 'k', 1000, p_obtain => 2);

select is((select relkind::text from pg_class where oid = 'public.k356b'::regclass), 'p',
  'B: the UNIQUE NULLS NOT DISTINCT table is converted');
select is((select r.relkind::text || ' ' || pg_get_constraintdef(c.oid)
             from pg_constraint c join pg_class r on r.oid = c.conrelid
            where c.conrelid = 'public.k356b'::regclass and c.conname = 'k356b_u'),
  'p UNIQUE NULLS NOT DISTINCT (tenant, k)', 'B: the parent''s k356b_u is NULLS NOT DISTINCT, as the table''s was');
select is((select array_agg(indexrelid order by indexrelid) from pg_index
            where indrelid = (select monolith_oid from pgpm.config where parent_table = 'public.k356b'::regclass)),
  (select idx from pg_temp.b_before),
  'B: the monolith''s indexes are exactly the ones it came with: no second unique index was built under the lock');
select is((select array_agg(c.conindid) from pg_constraint c
            where c.conrelid = (select monolith_oid from pgpm.config where parent_table = 'public.k356b'::regclass)
              and c.contype = 'u'),
  array[:b_idx::oid], 'B: the monolith''s one unique constraint is the original index');
insert into public.k356b values (null, 3500, 1), (null, 3600, 2);
select ok((select bool_and(tableoid <> (select monolith_oid from pgpm.config where parent_table = 'public.k356b'::regclass))
             from public.k356b where k in (3500, 3600)),
  'LIVENESS: (B) (NULL, 3500) and (NULL, 3600) were accepted, in a forward partition');
select throws_ok($$insert into public.k356b values (null, 3500, 3)$$, '23505', null,
  'B: the forward partition refuses a second (NULL, 3500), as the table''s NULLS NOT DISTINCT key did');
select is((select string_agg(k || ':' || v, ',' order by k) from public.k356b where k >= 3000), '3500:1,3600:2',
  'B: exactly the two distinct rows are past the monolith, the duplicate is not');

-- ==================== (C) INCLUDE, storage parameters and deferral together; untransmute ====================
create table public.k356c (id bigint not null, k bigint not null, payload text, note text,
  constraint k356c_pk primary key (k, id) include (payload, note) with (fillfactor = 70) deferrable initially deferred);
insert into public.k356c select g, g * 700, 'p' || g, 'n' || g from generate_series(1, 4) g;
select conindid as c_idx, pg_get_constraintdef(oid) as c_def
  from pg_constraint where conrelid = 'public.k356c'::regclass and contype = 'p' \gset

call pgpm.transmute('public.k356c', 'k', 1000, p_obtain => 2);

select is((select r.relkind::text || ' ' || pg_get_constraintdef(c.oid)
             from pg_constraint c join pg_class r on r.oid = c.conrelid
            where c.conrelid = 'public.k356c'::regclass and c.conname = 'k356c_pk'),
  'p ' || :'c_def', 'C: the parent''s k356c_pk has the whole definition: INCLUDE (payload, note), DEFERRABLE INITIALLY DEFERRED');
select is((select c.reloptions from pg_class c
            where c.oid = (select k.conindid from pg_constraint k join pg_class r on r.oid = k.conrelid
                            where k.conrelid = 'public.k356c'::regclass and k.conname = 'k356c_pk' and r.relkind = 'p')),
  array['fillfactor=70'], 'C: and the parent''s index has the key''s storage parameters');
select is((select (pg_get_indexdef(i.indexrelid) like '% INCLUDE (payload, note) WITH (fillfactor=''70'')')::text
                  || ' ' || k.condeferrable::text || ' ' || k.condeferred::text
             from pg_index i join pg_constraint k on k.conindid = i.indexrelid
            where i.indisprimary
              and i.indrelid = (select min(h.inhrelid::bigint)::oid from pg_inherits h
                                 where h.inhparent = 'public.k356c'::regclass
                                   and h.inhrelid <> (select monolith_oid from pgpm.config where parent_table = 'public.k356c'::regclass))),
  'true true true', 'C: a forward partition''s key has INCLUDE, the storage parameters and the deferral');
select is((select c.conindid from pg_constraint c
            where c.conrelid = (select monolith_oid from pgpm.config where parent_table = 'public.k356c'::regclass)
              and c.contype = 'p'),
  :c_idx::oid, 'C: the monolith''s key is the original index');
select lives_ok($$select pgpm.untransmute('public.k356c')$$, 'C: untransmute runs');
select is((select relkind::text from pg_class where oid = 'public.k356c'::regclass), 'r', 'LIVENESS: (C) k356c is a plain table again');
select is((select conname::text || ' ' || conindid::text || ' ' || pg_get_constraintdef(oid) from pg_constraint
            where conrelid = 'public.k356c'::regclass and contype = 'p'),
  'k356c_pk ' || :c_idx || ' ' || :'c_def',
  'C: the restored table''s key is k356c_pk again, the original index, with its whole definition');
select is((select string_agg(id::text, ',' order by id) from public.k356c), '1,2,3,4',
  'C: and it holds its four rows');

-- ==================== (D) a regrain of the monolith keeps the key's shape ====================
create temp table d_err (e text);
do $$ declare s text; n int := 0; begin
  loop s := pgpm.regrain_step('public.k356a', (select relname from pg_class where oid =
                (select monolith_oid from pgpm.config where parent_table = 'public.k356a'::regclass)), '100', 1);
    exit when s like 'swapped:%'; n := n + 1; if n > 500 then raise exception 'no convergence: %', s; end if; end loop;
exception when others then insert into d_err values (sqlerrm);
end $$;
select is((select e from d_err), null, 'D: a regrain of k356a''s monolith, a nullable INCLUDE column in its key, runs to its swap');
select is((select count(*)::int from pgpm.log where parent_table = 'public.k356a'::regclass
             and action = 'regrain' and method = 'copy_swap_drop'),
  1, 'LIVENESS: (D) the regrain of k356a''s monolith swapped');
select is((select string_agg(distinct (pg_get_indexdef(i.indexrelid) like '% USING btree (k, id) INCLUDE (payload)'
                                      and (select conparentid <> 0 from pg_constraint where conindid = i.indexrelid))::text, ',')
             from pg_inherits h join pg_index i on i.indrelid = h.inhrelid and i.indisprimary
            where h.inhparent = 'public.k356a'::regclass),
  'true', 'D: every partition of k356a, the regrain''s fine children with them, has the key with INCLUDE (payload), attached under the parent''s');
select is((select string_agg(id::text, ',' order by id) from public.k356a), '1,2,3,4,5,6,7,8',
  'D: and k356a holds every row it had');

-- ==================== (E) changes to an INCLUDE column during a regrain ====================
create table public.k356e (id bigint not null, k bigint not null, payload text, primary key (k, id) include (payload));
insert into public.k356e values (1, 110, 'a'), (2, 120, null), (3, 130, 'c'), (4, 140, 'd');
call pgpm.transmute('public.k356e', 'k', 1000, p_obtain => 2);
insert into public.k356e values (5, 1400, 'z');   -- past the monolith, so its range is frozen and regrains
create temp table e_err (e text);
create temp table e_copied (n bigint);
-- the source by its oid on every tick: the first renames it
create function pg_temp.e_tick() returns text language sql as $$
  select pgpm.regrain_step('public.k356e', (select relname from pg_class where oid =
           (select monolith_oid from pgpm.config where parent_table = 'public.k356e'::regclass)), '100', 1) $$;
-- copy until rows 1 and 2 (k 110 and 120, one per batch) are in the fine copy, change both, run to the swap
do $$ declare s text; n int := 0; begin
  loop s := pg_temp.e_tick();
    exit when (select sum(rows) from pgpm.log where parent_table = 'public.k356e'::regclass and action = 'regrain_copy') >= 2;
    n := n + 1; if n > 50 then raise exception 'never copied: %', s; end if; end loop;
exception when others then insert into e_err values (sqlerrm);
end $$;
insert into e_copied select sum(rows) from pgpm.log where parent_table = 'public.k356e'::regclass and action = 'regrain_copy';
update public.k356e set payload = null where id = 1;
update public.k356e set payload = 'B' where id = 2;
do $$ declare s text; n int := 0; begin
  loop s := pg_temp.e_tick();
    exit when s like 'swapped:%'; n := n + 1; if n > 500 then raise exception 'no convergence: %', s; end if; end loop;
exception when others then insert into e_err values (sqlerrm);
end $$;
select is((select n from e_copied), 2::bigint, 'LIVENESS: (E) rows 1 and 2 were copied, and rows 3 and 4 not, before the two updates');
select is((select string_agg(e, '; ') from e_err), null, 'E: the regrain of k356e runs to its swap');
select is((select count(*)::int from pgpm.log where parent_table = 'public.k356e'::regclass
             and action = 'regrain' and method = 'copy_swap_drop'),
  1, 'LIVENESS: (E) the regrain of k356e''s monolith swapped');
select is((select string_agg(id || ':' || coalesce(payload, '<null>'), ',' order by id) from public.k356e),
  '1:<null>,2:B,3:c,4:d,5:z', 'E: the two INCLUDE values changed during the regrain are the ones the table holds after the swap');

select * from finish();
