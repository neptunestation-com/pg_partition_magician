-- The write frontier is read in pruned windows, and holds no lock-table slot per partition (issue #632).
--
-- THE BUG. _frontier_native read max(control) with one ORDER BY ... LIMIT 1 over the parent, which locked
-- every partition and its index (two lock-table slots each) until the caller's transaction ended. obtain's
-- lock budget (#786) is zeroed after that read, so a tick held twice the partition count plus what the
-- budget allows: at the default max_locks_per_transaction (64) and max_connections (100) a 12,000-cell
-- lookahead grown by maintain_obtain wedged at 5,727 partitions, every tick a skip_obtain `out of shared
-- memory`, the grid no longer growing. At about 7,000 the read alone overflowed the lock table.
--
-- THE CONTRACT. The read takes windows of the control column top-down, each pruned at planning to the
-- partitions it can reach and rolled back once read, so it holds at most one window's partitions at a time.
--   PART A  slots: at 1,001 partitions with the only row in the bottom cell (so every window is read), the
--           frontier read and a no-op obtain each leave fewer than 64 locks held (pg_locks, the fast-path ones
--           included), where the one unpruned read holds two per partition (the instrument's witness, in the
--           same transaction shape).
--   PART B  the value, exactly, as the maximum moves up through the windows: in the bottom cell (every
--           window read), exactly ON a window's lower cut (the window's bound is inclusive), in the grid's
--           top cell, and in a partition attached by hand ABOVE the grid, which pgpm does not record (#1119)
--           and only the top window, unbounded above, can reach. Then the rows are taken out: the anchor.
--   PART C  a uuidv7 grid, whose cuts are encoded uuids: a row exactly on the first cut, in the future, is
--           the frontier, not the clock.
-- Each step moves the maximum to a value the previous answer is not, so a read that missed a window
-- answers with a value the assertion names as wrong.
create extension if not exists pgtap;
set client_min_messages = warning;

select plan(15);

-- ==================== (A) the read holds no slot per partition ====================
create table public.fw401 (id bigint primary key);
insert into public.fw401 values (3);
call pgpm.transmute('public.fw401', 'id', 10::bigint, p_obtain => 1000);
-- transmute's obtain can stop at its lock budget; fill the grid the way the obtain job would
do $$ begin for i in 1 .. 6 loop exit when pgpm.obtain('public.fw401') = 0; end loop; end $$;

select is((select count(*)::int from pg_inherits where inhparent = 'public.fw401'::regclass), 1001,
  'LIVENESS: the grid is built to its lookahead, 1,001 partitions');

create temporary table slots401 (what text, val text, slots bigint);
do $$ declare v text; begin
  v := pgpm._frontier_native('public.fw401'::regclass);
  insert into slots401 select 'frontier', v, count(*) from pg_locks where pid = pg_backend_pid();
end $$;
do $$ declare v text; begin
  v := pgpm.obtain('public.fw401')::text;
  insert into slots401 select 'obtain', v, count(*) from pg_locks where pid = pg_backend_pid();
end $$;
do $$ declare v text; begin
  execute 'select t.id::text from public.fw401 t order by t.id desc limit 1' into v;
  insert into slots401 select 'unpruned', v, count(*) from pg_locks where pid = pg_backend_pid();
end $$;

select ok((select slots from slots401 where what = 'unpruned') >= 2002,
  'LIVENESS: the instrument sees one unpruned read of the parent hold two slots per partition');
select is((select val from slots401 where what = 'frontier'), '3',
  'LIVENESS: the measured read found the one row, in the bottom cell, so it read every window');
select cmp_ok((select slots from slots401 where what = 'frontier'), '<', 64::bigint,
  'A: the frontier read at 1,001 partitions leaves fewer than 64 locks held');
select is((select val from slots401 where what = 'obtain'), '0', 'LIVENESS: the measured obtain was a no-op tick');
select cmp_ok((select slots from slots401 where what = 'obtain'), '<', 64::bigint,
  'A: a no-op obtain at 1,001 partitions leaves fewer than 64 locks held');
select diag(format('slots held: frontier %s, no-op obtain %s, one unpruned read %s',
  (select slots from slots401 where what = 'frontier'), (select slots from slots401 where what = 'obtain'),
  (select slots from slots401 where what = 'unpruned')));

-- ==================== (B) the value, exactly, through the windows ====================
-- the first cut: the 128th distinct lo from the top of the recorded grid
create temporary table cut401 as
  select lo::bigint as lo from (select distinct lo from pgpm.part
                                 where parent_table = 'public.fw401'::regclass and attached) d
   order by lo::numeric desc offset 127 limit 1;
select ok((select lo from cut401) > 3 and (select lo from cut401) < 10000,
  'LIVENESS: the first cut lies inside the grid, above the bottom cell and below the top');

insert into public.fw401 select lo from cut401;
select is(pgpm._frontier_native('public.fw401'::regclass), (select lo::text from cut401),
  'B: a maximum exactly on a window''s lower cut is the frontier');

insert into public.fw401 values (10005);
select is(pgpm._frontier_native('public.fw401'::regclass), '10005',
  'B: a maximum in the grid''s top cell is the frontier');

create table public.fw401_extra partition of public.fw401 for values from (20000) to (20010);
insert into public.fw401 values (20003);
select ok(not exists (select 1 from pgpm.part where parent_table = 'public.fw401'::regclass
                       and child_oid = 'public.fw401_extra'::regclass::oid),
  'LIVENESS: the partition attached above the grid is one pgpm does not record');
select is(pgpm._frontier_native('public.fw401'::regclass), '20003',
  'B: a maximum in a partition attached by hand above the grid is the frontier');

delete from public.fw401;
select is(pgpm._frontier_native('public.fw401'::regclass), '0',
  'B: with every row taken out, the frontier is the anchor');

-- ==================== (C) a uuidv7 grid's cuts are encoded uuids ====================
create table public.fu401 (id uuid primary key);
insert into public.fu401 values (pgpm._ts_to_uuid(now()));
call pgpm.transmute('public.fu401', 'id', interval '1 hour', p_obtain => 300);
do $$ begin for i in 1 .. 6 loop exit when pgpm.obtain('public.fu401') = 0; end loop; end $$;
create temporary table cutu401 as
  select lo from (select distinct lo from pgpm.part where parent_table = 'public.fu401'::regclass and attached) d
   order by lo::timestamptz desc offset 127 limit 1;
select ok((select lo::timestamptz from cutu401) > now() + interval '1 day',
  'LIVENESS: the uuidv7 grid''s first cut lies over a day ahead of the clock');
insert into public.fu401 select pgpm._encode('uuidv7', lo)::uuid from cutu401;
select is(pgpm._frontier_native('public.fu401'::regclass), (select pgpm._ts_text(lo::timestamptz) from cutu401),
  'C: a uuidv7 maximum exactly on the first cut is the frontier');
select ok(pgpm._frontier_native('public.fu401'::regclass)::timestamptz > now() + interval '1 day',
  'C: and it is the row''s time, not the clock''s');

select * from finish();
