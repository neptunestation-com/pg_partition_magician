-- A re-run of from_hypertable_copy hands the previous copy's objects to the hypertable's owner before it drops
-- them, or refuses up front (issue #1037, bullet 2).
--
-- THE DEFECT. A re-run of from_hypertable_copy replaces what the previous copy recorded (#955): it drops the
-- capture trigger, the capture function, the delta and the copy, by their oids. #986 made every drain and the
-- cutover call pgpm._scratch_owner_follow first (_from_hypertable_scratch_follow), and the copy did not. So
-- after ALTER TABLE <hypertable> OWNER TO, the new owner's re-run died raw 'must be owner of function
-- <rel>_pgpm_delta_fn' (or of the old copy, without tracking) on the old owner's objects, naming no remedy,
-- where docs/reference.md ("Handing a table to a new owner") promises every path that drops those objects
-- refuses once, up front, SQLSTATE 42501, leading with pgpm.hand_over_scratch.
--
-- PART A, the new owner, which holds none of the old owner's privileges, re-runs the copy of a tracking copy
-- (m371) and of an append-only one (k371); each is refused 42501 by the follow, pinned by its whole message
-- (the copy commits, so one that does not refuse dies at its first COMMIT inside the helper with 2D000, and
-- one that fails raw has 42501 with no remedy: neither passes). Liveness: the objects are the old owner's and
-- the hypertables the new owner's; after the refusals the apparatus is untouched (the same oids, still the old
-- owner's, the trigger still on m371, the delta's pending keys still there).
-- PART B, the follow hands over when it may: a member of both owners re-runs k371's copy, which hands the old
-- copy over, drops it and builds a new one, the new owner's, with every row. And the documented remedy:
-- hand_over_scratch, then the new owner's own re-run of m371's tracking copy, which replaces the apparatus.
--
-- ASYMMETRIC: m371 holds 30 rows (ids 1 to 30), 2 of them updated after the copy (ids 4 and 9); k371 holds 12
-- (ids 101 to 112). The chunks live in public (associated_schema_name), as in tests/timescale/db/53, whose
-- harness notes apply. bench/hypertable_copy_rerun_owner_follow.sh runs this file against the
-- hypertable_copy_rerun_owner_not_followed mutant, which it must FAIL.
select plan(15);

do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'w371_old') then create role w371_old; end if;
  if not exists (select 1 from pg_roles where rolname = 'w371_new') then create role w371_new; end if;
end $$;
grant w371_old, w371_new to postgres;   -- by name: a member of both, as the hand-over requires
grant usage, create on schema public to w371_old, w371_new;
grant usage on schema pgpm to w371_new;
grant select, insert, update, delete on all tables in schema pgpm to w371_new;

set role w371_old;
create table public.m371 (ts timestamptz not null, id bigint not null, v int, primary key (id, ts));
select create_hypertable('public.m371', 'ts', chunk_time_interval => interval '1 day', associated_schema_name => 'public');
insert into public.m371 select timestamptz '2024-01-01 00:00+00' + g * interval '2 hours', g, g from generate_series(1, 30) g;
create table public.k371 (ts timestamptz not null, id bigint not null, v int);
select create_hypertable('public.k371', 'ts', chunk_time_interval => interval '1 day', associated_schema_name => 'public');
insert into public.k371 select timestamptz '2024-02-01 00:00+00' + g * interval '3 hours', 100 + g, g from generate_series(1, 12) g;
reset role;
call pgpm.from_hypertable_copy('public.m371', 'ts', p_track_changes => true);
call pgpm.from_hypertable_copy('public.k371', 'ts');
update public.m371 set v = -id where id in (4, 9);
alter table public.m371 owner to w371_new;
alter table public.k371 owner to w371_new;

-- what a statement raised, as 'SQLSTATE: message', or 'no error'
create function w371_raised(p_sql text) returns text language plpgsql as $f$
begin
  execute p_sql;
  return 'no error';
exception when others then
  return sqlstate || ': ' || sqlerrm;
end $f$;
-- every object pgpm recorded for a hypertable, as kind=oid:owner, in kind order
create function w371_scratch(p_ht regclass) returns text language sql as $f$
  select string_agg(s.kind || '=' || s.obj || ':'
                    || coalesce((select pg_get_userbyid(c.relowner)::text from pg_class c where c.oid = s.obj),
                                (select pg_get_userbyid(p.proowner)::text from pg_proc p where p.oid = s.obj)),
                    ',' order by s.kind)
    from pgpm.scratch s where s.parent_oid = p_ht::oid
$f$;
-- the refusal the copy must give
create function w371_refusal(p_ht text) returns text language sql as $f$
  select format('42501: pg_partition_magician: run select pgpm.hand_over_scratch(%L) as a superuser or a member of both w371_old and w371_new: from_hypertable_copy of %s cannot go on while pgpm''s scratch objects for it are owned by w371_old, not by the table''s owner w371_new, and this session (w371_new) can neither hand them over nor act as their owner. A table handed to a new owner needs them handed over too (docs/reference.md, "Handing a table to a new owner").',
                'public.' || p_ht, p_ht)
$f$;
create table w371_before as
  select 'm371' as ht, w371_scratch('public.m371') as s union all select 'k371', w371_scratch('public.k371');

-- ======================================================================================================
-- PART A: the new owner's re-run refuses up front
-- ======================================================================================================
select ok((select s from w371_before where ht = 'm371') ~ '^hypertable_delta=[0-9]+:w371_old,hypertable_delta_fn=[0-9]+:w371_old,hypertable_dest=[0-9]+:w371_old$',
  'LIVENESS: m371''s copy, delta and capture function are recorded, and the old owner''s');
select ok((select s from w371_before where ht = 'k371') ~ '^hypertable_dest=[0-9]+:w371_old$',
  'LIVENESS: k371''s copy is recorded, and the old owner''s');
select is((select string_agg(pg_get_userbyid(relowner)::text, ',' order by relname) from pg_class
            where oid in ('public.m371'::regclass, 'public.k371'::regclass)), 'w371_new,w371_new',
  'LIVENESS: both hypertables now belong to the new owner');
select ok(not pg_has_role('w371_new', 'w371_old', 'USAGE'), 'LIVENESS: the new owner holds none of the old owner''s privileges');

set role w371_new;
create temp table w371_got as
  select 'm371' as ht, w371_raised($$call pgpm.from_hypertable_copy('public.m371', 'ts', p_track_changes => true)$$) as got
  union all select 'k371', w371_raised($$call pgpm.from_hypertable_copy('public.k371', 'ts')$$);
reset role;
select is((select got from w371_got where ht = 'm371'), w371_refusal('m371'),
  'the new owner''s re-run of a tracking copy refuses up front, 42501, naming pgpm.hand_over_scratch (#1037)');
select is((select got from w371_got where ht = 'k371'), w371_refusal('k371'),
  'the new owner''s re-run of an append-only copy refuses the same way');
select is(w371_scratch('public.m371') || ' / ' || w371_scratch('public.k371'),
  (select s from w371_before where ht = 'm371') || ' / ' || (select s from w371_before where ht = 'k371'),
  'the refusals dropped and handed over nothing: the same objects, still the old owner''s');
select ok(exists (select 1 from pg_trigger where tgrelid = 'public.m371'::regclass and tgname = 'm371_pgpm_delta_trg'),
  'm371''s capture trigger is still on the hypertable');
select is((select array_agg(distinct id order by id) from public.m371_pgpm_delta), array[4, 9]::bigint[],
  'm371''s delta still holds the two changed keys');

-- ======================================================================================================
-- PART B: the follow hands over when it may, and the documented remedy works
-- ======================================================================================================
call pgpm.from_hypertable_copy('public.k371', 'ts');   -- postgres: a member of both owners
select ok(w371_scratch('public.k371') ~ '^hypertable_dest=[0-9]+:w371_new$'
          and w371_scratch('public.k371') <> (select s from w371_before where ht = 'k371'),
  'a member of both owners re-runs k371''s copy: the old copy is handed over and replaced by one the new owner owns');
select is((select string_agg(id::text, ',' order by id) from public.k371_pgpm_dest),
  (select string_agg(id::text, ',' order by id) from public.k371),
  'and the new copy holds k371''s rows, 101 to 112');
select ok(not exists (select 1 from pg_class c join regexp_split_to_table((select s from w371_before where ht = 'k371'), ',') e
                        on c.oid = split_part(split_part(e, '=', 2), ':', 1)::oid),
  'the previous copy is gone');

select is(pgpm.hand_over_scratch('public.m371'), 3, 'LIVENESS: hand_over_scratch, run by a member of both owners, hands m371''s three objects over');
set role w371_new;
call pgpm.from_hypertable_copy('public.m371', 'ts', p_track_changes => true);
reset role;
select ok(w371_scratch('public.m371') ~ '^hypertable_delta=[0-9]+:w371_new,hypertable_delta_fn=[0-9]+:w371_new,hypertable_dest=[0-9]+:w371_new$'
          and w371_scratch('public.m371') <> (select s from w371_before where ht = 'm371'),
  'after the remedy the new owner''s re-run replaces m371''s apparatus with its own');
select is((select string_agg(id || '=' || v, ',' order by id) from public.m371_pgpm_dest where id in (3, 4, 9, 10)),
  '3=3,4=-4,9=-9,10=10', 'and the new copy holds m371''s rows as they are now, by identity');

select * from finish();

-- roles are cluster-wide: leave none behind. Everything they own or hold a grant on goes first.
drop table public.m371 cascade;
drop table public.k371 cascade;
drop table if exists public.m371_pgpm_delta, public.m371_pgpm_dest, public.k371_pgpm_dest;
revoke all on all tables in schema pgpm from w371_new;
revoke usage on schema pgpm from w371_new;
revoke usage, create on schema public from w371_old, w371_new;
drop owned by w371_old, w371_new;
drop role w371_old, w371_new;
