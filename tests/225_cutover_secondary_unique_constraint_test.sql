-- transmute carries a secondary UNIQUE constraint as a constraint, under its name and with its deferrability
-- (issue #828).
--
-- Step 9b carried every secondary unique index through pg_get_indexdef, a bare unique index named
-- <name>_pgpm, including the ones that back a UNIQUE CONSTRAINT beside the reused key. So what #789 and
-- #731 carry for the reused key stopped there: INSERT ... ON CONFLICT ON CONSTRAINT <name> failed with
-- 42704 on the converted table, and a DEFERRABLE constraint was immediate on the parent and on every
-- forward partition, so a one-statement swap the table accepted before failed with 23505 past the monolith.
--
-- The fix carries such a constraint the way step 8 carries the key: the monolith's copy is renamed
-- pgpm_key_<its index oid>, the parent takes the original name with the original definition
-- (pg_get_constraintdef: columns, NULLS NOT DISTINCT, INCLUDE, DEFERRABLE, INITIALLY DEFERRED), and the
-- monolith's own index is attached under it by name, so no index is rebuilt and the adoption is exact.
-- untransmute hands every such name back. Fixtures, each a different shape so a mutant that carries one
-- property and not another fails a different assertion:
--   (A) u225: PK + an immediate UNIQUE u225_code_ts_key + a BARE unique index + a plain index, 6 rows;
--   (B) d225: PK + UNIQUE ... DEFERRABLE (code, ts) + UNIQUE ... DEFERRABLE INITIALLY DEFERRED (tag, ts), 9 rows;
--   (C) n225: PK + UNIQUE NULLS NOT DISTINCT (code, ts) INCLUDE (note) WITH (fillfactor = 70), 4 rows;
--   (D) r225: PK + two unique constraints, transmuted and untransmuted: every name handed back, 3 rows;
--   (E) e225: a relation squatting on the pgpm_key_<oid> name the secondary's monolith copy needs is
--       refused up front, naming it, 2 rows;
--   (F) l225: a 60-byte secondary constraint name converts (it gets no _pgpm suffix any more), 5 rows.
-- bench/cutover_secondary_unique_constraint.sh runs this file against a mutant whose step 9b carries the
-- constraint as a bare index again (cutover_secondary_unique_as_index), so it is also required to FAIL there.
create extension if not exists pgtap;
select plan(37);

set timezone = 'UTC';

-- ==================== (A) an immediate secondary unique constraint ====================
create table public.u225 (id bigint, code int not null, ref int not null, note text, ts timestamptz not null,
                          primary key (id, ts), constraint u225_code_ts_key unique (code, ts));
create unique index u225_ref_ts_uidx on public.u225 (ref, ts);
create index u225_note_idx on public.u225 (note);
insert into public.u225 select g, g, 10 + g, 'n' || g, date_trunc('month', now()) - (g || ' days')::interval
  from generate_series(1, 6) g;
select conindid as u_idx, (select relfilenode from pg_class where oid = conindid) as u_fn
  from pg_constraint where conrelid = 'public.u225'::regclass and conname = 'u225_code_ts_key' \gset
insert into public.u225 select 99, code, 0, 'dup', ts from public.u225 where id = 2
  on conflict on constraint u225_code_ts_key do nothing;
select is((select string_agg(id::text, ',' order by id) from public.u225 where code = 2), '2',
  'A LIVENESS: before the conversion ON CONFLICT ON CONSTRAINT u225_code_ts_key works');
call pgpm.transmute('public.u225', 'ts', interval '1 month', p_obtain => 2);
select is((select relkind::text from pg_class where oid = 'public.u225'::regclass), 'p', 'A LIVENESS: u225 is converted');
select is((select array_agg(conname::text || ' ' || condeferrable::text || ' ' || condeferred::text order by conname)
             from pg_constraint where conrelid = 'public.u225'::regclass and contype = 'u'),
  array['u225_code_ts_key false false'],
  'A: the parent carries u225_code_ts_key as a UNIQUE constraint under its own name, immediate as it was');
select is((select relname::text from pg_class
            where oid = (select conindid from pg_constraint where conrelid = 'public.u225'::regclass and conname = 'u225_code_ts_key')),
  'u225_code_ts_key', 'A: and so is the parent''s index behind it');
select is(
  (select c.conname::text || ' ' || (c.conindid = :u_idx)::text || ' '
          || ((select relfilenode from pg_class where oid = c.conindid) = :u_fn)::text || ' ' || p.conname::text
     from pg_constraint c join pg_constraint p on p.oid = c.conparentid
    where c.conrelid = (select monolith_oid from pgpm.config where parent_table = 'public.u225'::regclass)
      and c.contype = 'u'),
  'pgpm_key_' || :u_idx || ' true true u225_code_ts_key',
  'A: the monolith''s copy is the original index, adopted in place (same oid, same relfilenode) under the parent''s u225_code_ts_key, renamed pgpm_key_<index oid>');
select ok(to_regclass('public.u225_code_ts_key_pgpm') is null,
  'A: no bare u225_code_ts_key_pgpm index stands in for the constraint');
select is((select relkind::text || ' ' || (select indisunique from pg_index where indexrelid = c.oid)::text
                  || ' ' || exists (select 1 from pg_constraint where conindid = c.oid)::text
             from pg_class c where c.oid = to_regclass('public.u225_ref_ts_uidx_pgpm')),
  'I true false',
  'A LIVENESS: the bare unique index is still carried as one, u225_ref_ts_uidx_pgpm, backing no constraint');
select ok(to_regclass('public.u225_note_idx_pgpm') is not null,
  'A LIVENESS: and the plain index as u225_note_idx_pgpm');
select (select hi::timestamptz from pgpm.part where parent_table = 'public.u225'::regclass
         and child_oid = (select monolith_oid from pgpm.config where parent_table = 'public.u225'::regclass)) + interval '1 hour'
       as u_fwd \gset
insert into public.u225 values (100, 7, 70, 'fwd', :'u_fwd');
select ok((select tableoid <> (select monolith_oid from pgpm.config where parent_table = 'public.u225'::regclass)
             from public.u225 where id = 100),
  'A LIVENESS: row 100 landed in a forward partition');
select lives_ok($$ insert into public.u225 values (101, 7, 71, 'dup', '$$ || :'u_fwd' || $$')
                     on conflict on constraint u225_code_ts_key do nothing $$,
  'A: the upsert naming u225_code_ts_key runs on the converted table');
select is((select string_agg(id || ':' || note, ',' order by id) from public.u225 where code = 7), '100:fwd',
  'A: and the conflict was found through it in the forward partition: row 100 is kept, 101 is not inserted');
select lives_ok($$ insert into public.u225 select 999, code, 99, 'new', ts from public.u225 where id = 3
                     on conflict on constraint u225_code_ts_key do update set note = 'upd' $$,
  'A: an ON CONFLICT ON CONSTRAINT u225_code_ts_key DO UPDATE against a monolith row runs');
select is((select string_agg(id || ':' || note, ',' order by id) from public.u225 where code = 3), '3:upd',
  'A: and updated monolith row 3 in place, inserting no row 999');
select is((select p.conname::text from pg_constraint c join pg_constraint p on p.oid = c.conparentid
            where c.conrelid = (select tableoid from public.u225 where id = 100) and c.contype = 'u'),
  'u225_code_ts_key', 'A: the forward partition''s unique constraint is a clone of the parent''s u225_code_ts_key');

-- ==================== (B) deferrable secondary unique constraints ====================
create table public.d225 (id bigint, code int not null, tag text not null, ts timestamptz not null,
                          primary key (id, ts),
                          constraint d225_code_ts_key unique (code, ts) deferrable,
                          constraint d225_tag_ts_key unique (tag, ts) deferrable initially deferred);
insert into public.d225 select g, g, 't' || g, date_trunc('month', now()) - (g || ' days')::interval
  from generate_series(1, 9) g;
select lives_ok($$ update public.d225 set code = 10 - code $$,
  'B LIVENESS: before the conversion d225 accepts a (code, ts) swap in one statement');
call pgpm.transmute('public.d225', 'ts', interval '1 month', p_obtain => 2);
select is((select relkind::text from pg_class where oid = 'public.d225'::regclass), 'p', 'B LIVENESS: d225 is converted');
select is((select array_agg(conname::text || ' ' || condeferrable::text || ' ' || condeferred::text order by conname)
             from pg_constraint where conrelid = 'public.d225'::regclass and contype = 'u'),
  array['d225_code_ts_key true false', 'd225_tag_ts_key true true'],
  'B: the parent carries both constraints under their names, DEFERRABLE and DEFERRABLE INITIALLY DEFERRED as they were');
select (select hi::timestamptz from pgpm.part where parent_table = 'public.d225'::regclass
         and child_oid = (select monolith_oid from pgpm.config where parent_table = 'public.d225'::regclass)) + interval '1 hour'
       as d_fwd \gset
insert into public.d225 values (100, 1, 'a', :'d_fwd'), (101, 2, 'b', :'d_fwd');
select ok((select count(distinct tableoid) = 1 and bool_and(tableoid <> (select monolith_oid from pgpm.config where parent_table = 'public.d225'::regclass))
             from public.d225 where id in (100, 101)),
  'B LIVENESS: rows 100 and 101 landed together in one forward partition');
select is((select string_agg(p.conname::text || ' ' || c.condeferrable::text || ' ' || c.condeferred::text, ', ' order by p.conname)
             from pg_constraint c join pg_constraint p on p.oid = c.conparentid
            where c.conrelid = (select tableoid from public.d225 where id = 100) and c.contype = 'u'),
  'd225_code_ts_key true false, d225_tag_ts_key true true',
  'B: that forward partition''s clones are DEFERRABLE and DEFERRABLE INITIALLY DEFERRED too');
select lives_ok($$ update public.d225 set code = 3 - code where id in (100, 101) $$,
  'B: a (code, ts) swap in one statement is accepted in the forward partition');
select is((select string_agg(id || ':' || code, ' ' order by id) from public.d225 where id in (100, 101)), '100:2 101:1',
  'B: and it exchanged exactly those two codes');
begin;
select lives_ok($$ update public.d225 set tag = 'b' where id = 100 $$,
  'B: inside a transaction, a statement that leaves (tag, ts) duplicated is accepted (the check is deferred to commit)');
select lives_ok($$ update public.d225 set tag = 'a' where id = 101 $$,
  'B: and so is the statement that resolves it before the commit');
commit;
select is((select string_agg(id || ':' || tag, ' ' order by id) from public.d225 where id in (100, 101)), '100:b 101:a',
  'B: and the two-statement tag swap committed');
begin;
set constraints all immediate;
select throws_ok($$ insert into public.d225 values (102, 1, 'c', '$$ || :'d_fwd' || $$') $$, '23505', NULL,
  'B: a real (code, ts) duplicate in the forward partition is still refused once the check runs');
rollback;

-- ==================== (C) NULLS NOT DISTINCT and INCLUDE ====================
create table public.n225 (id bigint, code int, note text, ts timestamptz not null, primary key (id, ts),
                          constraint n225_code_ts_key unique nulls not distinct (code, ts) include (note) with (fillfactor = 70));
insert into public.n225 select g, g, 'n' || g, date_trunc('month', now()) - (g || ' days')::interval
  from generate_series(1, 4) g;
select pg_get_constraintdef(oid) as n_def from pg_constraint where conrelid = 'public.n225'::regclass and conname = 'n225_code_ts_key' \gset
call pgpm.transmute('public.n225', 'ts', interval '1 month', p_obtain => 2);
select is((select relkind::text from pg_class where oid = 'public.n225'::regclass), 'p', 'C LIVENESS: n225 is converted');
select is((select pg_get_constraintdef(oid) from pg_constraint where conrelid = 'public.n225'::regclass and conname = 'n225_code_ts_key'),
  :'n_def', 'C: the parent''s n225_code_ts_key has the original definition (NULLS NOT DISTINCT, INCLUDE (note))');
select (select hi::timestamptz from pgpm.part where parent_table = 'public.n225'::regclass
         and child_oid = (select monolith_oid from pgpm.config where parent_table = 'public.n225'::regclass)) + interval '1 hour'
       as n_fwd \gset
insert into public.n225 values (100, null, 'x', :'n_fwd');
select is((select ic.reloptions from pg_constraint c join pg_constraint p on p.oid = c.conparentid
             join pg_class ic on ic.oid = c.conindid
            where c.conrelid = (select tableoid from public.n225 where id = 100) and p.conname = 'n225_code_ts_key'),
  array['fillfactor=70'],
  'C: the forward partition''s clone of n225_code_ts_key has the index''s storage parameters (fillfactor=70)');
select throws_ok($$ insert into public.n225 values (101, null, 'y', '$$ || :'n_fwd' || $$') $$, '23505', NULL,
  'C: a second null code at the same instant in the forward partition is refused, NULLS NOT DISTINCT');

-- ==================== (D) untransmute hands every name back ====================
create table public.r225 (id bigint, code int not null, tag text not null, ts timestamptz not null,
                          constraint r225_pk primary key (id, ts),
                          constraint r225_code_ts_key unique (code, ts),
                          constraint r225_tag_ts_key unique (tag, ts) deferrable initially deferred);
insert into public.r225 select g, g, 'r' || g, date_trunc('month', now()) - (g || ' days')::interval
  from generate_series(1, 3) g;
select string_agg(conname || '=' || conindid || ' ' || condeferrable || ' ' || condeferred, ', ' order by conname) as r_before
  from pg_constraint where conrelid = 'public.r225'::regclass and contype in ('p', 'u') \gset
call pgpm.transmute('public.r225', 'ts', interval '1 month', p_obtain => 2);
select is((select count(*)::int from pg_constraint
            where conrelid = (select monolith_oid from pgpm.config where parent_table = 'public.r225'::regclass)
              and conname = 'pgpm_key_' || conindid::text),
  3, 'D LIVENESS: r225 is converted and its three monolith copies are named pgpm_key_<index oid>');
select pgpm.untransmute('public.r225');
select is((select string_agg(conname || '=' || conindid || ' ' || condeferrable || ' ' || condeferred, ', ' order by conname)
             from pg_constraint where conrelid = 'public.r225'::regclass and contype in ('p', 'u')),
  :'r_before',
  'D: untransmute hands back the key and both unique constraints under their names, the same indexes, the same flags');

-- ==================== (E) the pgpm_key_<oid> name a secondary needs is taken ====================
create table public.e225 (id bigint, code int not null, ts timestamptz not null, primary key (id, ts),
                          constraint e225_code_ts_key unique (code, ts));
insert into public.e225 values (1, 1, now() - interval '2 days'), (2, 2, now() - interval '3 days');
select conindid as e_idx from pg_constraint where conrelid = 'public.e225'::regclass and conname = 'e225_code_ts_key' \gset
select format('create table public.%I (x int)', 'pgpm_key_' || :e_idx) as e_squat \gset
:e_squat;
select throws_like(
  $$ call pgpm.transmute('public.e225', 'ts', interval '1 month', p_obtain => 2) $$,
  'pg_partition_magician: cannot transmute e225 -- the name pgpm_key_' || :'e_idx' || ' is already taken%',
  'E: transmute refuses up front when the name the monolith''s copy of a secondary unique constraint needs is taken, naming it');
select is((select relkind::text || ' ' || (select count(*) from public.e225)::text
                  || ' ' || exists (select 1 from pgpm.transmute_inflight where parent_table = 'public.e225'::regclass)::text
             from pg_class where oid = 'public.e225'::regclass),
  'r 2 false', 'E: and the table is left as it was, a plain table holding its 2 rows, with no claim');
select format('drop table public.%I', 'pgpm_key_' || :e_idx) as e_unsquat \gset
:e_unsquat;
call pgpm.transmute('public.e225', 'ts', interval '1 month', p_obtain => 2);
select is((select relkind::text from pg_class where oid = 'public.e225'::regclass), 'p',
  'E LIVENESS: with the squatter gone the same transmute converts e225');

-- ==================== (F) a long secondary constraint name ====================
select repeat('l', 51) || '_code_key' as l_name \gset
create table public.l225 (id bigint, code int not null, ts timestamptz not null, primary key (id, ts));
select format('alter table public.l225 add constraint %I unique (code, ts)', :'l_name') as l_add \gset
:l_add;
insert into public.l225 select g, g, date_trunc('month', now()) - (g || ' days')::interval from generate_series(1, 5) g;
select is((select octet_length(conname) from pg_constraint where conrelid = 'public.l225'::regclass and contype = 'u'), 60,
  'F LIVENESS: l225''s unique constraint has a 60-byte name, too long for a <name>_pgpm copy');
call pgpm.transmute('public.l225', 'ts', interval '1 month', p_obtain => 2);
select is((select relkind::text from pg_class where oid = 'public.l225'::regclass), 'p', 'F LIVENESS: l225 is converted');
select is((select array_agg(conname::text) from pg_constraint where conrelid = 'public.l225'::regclass and contype = 'u'),
  array[:'l_name'], 'F: the parent carries it under its own 60-byte name');

select * from finish();
