-- The regrain copy batch, the copy's making, the reconcile's reads of the delta and the swap's TRUNCATE of it reach
-- the relations pgpm identified by oid (issue #1358).
--
-- THE BUG. regrain_step's copy batch, `insert into <copy> ... select ... from <source>`, named the fine copy and the
-- source by names rendered before the statement, with nothing locked by oid first. The INSERT waits for ROW EXCLUSIVE
-- on the copy (or ACCESS SHARE on the source) behind a holder, and resolves its names again once granted: a lock pins
-- a relation's own name, never its schema's (ALTER SCHEMA ... RENAME takes no relation lock), so a schema renamed
-- aside during the wait, with a namesake schema holding a namesake copy and source committed in its place, was what
-- the INSERT reached. The batch came from a stranger, or went into one, the short batch advanced the cursor past the
-- sub-range, and the swap attached the copy pgpm recorded without those rows and dropped the source: rows gone from
-- the table, or a stranger's rows served in their place. The same shape sat where a copy is made (the statements
-- after its CREATE, and the caller's owner and ACL mint, bound CHECK and pgpm.part anchor, named it by a name read
-- before an outgoing key's ADD waited for its referenced table) and in the reconcile, whose every statement on the
-- capture delta named it by a name read before the tick's first wait on it, so a namesake delta's rows were read as
-- the batch and consumed.
--
-- THE CONTRACT.
--   PART A  the copy batch waits for the copy behind a holder; the schema is swapped with a namesake source and copy:
--           the batch reaches the copy pgpm recorded from the source pgpm recorded, the namesake copy receives
--           nothing, and the finished regrain serves every row.
--   PART B  the copy batch waits for the source behind a holder (a time grid, so nothing earlier in the tick reads
--           the source); the namesake source holds stale versions of the next batch's rows: none of them reaches the
--           copy, and the finished regrain serves the source's values.
--   PART C  the copy is made in the tick that copies into it, and its outgoing key's ADD waits for the referenced
--           table behind a writer; the schema is swapped with a namesake of the copy (carrying a constraint of the
--           key's name, so a VALIDATE by name would pass): the namesake keeps its rows, its grant and no bound CHECK,
--           pgpm.part anchors the copy that CREATE made, and that copy holds the batch.
--   PART D  the reconcile waits for the delta behind a holder; the schema is swapped with a namesake delta holding two
--           rows of its own: the tick reconciles the captured change from the delta pgpm recorded into the copy, and
--           the namesake keeps both its rows.
--   PART E  the swap's TRUNCATE of a delta never written (no page to empty) waits behind a reader, in the tick that
--           grants the table's new writer INSERT on the delta (a write of its pg_class row); the schema is swapped
--           with a namesake delta holding two rows: the TRUNCATE's effect check refuses (the delta was not created by
--           this transaction, whatever wrote its catalog row), the namesake keeps its rows, and the next tick swaps.
-- Every concurrent order is set by a lock queue: a second session ('h350') holds the lock, a third ('r350') makes the
-- call, and a server-side poll (snapshot cleared every iteration) sees the call waiting on the oid before the holder
-- renames, creates and commits.
--
-- ASYMMETRIC FIXTURES. A and D's monoliths hold ids 10..990 (99 rows); A copies in batches of 20, so its second batch
-- (ids 210..400) is the one in flight, and its namesake source holds only 210 and 220. B's monolith holds ids 1..10
-- in batches of 4, its namesake source the stale 5..8. C's namesake copy holds 15 and 25. D's delta holds the two
-- captured rows of one key (40), its namesake two rows of other keys (50, 60); E's namesake delta holds 7 and 8.
-- Every check names a relation by oid and its rows by value. regrain_step and regrain are functions, not committing
-- procedures; no throws_* here.
create extension if not exists pgtap;
create extension if not exists dblink;
set client_min_messages = warning;
select plan(49);

-- the call in session r350 is waiting, ungranted, on p_oid (in p_mode, or any mode when it is null): one statement
-- per sample, snapshot cleared
create function pg_temp.waits_for(p_oid oid, p_mode text) returns boolean language plpgsql as $$
begin
  for i in 1 .. 800 loop
    perform pg_stat_clear_snapshot();
    if exists (select 1 from pg_locks l
                where not l.granted and l.locktype = 'relation' and l.relation = p_oid
                  and (p_mode is null or l.mode = p_mode)
                  and l.pid = current_setting('pgpm350.r_pid')::int) then
      return true;
    end if;
    perform pg_sleep(0.025);
  end loop;
  return false;
end $$;

-- the rows a relation holds (its partitions' too), read by its oid as id=payload: null when the oid is gone
create function pg_temp.rows_of(p_oid oid) returns text[] language plpgsql as $$
declare v text[];
begin
  if not exists (select 1 from pg_class where oid = p_oid) then return null; end if;
  execute format('select array_agg(id || ''='' || payload order by id) from %s', p_oid::regclass) into v;
  return v;
end $$;

-- how many rows a relation holds, read by its oid
create function pg_temp.n_of(p_oid oid) returns bigint language plpgsql as $$
declare v bigint;
begin
  execute format('select count(*) from %s', p_oid::regclass) into v;
  return v;
end $$;

select dblink_connect('h350', format('dbname=%s user=postgres', current_database())) as h \gset
select dblink_connect('r350', format('dbname=%s user=postgres', current_database())) as r \gset
select set_config('pgpm350.r_pid', (select pid::text from dblink('r350', 'select pg_backend_pid()') as t(pid int)), false) as r_pid \gset
select dblink_exec('r350', 'set lock_timeout = ''60s''') as r_lt \gset
select dblink_exec('r350', 'set statement_timeout = ''120s''') as r_st \gset

-- ======================= (A) the copy batch waits for the copy; the schema is swapped =============================
create schema a350s;
create table a350s.t (id bigint primary key, payload text);
insert into a350s.t select g * 10, 'real' from generate_series(1, 99) g;
call pgpm.transmute('a350s.t', 'id', 1000, p_paused => true);
insert into a350s.t values (20000, 'frontier');
select 'a350s.t'::regclass::oid as a_parent \gset
select is(pgpm.regrain_step('a350s.t', (select child_name from pgpm.part
    where parent_table = 'a350s.t'::regclass and attached and lo = '0'), '500', 20), 'prepared',
  'fixture: A''s regrain is prepared');
select is(pgpm.regrain_step('a350s.t', (select child_name from pgpm.part
    where parent_table = 'a350s.t'::regclass and attached and lo = '0'), '500', 20), 'copied:20',
  'fixture: A''s first batch copied ids 10..200 into the copy of [0, 500)');
select child_name as a_src from pgpm.part where parent_table = 'a350s.t'::regclass and attached and lo = '0' \gset
select child_name as a_cpy, child_oid as a_cpy_oid from pgpm.part
 where parent_table = 'a350s.t'::regclass and not attached and lo = '0' \gset

select dblink_exec('h350', 'begin') as a1 \gset
select dblink_exec('h350', format('lock table a350s.%I in access exclusive mode', :'a_cpy')) as a2 \gset
select dblink_send_query('r350', format('select pgpm.regrain_step(%s::oid::regclass, %L, %L, 20)', :'a_parent', :'a_src', '500')) as a3 \gset
select ok(pg_temp.waits_for(:'a_cpy_oid'::oid, 'RowExclusiveLock'),
  'LIVENESS: A: the copy batch waits for ROW EXCLUSIVE on the copy''s oid, behind the holder');
select dblink_exec('h350', 'alter schema a350s rename to a350s_aside') as a4 \gset
select dblink_exec('h350', 'create schema a350s') as a5 \gset
select dblink_exec('h350', format('create table a350s.%I (id bigint primary key, payload text)', :'a_src')) as a6 \gset
select dblink_exec('h350', format($$insert into a350s.%I values (210, 'stranger'), (220, 'stranger')$$, :'a_src')) as a7 \gset
select dblink_exec('h350', format('create table a350s.%I (like a350s_aside.%I including all)', :'a_cpy', :'a_cpy')) as a8 \gset
select o as a_squat from dblink('h350', format('select %L::regclass::oid', 'a350s.' || quote_ident(:'a_cpy'))) as t(o oid) \gset
select dblink_exec('h350', 'commit') as a9 \gset
select coalesce(string_agg(x, ','), 'no row') as a_ret from dblink_get_result('r350', false) as t(x text) \gset
select dblink_error_message('r350') as a_err \gset
select count(*) as a_drained from dblink_get_result('r350', false) as t(x text) \gset
select ok(:'a_squat'::oid <> :'a_cpy_oid'::oid, 'LIVENESS: A: the copy''s name denotes the namesake now');

select is(:'a_ret'::text, 'copied:20', format('A: the batch copied 20 rows (%s)', :'a_err'));
select is(pg_temp.rows_of(:'a_squat'), null::text[], 'A: the namesake copy received nothing');
select is(pg_temp.rows_of(:'a_cpy_oid'), (select array_agg(g * 10 || '=real' order by g) from generate_series(1, 40) g),
  'A: the copy pgpm recorded holds ids 10..400, every one the source''s, and neither 210 nor 220 twice');
select is((select regrain_cursor from pgpm.config where parent_table = :'a_parent'::oid), '0',
  'A: the cursor has not passed [0, 500), whose copy still lacks ids 410..490');
select is(pgpm.regrain(:'a_parent'::oid::regclass, (select child_name from pgpm.part
    where parent_table = :'a_parent'::oid and attached and lo = '0'), '500'), 2, 'A: the regrain runs to its swap');
select is(pg_temp.rows_of(:'a_parent'),
  (select array_agg(g * 10 || '=real' order by g) from generate_series(1, 99) g) || '20000=frontier'::text,
  'A: and the table serves every one of ids 10..990, the source''s, and its frontier row');

-- ======================= (B) the copy batch waits for the source; the schema is swapped ===========================
set timezone = 'UTC';
-- the grid's anchor, and so the monolith's hi: two whole seconds ahead of the clock, so the monolith freezes
select (date_trunc('second', clock_timestamp()) + interval '2 seconds')::text as b_anc \gset
select set_config('pgpm350.anc', :'b_anc', false) as b_anc_set \gset
create schema b350s;
create table b350s.ev (id bigint not null, ts timestamptz not null, payload text, primary key (id, ts));
insert into b350s.ev
  select g, :'b_anc'::timestamptz - interval '5 hours' + g * interval '1 minute', 'orig' from generate_series(1, 10) g;
call pgpm.transmute('b350s.ev', 'ts', interval '1 minute', p_obtain => 2, p_anchor => :'b_anc'::timestamptz);
do $$ begin
  for i in 1 .. 100 loop
    exit when clock_timestamp() > current_setting('pgpm350.anc')::timestamptz + interval '200 ms';
    perform pg_sleep(0.1);
  end loop;
end $$;
select 'b350s.ev'::regclass::oid as b_parent \gset
select is(pgpm.regrain_step('b350s.ev', (select p.child_name from pgpm.part p
    where p.parent_table = 'b350s.ev'::regclass and p.attached order by p.lo::timestamptz limit 1), '30 minutes', 4), 'prepared',
  'fixture: B''s regrain is prepared');
-- the prepare tick may rename the source (#266): read it by its place
select p.child_name as b_src, p.child_oid as b_src_oid from pgpm.part p
 where p.parent_table = 'b350s.ev'::regclass and p.attached order by p.lo::timestamptz limit 1 \gset
select is(pgpm.regrain_step('b350s.ev', :'b_src', '30 minutes', 4), 'copied:4', 'fixture: B''s first batch copied ids 1..4');
select p.child_name as b_cpy, p.child_oid as b_cpy_oid from pgpm.part p
 where p.parent_table = 'b350s.ev'::regclass and not p.attached \gset

select dblink_exec('h350', 'begin') as b1 \gset
select dblink_exec('h350', format('lock table b350s.%I in access exclusive mode', :'b_src')) as b2 \gset
select dblink_send_query('r350', format('select pgpm.regrain_step(%s::oid::regclass, %L, %L, 4)', :'b_parent', :'b_src', '30 minutes')) as b3 \gset
select ok(pg_temp.waits_for(:'b_src_oid'::oid, 'AccessShareLock'),
  'LIVENESS: B: the copy batch waits for ACCESS SHARE on the source''s oid, behind the holder');
select dblink_exec('h350', 'alter schema b350s rename to b350s_aside') as b4 \gset
select dblink_exec('h350', 'create schema b350s') as b5 \gset
select dblink_exec('h350', format('create table b350s.%I (like b350s_aside.%I)', :'b_src', :'b_src')) as b6 \gset
select dblink_exec('h350', format($$insert into b350s.%I select g, %L::timestamptz - interval '5 hours' + g * interval '1 minute', 'stale' from generate_series(5, 8) g$$,
                                  :'b_src', :'b_anc')) as b7 \gset
select dblink_exec('h350', format('create table b350s.%I (like b350s_aside.%I)', :'b_cpy', :'b_cpy')) as b8 \gset
select o as b_squat from dblink('h350', format('select %L::regclass::oid', 'b350s.' || quote_ident(:'b_src'))) as t(o oid) \gset
select dblink_exec('h350', 'commit') as b9 \gset
select coalesce(string_agg(x, ','), 'no row') as b_ret from dblink_get_result('r350', false) as t(x text) \gset
select dblink_error_message('r350') as b_err \gset
select count(*) as b_drained from dblink_get_result('r350', false) as t(x text) \gset
select ok(:'b_squat'::oid <> :'b_src_oid'::oid, 'LIVENESS: B: the source''s name denotes the namesake now');

select is(:'b_ret'::text, 'copied:4', format('B: the batch copied 4 rows (%s)', :'b_err'));
select is(pg_temp.rows_of(:'b_cpy_oid'), (select array_agg(g || '=orig' order by g) from generate_series(1, 8) g),
  'B: the copy pgpm recorded holds ids 1..8 as the source holds them, none of the namesake''s stale ones');
select is(pgpm.regrain(:'b_parent'::oid::regclass, (select p.child_name from pgpm.part p
    where p.parent_table = :'b_parent'::oid and p.attached order by p.lo::timestamptz limit 1), '30 minutes') > 0, true,
  'B: the regrain runs to its swap');
select is(pg_temp.rows_of(:'b_parent'), (select array_agg(g || '=orig' order by g) from generate_series(1, 10) g),
  'B: and the table serves ids 1..10 with the source''s values');
reset timezone;

-- ======================= (C) the copy's outgoing key waits for its referenced table; the schema is swapped =========
do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'c350_reader') then create role c350_reader nologin; end if;
end $$;
create table public.c350_ref (id bigint primary key);
insert into public.c350_ref select g from generate_series(1, 5) g;
create schema c350s;
create table c350s.t (id bigint primary key, ref_id bigint references public.c350_ref (id), payload text);
insert into c350s.t select g * 10, 1 + g % 5, 'real' from generate_series(1, 99) g;
call pgpm.transmute('c350s.t', 'id', 1000, p_paused => true);
insert into c350s.t values (20000, 1, 'frontier');
select 'c350s.t'::regclass::oid as c_parent \gset
select 'public.c350_ref'::regclass::oid as c_ref \gset
select conname as c_fk from pg_constraint where conrelid = 'c350s.t'::regclass and contype = 'f' \gset
select is(pgpm.regrain_step('c350s.t', (select child_name from pgpm.part
    where parent_table = 'c350s.t'::regclass and attached and lo = '0'), '500', 20), 'prepared',
  'fixture: C''s regrain is prepared, with no copy made yet');
select child_name as c_src from pgpm.part where parent_table = 'c350s.t'::regclass and attached and lo = '0' \gset
select pgpm._regrain_sub_name('t', c, '500', '0', '500') as c_cpy from pgpm.config c where c.parent_table = 'c350s.t'::regclass \gset

select dblink_exec('h350', 'begin') as c1 \gset
select dblink_exec('h350', 'insert into public.c350_ref values (100)') as c2 \gset
select dblink_send_query('r350', format('select pgpm.regrain_step(%s::oid::regclass, %L, %L, 20)', :'c_parent', :'c_src', '500')) as c3 \gset
select ok(pg_temp.waits_for(:'c_ref'::oid, 'ShareRowExclusiveLock'),
  'LIVENESS: C: the copy''s key ADD waits for SHARE ROW EXCLUSIVE on the referenced table, behind the writer');
select dblink_exec('h350', 'alter schema c350s rename to c350s_aside') as c4 \gset
select dblink_exec('h350', 'create schema c350s') as c5 \gset
select dblink_exec('h350', format('create table c350s.%I (id bigint, ref_id bigint, payload text, constraint %I check (true) not valid)', :'c_cpy', :'c_fk')) as c6 \gset
select dblink_exec('h350', format($$insert into c350s.%I values (15, 1, 'stranger'), (25, 1, 'stranger')$$, :'c_cpy')) as c7 \gset
select dblink_exec('h350', format('grant select on c350s.%I to c350_reader', :'c_cpy')) as c8 \gset
select o as c_squat from dblink('h350', format('select %L::regclass::oid', 'c350s.' || quote_ident(:'c_cpy'))) as t(o oid) \gset
select dblink_exec('h350', 'commit') as c9 \gset
select coalesce(string_agg(x, ','), 'no row') as c_ret from dblink_get_result('r350', false) as t(x text) \gset
select dblink_error_message('r350') as c_err \gset
select count(*) as c_drained from dblink_get_result('r350', false) as t(x text) \gset
select child_oid as c_cpy_oid from pgpm.part where parent_table = :'c_parent'::oid and not attached and lo = '0' \gset
select c.oid as c_made from pg_class c where c.relname = :'c_cpy' and c.relnamespace = 'c350s_aside'::regnamespace \gset
select ok(:'c_squat'::oid <> :'c_made'::oid and :'c_squat'::oid = ('c350s.' || quote_ident(:'c_cpy'))::regclass::oid,
  'LIVENESS: C: the CREATE made the copy beside the source, and the copy''s name denotes the namesake now');

select is(:'c_ret'::text, 'copied:20', format('C: the tick made the copy and copied a batch into it (%s)', :'c_err'));
select is(pg_temp.rows_of(:'c_squat'), array['15=stranger', '25=stranger'], 'C: the namesake keeps its rows 15 and 25 alone');
select ok(not exists (select 1 from pg_constraint where conrelid = :'c_squat'::oid and conname = :'c_cpy' || '_ck'),
  'C: the namesake carries no bound CHECK of the copy''s');
select ok(has_table_privilege('c350_reader', :'c_squat'::oid, 'select'), 'C: and keeps the grant its owner gave');
select is(:'c_cpy_oid'::oid, :'c_made'::oid, 'C: pgpm.part anchors the copy the CREATE made, beside the source');
select is(pg_temp.rows_of(:'c_cpy_oid'), (select array_agg(g * 10 || '=real' order by g) from generate_series(1, 20) g),
  'C: and that copy holds the batch, ids 10..200');
select ok(exists (select 1 from pg_constraint where conrelid = :'c_cpy_oid'::oid and conname = :'c_fk' and contype = 'f' and convalidated),
  'C: with the parent''s key on it, validated');
drop owned by c350_reader;
drop role c350_reader;

-- ======================= (D) the reconcile waits for the delta; the schema is swapped ==============================
create schema d350s;
create table d350s.t (id bigint primary key, payload text);
insert into d350s.t select g * 10, 'real' from generate_series(1, 99) g;
call pgpm.transmute('d350s.t', 'id', 1000, p_paused => true);
insert into d350s.t values (20000, 'frontier');
select 'd350s.t'::regclass::oid as d_parent \gset
select is(pgpm.regrain_step('d350s.t', (select child_name from pgpm.part
    where parent_table = 'd350s.t'::regclass and attached and lo = '0'), '500', 1000), 'prepared',
  'fixture: D''s regrain is prepared');
select child_name as d_src from pgpm.part where parent_table = 'd350s.t'::regclass and attached and lo = '0' \gset
select is(pgpm.regrain_step(:'d_parent'::oid::regclass, :'d_src', '500', 1000), 'copied:49',
  'fixture: D''s copy of [0, 500) is complete, so a change in it is reconciled');
update d350s.t set payload = 'changed' where id = 30;
-- this tick analyzes the delta (it never was) and reconciles id 30: after it the delta's statistics stand, so the
-- next tick's first statement on the delta is the batch's read
select is(pgpm.regrain_step(:'d_parent'::oid::regclass, :'d_src', '500', 1000), 'reconciled:2',
  'fixture: D''s first captured change (id 30) is reconciled');
update d350s.t set payload = 'changed' where id = 40;
select child_oid as d_cpy_oid from pgpm.part where parent_table = :'d_parent'::oid and not attached and lo = '0' \gset
select regrain_delta_oid as d_delta, (select relname from pg_class where oid = regrain_delta_oid) as d_delta_name
  from pgpm.config where parent_table = :'d_parent'::oid \gset
select is((select array_agg(id order by id) from d350s.:"d_delta_name"), array[40, 40]::bigint[],
  'fixture: D''s delta holds the two captured rows of id 40');

select dblink_exec('h350', 'begin') as d1 \gset
select dblink_exec('h350', format('lock table d350s.%I in access exclusive mode', :'d_delta_name')) as d2 \gset
select dblink_send_query('r350', format('select pgpm.regrain_step(%s::oid::regclass, %L, %L, 1000)', :'d_parent', :'d_src', '500')) as d3 \gset
select ok(pg_temp.waits_for(:'d_delta'::oid, null), 'LIVENESS: D: the tick waits for a lock on the delta''s oid, behind the holder');
select dblink_exec('h350', 'alter schema d350s rename to d350s_aside') as d4 \gset
select dblink_exec('h350', 'create schema d350s') as d5 \gset
select dblink_exec('h350', format('create table d350s.%I (id bigint, pgpm_seq bigint)', :'d_delta_name')) as d6 \gset
select dblink_exec('h350', format('insert into d350s.%I values (50, 900), (60, 901)', :'d_delta_name')) as d7 \gset
select o as d_squat from dblink('h350', format('select %L::regclass::oid', 'd350s.' || quote_ident(:'d_delta_name'))) as t(o oid) \gset
select dblink_exec('h350', 'commit') as d8 \gset
select coalesce(string_agg(x, ','), 'no row') as d_ret from dblink_get_result('r350', false) as t(x text) \gset
select dblink_error_message('r350') as d_err \gset
select count(*) as d_drained from dblink_get_result('r350', false) as t(x text) \gset
select ok(:'d_squat'::oid <> :'d_delta'::oid, 'LIVENESS: D: the delta''s name denotes the namesake now');

select is(:'d_ret'::text, 'reconciled:2', format('D: the tick reconciled the two captured rows of the delta pgpm recorded (%s)', :'d_err'));
select is((select array_agg(r) from unnest(pg_temp.rows_of(:'d_cpy_oid')) r where r like '30=%' or r like '40=%'),
  array['30=changed', '40=changed'], 'D: and the copy pgpm recorded holds id 40 as changed');
select is((select array_agg(id || ':' || pgpm_seq order by id) from d350s.:"d_delta_name"), array['50:900', '60:901'],
  'D: the namesake delta keeps both its rows');
select is(pg_temp.n_of(:'d_delta'), 0::bigint, 'D: and the delta pgpm recorded is consumed');

-- ======================= (E) the swap's TRUNCATE of a never-written delta, the schema swapped during its wait ========
-- The swap empties the delta with pgpm._truncate_checked, judged by its effect on the delta's oid (#1335 b10): a new
-- relfilenode, or, for a delta this transaction created (regrain() prepares and swaps in one), an empty one TRUNCATE
-- emptied in place. That second branch asked whether this transaction wrote the delta's pg_class row, which a GRANT
-- this tick makes too: the swap tick grants a writer of the table new since the last tick INSERT on the delta (#496).
-- So a never-written delta (no page to empty) under such a grant passed the check while the TRUNCATE emptied a
-- namesake a schema swap put under its name during its wait, and the swap committed. The judge is the delta's
-- creation, which no grant or owner change rewrites: the namesake keeps its rows and the swap is refused.
do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'e350_writer') then create role e350_writer nologin; end if;
end $$;
create schema e350s;
create table e350s.t (id bigint primary key, payload text);
insert into e350s.t select g * 10, 'real' from generate_series(1, 99) g;
call pgpm.transmute('e350s.t', 'id', 1000, p_paused => true);
insert into e350s.t values (20000, 'frontier');
select 'e350s.t'::regclass::oid as e_parent \gset
select is(pgpm.regrain_step('e350s.t', (select child_name from pgpm.part
    where parent_table = 'e350s.t'::regclass and attached and lo = '0'), '500', 1000), 'prepared',
  'fixture: E''s regrain is prepared');
select child_name as e_src, child_oid as e_src_oid from pgpm.part where parent_table = 'e350s.t'::regclass and attached and lo = '0' \gset
select is(pgpm.regrain_step(:'e_parent'::oid::regclass, :'e_src', '500', 1000), 'copied:49', 'fixture: E''s first copy');
select is(pgpm.regrain_step(:'e_parent'::oid::regclass, :'e_src', '500', 1000), 'copied:50', 'fixture: E''s second copy: the next tick swaps');
select regrain_delta_oid as e_delta, (select relname from pg_class where oid = regrain_delta_oid) as e_delta_name
  from pgpm.config where parent_table = :'e_parent'::oid \gset
grant insert on e350s.t to e350_writer;
select ok(pg_relation_size(:'e_delta'::oid) = 0 and not has_table_privilege('e350_writer', :'e_delta'::oid, 'insert'),
  'LIVENESS: E: the delta was never written, and the swap tick will grant the table''s new writer INSERT on it');

select dblink_exec('h350', 'begin') as e1 \gset
select x as e_seen from dblink('h350', format('select count(*)::text from e350s.%I', :'e_delta_name')) as t(x text) \gset
select dblink_send_query('r350', format('select pgpm.regrain_step(%s::oid::regclass, %L, %L, 1000)', :'e_parent', :'e_src', '500')) as e2 \gset
select ok(pg_temp.waits_for(:'e_delta'::oid, 'AccessExclusiveLock'),
  'LIVENESS: E: the swap''s TRUNCATE waits for ACCESS EXCLUSIVE on the delta''s oid, behind the reader');
select dblink_exec('h350', 'alter schema e350s rename to e350s_aside') as e3 \gset
select dblink_exec('h350', 'create schema e350s') as e4 \gset
select dblink_exec('h350', format('create table e350s.%I (id bigint, pgpm_seq bigint)', :'e_delta_name')) as e5 \gset
select dblink_exec('h350', format('insert into e350s.%I values (7, 1), (8, 2)', :'e_delta_name')) as e6 \gset
select o as e_squat from dblink('h350', format('select %L::regclass::oid', 'e350s.' || quote_ident(:'e_delta_name'))) as t(o oid) \gset
select dblink_exec('h350', 'commit') as e7 \gset
select coalesce(string_agg(x, ','), 'no row') as e_ret from dblink_get_result('r350', false) as t(x text) \gset
select dblink_error_message('r350') as e_err \gset
select count(*) as e_drained from dblink_get_result('r350', false) as t(x text) \gset
select ok(:'e_squat'::oid <> :'e_delta'::oid, 'LIVENESS: E: the delta''s name denotes the namesake now');

select is((select array_agg(id order by id) from e350s.:"e_delta_name"), array[7, 8]::bigint[],
  format('E: the namesake keeps its rows 7 and 8 (tick: %s)', :'e_ret'));
select ok(:'e_err' like '%emptying the delta after the swap, reached another relation than the one it identified%',
  'E: the swap refuses, saying its TRUNCATE reached another relation');
select ok(exists (select 1 from pg_inherits where inhrelid = :'e_src_oid'::oid and inhparent = :'e_parent'::oid),
  'E: and rolls back whole: the source is still attached');
select is(pgpm.regrain_step(:'e_parent'::oid::regclass, :'e_src', '500', 1000), 'swapped:2',
  'E: the next tick, with no reader in the way, swaps');
select is(pg_temp.rows_of(:'e_parent'),
  (select array_agg(g * 10 || '=real' order by g) from generate_series(1, 99) g) || '20000=frontier'::text,
  'E: and the table serves every one of ids 10..990 and its frontier row');
revoke all on e350s_aside.t from e350_writer;
drop owned by e350_writer;
drop role e350_writer;

select dblink_disconnect('h350') as dh \gset
select dblink_disconnect('r350') as dr \gset
select * from finish();
