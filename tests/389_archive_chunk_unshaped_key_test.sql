-- The archive step's chunk picker does not decode a text_time key that lacks the declared shape (issue #709, the
-- archive step's bullet).
--
-- THE GAP. pgpm._next_archive_chunk sizes a chunk by reading the window's newest control value and then the next
-- distinct value past it (and, when a run of rows shares one native unit, the first row past that unit), and decoded
-- each to the native grid with _col_to_native. A text_time partition's bounds are strings, so PostgreSQL routes a key
-- that lacks the declared shape (a character outside the alphabet, a field shorter than the width) into a partition by
-- string order, and pgpm itself treats such keys as reachable (_frontier_native's #661 fallback, the regrain
-- reconcile's #1191 routing). Once one stood at a chunk boundary, the decode raised 22P02 on every tick: the archive
-- step logged skip_archive each time, no chunk was recorded past it, and the aged partition was never covered nor
-- retired.
--
-- THE CONTRACT. A chunk's bounds are native values, and a key without the shape has no native value, so the picker
-- ends a chunk at a key that has one: the window's newest value is used only as a literal (the next-distinct probe
-- compares the column against it), and both reads that end a chunk skip keys without the shape. The chunks stay
-- gapless in the column's own order, so the odd key travels inside the chunk whose encoded bounds hold it, and the
-- partition is covered and retired.
--
-- The fixture is tests/125's (ObjectId-shaped ids, 8 hex digits of Unix seconds; a frontier pinned two years out so
-- the monolith regrains into year children; a horizon at 2021-06-15), with THREE odd keys in the 2020 child, one at
-- each read: left(<key>, 7) || 'z' sorts after every key of its 16-second block and before the next, and 'z' is no hex
-- digit. A budget of about three rows makes
--   odd1 (after Jan 11) the window's newest value of the first chunk                         [Jan 01, Jan 12)  3 rows
--   odd2 (after Jan 14) the next distinct value past the second chunk's window               [Jan 12, Jan 15)  4 rows
--   odd3 (after a 5-row burst in the one second Mar 01 00:00:00) the first row past that
--        second, which the unit extension reads because the window and its next distinct
--        value both decode to the chunk's own lo                                              [Mar 01, Mar 05)  6 rows
-- The row counts differ chunk to chunk, so a chunk error cannot cancel in a total.
set timezone = 'UTC';
create extension if not exists pgtap;

select plan(9);

create schema pgpm_test389;

create function pgpm_test389.oid_at(p_ts timestamptz, p_n bigint) returns text language sql immutable as
  $$ select lpad(to_hex(extract(epoch from p_ts)::bigint), 8, '0') || lpad(to_hex(p_n), 16, '0') $$;
-- an odd key: the 16-second block's 7 digits, then a character outside the alphabet
create function pgpm_test389.odd_after(p_ts timestamptz) returns text language sql immutable as
  $$ select left(pgpm_test389.oid_at(p_ts, 0), 7) || 'z' $$;

create table public.oid389 (id text collate "C" primary key, v int not null);
insert into public.oid389 values
  (pgpm_test389.oid_at('2020-01-10 00:00:00+00', 1), 1),
  (pgpm_test389.oid_at('2020-01-11 00:00:00+00', 1), 2),
  (pgpm_test389.oid_at('2020-01-12 00:00:00+00', 1), 3),
  (pgpm_test389.oid_at('2020-01-13 00:00:00+00', 1), 4),
  (pgpm_test389.oid_at('2020-01-14 00:00:00+00', 1), 5),
  (pgpm_test389.oid_at('2020-01-15 00:00:00+00', 1), 6),
  (pgpm_test389.oid_at('2020-02-10 00:00:00+00', 1), 7),
  (pgpm_test389.oid_at('2020-03-05 00:00:00+00', 1), 8),
  (pgpm_test389.oid_at('2020-06-01 00:00:00+00', 1), 9);
insert into public.oid389
  select pgpm_test389.oid_at('2020-03-01 00:00:00+00', g), 10 + g from generate_series(1, 5) g;   -- the burst

select (now() - timestamptz '2021-06-15 00:00:00+00') as ret \gset
call pgpm.transmute('public.oid389', 'id', interval '1 year', p_obtain => 1, p_retain => :'ret'::interval,
  p_paused => false, p_tt_prefix => '', p_tt_width => 8, p_tt_radix => 16, p_tt_unit => 's');
select pgpm.set_archive_fn('public.oid389', 'pgpm._archive_noop(regclass,name,text,text)');

select (date_trunc('year', now()) + interval '2 years 5 months 14 days') as t_pin \gset
select pgpm.extend_to('public.oid389', pgpm_test389.oid_at(:'t_pin'::timestamptz, 1)) as extended \gset
insert into public.oid389 values (pgpm_test389.oid_at(:'t_pin'::timestamptz, 1), -9);
insert into public.oid389 values (pgpm_test389.oid_at('2021-03-10 00:00:00+00', 1), -3);       -- live: must survive

create table pgpm_test389.regrain as select null::text as last_status;
do $$
declare v_child name; v_status text; i int := 0;
begin
  select child_name into v_child from pgpm.part where parent_table = 'public.oid389'::regclass
     and lo::timestamptz = '2020-01-01 00:00:00+00';
  loop
    v_status := pgpm.regrain_step('public.oid389', v_child, '1 year', 500);
    i := i + 1;
    exit when v_status like 'swapped:%' or v_status in ('active', 'nokey', 'nosubdiv') or i > 100;
  end loop;
  update pgpm_test389.regrain set last_status = v_status;
end $$;
select child_name as y2020 from pgpm.part
 where parent_table = 'public.oid389'::regclass and lo::timestamptz = '2020-01-01 00:00:00+00' \gset

-- the odd keys go in after the swap, through the parent, into the 2020 child that string order routes them to
insert into public.oid389 values
  (pgpm_test389.odd_after('2020-01-11 00:00:00+00'), 101),
  (pgpm_test389.odd_after('2020-01-14 00:00:00+00'), 102),
  (pgpm_test389.odd_after('2020-03-01 00:00:00+00'), 103);
-- about three rows a chunk
update pgpm.config set archive_byte_budget = (select (avg(pg_column_size(t.*)) * 3.5)::bigint from public.oid389 t)
 where parent_table = 'public.oid389'::regclass;

select ok((select last_status from pgpm_test389.regrain) like 'swapped:%'
          and (select hi::timestamptz from pgpm.part where parent_table = 'public.oid389'::regclass and child_name = :'y2020')
              = timestamptz '2021-01-01 00:00:00+00',
  'LIVENESS: the monolith regrained into year children, and the 2020 child is [2020, 2021), behind the horizon');
select is((select array_agg(t.v order by t.id collate "C")
             from public.oid389 t where t.tableoid = format('public.%I', :'y2020')::regclass
              and not pgpm._text_time_shaped(t.id, '', 8, 16)),
  array[101, 102, 103],
  'LIVENESS: the 2020 child holds the three keys that lack the declared shape');
select is((select array_agg(t.v order by t.id collate "C") from public.oid389 t
            where t.tableoid = format('public.%I', :'y2020')::regclass),
  array[1, 2, 101, 3, 4, 5, 102, 6, 7, 11, 12, 13, 14, 15, 103, 8, 9],
  'LIVENESS: in the column''s order each odd key sits where its chunk boundary falls');
select cmp_ok((select floor((select archive_byte_budget from pgpm.config where parent_table = 'public.oid389'::regclass)
                             / avg(pg_column_size(t.*)))::int from public.oid389 t), '=', 3,
  'LIVENESS: the byte budget holds three rows, so the windows end where the fixture put the odd keys');

-- the pipeline: up to twenty ticks, or until the 2020 child is retired
do $$ declare i int := 0; v_status text; begin
  while i < 20 and exists (select 1 from pgpm.part where parent_table = 'public.oid389'::regclass
                            and lo::timestamptz = '2020-01-01 00:00:00+00') loop
    call pgpm.maintain('public.oid389', v_status);
    i := i + 1;
  end loop;
end $$;

select ok(exists (select 1 from pgpm.archive_ledger where parent_table = 'public.oid389'::regclass and child_name = :'y2020')
          or exists (select 1 from pgpm.log where parent_table = 'public.oid389'::regclass and action = 'skip_archive'
                       and lo::timestamptz = '2020-01-01 00:00:00+00'),
  'LIVENESS: the archive step worked on the 2020 child (a chunk recorded or a skip logged for it)');
select is((select array_agg(distinct left(method, 120)) from pgpm.log
            where parent_table = 'public.oid389'::regclass and action = 'skip_archive'),
  null,
  'no tick skipped the archive step on a key it could not decode');
select is((select array_agg(format('[%s, %s) %s', to_char(lo::timestamptz, 'MM-DD'),
                                   to_char(hi::timestamptz, 'YYYY-MM-DD'), rows_archived) order by lo::timestamptz)
             from pgpm.archive_ledger where parent_table = 'public.oid389'::regclass and child_name = :'y2020'),
  array['[01-01, 2020-01-12) 3', '[01-12, 2020-01-15) 4', '[01-15, 2020-03-01) 2', '[03-01, 2020-03-05) 6',
        '[03-05, 2021-01-01) 2'],
  'each chunk ends at a key that has a native value, and each odd key travels inside the chunk whose bounds hold it');
select ok(exists (select 1 from pgpm.log where parent_table = 'public.oid389'::regclass and action = 'retain_drop'
                   and lo::timestamptz = '2020-01-01 00:00:00+00')
          and to_regclass(format('public.%I', :'y2020')) is null,
  'once covered, retire dropped the 2020 child');
select is((select array_agg(v order by v) from public.oid389), array[-9, -3],
  'what remains is the live marker and the frontier pin: the odd keys went with the child');

select * from finish();
