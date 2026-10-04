-- transmute refuses a null argument that has no null meaning, up front, naming it (issue #896).
--
-- PL/pgSQL compares a null with three-valued logic, so every check of the shape `if not p_x then raise`,
-- `if p_x not in (...) then raise` or `if p_x = 'error' then raise` reads a null as "not true" and skips
-- its refusal. Before the fix only p_obtain's null was refused (#581), and each other argument failed in
-- its own way:
--   A. p_regrain_batch or p_paused => null passed every check, phases 1 and 2 committed the
--      write-rejecting pgpm_monolith_bound CHECK and the claim, and the cutover died on config's NOT NULL
--      with a raw 23502: the table rejected every write past hi until an abort. The generic arguments
--      (the table, the column, the step, the anchor, the headroom, the lock timeout) had no check either.
--   B. p_incoming_fks => null passed the argument check, the incoming-FK gate and the cutover's drop, all
--      three of which compare it, so the incoming key followed the rename onto the monolith partition.
--   C. p_force_frontier => null skipped both far-frontier refusals (`not p_force_frontier` is null) and
--      pinned the monolith's permanent hi a year out, exactly as => true does.
--   D. The id overload reaches the same _transmute, with its own step and anchor.
-- The text_time and uuidv7 arguments, and extend_to, are tests/249.
--
-- INSTRUMENT, as tests/125: every refused call runs through dblink, so a build that does NOT refuse
-- really commits phases 1 and 2 (a committing procedure inside throws_* dies at its first COMMIT with
-- 2D000 and rolls back into the state a refusal leaves), and the state assertions after each part see the
-- damage the refusal exists to prevent. Each refusal is pinned by its message, which names the null
-- argument(s) and stops at a colon, so the assertion says WHICH argument was refused.
--
-- WITNESSES. Each part proves the condition its null would have exploited is present (B: the default
-- refuses the incoming key; C: the default refuses the far frontier, and => true pins the far hi the null
-- did), and each fixture converts once the null is gone, so a transmute that refused everything could not
-- pass. The liveness conversions pass p_retain => null explicitly: a null that DOES have a meaning (keep
-- everything) must still be accepted, which an over-eager fix refusing every null would break.
-- bench/null_arguments_refused.sh runs this file against the mutants (bench/mutations/mutate.py).
create extension if not exists pgtap;
create extension if not exists dblink;
set timezone = 'UTC';

select plan(37);

-- ======================= A. p_regrain_batch, p_paused, and the generic arguments =======================
create table public.n_ts (id bigint not null, ts timestamptz not null, primary key (id, ts));
insert into public.n_ts values (1, now() - interval '1 day'), (2, now() - interval '2 hours');

select throws_like(
  $$ select dblink_exec('dbname=' || current_database(),
       $c$ call pgpm.transmute('public.n_ts', 'ts', interval '1 month', p_regrain_batch => null) $c$) $$,
  'pg_partition_magician: transmute does not accept null for p_regrain_batch: %',
  'A: p_regrain_batch => null is refused, naming it');
select throws_like(
  $$ select dblink_exec('dbname=' || current_database(),
       $c$ call pgpm.transmute('public.n_ts', 'ts', interval '1 month', p_paused => null) $c$) $$,
  'pg_partition_magician: transmute does not accept null for p_paused: %',
  'A: p_paused => null is refused, naming it');
select throws_like(
  $$ select dblink_exec('dbname=' || current_database(),
       $c$ call pgpm.transmute('public.n_ts', 'ts', interval '1 month', p_paused => null, p_regrain_batch => null) $c$) $$,
  'pg_partition_magician: transmute does not accept null for p_regrain_batch, p_paused: %',
  'A: two nulls are refused together, both named, in the signature''s order');
select throws_like(
  $$ select dblink_exec('dbname=' || current_database(),
       $c$ call pgpm.transmute(null, 'ts', interval '1 month') $c$) $$,
  'pg_partition_magician: transmute does not accept null for p_parent: %',
  'A: a null table is refused, naming p_parent');
select throws_like(
  $$ select dblink_exec('dbname=' || current_database(),
       $c$ call pgpm.transmute('public.n_ts', null, interval '1 month') $c$) $$,
  'pg_partition_magician: transmute does not accept null for p_control: %',
  'A: a null control column is refused, naming p_control');
select throws_like(
  $$ select dblink_exec('dbname=' || current_database(),
       $c$ call pgpm.transmute('public.n_ts', 'ts', null::interval) $c$) $$,
  'pg_partition_magician: transmute does not accept null for p_interval: %',
  'A: a null interval is refused, naming p_interval');
select throws_like(
  $$ select dblink_exec('dbname=' || current_database(),
       $c$ call pgpm.transmute('public.n_ts', 'ts', interval '1 month', p_anchor => null) $c$) $$,
  'pg_partition_magician: transmute does not accept null for p_anchor: %',
  'A: a null anchor is refused, naming p_anchor');
select throws_like(
  $$ select dblink_exec('dbname=' || current_database(),
       $c$ call pgpm.transmute('public.n_ts', 'ts', interval '1 month', p_bound_headroom => null) $c$) $$,
  'pg_partition_magician: transmute does not accept null for p_bound_headroom: %',
  'A: a null p_bound_headroom is refused, naming it');
select throws_like(
  $$ select dblink_exec('dbname=' || current_database(),
       $c$ call pgpm.transmute('public.n_ts', 'ts', interval '1 month', p_lock_timeout => null) $c$) $$,
  'pg_partition_magician: transmute does not accept null for p_lock_timeout: %',
  'A: a null p_lock_timeout is refused, naming it');

-- what the refusals left: nothing. A write past the hi a bound would have imposed (the first month
-- boundary after now) is accepted, then removed so the liveness conversion's frontier stays near the clock.
create table n_probe (accepted boolean, err text);
do $$ begin
  insert into public.n_ts values (3, now() + interval '45 days');
  insert into n_probe values (true, null);
exception when others then
  insert into n_probe values (false, sqlerrm);
end $$;
select is((select accepted from n_probe), true,
  'A: n_ts accepts a write 45 days ahead after the refusals (' || coalesce((select err from n_probe), 'no error') || ')');
delete from public.n_ts where id = 3;
select ok(not exists (select 1 from pg_constraint where conrelid = 'public.n_ts'::regclass and conname = 'pgpm_monolith_bound'),
  'A: no refused call left a pgpm_monolith_bound CHECK on n_ts');
select ok(not exists (select 1 from pgpm.transmute_inflight where parent_table = 'public.n_ts'::regclass)
          and not exists (select 1 from pgpm.config where parent_table = 'public.n_ts'::regclass),
  'A: nor a claim or a registration');

-- LIVENESS: the same table converts once the nulls are gone, and a documented null (p_retain) is accepted
call pgpm.transmute('public.n_ts', 'ts', interval '1 month', p_retain => null, p_obtain => 2);
select is((select relkind::text from pg_class where oid = 'public.n_ts'::regclass), 'p',
  'A LIVENESS: n_ts converts with every argument set, p_retain => null included');
select is((select (retain is null) and regrain_batch = 5000 and paused from pgpm.config where parent_table = 'public.n_ts'::regclass), true,
  'A LIVENESS: registered with retain null (keep everything) and the defaults the refused nulls stood for');
select is((select array_agg(id order by id) from public.n_ts), array[1, 2]::bigint[],
  'A LIVENESS: n_ts holds exactly rows 1 and 2');

-- ======================= B. p_incoming_fks => null on a table with an incoming key =======================
create table public.n_pa (id bigint not null, ts timestamptz not null, primary key (id, ts));
insert into public.n_pa values (1, now() - interval '1 day'), (2, now() - interval '2 hours');
create table public.n_ch (cid int primary key, pid bigint not null, pts timestamptz not null,
                          constraint n_ch_fk foreign key (pid, pts) references public.n_pa (id, ts));
insert into public.n_ch values (1, 1, (select ts from public.n_pa where id = 1));

select throws_like(
  $$ select dblink_exec('dbname=' || current_database(),
       $c$ call pgpm.transmute('public.n_pa', 'ts', interval '1 month') $c$) $$,
  'pg_partition_magician: n_pa has incoming foreign key(s) (n_ch_fk on n_ch)%',
  'B WITNESS: with the default p_incoming_fks the incoming key n_ch_fk is refused');
select throws_like(
  $$ select dblink_exec('dbname=' || current_database(),
       $c$ call pgpm.transmute('public.n_pa', 'ts', interval '1 month', p_incoming_fks => null) $c$) $$,
  'pg_partition_magician: transmute does not accept null for p_incoming_fks: %',
  'B: p_incoming_fks => null is refused, naming it');
select is((select relkind::text from pg_class where oid = 'public.n_pa'::regclass), 'r',
  'B: n_pa is still a plain table');
select is((select confrelid::regclass::text from pg_constraint where conrelid = 'public.n_ch'::regclass and conname = 'n_ch_fk'),
  'n_pa', 'B: n_ch_fk still references n_pa itself, not a monolith partition');
select ok(not exists (select 1 from pgpm.dropped_fk where constraint_name = 'n_ch_fk')
          and not exists (select 1 from pgpm.config where parent_table = 'public.n_pa'::regclass),
  'B: nothing was recorded or registered');

-- LIVENESS: 'preserve' converts it and records the key against the new parent
call pgpm.transmute('public.n_pa', 'ts', interval '1 month', p_incoming_fks => 'preserve', p_obtain => 2);
select is((select relkind::text from pg_class where oid = 'public.n_pa'::regclass), 'p',
  'B LIVENESS: n_pa converts with p_incoming_fks => ''preserve''');
select is((select parent_table::text from pgpm.dropped_fk where constraint_name = 'n_ch_fk'), 'n_pa',
  'B LIVENESS: and n_ch_fk is recorded against n_pa for restore');

-- ======================= C. p_force_frontier => null on a row a year ahead =======================
create table public.n_ff (id bigint not null, ts timestamptz not null, primary key (id, ts));
insert into public.n_ff values (1, now() - interval '1 day'), (2, now() + interval '1 year');

select throws_like(
  $$ select dblink_exec('dbname=' || current_database(),
       $c$ call pgpm.transmute('public.n_ff', 'ts', interval '1 month') $c$) $$,
  'pg_partition_magician: n_ff cannot be partitioned on a time grid using ts: its newest value is %',
  'C WITNESS: with the default p_force_frontier (false) the far frontier is refused for this data');
select throws_like(
  $$ select dblink_exec('dbname=' || current_database(),
       $c$ call pgpm.transmute('public.n_ff', 'ts', interval '1 month', p_force_frontier => null) $c$) $$,
  'pg_partition_magician: transmute does not accept null for p_force_frontier: %',
  'C: p_force_frontier => null is refused, naming it, not read as true');
select ok(not exists (select 1 from pgpm.config where parent_table = 'public.n_ff'::regclass)
          and not exists (select 1 from pg_constraint where conrelid = 'public.n_ff'::regclass and conname = 'pgpm_monolith_bound')
          and not exists (select 1 from pgpm.transmute_inflight where parent_table = 'public.n_ff'::regclass),
  'C: n_ff is not converted, bounded or claimed');
select is((select array_agg(id order by id) from public.n_ff), array[1, 2]::bigint[],
  'C: both rows, the future-dated one included, are still in n_ff');

-- LIVENESS: => true accepts the far frontier, pinning the monolith's hi months out: what the null did
call pgpm.transmute('public.n_ff', 'ts', interval '1 month', p_force_frontier => true, p_obtain => 1);
select ok((select p.hi::timestamptz > now() + interval '6 months'
             from pgpm.part p join pgpm.config c on c.parent_table = p.parent_table
            where p.parent_table = 'public.n_ff'::regclass and p.child_oid = c.monolith_oid),
  'C LIVENESS: p_force_frontier => true converts n_ff with its monolith hi months ahead');

-- ======================= D. the id overload =======================
create table public.n_id (id bigint primary key, body text);
insert into public.n_id select g, 'row ' || g from generate_series(1, 15) g;   -- step 10 -> monolith [0, 20)

select throws_like(
  $$ select dblink_exec('dbname=' || current_database(),
       $c$ call pgpm.transmute('public.n_id', 'id', null::bigint) $c$) $$,
  'pg_partition_magician: transmute does not accept null for p_step: %',
  'D: a null id step is refused, named as the id overload spells it');
select throws_like(
  $$ select dblink_exec('dbname=' || current_database(),
       $c$ call pgpm.transmute('public.n_id', 'id', 10::bigint, p_anchor => null) $c$) $$,
  'pg_partition_magician: transmute does not accept null for p_anchor: %',
  'D: a null id anchor is refused');
select throws_like(
  $$ select dblink_exec('dbname=' || current_database(),
       $c$ call pgpm.transmute('public.n_id', 'id', 10::bigint, p_regrain_batch => null) $c$) $$,
  'pg_partition_magician: transmute does not accept null for p_regrain_batch: %',
  'D: p_regrain_batch => null is refused on the id overload too');
select throws_like(
  $$ select dblink_exec('dbname=' || current_database(),
       $c$ call pgpm.transmute('public.n_id', 'id', 10::bigint, p_incoming_fks => null) $c$) $$,
  'pg_partition_magician: transmute does not accept null for p_incoming_fks: %',
  'D: and so is p_incoming_fks => null');
select ok(not exists (select 1 from pg_constraint where conrelid = 'public.n_id'::regclass and conname = 'pgpm_monolith_bound')
          and not exists (select 1 from pgpm.transmute_inflight where parent_table = 'public.n_id'::regclass)
          and not exists (select 1 from pgpm.config where parent_table = 'public.n_id'::regclass),
  'D: n_id is not bounded, claimed or registered');
insert into public.n_id values (25, 'twenty-five');
select is((select body from public.n_id where id = 25), 'twenty-five',
  'D: n_id accepts an id past the monolith a bound would have imposed');
delete from public.n_id where id = 25;

-- LIVENESS: the id overload converts with every argument set, p_retain => null included
call pgpm.transmute('public.n_id', 'id', 10::bigint, p_retain => null, p_obtain => 2);
select is((select string_agg('[' || lo || ',' || hi || ')', ' ' order by lo::numeric) from pgpm.part
            where parent_table = 'public.n_id'::regclass and attached),
  '[0,20) [20,30) [30,40)', 'D LIVENESS: n_id converts on the id grid, monolith [0, 20) and two forward cells');
select is((select retain from pgpm.config where parent_table = 'public.n_id'::regclass), null,
  'D LIVENESS: registered with retain null');
insert into public.n_id values (25, 'twenty-five');
select is((select c.relname::text from public.n_id e join pg_class c on c.oid = e.tableoid where e.id = 25),
  'n_id_p0000000000000000020', 'D LIVENESS: id 25 lands in the forward partition [20, 30)');
select is((select count(*)::int from pgpm.transmute_inflight
            where parent_table in ('public.n_ts'::regclass, 'public.n_pa'::regclass, 'public.n_ff'::regclass, 'public.n_id'::regclass)),
  0, 'LIVENESS: every liveness conversion completed and released its claim');

select * from finish();
