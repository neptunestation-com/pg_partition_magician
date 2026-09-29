-- Copies made without change capture are discarded at the re-prepare whatever the cursor says (issue #569).
--
-- regrain_step's prepare tick installs change capture on the source, and when it finds none installed it
-- discards the regrain's existing copies first: they were made while nothing recorded the source's
-- changes, so they are unreconciled, and resuming from them lets the swap attach stale rows. That discard
-- used to be gated on config.regrain_cursor IS NOT NULL. The janitor (_enforce_regrain_capture) is
-- documented as the backstop for a cursor cleared by some other route (a hand edit): it sees capture the
-- null cursor does not cover and tears it down, and it leaves the copies. So the one state the restart
-- exists for arrived with the cursor null, the gate skipped the discard, the next run resumed from the
-- stale copies, and the swap made them the authority: an UPDATE made while capture was off reverted, a
-- DELETE came back, and an INSERT vanished.
--
-- Now the prepare tick discards every not-attached copy inside the source's range whenever capture is
-- not installed, and logs regrain_restart when it discarded one (or, as before, when a cursor was set).
-- A first prepare with no copies and no cursor still logs nothing of the kind.
--
-- The fixture is asymmetric (an UPDATE and an INSERT in, a DELETE out, all in a sub-range already
-- copied), so no pair of errors can cancel, and the rows are asserted by WHICH ids hold WHICH payload.
-- Every negative is paired with a witness that its conditions were present: the copy really existed,
-- the janitor really reaped the capture, the changes really went uncaptured, the swap really ran.
-- bench/regrain_restart_null_cursor.sh runs this file against a mutant with the cursor gate put back
-- (regrain_restart_needs_cursor), so it is also required to FAIL there.
create extension if not exists pgtap;

select plan(20);

create table public.rn (id bigint primary key, payload text);
insert into public.rn select g, 'orig' from generate_series(1000, 299000, 1000) g;   -- 299 rows
insert into public.rn values (1999999, 'widen');                                    -- monolith [0, 2000000)
call pgpm.transmute('public.rn', 'id', 1000000);
insert into public.rn values (3500000, 'frontier');                                 -- it is frozen
select child_name as mono from pgpm.part
 where parent_table = 'public.rn'::regclass and attached order by lo::numeric limit 1 \gset

select is(:'mono'::text, 'rn_p0000000000000000000_to_0000000000002000000',
  'LIVENESS: the monolith is [0, 2000000)');

-- ======================================================================================================
-- the first run: prepare, then copy [0, 100000) whole, under capture
-- ======================================================================================================
select is(pgpm.regrain_step('public.rn', :'mono', '100000', 1000), 'prepared',
  'LIVENESS: the first tick prepares (installs capture)');
select is(
  (select array_agg(action order by id) from pgpm.log
    where parent_table = 'public.rn'::regclass and action in ('regrain_prepare', 'regrain_restart')),
  array['regrain_prepare'],
  'a first prepare with no copies and no cursor logs no regrain_restart (the prepare witnesses it ran)');
select is(pgpm.regrain_step('public.rn', :'mono', '100000', 1000), 'copied:99',
  'LIVENESS: the second tick copies all 99 rows of [0, 100000)');
select is((select regrain_cursor from pgpm.config where parent_table = 'public.rn'::regclass), '100000',
  'LIVENESS: the cursor sits at the end of the copied sub-range');
select is(
  (select array_agg(lo || '-' || hi) from pgpm.part where parent_table = 'public.rn'::regclass and not attached),
  array['0-100000'],
  'LIVENESS: exactly one not-attached copy is recorded, for [0, 100000)');
select is((select array_agg(id || ':' || payload order by id) from public.rn_p0000000000000000000
            where id between 49000 and 51000),
          array['49000:orig', '50000:orig', '51000:orig'],
  'LIVENESS: the copy holds 49000, 50000 and 51000, each as it was');
select ok(pgpm._regrain_capture_active('public.rn', :'mono'),
  'LIVENESS: capture is installed on the source');

-- ======================================================================================================
-- the janitor's documented backstop: a cursor cleared by hand, then its sweep
-- ======================================================================================================
update pgpm.config set regrain_cursor = null where parent_table = 'public.rn'::regclass;
select pgpm._enforce_regrain_capture('public.rn');
select is(
  (select array_agg(method) from pgpm.log
    where parent_table = 'public.rn'::regclass and action = 'regrain_capture_orphan'),
  array[:'mono'::text],
  'LIVENESS: the janitor reaped the source''s capture as orphaned (one regrain_capture_orphan, naming it)');
select ok(not pgpm._regrain_capture_active('public.rn', :'mono'),
  'LIVENESS: no capture is installed on the source now');
select isnt(to_regclass('public.rn_p0000000000000000000'), null::regclass,
  'LIVENESS: the janitor left the copy behind, on disk and with the cursor null');

-- uncaptured changes to the already-copied sub-range: two in (an UPDATE and an INSERT), one out (a DELETE)
update public.rn set payload = 'changed' where id = 50000;
insert into public.rn values (50500, 'new');
delete from public.rn where id = 51000;
select is(pgpm._regrain_delta_count('public.rn'), 0::bigint,
  'LIVENESS: none of the three changes was captured');

-- ======================================================================================================
-- the next run: the re-prepare must discard the copy, whatever the (null) cursor says
-- ======================================================================================================
select is(pgpm.regrain_step('public.rn', :'mono', '100000', 1000), 'prepared',
  'LIVENESS: the next tick re-prepares (capture was gone)');
select is(
  (select array_agg(lo || '-' || hi || ':' || rows || ':' || method) from pgpm.log
    where parent_table = 'public.rn'::regclass and action = 'regrain_restart'),
  array['0-2000000:1:copies predate change capture'],
  'the re-prepare logged one regrain_restart for the source, discarding exactly one copy');
select is(to_regclass('public.rn_p0000000000000000000'), null::regclass,
  'the copy made without capture behind it is dropped');
select is((select count(*) from pgpm.part where parent_table = 'public.rn'::regclass and not attached), 0::bigint,
  'and no not-attached pgpm.part row is left to resume from');

do $$
declare s text; n int := 0;
begin
  loop
    s := pgpm.regrain_step('public.rn', 'rn_p0000000000000000000_to_0000000000002000000', '100000', 1000);
    exit when s like 'swapped:%';
    n := n + 1;
    if n > 80 then raise exception 'regrain did not swap (last status: %)', s; end if;
  end loop;
end $$;
select is(to_regclass(format('public.%I', :'mono')), null::regclass,
  'LIVENESS: the swap ran: the source is dropped and the fine children serve the range');

-- ======================================================================================================
-- identity through the swap
-- ======================================================================================================
select is((select array_agg(id || ':' || payload order by id) from public.rn where id between 49000 and 51000),
          array['49000:orig', '50000:changed', '50500:new'],
  'the UPDATE survives, the INSERT survives, the DELETE stays deleted; the untouched neighbour is unchanged');
select is(
  (select array_agg(id order by id) from public.rn),
  (select array_agg(id order by id) from (
     select g::bigint as id from generate_series(1000, 299000, 1000) g where g <> 51000
     union all select 50500 union all select 1999999 union all select 3500000) e),
  'the table holds exactly the ids it should: all 299 originals but 51000, plus 50500, the widen row and the frontier');
select is(
  (select array_agg(action order by id) from pgpm.log
    where parent_table = 'public.rn'::regclass
      and action in ('regrain_prepare', 'regrain_restart', 'regrain_capture_orphan')),
  array['regrain_prepare', 'regrain_capture_orphan', 'regrain_restart', 'regrain_prepare'],
  'the run''s story in order: prepare, the janitor''s sweep, the restart, the re-prepare');

select * from finish();
