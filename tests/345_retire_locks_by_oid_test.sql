-- A lock taken by name is checked against the oid it was meant for (issue #1335 bullet 10).
--
-- THE BUG. retire() proves a partition's name still denotes the relation pgpm.part recorded (the #407/#428
-- identity check), then took its SHARE UPDATE EXCLUSIVE lock BY NAME. LOCK TABLE resolves the name again once the
-- lock is granted, so a rename of the partition plus a table created under its old name, committed while retire()
-- waited, left the lock on that table. retire() then judged the original (by oid, still attached) and went on to
-- the one-step `drop table <schema>.<name>`, which resolved the name a third time and dropped the stranger, rows
-- and all, reported true and logged retain_drop. A DROP TABLE that waits for its lock re-resolves its name the same
-- way, and so does ATTACH PARTITION, which is how the regrain swap attached a table that took a renamed copy's
-- name, and dropped the source whose rows only the copy held, and how _retain_recall attached a table that took
-- a detached partition's name in its place.
--
-- THE CONTRACT.
--   PART A  retire() on a time grid (nothing locks the partition before its own lock), the partition renamed aside
--           and a table created under its name while retire() waits for that lock: false, logged
--           fail_retain_identity naming the oid the name stopped denoting, and nothing else logged; the stranger
--           keeps its rows; the partition stays attached with its rows and its pgpm.part row.
--   PART B  the same with nothing put in the name's place: pgpm's refusal (false, fail_retain_identity), not
--           LOCK TABLE's raw 42P01 about the old name; the partition, renamed back, is then retired (true,
--           retain_drop), so the refusal is the name's, not the lock's.
--   PART C  the sibling: the regrain swap's ATTACH of a copy, the copy renamed aside and a table LIKE it
--           (INCLUDING ALL, so its bound CHECK too) created under its name while the swap waits for the copy: the
--           copy pgpm recorded is the one attached (found by oid wherever it sits, #707), so the table's range
--           holds the copied rows, and the stranger is attached to nothing and keeps its rows.
--   PART D  the sibling: _retain_recall's re-attach of a partition its retirement detached (retention loosened
--           since), the partition renamed aside and a table LIKE it created under its name while the ATTACH
--           waits: the stranger is not attached (fail_retain_reattach, the mark kept), and the table serves none
--           of its rows.
-- Every concurrent order is set by a lock queue: a second session ('h345') holds ACCESS EXCLUSIVE on the target, a
-- third ('r345') makes the call, and a server-side poll (snapshot cleared every iteration) sees the call waiting
-- for its lock on the target's oid before the holder renames, creates and commits.
--
-- ASYMMETRIC FIXTURES. A's partition holds 3 rows and its stranger 2; B's partition holds 4; C's copy holds ids
-- 10..490 (49 rows) and its stranger 2 rows (7, 8); D's partition ids 1..2500 and its stranger 2 rows (7, 8). Every check names the relation by oid and its rows by value.
-- retire(), regrain_step and _retain_recall are functions, not committing procedures; no throws_* here.
create extension if not exists pgtap;
create extension if not exists dblink;
set client_min_messages = warning;
select plan(36);

-- the call in session r345 is waiting, ungranted, for p_mode on p_oid: one statement per sample, snapshot cleared
create function pg_temp.waits_for(p_oid oid, p_mode text) returns boolean language plpgsql as $$
begin
  for i in 1 .. 400 loop
    perform pg_stat_clear_snapshot();
    if exists (select 1 from pg_locks l
                where not l.granted and l.locktype = 'relation' and l.relation = p_oid and l.mode = p_mode
                  and l.pid = current_setting('pgpm345.r_pid')::int) then
      return true;
    end if;
    perform pg_sleep(0.025);
  end loop;
  return false;
end $$;

-- the ids a relation holds, read by its oid: null when no relation has that oid any more (a read by name would
-- fail the file on a dropped relation, and could read whatever holds the name)
create function pg_temp.ids_of(p_oid oid) returns bigint[] language plpgsql as $$
declare v bigint[];
begin
  if not exists (select 1 from pg_class where oid = p_oid) then return null; end if;
  execute format('select array_agg(id order by id) from only %s', p_oid::regclass) into v;
  return v;
end $$;

select dblink_connect('h345', format('dbname=%s user=postgres', current_database())) as h \gset
select dblink_connect('r345', format('dbname=%s user=postgres', current_database())) as r \gset
select set_config('pgpm345.r_pid', (select pid::text from dblink('r345', 'select pg_backend_pid()') as t(pid int)), false) as r_pid \gset

-- ======================= fixtures: two time-grid tables, A's and B's, each wholly behind a 1 s horizon ===========
create table public.r345a (id bigint, ts timestamptz not null, payload text, primary key (id, ts));
insert into public.r345a
select g, clock_timestamp() - interval '10 seconds' + make_interval(secs => g / 1000.0), 'a' from generate_series(1, 3) g;
call pgpm.transmute('public.r345a', 'ts', interval '1 second', p_obtain => 4, p_retain => interval '1 second', p_paused => true);
create table public.r345b (id bigint, ts timestamptz not null, payload text, primary key (id, ts));
insert into public.r345b
select g, clock_timestamp() - interval '10 seconds' + make_interval(secs => g / 1000.0), 'b' from generate_series(1, 4) g;
call pgpm.transmute('public.r345b', 'ts', interval '1 second', p_obtain => 4, p_retain => interval '1 second', p_paused => true);

select p.child_name as a_name, p.hi as a_hi, p.child_oid as a_oid from pgpm.part p
  join pgpm.config c on c.parent_table = p.parent_table and c.monolith_oid = p.child_oid
 where p.parent_table = 'public.r345a'::regclass \gset
select p.child_name as b_name, p.hi as b_hi, p.child_oid as b_oid from pgpm.part p
  join pgpm.config c on c.parent_table = p.parent_table and c.monolith_oid = p.child_oid
 where p.parent_table = 'public.r345b'::regclass \gset
select pg_sleep(greatest(0, extract(epoch from (greatest(:'a_hi'::timestamptz, :'b_hi'::timestamptz) + interval '1.5 seconds' - clock_timestamp()))));

select is(pg_temp.ids_of(:'a_oid'), array[1, 2, 3]::bigint[],
  'fixture: A''s partition (the monolith) holds ids 1, 2, 3');
select is((select count(*)::int from pg_constraint where confrelid in ('public.r345a'::regclass, 'public.r345b'::regclass) and contype = 'f'), 0,
  'fixture: neither table is referenced, so retire() takes the one-step DROP');

-- ======================= (A) a rename and a stranger under the name while retire() waits =======================
select max(id) as a_mark from pgpm.log \gset
select dblink_exec('h345', 'begin') as a1 \gset
select dblink_exec('h345', format('lock table public.%I in access exclusive mode', :'a_name')) as a2 \gset
select dblink_send_query('r345', format('select pgpm.retire(%L, %L)::text', 'public.r345a', :'a_name')) as a3 \gset
select ok(pg_temp.waits_for(:'a_oid'::oid, 'ShareUpdateExclusiveLock'),
  'LIVENESS: retire() passed the identity check and waits for SHARE UPDATE EXCLUSIVE on the partition''s oid');
select dblink_exec('h345', format('alter table public.%I rename to r345a_aside', :'a_name')) as a4 \gset
select dblink_exec('h345', format('create table public.%I (id bigint, payload text)', :'a_name')) as a5 \gset
select dblink_exec('h345', format('insert into public.%I values (7, %L), (8, %L)', :'a_name', 'stranger', 'stranger')) as a6 \gset
select o as a_squat from dblink('h345', format('select %L::regclass::oid', 'public.' || quote_ident(:'a_name'))) as t(o oid) \gset
select dblink_exec('h345', 'commit') as a7 \gset
select x as a_ret from dblink_get_result('r345') as t(x text) \gset
select count(*) as a_drained from dblink_get_result('r345') as t(x text) \gset

select ok(:'a_squat'::oid <> :'a_oid'::oid, 'LIVENESS: the name denotes another relation now, the stranger');
select is(:'a_ret'::text, 'false', 'retire() returns false: it dropped nothing');
select is(pg_temp.ids_of(:'a_oid'), array[1, 2, 3]::bigint[], 'the partition, renamed aside, keeps ids 1, 2, 3');
select ok(exists (select 1 from pg_inherits where inhrelid = :'a_oid'::oid and inhparent = 'public.r345a'::regclass),
  'and is still attached to its parent');
select is((select child_oid from pgpm.part where parent_table = 'public.r345a'::regclass and child_name = :'a_name'),
  :'a_oid'::oid, 'and its pgpm.part row is kept, anchored to its oid');
select ok(exists (select 1 from pg_class where oid = :'a_squat'::oid), 'the stranger still exists');
select is(pg_temp.ids_of(:'a_squat'), array[7, 8]::bigint[],
  'and keeps its rows 7, 8');
select is((select array_agg(action order by id) from pgpm.log where id > :a_mark and parent_table = 'public.r345a'::regclass),
  array['fail_retain_identity']::text[], 'the call logged one row, fail_retain_identity, and no retain_drop');
select ok(exists (select 1 from pgpm.log where id > :a_mark and parent_table = 'public.r345a'::regclass
                   and action = 'fail_retain_identity'
                   and method like format('public.%s stopped denoting oid %s while retire() waited for its lock on it%%', quote_ident(:'a_name'), :'a_oid')),
  'naming the name and the oid it stopped denoting');

-- ======================= (B) a rename with nothing in the name's place =======================
select max(id) as b_mark from pgpm.log \gset
select dblink_exec('h345', 'begin') as b1 \gset
select dblink_exec('h345', format('lock table public.%I in access exclusive mode', :'b_name')) as b2 \gset
select dblink_send_query('r345', format('select pgpm.retire(%L, %L)::text', 'public.r345b', :'b_name')) as b3 \gset
select ok(pg_temp.waits_for(:'b_oid'::oid, 'ShareUpdateExclusiveLock'),
  'LIVENESS: retire() waits for its lock on B''s partition');
select dblink_exec('h345', format('alter table public.%I rename to r345b_aside', :'b_name')) as b4 \gset
select dblink_exec('h345', 'commit') as b5 \gset
select count(*) as b_rows from dblink_get_result('r345', false) as t(x text) \gset
select is(dblink_error_message('r345'), 'OK', 'retire() raises nothing (LOCK TABLE''s 42P01 about the old name is no refusal)');
select count(*) as b_drained from dblink_get_result('r345', false) as t(x text) \gset
select is((select array_agg(action order by id) from pgpm.log where id > :b_mark and parent_table = 'public.r345b'::regclass),
  array['fail_retain_identity']::text[], 'it refuses as the identity check does: fail_retain_identity, nothing dropped');
select is(pg_temp.ids_of(:'b_oid'), array[1, 2, 3, 4]::bigint[],
  'B''s partition keeps ids 1..4');
select lives_ok(format('alter table public.r345b_aside rename to %I', :'b_name'), 'the operator renames it back');
select is(pgpm.retire('public.r345b', :'b_name'), true,
  'LIVENESS: and retire() then retires it, so the refusal was the name''s, not the lock''s');
select ok(not exists (select 1 from pg_class where oid = :'b_oid'::oid)
          and not exists (select 1 from pgpm.part where parent_table = 'public.r345b'::regclass and child_name = :'b_name'),
  'the partition and its pgpm.part row are gone');

-- ======================= (C) the sibling: the regrain swap attaches the copy, not a table under its name =========
create table public.r345c (id bigint primary key, payload text);
insert into public.r345c select g * 10, 'c' from generate_series(1, 99) g;
call pgpm.transmute('public.r345c', 'id', 1000, p_paused => true);
insert into public.r345c values (20000, 'frontier');
create function pg_temp.c_step() returns text language sql as $$
  select pgpm.regrain_step('public.r345c', (select child_name from pgpm.part
    where parent_table = 'public.r345c'::regclass and attached and lo = '0'), '500', 1000) $$;
select is(array[pg_temp.c_step(), pg_temp.c_step(), pg_temp.c_step()], array['prepared', 'copied:49', 'copied:50'],
  'fixture: C''s regrain of [0, 1000) to 500 is prepared and copies both halves; the next tick swaps');
select child_oid as c_oid from pgpm.part
 where parent_table = 'public.r345c'::regclass and child_name = 'r345c_p0000000000000000000' and not attached \gset
select is(pg_temp.ids_of(:'c_oid'), (select array_agg((g * 10)::bigint order by g) from generate_series(1, 49) g),
  'fixture: the copy of [0, 500) holds ids 10..490');

select dblink_exec('h345', 'begin') as c1 \gset
select dblink_exec('h345', 'lock table public.r345c_p0000000000000000000 in access exclusive mode') as c2 \gset
select dblink_send_query('r345', $$select pgpm.regrain_step('public.r345c', (select child_name from pgpm.part
  where parent_table = 'public.r345c'::regclass and attached and lo = '0'), '500', 1000)$$) as c3 \gset
select ok(pg_temp.waits_for(:'c_oid'::oid, 'AccessExclusiveLock'),
  'LIVENESS: the swap tick waits for ACCESS EXCLUSIVE on the copy''s oid');
select dblink_exec('h345', 'alter table public.r345c_p0000000000000000000 rename to r345c_copy_aside') as c4 \gset
select dblink_exec('h345', 'create table public.r345c_p0000000000000000000 (like public.r345c_copy_aside including all)') as c5 \gset
select dblink_exec('h345', $$insert into public.r345c_p0000000000000000000 values (7, 'stranger'), (8, 'stranger')$$) as c6 \gset
select o as c_squat from dblink('h345', $$select 'public.r345c_p0000000000000000000'::regclass::oid$$) as t(o oid) \gset
select dblink_exec('h345', 'commit') as c7 \gset
select x as c_ret from dblink_get_result('r345', false) as t(x text) \gset
select count(*) as c_drained from dblink_get_result('r345', false) as t(x text) \gset
select ok(:'c_squat'::oid <> :'c_oid'::oid, 'LIVENESS: the copy''s name denotes another relation now, the stranger');
select is(:'c_ret'::text, 'swapped:2', 'the swap completes');
select is((select array_agg(id order by id) from public.r345c where id < 500),
  (select array_agg((g * 10)::bigint order by g) from generate_series(1, 49) g),
  'the table''s [0, 500) holds the copied ids 10..490, and neither of the stranger''s');
select ok(exists (select 1 from pg_inherits where inhrelid = :'c_oid'::oid and inhparent = 'public.r345c'::regclass),
  'the copy pgpm recorded is the partition attached');
select ok(not exists (select 1 from pg_inherits where inhrelid = :'c_squat'::oid),
  'the stranger is attached to nothing');
select is(pg_temp.ids_of(:'c_squat'), array[7, 8]::bigint[], 'and keeps its rows 7, 8');

-- ======================= (D) the sibling: the recall re-attaches the partition, not a table under its name =========
-- The state retire() leaves once its dispatched detach has landed (marked, the dispatch recorded, detached), with
-- retention then loosened so it no longer reaches the partition: _retain_recall re-attaches it on its bounds.
create table public.r345d (id bigint primary key, payload text);
insert into public.r345d select g, 'd' from generate_series(1, 2500) g;
call pgpm.transmute('public.r345d', 'id', 1000, p_paused => true);
insert into public.r345d values (20000, 'frontier');
select child_name as d_name, child_oid as d_oid from pgpm.part where parent_table = 'public.r345d'::regclass and lo = '0' \gset
update pgpm.part set retiring_at = now(), retiring_oid = child_oid, detach_dispatched_oid = child_oid
 where parent_table = 'public.r345d'::regclass and child_name = :'d_name';
select format('alter table public.r345d detach partition public.%I', :'d_name') as d_detach \gset
:d_detach;
select is((select (count(*), min(id), max(id))::text from only public.:"d_name"), '(2500,1,2500)',
  'fixture: D''s partition, detached by its retirement, holds ids 1..2500');
select max(id) as d_mark from pgpm.log \gset

select dblink_exec('h345', 'begin') as d1 \gset
select dblink_exec('h345', format('lock table public.%I in access exclusive mode', :'d_name')) as d2 \gset
select dblink_send_query('r345', $$select pgpm._retain_recall('public.r345d', true)::text$$) as d3 \gset
select ok(pg_temp.waits_for(:'d_oid'::oid, 'AccessExclusiveLock'),
  'LIVENESS: the recall''s re-attach waits for ACCESS EXCLUSIVE on the partition''s oid');
select dblink_exec('h345', format('alter table public.%I rename to r345d_aside', :'d_name')) as d4 \gset
select dblink_exec('h345', format('create table public.%I (like public.r345d_aside including all)', :'d_name')) as d5 \gset
select dblink_exec('h345', format('insert into public.%I values (7, %L), (8, %L)', :'d_name', 'stranger', 'stranger')) as d6 \gset
select o as d_squat from dblink('h345', format('select %L::regclass::oid', 'public.' || quote_ident(:'d_name'))) as t(o oid) \gset
select dblink_exec('h345', 'commit') as d7 \gset
select x as d_ret from dblink_get_result('r345', false) as t(x text) \gset
select count(*) as d_drained from dblink_get_result('r345', false) as t(x text) \gset
select ok(:'d_squat'::oid <> :'d_oid'::oid, 'LIVENESS: the partition''s name denotes another relation now, the stranger');
select ok(not exists (select 1 from pg_inherits where inhrelid = :'d_squat'::oid),
  'the stranger is attached to nothing');
select is((select array_agg(id order by id) from public.r345d where id < 3000), null,
  'and the table''s [0, 3000) serves none of its rows (nor any other)');
select is((select array_agg(action order by id) from pgpm.log where id > :d_mark and parent_table = 'public.r345d'::regclass),
  array['fail_retain_reattach']::text[], 'the recall logged fail_retain_reattach, not retain_reattach');
select ok((select retiring_at is not null and detach_dispatched_oid = :'d_oid'::oid from pgpm.part
            where parent_table = 'public.r345d'::regclass and child_name = :'d_name'),
  'and kept the retirement''s mark and its record, so nothing reads the partition as taken back');
select is(pg_temp.ids_of(:'d_oid'), (select array_agg(g::bigint order by g) from generate_series(1, 2500) g),
  'the partition, renamed aside, keeps ids 1..2500');
update pgpm.part set retiring_at = null, retiring_oid = null, detach_dispatched_oid = null
 where parent_table = 'public.r345d'::regclass and child_name = :'d_name';

select dblink_disconnect('h345') as dh \gset
select dblink_disconnect('r345') as dr \gset
select * from finish();
