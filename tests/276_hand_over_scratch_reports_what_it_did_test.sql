-- pgpm.hand_over_scratch hands every scratch object over, or refuses; its count is what it handed (issue #987).
--
-- docs/reference.md, "Handing a table to a new owner": hand_over_scratch gives every scratch relation pgpm
-- recorded for a table to the table's owner as it is now and returns how many it handed over; run it as a
-- superuser or a member of both the old owner and the new, otherwise it refuses. It counted the objects not
-- yet the owner's BEFORE calling _scratch_owner_follow, and the follow lets a session that can still act as
-- the old owner go on without handing anything over (right for a tick, which can work the objects as
-- before). So a member of the old owner alone, the old owner itself included, was told it had handed over N
-- objects while every one stayed with the old owner and nothing refused. It now reads back what the follow
-- did and refuses, SQLSTATE 42501 with the remedy, when any object is left with another owner.
--
-- The state is a regrain in flight (a delta, its capture function and a not-yet-attached copy) on a table
-- handed from w276_old to w276_new, ALTER TABLE ... OWNER TO on the table and every partition, as the docs
-- say. ASYMMETRIC: of the three objects, the copy is already the new owner's, so the remedy hands over 2,
-- not 3, and each object is named by its oid.
-- PART A, refused: w276_old itself, then w276_member (a member of w276_old only), each told to run it as a
-- member of both, by SQLSTATE and message; after both, the delta and the function are still w276_old's and
-- the copy still w276_new's. LIVENESS: each caller can act as w276_old and is no member of w276_new, and the
-- objects were there to hand.
-- PART B, the remedy: a superuser hands over exactly the two that were not the new owner's, returns 2, and a
-- second call has nothing left to hand and returns 0.
-- Roles are cluster-wide: created only when absent, a leftover membership of the new owner revoked first,
-- and every one dropped at the end. bench/hand_over_scratch_reports.sh runs this file against the
-- hand_over_scratch_unverified mutant, which it must FAIL.
select plan(11);

do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'w276_old') then create role w276_old; end if;
  if not exists (select 1 from pg_roles where rolname = 'w276_new') then create role w276_new; end if;
  if not exists (select 1 from pg_roles where rolname = 'w276_member') then create role w276_member; end if;
end $$;
do $$ begin   -- GUARD: no membership of the new owner left from an earlier run
  if exists (select 1 from pg_auth_members where roleid = 'w276_new'::regrole and member = 'w276_member'::regrole) then
    revoke w276_new from w276_member;
  end if;
  if exists (select 1 from pg_auth_members where roleid = 'w276_new'::regrole and member = 'w276_old'::regrole) then
    revoke w276_new from w276_old;
  end if;
end $$;
grant w276_old to w276_member;      -- a member of the OLD owner only
grant usage, create on schema public to w276_old, w276_new;
grant usage on schema pgpm to w276_old, w276_member, w276_new;
grant all on all tables in schema pgpm to w276_new;   -- the new owner works the regrain at the end
grant all on all sequences in schema pgpm to w276_new;
grant select on all tables in schema pgpm to w276_old, w276_member;

create table public.ev276 (id bigint primary key, v text);
alter table public.ev276 owner to w276_old;
insert into public.ev276 select g, 'x' from generate_series(1, 4500) g;
call pgpm.transmute('public.ev276', 'id', 1000, p_obtain => 3);
insert into public.ev276 values (5500, 'y');
select child_name as mono from pgpm.part where parent_table = 'public.ev276'::regclass and lo = '0' \gset
select is(array[pgpm.regrain_step('public.ev276', :'mono', null, 100), pgpm.regrain_step('public.ev276', :'mono', null, 100)],
  array['prepared', 'copied:100'], 'LIVENESS: a regrain is in flight, prepared and one copy batch in');

-- the three scratch objects, by oid
create temp table w276_obj as
  select 'delta' as kind, regrain_delta_oid as obj from pgpm.config where parent_table = 'public.ev276'::regclass
  union all select 'fn', regrain_capture_fn_oid from pgpm.config where parent_table = 'public.ev276'::regclass
  union all select 'copy', child_oid from pgpm.part where parent_table = 'public.ev276'::regclass and not attached;
create function w276_owners() returns text language sql as $f$
  select string_agg(o.kind || '=' || pg_get_userbyid(coalesce(c.relowner, p.proowner)), ',' order by o.kind)
    from w276_obj o left join pg_class c on c.oid = o.obj and o.kind <> 'fn' left join pg_proc p on p.oid = o.obj and o.kind = 'fn'
$f$;
select is(w276_owners(), 'copy=w276_old,delta=w276_old,fn=w276_old',
  'LIVENESS: the regrain minted its delta, capture function and copy, each owned like the table (w276_old)');

-- hand the table over, as the docs say, and the copy alone ahead of the rest
do $$ declare r record; begin
  execute 'alter table public.ev276 owner to w276_new';
  for r in select inhrelid::regclass as t from pg_inherits where inhparent = 'public.ev276'::regclass loop
    execute format('alter table %s owner to w276_new', r.t);
  end loop;
  execute format('alter table %s owner to w276_new', (select obj::regclass from w276_obj where kind = 'copy'));
end $$;
select is(w276_owners(), 'copy=w276_new,delta=w276_old,fn=w276_old',
  'LIVENESS: two objects are left with the old owner, and the copy is the new owner''s already');
select ok(pg_has_role('w276_member', 'w276_old', 'USAGE') and not pg_has_role('w276_member', 'w276_new', 'MEMBER')
          and not pg_has_role('w276_old', 'w276_new', 'MEMBER'),
  'LIVENESS: w276_old and w276_member can each act as the old owner, and neither is a member of the new');

-- ======================================================================================================
-- PART A: a member of the old owner alone is refused, and nothing changes
-- ======================================================================================================
set role w276_old;
select throws_ok($$select pgpm.hand_over_scratch('public.ev276')$$, '42501',
  'pg_partition_magician: run select pgpm.hand_over_scratch(''public.ev276'') as a superuser or a member of both w276_old and w276_new: this session (w276_old) can act as w276_old but cannot give pgpm''s scratch objects for ev276 to the table''s owner w276_new, so nothing was handed over (docs/reference.md, "Handing a table to a new owner").',
  'the old owner itself is refused, 42501, told to run it as a member of both, rather than told it handed 2 over');
reset role;
set role w276_member;
select throws_ok($$select pgpm.hand_over_scratch('public.ev276')$$, '42501',
  'pg_partition_magician: run select pgpm.hand_over_scratch(''public.ev276'') as a superuser or a member of both w276_old and w276_new: this session (w276_member) can act as w276_old but cannot give pgpm''s scratch objects for ev276 to the table''s owner w276_new, so nothing was handed over (docs/reference.md, "Handing a table to a new owner").',
  'a member of the old owner only is refused the same way');
reset role;
select is(w276_owners(), 'copy=w276_new,delta=w276_old,fn=w276_old',
  'the refusals left every object with the owner it had: nothing was handed over, nothing taken back');

-- ======================================================================================================
-- PART B: the remedy, run as a superuser, hands over exactly what was not the new owner's
-- ======================================================================================================
select is(pgpm.hand_over_scratch('public.ev276'), 2, 'a superuser''s hand-over returns 2: the delta and the function, not the copy it already had');
select is(w276_owners(), 'copy=w276_new,delta=w276_new,fn=w276_new', 'every scratch object is the new owner''s');
select is(pgpm.hand_over_scratch('public.ev276'), 0, 'a second hand-over has nothing left to hand and says so');
set role w276_new;
select is(pgpm.regrain_step('public.ev276', :'mono', null, 100), 'copied:100',
  'the new owner''s next regrain step works the handed-over objects: it copies its next batch');
reset role;

select * from finish();

-- roles are cluster-wide: leave none behind (the database itself is dropped by the runner)
drop owned by w276_old, w276_new, w276_member;
drop role w276_member, w276_old, w276_new;
