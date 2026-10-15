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
--   PART E  pgpm._lock_oid itself: asked through a vouched name that denotes nothing, while this backend already
--           holds the lock, it answers false, never null (a null reads as "not refused" to every caller).
-- A lock pins a relation's own name, never its schema's (ALTER SCHEMA ... RENAME takes no relation lock), so a
-- statement that names a relation and then waits for a lock of its own reaches whatever a schema swap committed
-- during the wait put under that name. Each of these is checked after it ran (pgpm._reached_or_raise):
--   PART F  retire()'s one-step DROP, waiting behind a reader: false, fail_retain_drop, the namesake and the partition
--           both standing, the pgpm.part row kept.
--   PART G  retire()'s crossing DELETE, waiting behind a SHARE holder: fail_retain_crossing, the namesake keeps both
--           rows, nothing deleted from the parent either.
--   PART H  the write block's CREATE TRIGGER, waiting behind a writer: retire() refuses, the namesake carries no
--           trigger and keeps its rows, the partition stands with the row written meanwhile.
--   PART H2 the same for the ENABLE ALWAYS of a block disabled by hand, against a namesake carrying a trigger of
--           pgpm's name: retire() refuses, the namesake's trigger left disabled.
--   PART J  untransmute's gate, built before its ACCESS EXCLUSIVE wait: refused under the lock, the forward row
--           written meanwhile still served.
--   PART K  the regrain reconcile, waiting for a copy, the delta in a schema of its own: refused, the namesake copy
--           keeps its row of the captured key, the delta keeps the change.
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
select plan(74);

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

-- F's, G's and H's, each in a schema of its own (the schema is what their sessions rename)
create schema f345s;
create table f345s.r (id bigint, ts timestamptz not null, payload text, primary key (id, ts));
insert into f345s.r
select g, clock_timestamp() - interval '10 seconds' + make_interval(secs => g / 1000.0), 'f' from generate_series(1, 3) g;
call pgpm.transmute('f345s.r', 'ts', interval '1 second', p_obtain => 4, p_retain => interval '1 second', p_paused => true);
create schema g345s;
create table g345s.r (id bigint, ts timestamptz not null, payload text, primary key (id, ts));
insert into g345s.r
select g, date_trunc('second', clock_timestamp()) - interval '10 seconds' + make_interval(secs => g / 1000.0), 'g' from generate_series(1, 3) g;
create table public.g345_ref (id bigint, ts timestamptz, foreign key (id, ts) references g345s.r (id, ts) on delete cascade);
insert into public.g345_ref select id, ts from g345s.r where id = 2;
call pgpm.transmute('g345s.r', 'ts', interval '1 second', p_obtain => 4, p_retain => interval '1 second', p_paused => true, p_incoming_fks => 'preserve');
select pgpm.restore_incoming_fks('g345s.r') as g_restored \gset
create schema h345s;
create table h345s.r (id bigint, ts timestamptz not null, payload text, primary key (id, ts));
insert into h345s.r
select g, clock_timestamp() - interval '10 seconds' + make_interval(secs => g / 1000.0), 'h' from generate_series(1, 3) g;
call pgpm.transmute('h345s.r', 'ts', interval '1 second', p_obtain => 4, p_retain => interval '1 second', p_paused => true);
create schema w345s;
create table w345s.r (id bigint, ts timestamptz not null, payload text, primary key (id, ts));
insert into w345s.r
select g, clock_timestamp() - interval '10 seconds' + make_interval(secs => g / 1000.0), 'w' from generate_series(1, 3) g;
call pgpm.transmute('w345s.r', 'ts', interval '1 second', p_obtain => 4, p_retain => interval '1 second', p_paused => true);
select max(p.hi) as fgh_hi from pgpm.part p join pgpm.config c on c.parent_table = p.parent_table and c.monolith_oid = p.child_oid
 where p.parent_table in ('f345s.r'::regclass, 'g345s.r'::regclass, 'h345s.r'::regclass, 'w345s.r'::regclass) \gset

select p.child_name as a_name, p.hi as a_hi, p.child_oid as a_oid from pgpm.part p
  join pgpm.config c on c.parent_table = p.parent_table and c.monolith_oid = p.child_oid
 where p.parent_table = 'public.r345a'::regclass \gset
select p.child_name as b_name, p.hi as b_hi, p.child_oid as b_oid from pgpm.part p
  join pgpm.config c on c.parent_table = p.parent_table and c.monolith_oid = p.child_oid
 where p.parent_table = 'public.r345b'::regclass \gset
select pg_sleep(greatest(0, extract(epoch from (greatest(:'a_hi'::timestamptz, :'b_hi'::timestamptz, :'fgh_hi'::timestamptz) + interval '1.5 seconds' - clock_timestamp()))));

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

-- ======================= (E) the helper: a vouched name that denotes nothing is a refusal, never a null =========
-- This backend already holds ACCESS SHARE on r345c, so the lock manager alone would answer yes; the name it is asked
-- through names a schema that does not exist, as a schema renamed after the lock would. The answer must be false:
-- every caller tests `if not pgpm._lock_oid(...)`, and a null there is a branch not taken, the caller going on.
begin;
lock table only public.r345c in access share mode;
select ok(exists (select 1 from pg_locks l where l.locktype = 'relation' and l.relation = 'public.r345c'::regclass
                    and l.pid = pg_backend_pid() and l.mode = 'AccessShareLock' and l.granted),
  'LIVENESS: E: this backend holds ACCESS SHARE on the relation, so the witness alone answers yes');
select is(pgpm._lock_oid('public.r345c'::regclass, 'access share', true, 'r345_no_such_schema', 'r345c'), false,
  'E: asked through a name that denotes nothing, _lock_oid answers false, not null');
commit;

-- ======================= (F) a schema renamed while retire()'s DROP waits for its lock ============================
-- retire() holds its witnessed SHARE UPDATE EXCLUSIVE, which pins the partition's name but not its schema's; the
-- one-step DROP needs ACCESS EXCLUSIVE and waits behind a reader, and resolves its name again once granted.
select p.child_name as f_name, p.child_oid as f_oid from pgpm.part p
  join pgpm.config c on c.parent_table = p.parent_table and c.monolith_oid = p.child_oid
 where p.parent_table = 'f345s.r'::regclass \gset
select 'f345s.r'::regclass::oid as f_parent \gset
select max(id) as f_mark from pgpm.log \gset
select dblink_exec('h345', 'begin') as f1 \gset
select n as f_read from dblink('h345', format('select count(*)::int from f345s.%I', :'f_name')) as t(n int) \gset
select dblink_send_query('r345', format('select pgpm.retire(%L, %L)::text', 'f345s.r', :'f_name')) as f2 \gset
select ok(pg_temp.waits_for(:'f_oid'::oid, 'AccessExclusiveLock'),
  'LIVENESS: F: retire() waits at its DROP''s ACCESS EXCLUSIVE on the partition''s oid, behind the reader');
select dblink_exec('h345', 'alter schema f345s rename to f345s_aside') as f3 \gset
select dblink_exec('h345', 'create schema f345s') as f4 \gset
select dblink_exec('h345', format('create table f345s.%I (id bigint, payload text)', :'f_name')) as f5 \gset
select dblink_exec('h345', format('insert into f345s.%I values (7, %L), (8, %L)', :'f_name', 'stranger', 'stranger')) as f6 \gset
select o as f_squat from dblink('h345', format('select %L::regclass::oid', 'f345s.' || quote_ident(:'f_name'))) as t(o oid) \gset
select dblink_exec('h345', 'commit') as f7 \gset
select x as f_ret from dblink_get_result('r345', false) as t(x text) \gset
select count(*) as f_drained from dblink_get_result('r345', false) as t(x text) \gset
select ok(:'f_squat'::oid <> :'f_oid'::oid, 'LIVENESS: F: the partition''s name, in a schema of that name, denotes the stranger now');
select is(:'f_ret'::text, 'false', 'F: retire() returns false: what its DROP reached was not the partition');
select is(pg_temp.ids_of(:'f_squat'), array[7, 8]::bigint[], 'F: the stranger stands, with its rows 7, 8');
select is(pg_temp.ids_of(:'f_oid'), array[1, 2, 3]::bigint[], 'F: the partition, in the renamed schema, keeps ids 1, 2, 3');
select ok(exists (select 1 from pgpm.part where parent_table = :'f_parent'::oid and child_oid = :'f_oid'::oid),
  'F: and keeps its pgpm.part row');
select ok(exists (select 1 from pgpm.log where id > :f_mark and parent_table = :'f_parent'::oid and action = 'fail_retain_drop'
                   and method like '%dropped another relation than %')
          and not exists (select 1 from pgpm.log where id > :f_mark and parent_table = :'f_parent'::oid and action = 'retain_drop'),
  'F: logged fail_retain_drop saying the DROP reached another relation, and no retain_drop');

-- ======================= (G) a schema renamed while retire()'s crossing DELETE waits for its lock ===============
-- On the referenced path retire() deletes the referenced rows of the retiring range through the parent's name; the
-- DELETE waits for ROW EXCLUSIVE behind a SHARE holder and resolves the name again once granted.
select p.child_name as g_name from pgpm.part p
  join pgpm.config c on c.parent_table = p.parent_table and c.monolith_oid = p.child_oid
 where p.parent_table = 'g345s.r'::regclass \gset
select 'g345s.r'::regclass::oid as g_parent \gset
select ts as g_key_ts from g345s.r where id = 2 \gset
select is((select count(*)::int from pg_constraint where confrelid = :'g_parent'::oid and contype = 'f' and conparentid = 0), 1,
  'fixture: G''s table is referenced, so retire() takes the referenced path and its crossing DELETE');
select max(id) as g_mark from pgpm.log \gset
select dblink_exec('h345', 'begin') as g1 \gset
select dblink_exec('h345', 'lock table only g345s.r in share mode') as g2 \gset
select dblink_send_query('r345', format('select pgpm.retire(%L, %L)::text', 'g345s.r', :'g_name')) as g3 \gset
select ok(pg_temp.waits_for(:'g_parent'::oid, 'RowExclusiveLock'),
  'LIVENESS: G: retire()''s crossing DELETE waits for ROW EXCLUSIVE on the parent''s oid, behind the SHARE holder');
select dblink_exec('h345', 'alter schema g345s rename to g345s_aside') as g4 \gset
select dblink_exec('h345', 'create schema g345s') as g5 \gset
select dblink_exec('h345', 'create table g345s.r (id bigint, ts timestamptz, payload text)') as g6 \gset
select dblink_exec('h345', format('insert into g345s.r values (2, %L, %L), (9, %L, %L)', :'g_key_ts', 'stranger', :'g_key_ts'::timestamptz + interval '1 hour', 'stranger')) as g7 \gset
select o as g_squat from dblink('h345', 'select ''g345s.r''::regclass::oid') as t(o oid) \gset
select dblink_exec('h345', 'commit') as g8 \gset
select x as g_ret from dblink_get_result('r345', false) as t(x text) \gset
select count(*) as g_drained from dblink_get_result('r345', false) as t(x text) \gset
select ok(:'g_squat'::oid <> :'g_parent'::oid, 'LIVENESS: G: the parent''s name denotes the stranger now');
select is(pg_temp.ids_of(:'g_squat'), array[2, 9]::bigint[], 'G: the stranger keeps both its rows, the one on the crossing key too');
select is((select array_agg(id order by id) from public.g345_ref), array[2]::bigint[],
  'G: and the referencing row is untouched: nothing was deleted from the parent either');
select ok(exists (select 1 from pgpm.log where id > :g_mark and parent_table = :'g_parent'::oid and action = 'fail_retain_crossing'
                   and method like '%went through the name %')
          and not exists (select 1 from pgpm.log where id > :g_mark and parent_table = :'g_parent'::oid and action = 'retain_crossing'),
  'G: logged fail_retain_crossing naming the name it went through, and no retain_crossing');

-- ======================= (H) a schema renamed while the write block's CREATE TRIGGER waits for its lock ==========
-- retire() puts the write block on before it drops; CREATE TRIGGER waits for SHARE ROW EXCLUSIVE behind a writer.
select p.child_name as h_name, p.child_oid as h_oid, p.lo as h_lo from pgpm.part p
  join pgpm.config c on c.parent_table = p.parent_table and c.monolith_oid = p.child_oid
 where p.parent_table = 'h345s.r'::regclass \gset
select dblink_exec('h345', 'begin') as h1 \gset
select dblink_exec('h345', format('insert into h345s.r values (4, %L, %L)', :'h_lo', 'written')) as h2 \gset
select dblink_send_query('r345', format('select pgpm.retire(%L, %L)::text', 'h345s.r', :'h_name')) as h3 \gset
select ok(pg_temp.waits_for(:'h_oid'::oid, 'ShareRowExclusiveLock'),
  'LIVENESS: H: the write block''s CREATE TRIGGER waits for SHARE ROW EXCLUSIVE on the partition''s oid, behind the writer');
select dblink_exec('h345', 'alter schema h345s rename to h345s_aside') as h4 \gset
select dblink_exec('h345', 'create schema h345s') as h5 \gset
select dblink_exec('h345', format('create table h345s.%I (id bigint, ts timestamptz, payload text)', :'h_name')) as h6 \gset
select dblink_exec('h345', format('insert into h345s.%I values (7, now(), %L), (8, now(), %L)', :'h_name', 'stranger', 'stranger')) as h7 \gset
select o as h_squat from dblink('h345', format('select %L::regclass::oid', 'h345s.' || quote_ident(:'h_name'))) as t(o oid) \gset
select dblink_exec('h345', 'commit') as h8 \gset
select count(*) as h_rows from dblink_get_result('r345', false) as t(x text) \gset
select ok(dblink_error_message('r345') like '%the write block''s CREATE TRIGGER went through the name %',
  'H: retire() refuses, saying the write block''s CREATE TRIGGER reached another relation');
select count(*) as h_drained from dblink_get_result('r345', false) as t(x text) \gset
select ok(:'h_squat'::oid <> :'h_oid'::oid, 'LIVENESS: H: the partition''s name denotes the stranger now');
select ok(not exists (select 1 from pg_trigger where tgrelid = :'h_squat'::oid), 'H: the stranger carries no trigger of pgpm''s');
select is(pg_temp.ids_of(:'h_squat'), array[7, 8]::bigint[], 'H: and keeps its rows 7, 8');
select is(pg_temp.ids_of(:'h_oid'), array[1, 2, 3, 4]::bigint[],
  'H: the partition stands with ids 1..3 and the row written while retire() waited, 4');

-- ======================= (H2) the same while the write block's ENABLE ALWAYS waits for its lock ==================
-- A partition whose block was disabled by hand gets it back ENABLE ALWAYS (#710); that ALTER waits for SHARE ROW
-- EXCLUSIVE behind a writer, and names the trigger by pgpm's name, which a namesake can carry too.
select p.child_name as w_name, p.child_oid as w_oid, p.lo as w_lo from pgpm.part p
  join pgpm.config c on c.parent_table = p.parent_table and c.monolith_oid = p.child_oid
 where p.parent_table = 'w345s.r'::regclass \gset
select pgpm._install_write_block('w345s.r'::regclass, :'w_name') as w_block \gset
select format('alter table w345s.%I disable trigger pgpm_write_block', :'w_name') as w_disable \gset
:w_disable;
select is((select tgenabled::text from pg_trigger where tgrelid = :'w_oid'::oid and tgname = 'pgpm_write_block'), 'D',
  'fixture: H2''s partition carries the write block, disabled by hand');
select dblink_exec('h345', 'begin') as w1 \gset
select dblink_exec('h345', format('insert into w345s.r values (4, %L, %L)', :'w_lo', 'written')) as w2 \gset
select dblink_send_query('r345', format('select pgpm.retire(%L, %L)::text', 'w345s.r', :'w_name')) as w3 \gset
select ok(pg_temp.waits_for(:'w_oid'::oid, 'ShareRowExclusiveLock'),
  'LIVENESS: H2: the write block''s ENABLE ALWAYS waits for SHARE ROW EXCLUSIVE on the partition''s oid, behind the writer');
select dblink_exec('h345', 'alter schema w345s rename to w345s_aside') as w4 \gset
select dblink_exec('h345', 'create schema w345s') as w5 \gset
select dblink_exec('h345', format('create table w345s.%I (id bigint, ts timestamptz, payload text)', :'w_name')) as w6 \gset
select dblink_exec('h345', format('insert into w345s.%I values (7, now(), %L), (8, now(), %L)', :'w_name', 'stranger', 'stranger')) as w7 \gset
select dblink_exec('h345', format('create trigger pgpm_write_block before insert or update or delete on w345s.%I for each row execute function pgpm._write_block_raise()', :'w_name')) as w8 \gset
select dblink_exec('h345', format('alter table w345s.%I disable trigger pgpm_write_block', :'w_name')) as w9 \gset
select o as w_squat from dblink('h345', format('select %L::regclass::oid', 'w345s.' || quote_ident(:'w_name'))) as t(o oid) \gset
select dblink_exec('h345', 'commit') as w10 \gset
select count(*) as w_rows from dblink_get_result('r345', false) as t(x text) \gset
select ok(dblink_error_message('r345') like '%the write block''s ENABLE ALWAYS went through the name %',
  'H2: retire() refuses, saying the write block''s ENABLE ALWAYS reached another relation');
select count(*) as w_drained from dblink_get_result('r345', false) as t(x text) \gset
select ok(:'w_squat'::oid <> :'w_oid'::oid, 'LIVENESS: H2: the partition''s name denotes the namesake now');
select is((select tgenabled::text from pg_trigger where tgrelid = :'w_squat'::oid and tgname = 'pgpm_write_block'), 'D',
  'H2: the namesake''s trigger is left as its owner set it, disabled');
select is(pg_temp.ids_of(:'w_oid'), array[1, 2, 3, 4]::bigint[],
  'H2: the partition stands with ids 1..3 and the row written while retire() waited, 4');

-- ======================= (J) a schema renamed while untransmute's gate waits for its lock ========================
-- The gate is SQL text naming the parent, built before the lock and asked again under it; a forward row written
-- while it waits is outside the monolith, and the door must stay shut.
create schema j345s;
create table j345s.t (id bigint primary key, payload text);
insert into j345s.t select g, 'j' from generate_series(1, 250) g;
call pgpm.transmute('j345s.t', 'id', 1000, p_obtain => 2, p_paused => true);
select 'j345s.t'::regclass::oid as j_parent \gset
select dblink_exec('h345', 'begin') as j1 \gset
select dblink_exec('h345', 'insert into j345s.t values (1500, ''forward'')') as j2 \gset
select dblink_send_query('r345', $$select pgpm.untransmute('j345s.t')::text$$) as j3 \gset
select ok(pg_temp.waits_for(:'j_parent'::oid, 'AccessExclusiveLock'),
  'LIVENESS: J: untransmute waits for ACCESS EXCLUSIVE on the parent''s oid, behind the writer of a forward row');
select dblink_exec('h345', 'alter schema j345s rename to j345s_aside') as j4 \gset
select dblink_exec('h345', 'create schema j345s') as j5 \gset
select dblink_exec('h345', 'create table j345s.t (id bigint, payload text)') as j6 \gset
select dblink_exec('h345', 'commit') as j7 \gset
select count(*) as j_rows from dblink_get_result('r345', false) as t(x text) \gset
select ok(dblink_error_message('r345') like '%untransmute(%), asking the gate under its lock, went through the name %',
  'J: untransmute refuses, saying the gate under its lock read another relation');
select count(*) as j_drained from dblink_get_result('r345', false) as t(x text) \gset
select ok(exists (select 1 from pg_partitioned_table where partrelid = :'j_parent'::oid),
  'J: the table is still partitioned and managed');
select is((select array_agg(id order by id) from j345s_aside.t where id >= 1000), array[1500]::bigint[],
  'J: and still serves the forward row 1500 the reverse would have dropped with the parent');

-- ======================= (K) a schema renamed while the regrain reconcile waits for a copy ========================
-- The reconcile applies captured changes to a copy through the copy's and the source's renderings, the batch's keys
-- read from the delta. The delta moved to a schema of its own (#555) stays where it is when the copies' schema is
-- renamed, so the batch's real keys reach the namesakes: on the base, the copy's DELETE removed a namesake copy's row
-- of a captured INSERT's key (the INSERT after it, rendered again, found no duplicate in the real copy).
create schema k345s;
create schema k345d;
create table k345s.t (id bigint primary key, payload text);
insert into k345s.t select g * 10, 'k' from generate_series(1, 99) g;
call pgpm.transmute('k345s.t', 'id', 1000, p_paused => true);
insert into k345s.t values (20000, 'frontier');
create function pg_temp.k_step() returns text language sql as $$
  select pgpm.regrain_step('k345s.t', (select child_name from pgpm.part
    where parent_table = 'k345s.t'::regclass and attached and lo = '0'), '500', 1000) $$;
select is(array[pg_temp.k_step(), pg_temp.k_step()], array['prepared', 'copied:49'],
  'fixture: K''s regrain is prepared and copies [0, 500)');
select regrain_delta_oid as k_delta, (select relname from pg_class where oid = regrain_delta_oid) as k_delta_name
  from pgpm.config where parent_table = 'k345s.t'::regclass \gset
select format('alter table k345s.%I set schema k345d', :'k_delta_name') as k_move \gset
:k_move;
insert into k345s.t values (25, 'inserted');   -- a new key: the copy holds no row for it
select child_oid as k_copy, child_name as k_copy_name from pgpm.part
 where parent_table = 'k345s.t'::regclass and not attached and lo = '0' \gset
select child_name as k_src_name from pgpm.part where parent_table = 'k345s.t'::regclass and attached and lo = '0' \gset
select ok((select count(*) from k345d.:"k_delta_name" where id = 25) > 0,
  'fixture: K''s delta, in k345d, holds the captured insert of id 25');

select dblink_exec('h345', 'begin') as k1 \gset
select dblink_exec('h345', format('lock table k345s.%I in share mode', :'k_copy_name')) as k2 \gset
select dblink_send_query('r345', $$select pgpm.regrain_step('k345s.t', (select child_name from pgpm.part
  where parent_table = 'k345s.t'::regclass and attached and lo = '0'), '500', 1000)$$) as k3 \gset
select ok(pg_temp.waits_for(:'k_copy'::oid, 'RowExclusiveLock'),
  'LIVENESS: K: the reconcile waits for ROW EXCLUSIVE on the copy''s oid, behind the SHARE holder');
select dblink_exec('h345', 'alter schema k345s rename to k345s_aside') as k4 \gset
select dblink_exec('h345', 'create schema k345s') as k5 \gset
select dblink_exec('h345', format('create table k345s.%I (id bigint, payload text)', :'k_copy_name')) as k6 \gset
select dblink_exec('h345', format('insert into k345s.%I values (25, %L)', :'k_copy_name', 'stranger copy')) as k7 \gset
select dblink_exec('h345', format('create table k345s.%I (id bigint, payload text)', :'k_src_name')) as k8 \gset
select dblink_exec('h345', format('insert into k345s.%I values (25, %L)', :'k_src_name', 'stranger source')) as k9 \gset
select o as k_squat from dblink('h345', format('select %L::regclass::oid', 'k345s.' || quote_ident(:'k_copy_name'))) as t(o oid) \gset
select dblink_exec('h345', 'commit') as k10 \gset
select count(*) as k_rows from dblink_get_result('r345', false) as t(x text) \gset
select ok(dblink_error_message('r345') like '%the regrain reconcile of % went through the name %',
  'K: the tick refuses, saying the reconcile reached another relation');
select count(*) as k_drained from dblink_get_result('r345', false) as t(x text) \gset
select ok(:'k_squat'::oid <> :'k_copy'::oid, 'LIVENESS: K: the copy''s name denotes the namesake now');
select is((select array_agg(payload) from k345s.:"k_copy_name"), array['stranger copy'],
  'K: the namesake copy keeps its row 25: the batch''s key deleted nothing from it');
select ok((select count(*) from k345d.:"k_delta_name" where id = 25) > 0,
  'K: and the delta keeps the captured insert, for the next tick to apply to the copy pgpm recorded');

select dblink_disconnect('h345') as dh \gset
select dblink_disconnect('r345') as dr \gset
select * from finish();
