-- transmute carries a reused key's deferrability onto the parent (issue #731).
--
-- The cutover re-created the reused key on the parent as a bare ADD PRIMARY KEY / ADD UNIQUE, which is
-- immediate, and it still adopted a DEFERRABLE monolith key, so the monolith kept its deferred check while
-- every forward partition got an immediate clone of the parent's. A key swap inside one statement (what a
-- deferrable key is for) that the table accepted before the conversion failed with a duplicate key once its
-- rows were past the monolith. reference.md promises the key is reused in place and never rewritten.
--
-- Fixtures, one per combination of the two flags, so a mutant that carries one flag and not the other, or
-- carries a flag onto a key that never had it, fails a different assertion from one that carries nothing:
--   (A) dpk: PRIMARY KEY ... DEFERRABLE INITIALLY DEFERRED. The parent and a forward partition's clone are
--       deferrable and initially deferred, the monolith's index is adopted in place (same oid, same
--       relfilenode: no rebuild), a one-statement swap in a forward partition is accepted, and a real
--       duplicate there is still refused once the check runs;
--   (B) duq: no primary key, UNIQUE ... DEFERRABLE (initially immediate). The parent is deferrable and NOT
--       initially deferred, and a one-statement swap in a forward partition is accepted (a deferrable
--       unique check runs at the end of the statement, an immediate one per row);
--   (C) dim: a plain immediate PRIMARY KEY stays immediate on the parent, and the same swap in a forward
--       partition is refused with a duplicate key (the witness that the swap discriminates at all).
-- bench/transmute_key_deferrability.sh runs this file against a mutant whose step 8 drops the flags again
-- (transmute_key_immediate), so it is also required to FAIL there.
create extension if not exists pgtap;
select plan(18);

set timezone = 'UTC';

-- (A) a DEFERRABLE INITIALLY DEFERRED primary key
create table public.dpk (id bigint, ts timestamptz not null, payload text,
                         constraint dpk_pkey primary key (id, ts) deferrable initially deferred);
insert into public.dpk select g, date_trunc('month', now()) - (g || ' days')::interval, 'p' || g
  from generate_series(1, 30) g;
select conindid as dpk_idx, (select relfilenode from pg_class where oid = conindid) as dpk_fn
  from pg_constraint where conrelid = 'public.dpk'::regclass and contype = 'p' \gset
select lives_ok($$ update public.dpk set id = 31 - id $$,
  'LIVENESS: (A) before the conversion dpk accepts a key swap in one statement');
call pgpm.transmute('public.dpk', 'ts', interval '1 month', p_obtain => 2);
select is((select relkind::text from pg_class where oid = 'public.dpk'::regclass), 'p', 'LIVENESS: (A) dpk is converted');
select is((select condeferrable::text || ' ' || condeferred::text from pg_constraint
            where conrelid = 'public.dpk'::regclass and contype = 'p'),
  'true true', 'A: the parent''s primary key is DEFERRABLE INITIALLY DEFERRED, as the reused key was');
select is((select conindid::text || ' ' || (select relfilenode from pg_class where oid = conindid)::text
             || ' ' || (conparentid <> 0)::text
             from pg_constraint where conrelid = (select monolith_oid from pgpm.config where parent_table = 'public.dpk'::regclass)
              and contype = 'p'),
  :'dpk_idx' || ' ' || :'dpk_fn' || ' true',
  'A: the monolith''s own key index was adopted in place under the parent''s key (same oid, same relfilenode)');
select (select hi::timestamptz from pgpm.part where parent_table = 'public.dpk'::regclass
         and child_oid = (select monolith_oid from pgpm.config where parent_table = 'public.dpk'::regclass)) + interval '1 hour'
       as dpk_fwd \gset
insert into public.dpk values (100, :'dpk_fwd', 'a'), (101, :'dpk_fwd', 'b');
select ok((select count(distinct tableoid) = 1 and bool_and(tableoid <> (select monolith_oid from pgpm.config where parent_table = 'public.dpk'::regclass))
             from public.dpk where id in (100, 101)),
  'LIVENESS: (A) rows 100 and 101 landed together in one forward partition');
select is((select c.condeferrable::text || ' ' || c.condeferred::text from pg_constraint c
            where c.contype = 'p' and c.conrelid = (select tableoid from public.dpk where id = 100)),
  'true true', 'A: that forward partition''s key is DEFERRABLE INITIALLY DEFERRED too');
select lives_ok($$ update public.dpk set id = 201 - id where id in (100, 101) $$,
  'A: a key swap in one statement is accepted in the forward partition');
select is((select string_agg(id || payload, ' ' order by id) from public.dpk where id in (100, 101)), '100b 101a',
  'A: and it swapped exactly those two ids');
begin;
set constraints all immediate;
select throws_ok($$ insert into public.dpk values (100, '$$ || :'dpk_fwd' || $$', 'dup') $$, '23505', NULL,
  'A: a real duplicate in the forward partition is still refused once the check runs');
rollback;

-- (B) a DEFERRABLE (initially immediate) unique constraint, on a table with no primary key
create table public.duq (id bigint not null, ts timestamptz not null, payload text,
                         constraint duq_key unique (id, ts) deferrable);
insert into public.duq select g, date_trunc('month', now()) - (g || ' days')::interval, 'u' || g
  from generate_series(1, 20) g;
call pgpm.transmute('public.duq', 'ts', interval '1 month', p_obtain => 2);
select is((select relkind::text from pg_class where oid = 'public.duq'::regclass), 'p', 'LIVENESS: (B) duq is converted');
select is((select condeferrable::text || ' ' || condeferred::text from pg_constraint
            where conrelid = 'public.duq'::regclass and contype = 'u'),
  'true false', 'B: the parent''s unique constraint is DEFERRABLE and initially IMMEDIATE, as the reused key was');
select (select hi::timestamptz from pgpm.part where parent_table = 'public.duq'::regclass
         and child_oid = (select monolith_oid from pgpm.config where parent_table = 'public.duq'::regclass)) + interval '1 hour'
       as duq_fwd \gset
insert into public.duq values (50, :'duq_fwd', 'x'), (51, :'duq_fwd', 'y');
select ok((select count(distinct tableoid) = 1 and bool_and(tableoid <> (select monolith_oid from pgpm.config where parent_table = 'public.duq'::regclass))
             from public.duq where id in (50, 51)),
  'LIVENESS: (B) rows 50 and 51 landed together in one forward partition');
select lives_ok($$ update public.duq set id = 101 - id where id in (50, 51) $$,
  'B: a key swap in one statement is accepted in the forward partition');
select is((select string_agg(id || payload, ' ' order by id) from public.duq where id in (50, 51)), '50y 51x',
  'B: and it swapped exactly those two ids');

-- (C) an immediate primary key stays immediate
create table public.dim (id bigint, ts timestamptz not null, payload text, constraint dim_pkey primary key (id, ts));
insert into public.dim select g, date_trunc('month', now()) - (g || ' days')::interval, 'i' || g
  from generate_series(1, 10) g;
call pgpm.transmute('public.dim', 'ts', interval '1 month', p_obtain => 2);
select is((select relkind::text from pg_class where oid = 'public.dim'::regclass), 'p', 'LIVENESS: (C) dim is converted');
select is((select condeferrable::text || ' ' || condeferred::text from pg_constraint
            where conrelid = 'public.dim'::regclass and contype = 'p'),
  'false false', 'C: the parent''s primary key is not deferrable, as the reused key was not');
select (select hi::timestamptz from pgpm.part where parent_table = 'public.dim'::regclass
         and child_oid = (select monolith_oid from pgpm.config where parent_table = 'public.dim'::regclass)) + interval '1 hour'
       as dim_fwd \gset
insert into public.dim values (70, :'dim_fwd', 'p'), (71, :'dim_fwd', 'q');
select ok((select count(distinct tableoid) = 1 and bool_and(tableoid <> (select monolith_oid from pgpm.config where parent_table = 'public.dim'::regclass))
             from public.dim where id in (70, 71)),
  'LIVENESS: (C) rows 70 and 71 landed together in one forward partition');
select throws_ok($$ update public.dim set id = 141 - id where id in (70, 71) $$, '23505', NULL,
  'C: the same one-statement swap is refused there with a duplicate key (an immediate key checks per row)');

select * from finish();
