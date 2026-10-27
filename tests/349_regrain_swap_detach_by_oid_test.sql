-- The regrain swap's DETACH reaches the parent and the source it identified by oid (issue #1362).
--
-- THE BUG. regrain_step's swap ran `alter table <parent> detach partition <source>` with both names rendered from
-- their oids just before the statement, and nothing locked by oid first. The DETACH waits for ACCESS EXCLUSIVE on the
-- parent behind any reader, and resolves its names again once granted: a lock pins a relation's own name, never its
-- schema's (ALTER SCHEMA ... RENAME takes no relation lock), so a schema renamed aside during that wait, with a
-- namesake schema holding a namesake partitioned table and a namesake partition under the source's name committed
-- in its place, was what the DETACH reached. The stranger's partition left the stranger's table (its rows silently no
-- longer served), while the swap went on by oid, attached the copies, dropped the real source, and reported success.
--
-- THE CONTRACT. The swap locks the parent and the source by oid (pgpm._lock_oid_or_raise) in the DETACH's own mode
-- and order before the DETACH, and renders their names under those locks, so the DETACH waits for neither and
-- reaches the relations pgpm identified wherever their schema has gone.
--   PART A  the reported state: every sub-range of the monolith aged, so the swap has nothing to attach and nothing
--           after its DETACH can fail. A reader holds the parent (and so its partitions) when the swap tick arrives,
--           and the schema is swapped while the tick waits for ACCESS EXCLUSIVE on the parent's oid: the stranger's
--           partition stays attached to the stranger's table, which still serves its two rows, and the swap
--           completes on the table pgpm manages (swapped:0, the aged rows gone with the source by design).
--   PART B  the same reader and swap with two copies to attach: the swap completes, and the table serves exactly its
--           99 rows through the two copies pgpm recorded.
--   PART C  the reader holds only the source: the tick waits for the source's oid instead, and the swap completes all
--           the same (a DETACH that named the source before that wait reached the stranger's partition, which is
--           no partition of the parent, and failed).
-- Every concurrent order is set by a lock queue: a second session ('h349') holds the lock, a third ('r349') makes the
-- call, and a server-side poll (snapshot cleared every iteration) sees the call waiting on the oid before the holder
-- renames, creates and commits. The holder is READ COMMITTED and between statements, so it holds no snapshot the
-- swap's own snapshot wait (#1241) would wait for.
--
-- ASYMMETRIC FIXTURES. Each table's monolith [0, 1000) holds ids 10..990 (99 rows, 'real') and its frontier row
-- 20000, regrained to step 500 in copies of 49 and 50 rows (B, C) or none (A); each stranger holds ids 7 and 8.
-- Every check names a relation by oid and its rows by value. regrain_step is a function, not a committing
-- procedure; no throws_* here.
create extension if not exists pgtap;
create extension if not exists dblink;
set client_min_messages = warning;
select plan(33);

-- the call in session r349 is waiting, ungranted, for p_mode on p_oid: one statement per sample, snapshot cleared
create function pg_temp.waits_for(p_oid oid, p_mode text) returns boolean language plpgsql as $$
begin
  for i in 1 .. 800 loop
    perform pg_stat_clear_snapshot();
    if exists (select 1 from pg_locks l
                where not l.granted and l.locktype = 'relation' and l.relation = p_oid and l.mode = p_mode
                  and l.pid = current_setting('pgpm349.r_pid')::int) then
      return true;
    end if;
    perform pg_sleep(0.025);
  end loop;
  return false;
end $$;

-- the rows a relation serves (its partitions' too), read by its oid as id=payload: null when the oid is gone
create function pg_temp.rows_of(p_oid oid) returns text[] language plpgsql as $$
declare v text[];
begin
  if not exists (select 1 from pg_class where oid = p_oid) then return null; end if;
  execute format('select array_agg(id || ''='' || payload order by id) from %s', p_oid::regclass) into v;
  return v;
end $$;

select dblink_connect('h349', format('dbname=%s user=postgres', current_database())) as h \gset
select dblink_connect('r349', format('dbname=%s user=postgres', current_database())) as r \gset
select set_config('pgpm349.r_pid', (select pid::text from dblink('r349', 'select pg_backend_pid()') as t(pid int)), false) as r_pid \gset
select dblink_exec('r349', 'set lock_timeout = ''60s''') as r_lt \gset
select dblink_exec('r349', 'set statement_timeout = ''120s''') as r_st \gset

-- what the table serves, by oid: ids 10..990 'real'
select array_agg(g * 10 || '=real' order by g) as want_real from generate_series(1, 99) g \gset

-- ======================= (A) the reported state: a whole monolith aged, the reader on the parent ===============
-- retain 5000 below a frontier of 20000 puts the horizon at 15000, so every sub-range of the monolith [0, 1000) is
-- aged: the tick after the prepare skips them all and swaps at once, with no copy to attach (swapped:0), and the
-- source's rows go with it by design. Nothing after the DETACH can fail, so a DETACH that reached the stranger's
-- partition committed.
create schema a349s;
create table a349s.t (id bigint primary key, payload text);
insert into a349s.t select g * 10, 'real' from generate_series(1, 99) g;
call pgpm.transmute('a349s.t', 'id', 1000, p_paused => true, p_retain => '5000');
insert into a349s.t values (20000, 'frontier');
select 'a349s.t'::regclass::oid as a_parent \gset
select is(pgpm.regrain_step('a349s.t', (select child_name from pgpm.part
    where parent_table = 'a349s.t'::regclass and attached and lo = '0'), '500', 1000), 'prepared',
  'fixture: A''s regrain is prepared');
select child_name as a_src, child_oid as a_src_oid from pgpm.part
 where parent_table = 'a349s.t'::regclass and attached and lo = '0' \gset
select ok((select not pgpm._native_gt('id', '1000', pgpm._retain_boundary(c)) from pgpm.config c where c.parent_table = :'a_parent'::oid),
  'LIVENESS: A: the whole monolith is below the retention horizon, so the next tick swaps');
-- the run's last write, recorded as a copy batch records it (#1241): with none, the swap's snapshot wait counts this
-- session's own statement, which polls and then collects the tick, as a reader to wait for
update pgpm.config set regrain_written_xid = pg_current_xact_id() where parent_table = 'a349s.t'::regclass;
select max(id) as a_mark from pgpm.log \gset

select dblink_exec('h349', 'begin') as a1 \gset
select x as a_seen from dblink('h349', 'select count(*)::text from a349s.t') as t(x text) \gset
select dblink_send_query('r349', format('select pgpm.regrain_step(%s::oid::regclass, %L, %L, 1000)', :'a_parent', :'a_src', '500')) as a2 \gset
select ok(pg_temp.waits_for(:'a_parent'::oid, 'AccessExclusiveLock'),
  'LIVENESS: A: the swap tick waits for ACCESS EXCLUSIVE on the parent''s oid, behind the reader');
select ok(exists (select 1 from pg_inherits where inhrelid = :'a_src_oid'::oid and inhparent = :'a_parent'::oid),
  'LIVENESS: A: the source is still attached, so the tick has not detached it yet');
select dblink_exec('h349', 'alter schema a349s rename to a349s_aside') as a3 \gset
select dblink_exec('h349', 'create schema a349s') as a4 \gset
select dblink_exec('h349', 'create table a349s.t (id bigint, payload text) partition by range (id)') as a5 \gset
select dblink_exec('h349', format('create table a349s.%I partition of a349s.t for values from (0) to (1000)', :'a_src')) as a6 \gset
select dblink_exec('h349', $$insert into a349s.t values (7, 'stranger'), (8, 'stranger')$$) as a7 \gset
select o as a_squat from dblink('h349', $$select 'a349s.t'::regclass::oid$$) as t(o oid) \gset
select o as a_squat_part from dblink('h349', format('select %L::regclass::oid', 'a349s.' || quote_ident(:'a_src'))) as t(o oid) \gset
select dblink_exec('h349', 'commit') as a8 \gset
select coalesce(string_agg(x, ','), 'no row') as a_ret from dblink_get_result('r349', false) as t(x text) \gset
select dblink_error_message('r349') as a_err \gset
select count(*) as a_drained from dblink_get_result('r349', false) as t(x text) \gset
select ok(:'a_squat'::oid <> :'a_parent'::oid and :'a_squat_part'::oid <> :'a_src_oid'::oid,
  'LIVENESS: A: the parent''s and the source''s names denote the strangers once the reader commits');

select ok(exists (select 1 from pg_inherits where inhrelid = :'a_squat_part'::oid and inhparent = :'a_squat'::oid),
  format('A: the stranger''s partition is still attached to the stranger''s table (tick: %s, %s)', :'a_ret', :'a_err'));
select is(pg_temp.rows_of(:'a_squat'), array['7=stranger', '8=stranger'],
  'A: and the stranger''s table still serves its rows 7 and 8');
select is(:'a_ret'::text, 'swapped:0', 'A: the swap completed on the table pgpm manages, with nothing to attach');
select ok(not exists (select 1 from pg_class where oid = :'a_src_oid'::oid), 'A: the source it identified is dropped');
select is(pg_temp.rows_of(:'a_parent'), array['20000=frontier'],
  'A: and the table pgpm manages serves its frontier row alone, the aged rows gone with the source');
select is((select array_agg(action order by id) from pgpm.log where id > :a_mark and parent_table = :'a_parent'::oid),
  array['regrain_aged', 'regrain_aged', 'regrain'], 'A: logged the two aged sub-ranges and the swap');

-- ======================= (B) the same with copies to attach: the reader holds the parent ===========================
create schema b349s;
create table b349s.t (id bigint primary key, payload text);
insert into b349s.t select g * 10, 'real' from generate_series(1, 99) g;
call pgpm.transmute('b349s.t', 'id', 1000, p_paused => true);
insert into b349s.t values (20000, 'frontier');
select 'b349s.t'::regclass::oid as b_parent \gset
select is(pgpm.regrain_step('b349s.t', (select child_name from pgpm.part
    where parent_table = 'b349s.t'::regclass and attached and lo = '0'), '500', 1000), 'prepared',
  'fixture: B''s regrain is prepared');
select is(pgpm.regrain_step('b349s.t', (select child_name from pgpm.part
    where parent_table = 'b349s.t'::regclass and attached and lo = '0'), '500', 1000), 'copied:49',
  'fixture: B''s first copy holds [0, 500), ids 10..490');
select is(pgpm.regrain_step('b349s.t', (select child_name from pgpm.part
    where parent_table = 'b349s.t'::regclass and attached and lo = '0'), '500', 1000), 'copied:50',
  'fixture: B''s second copy holds [500, 1000), ids 500..990: the next tick swaps');
select child_name as b_src, child_oid as b_src_oid from pgpm.part
 where parent_table = 'b349s.t'::regclass and attached and lo = '0' \gset
select array_agg(child_oid order by lo::bigint) as b_copies from pgpm.part
 where parent_table = 'b349s.t'::regclass and not attached \gset

select dblink_exec('h349', 'begin') as b1 \gset
select x as b_seen from dblink('h349', 'select count(*)::text from b349s.t') as t(x text) \gset
select dblink_send_query('r349', format('select pgpm.regrain_step(%s::oid::regclass, %L, %L, 1000)', :'b_parent', :'b_src', '500')) as b2 \gset
select ok(pg_temp.waits_for(:'b_parent'::oid, 'AccessExclusiveLock'),
  'LIVENESS: B: the swap tick waits for ACCESS EXCLUSIVE on the parent''s oid, behind the reader');
select ok(exists (select 1 from pg_inherits where inhrelid = :'b_src_oid'::oid and inhparent = :'b_parent'::oid),
  'LIVENESS: B: the source is still attached, so the tick has not detached it yet');
select dblink_exec('h349', 'alter schema b349s rename to b349s_aside') as b3 \gset
select dblink_exec('h349', 'create schema b349s') as b4 \gset
select dblink_exec('h349', 'create table b349s.t (id bigint, payload text) partition by range (id)') as b5 \gset
select dblink_exec('h349', format('create table b349s.%I partition of b349s.t for values from (0) to (1000)', :'b_src')) as b6 \gset
select dblink_exec('h349', $$insert into b349s.t values (7, 'stranger'), (8, 'stranger')$$) as b7 \gset
select o as b_squat from dblink('h349', $$select 'b349s.t'::regclass::oid$$) as t(o oid) \gset
select o as b_squat_part from dblink('h349', format('select %L::regclass::oid', 'b349s.' || quote_ident(:'b_src'))) as t(o oid) \gset
select dblink_exec('h349', 'commit') as b8 \gset
select coalesce(string_agg(x, ','), 'no row') as b_ret from dblink_get_result('r349', false) as t(x text) \gset
select dblink_error_message('r349') as b_err \gset
select count(*) as b_drained from dblink_get_result('r349', false) as t(x text) \gset
select ok(:'b_squat'::oid <> :'b_parent'::oid and :'b_squat_part'::oid <> :'b_src_oid'::oid,
  'LIVENESS: B: the parent''s and the source''s names denote the strangers once the reader commits');

select ok(exists (select 1 from pg_inherits where inhrelid = :'b_squat_part'::oid and inhparent = :'b_squat'::oid),
  format('B: the stranger''s partition is still attached to the stranger''s table (tick: %s, %s)', :'b_ret', :'b_err'));
select is(pg_temp.rows_of(:'b_squat'), array['7=stranger', '8=stranger'],
  'B: and the stranger''s table still serves its rows 7 and 8');
select is(:'b_ret'::text, 'swapped:2', 'B: the swap completed on the table pgpm manages');
select ok(not exists (select 1 from pg_class where oid = :'b_src_oid'::oid), 'B: the source it identified is dropped');
select is((select array_agg(i.inhrelid order by i.inhrelid) from pg_inherits i
            where i.inhparent = :'b_parent'::oid and i.inhrelid = any(:'b_copies'::oid[])),
          (select array_agg(c order by c) from unnest(:'b_copies'::oid[]) c),
  'B: the two copies pgpm recorded are partitions of the table now');
select is((select array_agg(r) from unnest(pg_temp.rows_of(:'b_parent')) r where r <> '20000=frontier'), :'want_real'::text[],
  'B: which serves exactly ids 10..990, as copied, and none of the stranger''s');

-- ======================= (C) the reader holds only the source ======================================================
create schema c349s;
create table c349s.t (id bigint primary key, payload text);
insert into c349s.t select g * 10, 'real' from generate_series(1, 99) g;
call pgpm.transmute('c349s.t', 'id', 1000, p_paused => true);
insert into c349s.t values (20000, 'frontier');
select 'c349s.t'::regclass::oid as c_parent \gset
select is(pgpm.regrain_step('c349s.t', (select child_name from pgpm.part
    where parent_table = 'c349s.t'::regclass and attached and lo = '0'), '500', 1000), 'prepared',
  'fixture: C''s regrain is prepared');
select is(pgpm.regrain_step('c349s.t', (select child_name from pgpm.part
    where parent_table = 'c349s.t'::regclass and attached and lo = '0'), '500', 1000), 'copied:49',
  'fixture: C''s first copy holds [0, 500)');
select is(pgpm.regrain_step('c349s.t', (select child_name from pgpm.part
    where parent_table = 'c349s.t'::regclass and attached and lo = '0'), '500', 1000), 'copied:50',
  'fixture: C''s second copy holds [500, 1000): the next tick swaps');
select child_name as c_src, child_oid as c_src_oid from pgpm.part
 where parent_table = 'c349s.t'::regclass and attached and lo = '0' \gset

select dblink_exec('h349', 'begin') as c1 \gset
select dblink_exec('h349', format('lock table only c349s.%I in access share mode', :'c_src')) as c2 \gset
select dblink_send_query('r349', format('select pgpm.regrain_step(%s::oid::regclass, %L, %L, 1000)', :'c_parent', :'c_src', '500')) as c3 \gset
select ok(pg_temp.waits_for(:'c_src_oid'::oid, 'AccessExclusiveLock'),
  'LIVENESS: C: the swap tick waits for ACCESS EXCLUSIVE on the source''s oid, behind the reader');
select ok(exists (select 1 from pg_inherits where inhrelid = :'c_src_oid'::oid and inhparent = :'c_parent'::oid),
  'LIVENESS: C: the source is still attached, so the tick has not detached it yet');
select dblink_exec('h349', 'alter schema c349s rename to c349s_aside') as c4 \gset
select dblink_exec('h349', 'create schema c349s') as c5 \gset
select dblink_exec('h349', 'create table c349s.t (id bigint, payload text) partition by range (id)') as c6 \gset
select dblink_exec('h349', format('create table c349s.%I partition of c349s.t for values from (0) to (1000)', :'c_src')) as c7 \gset
select dblink_exec('h349', $$insert into c349s.t values (7, 'stranger'), (8, 'stranger')$$) as c8 \gset
select o as c_squat from dblink('h349', $$select 'c349s.t'::regclass::oid$$) as t(o oid) \gset
select o as c_squat_part from dblink('h349', format('select %L::regclass::oid', 'c349s.' || quote_ident(:'c_src'))) as t(o oid) \gset
select dblink_exec('h349', 'commit') as c9 \gset
select coalesce(string_agg(x, ','), 'no row') as c_ret from dblink_get_result('r349', false) as t(x text) \gset
select dblink_error_message('r349') as c_err \gset
select count(*) as c_drained from dblink_get_result('r349', false) as t(x text) \gset
select ok(:'c_squat_part'::oid <> :'c_src_oid'::oid, 'LIVENESS: C: the source''s name denotes the stranger''s partition now');

select is(:'c_ret'::text, 'swapped:2', format('C: the swap completed on the table pgpm manages (%s)', :'c_err'));
select ok(exists (select 1 from pg_inherits where inhrelid = :'c_squat_part'::oid and inhparent = :'c_squat'::oid),
  'C: the stranger''s partition is still attached to the stranger''s table');
select is(pg_temp.rows_of(:'c_squat'), array['7=stranger', '8=stranger'], 'C: which still serves its rows 7 and 8');
select is((select array_agg(r) from unnest(pg_temp.rows_of(:'c_parent')) r where r <> '20000=frontier'), :'want_real'::text[],
  'C: and the table pgpm manages serves exactly ids 10..990');

select dblink_disconnect('h349') as dh \gset
select dblink_disconnect('r349') as dr \gset
select * from finish();
