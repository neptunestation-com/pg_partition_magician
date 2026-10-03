-- regrain and untransmute read user rows under the CALLER's row-level security (issue #873, bullet 1).
-- transmute leaves the original table, now the monolith, with its own ENABLE / FORCE ROW LEVEL SECURITY
-- and policies. regrain_step copies the source partition by reading it directly (insert ... select from the
-- monolith), so for a non-superuser owner without BYPASSRLS the copy held only the rows its policies admit,
-- and the swap dropped the source whole: every hidden row was lost. untransmute's gate (does any row live
-- outside the monolith?) reads through the parent, so a hidden row in a forward partition was invisible
-- to it, and the reverse dropped that partition with the parent. Both now ask pgpm._refuse_filtered_reads
-- of the relation they actually read before anything is written, and refuse such a caller.
--
-- ASYMMETRIC FIXTURES. A: ids 1..60, every 7th (8 rows, tenant 'old') hidden from the owner, so the
-- 52-row copy the owner could make is not the 60-row monolith. C: ids 1..30 in the monolith, three of
-- them hidden, and one hidden row (45) in a forward partition, the one row the gate exists to see.
--
-- ISOLATION. Part A sets the PARENT NO FORCE after the conversion, so the owner's frontier read (through
-- the parent) is not filtered and the only read refused is the monolith's: the lever asked of the source
-- partition, not of the parent. Part B is the verifier's own shape (parent and monolith both FORCE'd).
-- Part C refuses on the parent, which is what untransmute reads.
--
-- INSTRUMENT. Refused calls run as the owner through a SECURITY DEFINER function the owner owns (pgTAP's
-- temp tables are the harness's, so `set role` around throws_* cannot work; tests/timescale/db/37). regrain,
-- regrain_step and untransmute are functions, so a call that does not refuse commits nothing of its own,
-- runs to its end, and the identity assertions after it see what it did. maintain runs as the owner at the
-- top level and is judged by its skip row. LIVENESS: the same regrain, run by a role the lever passes on
-- part B's table of the same shape, splits the monolith keeping every row; the same untransmute, run by that
-- role first, sees row 45 and refuses as the one-way door.
create extension if not exists pgtap;

select plan(22);

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 't242_owner') then
    create role t242_owner nosuperuser nobypassrls;
  end if;
end $$;
grant create, usage on schema public to t242_owner;
grant usage on schema pgpm to t242_owner;
grant all on all tables in schema pgpm to t242_owner;
grant all on all sequences in schema pgpm to t242_owner;

set role t242_owner;
create function public.t242_as_owner(p_sql text) returns void language plpgsql security definer as $f$
begin execute p_sql; end $f$;
create table public.rg242 (id bigint primary key, tenant text not null);
insert into public.rg242 select g, case when g % 7 = 0 then 'old' else 'new' end from generate_series(1, 60) g;
alter table public.rg242 enable row level security;
alter table public.rg242 force row level security;
create policy rg242_new on public.rg242 using (tenant = 'new');
create table public.rp242 (like public.rg242 including all);
insert into public.rp242 select g, case when g % 7 = 0 then 'old' else 'new' end from generate_series(1, 60) g;
alter table public.rp242 enable row level security;
alter table public.rp242 force row level security;
create policy rp242_new on public.rp242 using (tenant = 'new');
create table public.ut242 (id bigint primary key, tenant text not null);
insert into public.ut242 select g, case when g in (10, 20, 30) then 'old' else 'new' end from generate_series(1, 30) g;
alter table public.ut242 enable row level security;
alter table public.ut242 force row level security;
create policy ut242_new on public.ut242 using (tenant = 'new');
reset role;

-- The conversions, by the harness's role (it bypasses row-level security), then the frontier far past the
-- monoliths so they are frozen (regrainable), and the one hidden row past ut242's monolith.
call pgpm.transmute('public.rg242', 'id', 20::bigint, p_paused => false);
call pgpm.transmute('public.rp242', 'id', 20::bigint, p_paused => true);
call pgpm.transmute('public.ut242', 'id', 10::bigint, p_paused => true);
insert into public.rg242 values (500, 'new');
insert into public.rp242 values (500, 'new');
insert into public.ut242 values (45, 'old');
set role t242_owner;
alter table public.rg242 no force row level security;
reset role;

select child_name as rg_mono from pgpm.part where parent_table = 'public.rg242'::regclass and lo = '0' \gset
select child_name as rp_mono from pgpm.part where parent_table = 'public.rp242'::regclass and lo = '0' \gset
select child_name as ut_mono, hi as ut_hi from pgpm.part where parent_table = 'public.ut242'::regclass and lo = '0' \gset
select string_agg(g::text, ',' order by g) as rg_all from generate_series(1, 60) g \gset

set role t242_owner;
select (select count(*) from public.rg242 where id <= 60) as rg_parent,
       row_security_active('public.rg242')::text as rg_rls,
       row_security_active(format('public.%I', :'rg_mono')::regclass)::text as rg_mono_rls,
       (select count(*) from public.ut242 where id >= :'ut_hi'::bigint) as ut_outside
\gset owner_
select count(*) as rg_mono_direct from public.:"rg_mono" \gset owner_
reset role;

-- ================= WITNESSES =================
select is((select (not rolsuper and not rolbypassrls)::text from pg_roles where rolname = 't242_owner'), 'true',
  'WITNESS: t242_owner is neither a superuser nor BYPASSRLS');
select is((select relrowsecurity::text || '/' || relforcerowsecurity::text || '/' || pg_get_userbyid(relowner)
             from pg_class where oid = format('public.%I', :'rg_mono')::regclass), 'true/true/t242_owner',
  'WITNESS A: the monolith kept ENABLE + FORCE row-level security, and is t242_owner''s');
select is(:'owner_rg_rls'::text || '/' || :'owner_rg_mono_rls'::text, 'false/true',
  'WITNESS A: the parent (NO FORCE since the conversion) does not filter the owner, the monolith does');
select is(:'owner_rg_parent'::text || '/' || :'owner_rg_mono_direct'::text, '60/52',
  'WITNESS A: through the parent the owner sees all 60 rows; reading the monolith directly, 52');
select is(:'owner_ut_outside'::text || '/' || (select string_agg(id::text, ',') from public.ut242 where id >= :'ut_hi'::bigint),
  '0/45', 'WITNESS C: the owner sees no row of ut242 past its monolith; row 45 is there');

-- ================= A. regrain of a monolith that filters the owner: refused, every row kept =================
select throws_like(format($$ select public.t242_as_owner('select pgpm.regrain(''public.rg242'', ''%s'', ''10'')') $$, :'rg_mono'),
  format('pg_partition_magician: cannot regrain %s as t242_owner -- row-level security is active on it for that role (FORCE ROW LEVEL SECURITY holds even the table''s owner to the policies, and the role has no BYPASSRLS)%%the copy would hold only those rows, and the swap would drop the others with the source. Run it as a role with BYPASSRLS (or a superuser); nothing was changed.', :'rg_mono'),
  'A: regrain refuses the owner, naming the monolith it would copy from');
select is((select string_agg(id::text, ',' order by id) from public.rg242 where id <= 60), :'rg_all',
  'A: the parent holds exactly ids 1..60, the 8 hidden ones included');
select is((select string_agg(id::text, ',' order by id) from public.rg242 where tenant = 'old'), '7,14,21,28,35,42,49,56',
  'A: by identity, the hidden rows are the 8 they were');
select is((select string_agg(child_name || ':' || attached, ',') from pgpm.part
            where parent_table = 'public.rg242'::regclass and lo::bigint < 80), :'rg_mono' || ':true',
  'A: the monolith is still the one attached partition below the frontier, and no copy was made');
select throws_like(format($$ select public.t242_as_owner('select pgpm.regrain_step(''public.rg242'', ''%s'', ''10'')') $$, :'rg_mono'),
  format('pg_partition_magician: cannot regrain %s as t242_owner -- row-level security is active on it%%', :'rg_mono'),
  'A: regrain_step refuses at the top of its tick');
select pgpm.set_regrain('public.rg242', '10');
set role t242_owner;
call pgpm.maintain('public.rg242');
reset role;
select is((select count(*)::int from pgpm.log where parent_table = 'public.rg242'::regclass and action = 'skip_regrain'
             and method like format('pg_partition_magician: cannot regrain %s as t242_owner -- row-level security is active on it%%', :'rg_mono')),
  1, 'A: an owner''s maintenance tick defers the auto-regrain with pgpm''s message (skip_regrain)');
select is((select count(*)::int from pgpm.part where parent_table = 'public.rg242'::regclass and not attached)
          || '/' || (select count(*) from pg_trigger where tgrelid = format('public.%I', :'rg_mono')::regclass and tgname = 'pgpm_regrain_capture'),
  '0/0', 'A: and prepared nothing: no copy, no change capture on the monolith');
select is((select string_agg(id::text, ',' order by id) from public.rg242 where id <= 60), :'rg_all',
  'A: every row is still there after the tick');
select pgpm.set_regrain('public.rg242', null);

-- ================= B. the verifier's shape: parent and monolith both FORCE'd =================
select throws_like(format($$ select public.t242_as_owner('select pgpm.regrain(''public.rp242'', ''%s'', ''10'')') $$, :'rp_mono'),
  'pg_partition_magician: cannot %as t242_owner -- row-level security is active on it for that role%',
  'B: regrain refuses the owner when the parent filters it too');
select is((select string_agg(id::text, ',' order by id) from public.rp242 where id <= 60), :'rg_all',
  'B: and the parent still holds exactly ids 1..60');

-- ================= C. untransmute with a hidden row outside the monolith: refused =================
select throws_like($$ select pgpm.untransmute('public.ut242') $$,
  'pg_partition_magician: cannot untransmute ut242 -- rows now live outside the original monolith%',
  'C LIVENESS: read by a role the lever passes (first, so nothing the owner''s call does can bear on it), the gate sees row 45 and refuses as the one-way door');
select throws_like($$ select public.t242_as_owner('select pgpm.untransmute(''public.ut242'')') $$,
  'pg_partition_magician: cannot untransmute ut242 as t242_owner -- row-level security is active on it for that role (FORCE ROW LEVEL SECURITY holds even the table''s owner to the policies, and the role has no BYPASSRLS)%the check that every row still lives in the monolith would pass with rows outside it, and the reverse would drop them with the parent. Run it as a role with BYPASSRLS (or a superuser); nothing was changed.',
  'C: untransmute refuses the owner whose gate would not see row 45');
select is((select relkind::text from pg_class where oid = 'public.ut242'::regclass)
          || '/' || (select count(*) from pgpm.config where parent_table = 'public.ut242'::regclass)::text, 'p/1',
  'C: ut242 is still the managed partitioned table');
select is((select string_agg(id::text, ',' order by id) from public.ut242 where tenant = 'old'), '10,20,30,45',
  'C: and holds its hidden rows by identity, row 45 in its forward partition included');

-- ================= LIVENESS: the same regrain, run by a role the lever passes =================
-- On rp242, part B's table of the same shape: two checks stand in front of its owner's regrain (the parent's
-- frontier read and the source's), so whichever one is missing the owner's call above left it whole.
select lives_ok(format($$ select pgpm.regrain('public.rp242', %L, '10') $$, :'rp_mono'),
  'LIVENESS: the harness''s role regrains a monolith of the same shape');
select is((select string_agg(id::text, ',' order by id) from public.rp242 where id <= 60), :'rg_all',
  'LIVENESS: and keeps every row, the 8 hidden ones included');
select is((select count(*)::int from pgpm.part where parent_table = 'public.rp242'::regclass and attached and lo::bigint < 80),
  8, 'LIVENESS: in eight fine children: the split the owner''s call was refused');

select * from finish();
