-- The regrain reconcile files each captured change by its instant, whatever the session's DateStyle
-- (issue #570).
--
-- _regrain_reconcile decides which fine child a captured key belongs in by rendering the key's control
-- value as text and handing it to _grid_floor, which parses it back with ::timestamptz. It rendered with
-- a bare ::text, in the SESSION's DateStyle and TimeZone. Under a DateStyle that renders zone
-- abbreviations (SQL, Postgres) that round trip is not the identity: Asia/Kolkata renders 'IST', and the
-- default timezone_abbreviations read 'IST' as Israel (+02), so every key read 3.5 hours late. A
-- captured DELETE was "applied" to the fine child 3.5 hours up the range, deleting nothing there, and
-- consumed; the swap then attached the real fine child still holding the deleted row. Both branches of
-- the render had it: a timestamptz column's own ::text, and a naive (timestamp) column's wall time
-- converted to an instant and then ::text. Now both go through _ts_text, which pins ISO (#500), and ISO
-- text parses back to the same instant under every DateStyle.
--
-- The time kind's frontier is now(), so a monolith freezes only when the clock passes its hi. The grid
-- is anchored three seconds ahead of the clock, which puts the monolith's hi there, so the file waits
-- about three seconds for that instead of up to a whole step. That holds only while the three transmutes
-- finish before the anchor: transmute puts hi at the grid step above greatest(max, now()), so one that
-- ends past it gets hi a minute later, and under load the three took 11 s (#1340). So the fixture is
-- built in a loop that checks the monoliths' bounds and, when the clock beat them, drops the tables,
-- forgets them and starts again with a lead four times longer (12 s, then 48 s; a lead past the 1-minute
-- step would put hi below the anchor instead). A quick machine pays three seconds, a slow one a retry, and
-- the LIVENESS on the monoliths' bounds still fails if no attempt fits. The regrain target is 30 minutes on the
-- 1-minute grid (the hierarchical split regrain_history makes), which keeps the run to ten sub-ranges
-- while the misfiled key still has a fine child 3.5 hours up the range to land in.
--
-- Two tables (ev, timestamptz; evn, naive) take an asymmetric set of changes in the sub-range already
-- copied: one row deleted, one updated, one inserted. Misfiled, the UPDATE and INSERT reinsert the
-- source's row into a fine child whose CHECK refuses it, so there the defect wedges the regrain before
-- the swap. A third table (evd, timestamptz) takes a DELETE alone, the issue's own case, where nothing
-- refuses anything and the defect is silent loss: the swap brings the deleted row back. Rows are
-- asserted by which ids hold which payload, in which fine child. Every
-- negative is paired with a witness that its conditions were present: the session really renders
-- 'IST', a bare round trip in it really is 3.5 hours off, a fine child really exists where the misread
-- key goes, the changes really were captured and really were reconciled in that session, and the swap
-- really ran. bench/regrain_reconcile_datestyle.sh runs this file against a mutant with the bare
-- ::text put back (regrain_reconcile_bare_text), so it is also required to FAIL there.
--
-- PostgreSQL 18 resolves an abbreviation the SESSION's own zone uses to that zone's offset before
-- consulting timezone_abbreviations (pg_timezone_abbrevs shows IST as +05:30 under Asia/Kolkata there),
-- so on 18 the bare round trip is the identity and the defect is unreachable in one session. The two
-- round-trip witnesses below say so by version: 3.5 hours before 18, none on 18. The guard runs on 15.
create extension if not exists pgtap;

select plan(26);
set timezone = 'UTC';

-- ======================================================================================================
-- fixtures: a timestamptz control column and a naive (timestamp) one, the same rows on each, transmuted on
-- a grid anchored a few whole seconds ahead of the clock (the anchor is the monoliths' hi: see the header)
-- ======================================================================================================
do $$
declare
  v_lead interval := interval '3 seconds';
  v_anc timestamptz;
begin
  for attempt in 1 .. 3 loop   -- leads of 3, 12 and 48 s: under the 1-minute step, or hi would land below the anchor
    v_anc := date_trunc('second', clock_timestamp()) + v_lead;
    perform set_config('t136.anc', v_anc::text, false);
    create table public.ev (id bigint, ts timestamptz not null, payload text, primary key (id, ts));
    insert into public.ev values
      (1, v_anc - interval '4 hours 30 minutes' + interval '10 s', 'doomed'),
      (2, v_anc - interval '4 hours 30 minutes' + interval '20 s', 'kept'),
      (3, v_anc - interval '5 hours' + interval '5 s', 'oldest'),
      (4, v_anc - interval '2 minutes', 'newest');
    create table public.evn (id bigint, ts timestamp not null, payload text, primary key (id, ts));
    insert into public.evn select id, ts at time zone 'UTC', payload from public.ev;
    create table public.evd (like public.ev including all);
    insert into public.evd select * from public.ev;
    commit;
    call pgpm.transmute('public.ev', 'ts', interval '1 minute', p_obtain => 2, p_anchor => v_anc);
    call pgpm.transmute('public.evn', 'ts', interval '1 minute', p_obtain => 2, p_anchor => v_anc);
    call pgpm.transmute('public.evd', 'ts', interval '1 minute', p_obtain => 2, p_anchor => v_anc);
    exit when (select count(*) from pgpm.part
                where parent_table in ('public.ev'::regclass, 'public.evn'::regclass, 'public.evd'::regclass)
                  and attached and lo::timestamptz = v_anc - interval '5 hours' and hi::timestamptz = v_anc) = 3
              or attempt = 3;   -- the last attempt is kept as it is, for the LIVENESS below to judge
    -- the clock passed the anchor before a transmute finished: start again with a longer lead
    drop table public.ev, public.evn, public.evd;
    perform pgpm.forget_missing();
    commit;
    v_lead := v_lead * 4;
  end loop;
end $$;
select current_setting('t136.anc') as anc \gset
select child_name as mono_ev from pgpm.part
 where parent_table = 'public.ev'::regclass and attached order by lo::timestamptz limit 1 \gset
select child_name as mono_evn from pgpm.part
 where parent_table = 'public.evn'::regclass and attached order by lo::timestamptz limit 1 \gset
select set_config('t136.mono_ev', :'mono_ev', false) \g /dev/null
select child_name as mono_evd from pgpm.part
 where parent_table = 'public.evd'::regclass and attached order by lo::timestamptz limit 1 \gset
select set_config('t136.mono_evn', :'mono_evn', false) \g /dev/null
select set_config('t136.mono_evd', :'mono_evd', false) \g /dev/null

select is(
  (select array_agg(lo::timestamptz - :'anc'::timestamptz || ' ' || hi::timestamptz - :'anc'::timestamptz
                    order by parent_table::text)
     from pgpm.part where child_name in (:'mono_ev', :'mono_evn', :'mono_evd')),
  array['-05:00:00 00:00:00', '-05:00:00 00:00:00', '-05:00:00 00:00:00'],
  'LIVENESS: each monolith spans the five hours below the anchor');

-- wait for the clock to pass the anchor: the monoliths freeze (bounded by the anchor itself, whatever the lead)
do $$ begin
  loop
    exit when clock_timestamp() > current_setting('t136.anc')::timestamptz + interval '200 ms';
    perform pg_sleep(0.1);
  end loop;
end $$;

-- copy every sub-range from a UTC / ISO session; the SQL / Asia/Kolkata session below only reconciles
do $$
declare s text; n int; v text; t text;
begin
  foreach t in array array['ev', 'evd', 'evn'] loop
    n := 0;
    loop
      s := pgpm.regrain_step(('public.' || t)::regclass, current_setting('t136.mono_' || t), '30 minutes', 1000);
      select regrain_cursor into v from pgpm.config where parent_table = ('public.' || t)::regclass;
      exit when v is not null and v::timestamptz >= current_setting('t136.anc')::timestamptz;
      n := n + 1;
      if n > 40 then raise exception 'copy of % did not converge (last status: %)', t, s; end if;
    end loop;
  end loop;
end $$;
select is(
  (select array_agg(regrain_cursor::timestamptz = :'anc'::timestamptz order by parent_table::text)
     from pgpm.config where parent_table in ('public.ev'::regclass, 'public.evn'::regclass, 'public.evd'::regclass)),
  array[true, true, true],
  'LIVENESS: every sub-range of the three monoliths is copied (cursor at hi), so a captured key is eligible');
select is(
  (select array_agg(parent_table::text order by parent_table::text) from pgpm.part
    where not attached
      and lo::timestamptz = :'anc'::timestamptz - interval '1 hour'
      and hi::timestamptz = :'anc'::timestamptz - interval '30 minutes'),
  array['ev', 'evd', 'evn'],
  'LIVENESS: each has a fine child 3.5 hours above the changed rows, where a misread key would be sent');

-- the changes, in the copied sub-range [anc - 4h30m, anc - 4h): one out, two in
delete from public.ev where id = 1;
update public.ev set payload = 'updated' where id = 2;
insert into public.ev values (5, :'anc'::timestamptz - interval '4 hours 30 minutes' + interval '30 s', 'new');
delete from public.evn where id = 1;
update public.evn set payload = 'updated' where id = 2;
insert into public.evn values (5, (:'anc'::timestamptz - interval '4 hours 30 minutes' + interval '30 s') at time zone 'UTC', 'new');
delete from public.evd where id = 1;
select is(pgpm._regrain_delta_count('public.ev'), 4::bigint,
  'LIVENESS: the three changes to ev are captured (four delta rows: the UPDATE records its OLD and NEW key)');
select is(pgpm._regrain_delta_count('public.evn'), 4::bigint,
  'LIVENESS: the three changes to evn are captured (four delta rows: the UPDATE records its OLD and NEW key)');
select is(pgpm._regrain_delta_count('public.evd'), 1::bigint,
  'LIVENESS: the DELETE from evd is captured');
select max(id) as log_mark from pgpm.log \gset

-- ======================================================================================================
-- the operator's session: SQL DateStyle, Asia/Kolkata. It reconciles and swaps.
-- ======================================================================================================
set datestyle = 'SQL, MDY';
set timezone = 'Asia/Kolkata';
select ok((select ts::text from public.ev where id = 2) like '% IST',
  'LIVENESS: this session renders timestamptz with the IST abbreviation');
-- the abbreviation gap this session's bare round trip carries: 3.5 hours before PostgreSQL 18, none on 18
select case when current_setting('server_version_num')::int >= 180000 then interval '0'
            else interval '3 hours 30 minutes' end as gap \gset
select is((select (ts::text)::timestamptz - ts from public.ev where id = 2), :'gap'::interval,
  'LIVENESS: a bare ::text round trip in this session reads the instant late by the abbreviation gap (3.5 hours before PG 18, none on 18)');
select is((select ((ts at time zone 'UTC')::text)::timestamptz - (ts at time zone 'UTC') from public.evn where id = 2),
          :'gap'::interval,
  'LIVENESS: and so does the naive column''s wall time once converted to an instant (same gap)');

create temp table swap_err (tbl text, err text);
do $$
declare s text; n int; t text;
begin
  foreach t in array array['ev', 'evd', 'evn'] loop
    n := 0;
    begin
      loop
        s := pgpm.regrain_step(('public.' || t)::regclass, current_setting('t136.mono_' || t), '30 minutes', 1000);
        exit when s like 'swapped:%';
        n := n + 1;
        if n > 20 then raise exception 'regrain did not swap (last status: %)', s; end if;
      end loop;
    exception when others then
      insert into swap_err values (t, sqlerrm);
    end;
  end loop;
end $$;
reset datestyle;
set timezone = 'UTC';

select is((select array_agg(tbl || ': ' || err) from swap_err), null,
  'neither regrain raised on its way to the swap');
select is(
  (select array_agg(parent_table::text || ':' || rows order by parent_table::text) from (
     select parent_table, sum(rows) as rows from pgpm.log
      where id > :log_mark and action = 'regrain_reconcile'
        and parent_table in ('public.ev'::regclass, 'public.evn'::regclass, 'public.evd'::regclass)
      group by parent_table) r),
  array['ev:4', 'evd:1', 'evn:4'],
  'LIVENESS: that session reconciled every captured delta row of each table');
select is(to_regclass('public.' || :'mono_ev'), null::regclass,
  'LIVENESS: the ev swap ran; its source is dropped');
select is(to_regclass('public.' || :'mono_evn'), null::regclass,
  'LIVENESS: the evn swap ran; its source is dropped');
select is(to_regclass('public.' || :'mono_evd'), null::regclass,
  'LIVENESS: the evd swap ran; its source is dropped');

-- ======================================================================================================
-- identity through the swap
-- ======================================================================================================
select ok(not exists (select 1 from public.ev where id = 1),
  'ev: the committed DELETE of row 1 is not undone by the swap');
select is((select payload from public.ev where id = 2), 'updated',
  'ev: the committed UPDATE of row 2 is not reverted');
select is((select payload from public.ev where id = 5), 'new',
  'ev: the committed INSERT of row 5 is served');
select is((select array_agg(id || ':' || payload order by id) from public.ev),
          array['2:updated', '3:oldest', '4:newest', '5:new'],
  'ev: the table holds exactly rows 2 to 5, each as last written');
select is(
  (select array_agg(e.id order by e.id) from public.ev e join pgpm.part p
      on p.parent_table = 'public.ev'::regclass and p.child_name = e.tableoid::regclass::text
    where p.attached and e.ts >= p.lo::timestamptz and e.ts < p.hi::timestamptz),
  array[2, 3, 4, 5]::bigint[],
  'ev: every row is served by the fine child whose range holds it');

select ok(not exists (select 1 from public.evn where id = 1),
  'evn: the committed DELETE of row 1 is not undone by the swap');
select is((select payload from public.evn where id = 2), 'updated',
  'evn: the committed UPDATE of row 2 is not reverted');
select is((select payload from public.evn where id = 5), 'new',
  'evn: the committed INSERT of row 5 is served');
select is((select array_agg(id || ':' || payload order by id) from public.evn),
          array['2:updated', '3:oldest', '4:newest', '5:new'],
  'evn: the table holds exactly rows 2 to 5, each as last written');
select is(
  (select array_agg(e.id order by e.id) from public.evn e join pgpm.part p
      on p.parent_table = 'public.evn'::regclass and p.child_name = e.tableoid::regclass::text
    where p.attached and (e.ts at time zone 'UTC') >= p.lo::timestamptz and (e.ts at time zone 'UTC') < p.hi::timestamptz),
  array[2, 3, 4, 5]::bigint[],
  'evn: every row is served by the fine child whose range holds it');

select is((select array_agg(id || ':' || payload order by id) from public.evd),
          array['2:kept', '3:oldest', '4:newest'],
  'evd: the committed DELETE of row 1 is not undone by the swap; its neighbours are all still served');
select is(
  (select array_agg(e.id order by e.id) from public.evd e join pgpm.part p
      on p.parent_table = 'public.evd'::regclass and p.child_name = e.tableoid::regclass::text
    where p.attached and e.ts >= p.lo::timestamptz and e.ts < p.hi::timestamptz),
  array[2, 3, 4]::bigint[],
  'evd: every row is served by the fine child whose range holds it');

select * from finish();
