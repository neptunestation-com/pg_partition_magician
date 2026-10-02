-- from_hypertable_cutover refuses to swap a copy whose outgoing foreign keys are no longer the source's
-- (issue #840).
--
-- THE BUG. Outgoing foreign keys reach the migrated table only through from_hypertable_copy, which replays
-- the source's keys onto the destination and validates them there; the cutover does no work on them (#263),
-- and its shape check (#738), the one place it compares the copy with the source, compared columns,
-- defaults and CHECKs but not foreign keys. So a key added to the hypertable in the documented window
-- between the copy and the cutover was dropped with the source, and the migrated table accepted orphans;
-- and a key dropped in that window came back. Silently: no error, no log row. The shape check now compares
-- the outgoing keys by name and definition, up front and again under the swap's lock, and refuses, naming
-- every difference.
--
-- ASYMMETRIC FIXTURE. The window changes the keys in both directions at once: m40_dev_fkey (to dev40) is
-- ADDED to the source after the copy, and m40_site_fkey (to site40), which the copy carried, is DROPPED from
-- it. The refusal must name the two, each the right way round, and after the remedy the migrated table must
-- enforce the first and not the second (a row with an unknown site is accepted, so the orphan refusal is
-- the dev key and not the site key).
--
-- WHY the refusal is pinned by its message. The cutover commits, and throws_like runs it inside a function,
-- where a cutover that does NOT refuse dies at its first COMMIT with 2D000 and rolls back into the state a
-- refusal leaves. The message, naming the keys, is the only thing that separates the two. DDL that lands
-- while the cutover prepares reaches the same comparison under the lock, which bench/hypertable_cutover_shape.sh
-- proves for the check as a whole.
--
-- Autocommit, disposable-db. from_hypertable_copy and _cutover are called as bare statements.
select plan(11);

create table public.dev40 (id int primary key);
insert into public.dev40 select g from generate_series(1, 5) g;
create table public.site40 (code text primary key);
insert into public.site40 values ('a'), ('b');
create table public.m40 (id bigint not null, ts timestamptz not null, dev int, site text, primary key (id, ts),
                         constraint m40_site_fkey foreign key (site) references public.site40 (code));
select create_hypertable('public.m40', 'ts', chunk_time_interval => interval '1 day');
insert into public.m40
select g, timestamptz '2026-09-01 00:00+00' + g * interval '3 hours', 1 + g % 5, case when g % 2 = 0 then 'a' else 'b' end
  from generate_series(1, 20) g;

call pgpm.from_hypertable_copy('public.m40', 'ts');
select is(
  (select string_agg(conname || ':' || convalidated, ',' order by conname) from pg_constraint
    where conrelid = 'public.m40_pgpm_dest'::regclass and contype = 'f')
    || ' ' || (select string_agg(id::text, ',' order by id) from public.m40_pgpm_dest),
  'm40_site_fkey:true ' || (select string_agg(g::text, ',' order by g) from generate_series(1, 20) g),
  'LIVENESS: the copy holds every row and carries the source''s one key, validated');

-- The online window: one key added to the source, the other dropped from it. The copy keeps its key.
alter table public.m40 add constraint m40_dev_fkey foreign key (dev) references public.dev40 (id);
alter table public.m40 drop constraint m40_site_fkey;
select is(
  (select string_agg(conname || ':' || convalidated, ',' order by conname) from pg_constraint
    where conrelid = 'public.m40'::regclass and contype = 'f'),
  'm40_dev_fkey:true', 'LIVENESS: the source now has the validated m40_dev_fkey and no m40_site_fkey');
select throws_ok(
  $$ insert into public.m40 values (900, timestamptz '2026-09-02 07:00+00', 999, 'a') $$,
  '23503', NULL, 'LIVENESS: and the source refuses an orphan of dev40');

-- ================= THE CONTRACT: the cutover refuses, naming both keys =================
select throws_like(
  $$ call pgpm.from_hypertable_cutover('public.m40', 'ts', interval '1 day') $$,
  'pg_partition_magician: from_hypertable_cutover(m40) refusing to swap: the copy m40_pgpm_dest no longer has the source''s shape: FOREIGN KEY m40_dev_fkey (FOREIGN KEY (dev) REFERENCES dev40(id)) is on the source but not on the copy; FOREIGN KEY m40_site_fkey is on the copy but no longer on the source. %',
  'the cutover refuses the swap, naming the key added since the copy and the key dropped since');

-- Invariants (a wrongly proceeding cutover also rolls back at its first COMMIT and lands here).
select is(
  (select count(*)::int from timescaledb_information.hypertables where hypertable_schema = 'public' and hypertable_name = 'm40')
    || ' ' || (select string_agg(conname, ',' order by conname) from pg_constraint
                where conrelid = 'public.m40'::regclass and contype = 'f'),
  '1 m40_dev_fkey', 'invariant: m40 is still the hypertable, with its key');

-- ================= LIVENESS: the remedy the message names converts the table =================
call pgpm.from_hypertable_copy('public.m40', 'ts');
call pgpm.from_hypertable_cutover('public.m40', 'ts', interval '1 day', p_paused => false);
select is((select relkind::text from pg_class where oid = 'public.m40'::regclass), 'p',
  'LIVENESS: after a fresh copy the cutover converts the table');
select is(
  (select string_agg(id::text, ',' order by id) from public.m40),
  (select string_agg(g::text, ',' order by g) from generate_series(1, 20) g),
  'LIVENESS: with every row, by identity');
select is(
  (select string_agg(conname || ':' || pg_get_constraintdef(oid), ',' order by conname) from pg_constraint
    where conrelid = 'public.m40'::regclass and contype = 'f'),
  'm40_dev_fkey:FOREIGN KEY (dev) REFERENCES dev40(id)',
  'the migrated table carries the key added in the window, and not the one dropped in it');
select throws_ok(
  $$ insert into public.m40 values (901, timestamptz '2026-09-02 07:00+00', 999, 'a') $$,
  '23503', NULL, 'the migrated table refuses an orphan of dev40');
insert into public.m40 values (902, timestamptz '2026-09-02 08:00+00', 3, 'zzz');
select is((select site from public.m40 where id = 902), 'zzz',
  'and accepts a site site40 does not hold: the dropped key did not come back');
select is((select count(*)::int from public.m40 where id = 901), 0,
  'invariant: the orphan is not in the table');

select * from finish();
-- no teardown: the harness runs each db/ test in a throwaway database (disposable-db).
