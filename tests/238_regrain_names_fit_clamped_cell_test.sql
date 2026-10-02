-- set_regrain's name check names a clamped first cell the way regrain_step will (issue #815, F3-06).
--
-- _regrain_names_fit (#710) asks, at set_regrain time, whether every fine child auto-regrain would mint fits
-- PostgreSQL's 63-byte identifier limit. It rendered each sub-range with _part_name at the target step's
-- granularity, but regrain_step names a CLAMPED first sub-range (a child whose lo is off the target's
-- lattice) through _regrain_sub_name (#783), which labels it at a finer granularity and so a longer name: a
-- day cell clamped to an hour edge reads _pYYYY_MM_DD_HH, three bytes longer than the day label. A table
-- name that fit the day label and not the hour one passed set_regrain, and every auto-regrain tick then
-- raised the 63-byte refusal and logged skip_regrain, the wedge #510 and #710 exist to refuse at call time.
--
-- The contract: a target set_regrain accepts never fails its ticks on a fine child's name length, and the
-- refusal is made at call time and sets nothing. Fixtures are a boundary pair, one byte apart, on the shape
-- the issue reproduced (a Los Angeles monthly grid anchored at local midnight, whose summer month edge 07:00Z
-- is off the fixed day lattice at 08:00Z, regrained to '1 day'):
--   la49: a 49-byte parent. The day label fits (61 bytes), the clamped cell's hour label does not (64):
--         refused, regrain_to left null.
--   la48: a 48-byte parent. The hour label is exactly 63 bytes: accepted, and auto-regrain mints the
--         clamped cell under that name with no tick refused, the witness that the check is not simply
--         refusing more.
-- bench/regrain_names_fit_clamped_cell.sh runs this file against the mutant that renders the cells with
-- _part_name again (regrain_names_fit_part_name), so it is also required to FAIL there.
create extension if not exists pgtap;
select plan(10);

create function pg_temp.tt(p_ts timestamptz, p_tail text) returns text language sql immutable as $$
  select pgpm._ts_to_text_time(p_ts, '', 10, 32, 'ms', '0123456789ABCDEFGHJKMNPQRSTVWXYZ') || p_tail $$;
-- a text_time table from July 2024 in Los Angeles: a row a day from the 2nd, and one in the clamped first
-- hour [07:00Z, 08:00Z); monthly grid anchored at local midnight, frozen by a write three months ahead; then
-- renamed below (a rename is harmless by contract; transmute could not have named the monolith under it)
create function pg_temp.mk(p_short text) returns void language plpgsql as $$
begin
  execute format('create table public.%I (id text collate "C" primary key, ts timestamptz not null, body text)', p_short);
  execute format($f$insert into public.%I (id, ts, body)
                    select pg_temp.tt(d, 'D'), d, 'day-' || to_char(d at time zone 'UTC', 'DD')
                      from generate_series('2024-07-02 12:00+00'::timestamptz, '2024-07-31 12:00+00'::timestamptz,
                                           interval '1 day') d$f$, p_short);
  execute format($f$insert into public.%I values (pg_temp.tt('2024-07-01 07:30+00', 'E'), '2024-07-01 07:30+00', 'clamped')$f$,
                 p_short);
end $$;

set timezone = 'America/Los_Angeles';
select pg_temp.mk('la49');
select pg_temp.mk('la48');
call pgpm.transmute('public.la49', 'id', interval '1 month', p_obtain => 4, p_paused => false,
                    p_anchor => '2000-01-01 00:00 America/Los_Angeles',
                    p_tt_prefix => '', p_tt_width => 10, p_tt_radix => 32, p_tt_unit => 'ms',
                    p_tt_alphabet => '0123456789ABCDEFGHJKMNPQRSTVWXYZ');
call pgpm.transmute('public.la48', 'id', interval '1 month', p_obtain => 4, p_paused => false,
                    p_anchor => '2000-01-01 00:00 America/Los_Angeles',
                    p_tt_prefix => '', p_tt_width => 10, p_tt_radix => 32, p_tt_unit => 'ms',
                    p_tt_alphabet => '0123456789ABCDEFGHJKMNPQRSTVWXYZ');
select pgpm.obtain('public.la49');
select pgpm.obtain('public.la48');
insert into public.la49 values (pg_temp.tt(date_trunc('month', now()) + interval '3 months 1 day', 'F'),
                                date_trunc('month', now()) + interval '3 months 1 day', 'frontier');
insert into public.la48 values (pg_temp.tt(date_trunc('month', now()) + interval '3 months 1 day', 'F'),
                                date_trunc('month', now()) + interval '3 months 1 day', 'frontier');
alter table public.la49 rename to la49_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa;
alter table public.la48 rename to la48_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa;

select is(array[octet_length('la49_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'),
                octet_length('la48_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa')], array[49, 48],
          'fixture: the two parents are 49 and 48 bytes');
select ok((select bool_and(exists (select 1 from pgpm.part p where p.parent_table = t.rel and p.attached
                                     and p.lo::timestamptz = '2024-07-01 07:00+00'
                                     and p.hi::timestamptz > '2024-07-03 07:00+00'))
             from (values ('public.la49_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'::regclass),
                          ('public.la48_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'::regclass)) t(rel))
          and pgpm._grid_floor('text_time', '1 day',
                               (select partition_anchor from pgpm.config
                                 where parent_table = 'public.la48_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'::regclass),
                               '2024-07-01 07:00+00', 'America/Los_Angeles')::timestamptz = '2024-06-30 08:00+00'::timestamptz,
          'LIVENESS: both monoliths start at 07-01 07:00Z and the day lattice is at 08:00Z, so each first daily sub-range is clamped');
select throws_like($$ select pgpm._regrain_sub_name('la49_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
                       (select c from pgpm.config c where parent_table = 'public.la49_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'::regclass),
                       '1 day', '2024-07-01 07:00:00+00', '2024-07-01 08:00:00+00') $$,
                   '%la49_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa_p2024_07_01_07 is 64 bytes, over PostgreSQL''s 63-byte identifier limit%',
                   'LIVENESS: the name regrain_step gives la49''s clamped cell (an hour label) is 64 bytes');
select ok(octet_length(pgpm._part_name('la49_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', 'text_time', '1 day',
                                       '2024-07-01 07:00:00+00', null, 'America/Los_Angeles')) = 61,
          'LIVENESS: la49''s day label for the same cell fits (61 bytes), so a check at the step''s granularity passes it');

-- (1) la49: refused at call time, naming the clamped cell, and nothing set
select throws_like($$ select pgpm.set_regrain('public.la49_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', '1 day') $$,
                   '%cannot name a partition of la49_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa -- la49_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa_p2024_07_01_07 is 64 bytes%',
                   'set_regrain refuses a target whose clamped first cell''s name does not fit, naming that cell');
select is((select regrain_to from pgpm.config
            where parent_table = 'public.la49_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'::regclass),
          null, 'and the refusal set no regrain_to, so no tick will try');

-- (2) la48: the hour label is exactly 63 bytes; accepted, and auto-regrain mints the clamped cell under it
select lives_ok($$ select pgpm.set_regrain('public.la48_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', '1 day') $$,
                'set_regrain accepts the 48-byte parent, whose clamped cell''s name is exactly 63 bytes');
do $$ declare v_st text; begin
  for i in 1..4 loop call pgpm.maintain('public.la48_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', v_st); end loop;
end $$;
select ok(exists (select 1 from pgpm.log where parent_table = 'public.la48_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'::regclass
                   and action = 'regrain_copy' and rows = 1
                   and lo::timestamptz = '2024-07-01 07:00+00' and hi::timestamptz = '2024-07-01 08:00+00'),
          'LIVENESS: auto-regrain prepared la48''s monolith and copied its clamped first cell');
select is((select string_agg(distinct left(method, 160), ' | ') from pgpm.log
            where parent_table = 'public.la48_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'::regclass and action = 'skip_regrain'),
          null, 'and no tick of the accepted target was refused');
create function pg_temp.copy_of(p_parent regclass, p_lo timestamptz, p_hi timestamptz) returns text
language plpgsql as $$
declare v_oid oid; v text;
begin
  select child_oid into v_oid from pgpm.part
   where parent_table = p_parent and not attached and lo::timestamptz = p_lo and hi::timestamptz = p_hi;
  if v_oid is null then return null; end if;
  execute format('select string_agg(body, '','' order by body) from %s', v_oid::regclass) into v;
  return (select c.relname::text || ' ' || octet_length(c.relname) from pg_class c where c.oid = v_oid) || ' ' || v;
end $$;
select is(pg_temp.copy_of('public.la48_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', '2024-07-01 07:00+00', '2024-07-01 08:00+00'),
          'la48_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa_p2024_07_01_07 63 clamped',
          'the clamped cell''s copy is the 63-byte name set_regrain checked, holding its one row');

select * from finish();
