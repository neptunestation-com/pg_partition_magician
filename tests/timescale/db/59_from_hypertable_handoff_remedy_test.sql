-- The remedy for a refused hypertable handoff finishes the migration the handoff would have (issues #1079,
-- #1089), on a real hypertable.
--
-- from_hypertable_cutover commits its swap (the hypertable dropped, the copy renamed into place, the incoming
-- keys dropped and recorded in pgpm.dropped_fk) and only then calls transmute, which can still refuse: here,
-- because the name its carried secondary index needs on the new parent (<index>_pgpm) is taken. The reference
-- tells the operator to fix what the refusal names and finish the handoff themselves.
--   #1079  The retention the handoff passes transmute (p_retain, or left null the source's drop_chunks
--          interval) lived only in a plpgsql local, so the operator's transmute registered the table with
--          retain null. The swap now records it in pgpm.handoff, against the table it puts in place, and
--          transmute called on that table with p_retain null takes it; an explicit p_retain still wins.
--   #1089  The reference promised the next maintenance tick would re-add the keys, but transmute registers the
--          table paused by default and maintain returns 'paused' before its restore step. The remedy is now
--          the three calls the cutover makes after its swap: transmute, restore_incoming_fks,
--          validate_incoming_fks.
--
-- WHAT THE HARNESS ALLOWS. The refused handoff exists only after the swap's COMMIT, which throws_* cannot
-- reach (it runs the procedure inside a function, where the COMMIT dies with 2D000), and this track fails a
-- file that prints an ERROR: line. So each cutover runs in a dblink session, as a bare CALL there, and its
-- error is read back as a value (dblink_error_message), never printed. dblink connects to the container's
-- bridge address with the harness's password, as tests/timescale/db/57 explains. Apache TimescaleDB has no
-- retention policies, so the retention carried here is the cutover's explicit p_retain; the drop_chunks path
-- reads the same record, and bench/hypertable_handoff_remedy.sh drives it with stood-in catalog views and runs
-- the reference's remedy block verbatim.
--
-- ASYMMETRIC FIXTURE. h59 (4 rows, two of them referenced by ref59) is cut over with p_retain 45 days and
-- remedied as the reference says; h59b (3 rows) with p_retain 20 days and remedied with an explicit 7 days;
-- p59, a plain table, is transmuted with p_retain null while both records exist, and must take neither; a
-- record whose table is gone must be swept by that call. Rows and keys are asserted by identity.
create extension if not exists dblink;
\set pgpm_host `hostname -i | tr ' ' '\n' | grep -m1 '^[0-9][0-9.]*$'`
select set_config('t59.connstr', format('host=%s dbname=%s user=postgres password=postgres', :'pgpm_host', current_database()), false) \g /dev/null
select plan(18);

create table public.h59 (id bigint not null, ts timestamptz not null, v text, primary key (id, ts));
select create_hypertable('public.h59', 'ts', chunk_time_interval => interval '1 day') \g /dev/null
insert into public.h59 select g, now() - g * interval '1 day', 'r' || g from generate_series(1, 4) g;
create table public.ref59 (rid int primary key, h_id bigint, h_ts timestamptz,
                           constraint ref59_fk foreign key (h_id, h_ts) references public.h59 (id, ts));
insert into public.ref59 select id, id, ts from public.h59 where id in (2, 3);
create index h59_v_idx on public.h59 (v);
create table public.h59_v_idx_pgpm (squatter int);   -- takes the name transmute's carried index needs

create table public.h59b (id bigint not null, ts timestamptz not null, v text, primary key (id, ts));
select create_hypertable('public.h59b', 'ts', chunk_time_interval => interval '1 day') \g /dev/null
insert into public.h59b select g, now() - g * interval '1 day', 'b' || g from generate_series(1, 3) g;
create index h59b_v_idx on public.h59b (v);
create table public.h59b_v_idx_pgpm (squatter int);

create table public.p59 (id bigint not null, ts timestamptz not null, primary key (id, ts));
insert into public.p59 select g, now() - g * interval '1 day' from generate_series(1, 2) g;

call pgpm.from_hypertable_copy('public.h59', 'ts');
call pgpm.from_hypertable_copy('public.h59b', 'ts');
-- the relations each swap renames into place, by oid
create table public.d59 (t text primary key, dest oid);
insert into public.d59 values ('h59', to_regclass('public.h59_pgpm_dest')::oid),
                              ('h59b', to_regclass('public.h59b_pgpm_dest')::oid);

-- Each cutover in its own session, as a bare CALL; its error kept as a value.
create table public.o59 (t text primary key, res text, msg text);
create function pg_temp.cutover(p_t text, p_sql text) returns void language plpgsql as $f$
declare v_res text;
begin
  perform dblink_connect('c59', current_setting('t59.connstr'));
  v_res := dblink_exec('c59', p_sql, false);
  insert into public.o59 values (p_t, v_res, dblink_error_message('c59'));
  perform dblink_disconnect('c59');
end $f$;
select pg_temp.cutover('h59', $$call pgpm.from_hypertable_cutover('public.h59', 'ts', interval '1 day',
                                                                 p_retain => interval '45 days')$$) \g /dev/null
select pg_temp.cutover('h59b', $$call pgpm.from_hypertable_cutover('public.h59b', 'ts', interval '1 day',
                                                                  p_retain => interval '20 days')$$) \g /dev/null

-- ================================ the state the refused handoff leaves ================================
select is((select string_agg(t || ':' || res || ':' || (msg like '%cannot transmute %' || t || ' -- the name(s) ('
                                                         || t || '_v_idx_pgpm) are already taken%'), ',' order by t)
             from public.o59),
  'h59:ERROR:true,h59b:ERROR:true',
  'LIVENESS: each cutover failed, on transmute''s taken-index-name refusal after the swap');
select is((select string_agg(d.t || ':' || c.relkind::text || ':' || (c.relname = d.t), ',' order by d.t)
             from public.d59 d join pg_class c on c.oid = d.dest),
  'h59:r:true,h59b:r:true', 'LIVENESS: each swap committed: the copy is the plain table under the hypertable''s name');
select is((select string_agg(id || v, ',' order by id) from public.h59), '1r1,2r2,3r3,4r4',
  'LIVENESS: every h59 row is under its name');
select is((select count(*)::int from pg_constraint where conname = 'ref59_fk')
            || '/' || (select count(*) from pgpm.config),
  '0/0', 'LIVENESS: the swap dropped ref59_fk, and nothing is registered');
select is((select string_agg(d.t || ':' || h.retain, ',' order by d.t)
             from pgpm.handoff h join public.d59 d on d.dest = h.table_oid),
  'h59:45 days,h59b:20 days',
  'each swap recorded the retention it was handing over, against the table it put in place');

-- ================================ the record names its own table only ================================
create table public.gone59 (x int);
insert into pgpm.handoff (table_oid, retain) values ('public.gone59'::regclass::oid, interval '3 days');
drop table public.gone59;
call pgpm.transmute('public.p59', 'ts', interval '1 day');
select is((select coalesce(retain, 'null') from pgpm.config where parent_table = 'public.p59'::regclass), 'null',
  'an unrelated table transmuted with p_retain null takes no recorded retention');
select is((select string_agg(coalesce(d.t, 'other'), ',' order by d.t) from pgpm.handoff h
             left join public.d59 d on d.dest = h.table_oid),
  'h59,h59b', 'that call left both records in place, and swept the one whose table is gone');

-- ================================ h59: the remedy as the reference gives it ================================
drop table public.h59_v_idx_pgpm;
call pgpm.transmute('public.h59', 'ts', interval '1 day');
select is((select relkind::text from pg_class where oid = 'public.h59'::regclass)
            || '/' || (select string_agg(id || v, ',' order by id) from public.h59)
            || '/' || (select paused from pgpm.config where parent_table = 'public.h59'::regclass),
  'p/1r1,2r2,3r3,4r4/true', 'LIVENESS: transmute converted h59 with every row, registered paused');
select is((select retain::interval from pgpm.config where parent_table = 'public.h59'::regclass), interval '45 days',
  'h59 keeps the 45-day retention the cutover carried in, p_retain left null (#1079)');
select is((select count(*)::int from pgpm.handoff h join public.d59 d on d.dest = h.table_oid where d.t = 'h59'), 0,
  'registration spent h59''s record');
call pgpm.maintain('public.h59') \g /dev/null
select is((select count(*)::int from pg_constraint where conrelid = 'public.ref59'::regclass and conname = 'ref59_fk')
            || '/' || (select count(*) from pgpm.dropped_fk
                        where parent_table = 'public.h59'::regclass and constraint_name = 'ref59_fk' and restored_at is null),
  '0/1', 'LIVENESS: a maintenance tick of the paused table leaves ref59_fk dropped and recorded (why the remedy re-adds it)');
select is(pgpm.restore_incoming_fks('public.h59'), 1, 'restore_incoming_fks re-adds ref59_fk (#1089)');
select lives_ok($$ select pgpm.validate_incoming_fks('public.h59') $$, 'validate_incoming_fks runs');
select is((select string_agg(conname || ':' || convalidated, ',') from pg_constraint
            where conrelid = 'public.ref59'::regclass and contype = 'f' and confrelid = 'public.h59'::regclass),
  'ref59_fk:true', 'ref59_fk is back against the new parent, and validated');
select throws_ok($$ insert into public.ref59 values (9, 999, now()) $$, '23503', NULL,
  'and it enforces: an orphan reference is refused');
select lives_ok($$ insert into public.ref59 select 4, id, ts from public.h59 where id = 4 $$,
  'LIVENESS: while a valid reference is accepted');

-- ================================ h59b: an explicit p_retain still wins ================================
drop table public.h59b_v_idx_pgpm;
call pgpm.transmute('public.h59b', 'ts', interval '1 day', p_retain => interval '7 days');
select is((select relkind::text from pg_class where oid = 'public.h59b'::regclass)
            || '/' || (select string_agg(id || v, ',' order by id) from public.h59b),
  'p/1b1,2b2,3b3', 'LIVENESS: transmute converted h59b with every row');
select is((select retain::interval from pgpm.config where parent_table = 'public.h59b'::regclass)::text
            || '/' || (select count(*) from pgpm.handoff),
  '7 days/0', 'an explicit p_retain wins over the recorded 20 days, and the record is spent all the same');

select * from finish();
-- no teardown: the harness runs each db/ test in a throwaway database (disposable-db).
