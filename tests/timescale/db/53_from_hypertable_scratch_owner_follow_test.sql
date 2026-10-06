-- The hypertable's scratch objects follow its owner, or every step refuses up front (issue #986).
--
-- A from_hypertable migration's copy (<rel>_pgpm_dest), delta (<rel>_pgpm_delta) and capture function are owned
-- like the hypertable from the transaction that creates them (#949). ALTER TABLE <hypertable> OWNER TO reaches
-- none of them, and no drain and not the cutover called pgpm._scratch_owner_follow, so a hypertable handed to
-- a new owner mid-migration gave the new owner a raw 'permission denied for table <rel>_pgpm_delta' from the
-- first statement on the old owner's object, naming no remedy, where docs/reference.md ('Handing a table to a
-- new owner') promises every path that drops, empties or truncates them refuses once, up front, SQLSTATE 42501,
-- leading with the remedy. Each now calls the follow first (_from_hypertable_scratch_follow).
--
-- PART A, every step refuses, as the new owner, which holds none of the old owner's privileges: the drain
-- step, the drain, the append drain step, the append drain and the cutover. Each refusal is pinned by its
-- SQLSTATE AND its message (the procedures commit, and a procedure that does not refuse dies at its first
-- COMMIT inside the helper with 2D000, which must not pass; one that fails raw has 42501 with no remedy).
-- Liveness: the delta holds the three changed keys before and after every refusal, the copy still holds the
-- three rows' copied values, and the three objects are still the old owner's (nothing changed).
-- PART B, the remedy works: hand_over_scratch, run as a member of both owners, hands the three objects over,
-- and then the new owner's drain applies the three changes, by identity.
--
-- ASYMMETRIC: 30 rows copied, 3 of them updated after the copy (ids 2, 5, 7), named by identity. The chunks
-- live in public (associated_schema_name): re-owning a hypertable re-owns its chunks, and the fleet image's
-- postgres cannot grant CREATE on _timescaledb_internal (tests/timescale/db/33). Roles are named, never
-- `to current_user` (that segfaults a backend on the fleet image), created only when absent and dropped at
-- the end. bench/hypertable_scratch_owner_follow.sh runs this file against the
-- hypertable_drains_owner_not_followed mutant, which it must FAIL.
select plan(17);

do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'w53_old') then create role w53_old; end if;
  if not exists (select 1 from pg_roles where rolname = 'w53_new') then create role w53_new; end if;
end $$;
grant w53_old, w53_new to postgres;   -- by name: a member of both, as the hand-over requires
grant usage, create on schema public to w53_old, w53_new;
grant usage on schema pgpm to w53_new;
grant select, insert, update, delete on all tables in schema pgpm to w53_new;

set role w53_old;
create table public.m53 (ts timestamptz not null, id bigint not null, v int, primary key (id, ts));
select create_hypertable('public.m53', 'ts', chunk_time_interval => interval '1 day', associated_schema_name => 'public');
insert into public.m53 select timestamptz '2024-01-01 00:00+00' + g * interval '2 hours', g, g from generate_series(1, 30) g;
reset role;
call pgpm.from_hypertable_copy('public.m53', 'ts', p_track_changes => true);
update public.m53 set v = -id where id in (2, 5, 7);
alter table public.m53 owner to w53_new;

select pgpm._scratch_rel('public.m53', 'hypertable_delta')::text as delta \gset
select pgpm._scratch_rel('public.m53', 'hypertable_dest')::text as dest \gset

-- what a statement raised, as 'SQLSTATE: message', or 'no error'
create function w53_raised(p_sql text) returns text language plpgsql as $f$
begin
  execute p_sql;
  return 'no error';
exception when others then
  return sqlstate || ': ' || sqlerrm;
end $f$;
-- the delta's pending keys, and the copy's values for the changed rows, by identity
create function w53_pending() returns bigint[] language plpgsql as $f$
declare v bigint[];
begin
  execute format('select array_agg(distinct id order by id) from %s', pgpm._scratch_rel('public.m53', 'hypertable_delta')) into v;
  return v;
end $f$;
create function w53_copied() returns int[] language plpgsql as $f$
declare v int[];
begin
  execute format('select array_agg(v order by id) from %s where id in (2, 5, 7)', pgpm._scratch_rel('public.m53', 'hypertable_dest')) into v;
  return v;
end $f$;
create function w53_owners() returns text[] language sql as $f$
  select array[(select pg_get_userbyid(relowner)::text from pg_class where oid = pgpm._scratch_rel('public.m53', 'hypertable_dest')),
               (select pg_get_userbyid(relowner)::text from pg_class where oid = pgpm._scratch_rel('public.m53', 'hypertable_delta')),
               (select pg_get_userbyid(p.proowner)::text from pgpm.scratch s join pg_proc p on p.oid = s.obj
                 where s.parent_oid = 'public.m53'::regclass::oid and s.kind = 'hypertable_delta_fn')]
$f$;
-- the refusal every step must give, for p_what
create function w53_refusal(p_what text) returns text language sql as $f$
  select format('42501: pg_partition_magician: run select pgpm.hand_over_scratch(%L) as a superuser or a member of both w53_old and w53_new: %s of m53 cannot go on while pgpm''s scratch objects for it are owned by w53_old, not by the table''s owner w53_new, and this session (w53_new) can neither hand them over nor act as their owner. A table handed to a new owner needs them handed over too (docs/reference.md, "Handing a table to a new owner").',
                'public.m53', p_what)
$f$;

-- ======================================================================================================
-- PART A: every step refuses up front, as the new owner
-- ======================================================================================================
select is(w53_owners(), array['w53_old', 'w53_old', 'w53_old'],
  'LIVENESS: the copy, the delta and the capture function are still the old owner''s');
select is((select pg_get_userbyid(relowner)::text from pg_class where oid = 'public.m53'::regclass), 'w53_new',
  'LIVENESS: the hypertable now belongs to the new owner');
select ok(not pg_has_role('w53_new', 'w53_old', 'USAGE'), 'LIVENESS: the new owner holds none of the old owner''s privileges');
select is(w53_pending(), array[2, 5, 7]::bigint[], 'LIVENESS: the delta holds the three changed keys, for a drain to apply');
select is(w53_copied(), array[2, 5, 7], 'LIVENESS: the copy holds the three rows as they were copied');

set role w53_new;
create temp table w53_got as
  select 'from_hypertable_drain_delta_step' as what,
         w53_raised($$select pgpm.from_hypertable_drain_delta_step('public.m53', 'ts')$$) as got
  union all select 'from_hypertable_drain_delta', w53_raised($$call pgpm.from_hypertable_drain_delta('public.m53', 'ts')$$)
  union all select 'from_hypertable_drain_appends_step',
                   w53_raised($$select pgpm.from_hypertable_drain_appends_step('public.m53', 'ts', 100, null)$$)
  union all select 'from_hypertable_drain_appends', w53_raised($$call pgpm.from_hypertable_drain_appends('public.m53', 'ts')$$)
  union all select 'from_hypertable_cutover',
                   w53_raised($$call pgpm.from_hypertable_cutover('public.m53', 'ts', interval '1 month')$$);
reset role;
select is((select got from w53_got where what = 'from_hypertable_drain_delta_step'), w53_refusal('from_hypertable_drain_delta_step'),
  'from_hypertable_drain_delta_step refuses up front, 42501, naming pgpm.hand_over_scratch');
select is((select got from w53_got where what = 'from_hypertable_drain_delta'), w53_refusal('from_hypertable_drain_delta'),
  'from_hypertable_drain_delta refuses up front, 42501, naming pgpm.hand_over_scratch');
select is((select got from w53_got where what = 'from_hypertable_drain_appends_step'), w53_refusal('from_hypertable_drain_appends_step'),
  'from_hypertable_drain_appends_step refuses up front, 42501, naming pgpm.hand_over_scratch');
select is((select got from w53_got where what = 'from_hypertable_drain_appends'), w53_refusal('from_hypertable_drain_appends'),
  'from_hypertable_drain_appends refuses up front, 42501, naming pgpm.hand_over_scratch');
select is((select got from w53_got where what = 'from_hypertable_cutover'), w53_refusal('from_hypertable_cutover'),
  'from_hypertable_cutover refuses up front, 42501, naming pgpm.hand_over_scratch');
select is(w53_pending(), array[2, 5, 7]::bigint[], 'the refusals consumed none of the delta''s keys');
select is(w53_copied(), array[2, 5, 7], 'the refusals changed none of the copy''s rows');
select is(to_regclass('public.m53')::text || ':' || array_to_string(w53_owners(), ','),
  'm53:w53_old,w53_old,w53_old',
  'the hypertable is still there and every scratch object is still the old owner''s');

-- ======================================================================================================
-- PART B: the documented remedy, then the new owner's drain works
-- ======================================================================================================
select is(pgpm.hand_over_scratch('public.m53'), 3, 'LIVENESS: hand_over_scratch, run by a member of both owners, hands three objects over');
select is(w53_owners(), array['w53_new', 'w53_new', 'w53_new'], 'the copy, the delta and the capture function are the new owner''s');
set role w53_new;
call pgpm.from_hypertable_drain_delta('public.m53', 'ts');
reset role;
select is(w53_pending(), null::bigint[], 'the new owner''s drain emptied the delta');
select is(w53_copied(), array[-2, -5, -7], 'the new owner''s drain applied the three changes to the copy, by identity');

select * from finish();

-- roles are cluster-wide: leave none behind. Everything they own or hold a grant on goes first.
drop table public.m53;
drop table :delta, :dest;
revoke all on all tables in schema pgpm from w53_new;
revoke usage on schema pgpm from w53_new;
revoke usage, create on schema public from w53_old, w53_new;
drop owned by w53_old, w53_new;
drop role w53_old, w53_new;
