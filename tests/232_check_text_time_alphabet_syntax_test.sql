-- check_text_time reads the alphabet as data, never as regex syntax (issue #837).
--
-- check_text_time counts a sampled value implausible, without decoding it, when it does not have the
-- declared shape (the prefix, then p_width digits of the alphabet): "one bad row must not abort the
-- sample". It decided "every character is a digit of the alphabet" with the regex '[^' || alphabet || ']',
-- splicing the alphabet into a bracket expression raw, both for the sample and for the column's maximum.
-- An alphabet is data, and a bracket expression reads `-` between two characters as a range, `\` as an
-- escape and `^` or `]` as syntax. For '+-0123456789' (an alphabet transmute accepts: right length, no
-- repeats, ascending under "C") the class held `+ , - . / 0 ...`, so a value with `,` in its timestamp
-- field counted as shaped, reached _text_time_to_ts, raised 22P02, and aborted check_text_time and
-- transmute's sampling step with it (p_force_text_time cannot bypass a raise). For '0123456789\' the
-- bracket expression never closed and check_text_time raised on a column of nothing but good values.
-- The fix: both shape tests are pgpm._text_time_shaped, the translate()-based test #661 wrote for
-- exactly this reason, so the two cannot drift apart.
--
-- Fixtures are asymmetric (20 good, 1 malformed) so a count that dropped the good rows and kept the bad
-- one could not pass. The malformed row's shape is witnessed by _text_time_shaped itself, and a
-- control alphabet with no regex syntax in it (the default 0-9a-z one, radix 12) shows the same
-- malformed shape was already counted implausible there: the contract exists, and the alphabet's
-- characters are the only variable. bench/check_text_time_alphabet_syntax.sh runs this file against the
-- mutant check_text_time_alphabet_regex (the pre-fix regex), so it is also required to FAIL there.
create extension if not exists pgtap;
set client_min_messages = warning;
select plan(16);

-- ============================ a '-' between two characters of the alphabet ============================
create table public.tt232 (id text collate "C" primary key, body text);
insert into public.tt232
  select 'k' || pgpm._ts_to_text_time(now() - g * interval '1 hour', '', 14, 12, 'ms', '+-0123456789') || 'r' || g,
         'good' || g
    from generate_series(1, 20) g;
-- one malformed id: a good id of 10.5 hours ago with its last timestamp digit replaced by ',' (inside the
-- range "+-0" makes of '+', '-' and '0', not a digit of the alphabet), so it sorts between the good ids
-- of 10 and 11 hours ago. Neither the column's minimum nor its maximum on purpose: transmute decodes
-- those two outright, and a malformed one there is #709's subject, not this file's.
insert into public.tt232
  values ('k' || left(pgpm._ts_to_text_time(now() - interval '630 minutes', '', 14, 12, 'ms', '+-0123456789'), 13) || ',bad',
          'bad');

select ok(pgpm._text_time_shaped((select id from public.tt232 where body = 'good1'), 'k', 14, 12, '+-0123456789'),
  'LIVENESS: a good id has the declared shape (prefix k, 14 digits of +-0123456789)');
select ok(not pgpm._text_time_shaped((select id from public.tt232 where body = 'bad'), 'k', 14, 12, '+-0123456789'),
  'LIVENESS: the malformed id does not (its 14th timestamp character is a comma)');
select ok((select substr(id, 2, 14) ~ '[^+-0123456789]' = false from public.tt232 where body = 'bad'),
  'LIVENESS: the raw regex the alphabet used to be spliced into reads the comma as a digit (the range + through 0)');
select ok((select min(id) < (select id from public.tt232 where body = 'bad')
              and max(id) > (select id from public.tt232 where body = 'bad') from public.tt232),
  'LIVENESS: the malformed id is neither the column''s minimum nor its maximum');

create function pg_temp.ctt(p_table regclass, p_radix int, p_alphabet text) returns text language plpgsql as $f$
begin
  return (select array[sampled::text, plausible::text, coalesce(newest_decoded is not null, false)::text]::text
            from pgpm.check_text_time(p_table, 'id', 'k', 14, p_radix, 'ms', 1000, p_alphabet));
exception when others then
  return 'raised ' || sqlstate || ': ' || sqlerrm;
end $f$;

select is(pg_temp.ctt('public.tt232', 12, '+-0123456789'), '{21,20,true}',
  'check_text_time samples all 21 rows, counts the 20 good ones plausible and the malformed one not, and decodes the maximum');

-- control: the same malformed shape under an alphabet with no regex syntax in it
create table public.tt232c (id text collate "C" primary key, body text);
insert into public.tt232c
  select 'k' || pgpm._ts_to_text_time(now() - g * interval '1 hour', '', 14, 12, 'ms', null) || 'r' || g, 'good' || g
    from generate_series(1, 20) g;
insert into public.tt232c
  values ('k' || left(pgpm._ts_to_text_time(now() - interval '30 hours', '', 14, 12, 'ms', null), 13) || ',bad', 'bad');
select is(pg_temp.ctt('public.tt232c', 12, null), '{21,20,true}',
  'LIVENESS: under the default alphabet the same malformed row is counted implausible (the contract the regex broke)');

-- ============================ the maximum's shape test, the same splice ============================
-- the malformed value is the column's MAXIMUM here ('9' is the alphabet's highest digit, and every good
-- id of this century starts lower), so it is m_decoded's test that has to refuse to decode it
create table public.tt232m (id text collate "C" primary key, body text);
insert into public.tt232m
  select 'k' || pgpm._ts_to_text_time(now() - g * interval '1 hour', '', 14, 12, 'ms', '+-0123456789') || 'r' || g,
         'good' || g
    from generate_series(1, 4) g;
insert into public.tt232m values ('k9999999999999,bad', 'bad');
select is((select body from public.tt232m order by id desc limit 1), 'bad',
  'LIVENESS: the malformed id is the column''s maximum');
select is(pg_temp.ctt('public.tt232m', 12, '+-0123456789'), '{5,4,false}',
  'check_text_time counts the 4 good ids plausible and reports a malformed maximum as null instead of raising');

-- ============================ a backslash: the bracket expression never closed ============================
create table public.tt232b (id text collate "C" primary key, body text);
insert into public.tt232b
  select 'k' || pgpm._ts_to_text_time(now() - g * interval '1 hour', '', 14, 11, 'ms', E'0123456789\\') || 'r' || g,
         'good' || g
    from generate_series(1, 6) g;
insert into public.tt232b
  values ('k' || left(pgpm._ts_to_text_time(now() - interval '210 minutes', '', 14, 11, 'ms', E'0123456789\\'), 13) || ',bad',
          'bad');
select lives_ok($$ select pgpm._check_text_time_collation('public.tt232b', 'id', 'k', 14, 11, E'0123456789\\') $$,
  'LIVENESS: transmute''s collation check accepts the alphabet 0123456789\ on a "C" column');
select ok(pgpm._text_time_shaped((select id from public.tt232b where body = 'good1'), 'k', 14, 11, E'0123456789\\'),
  'LIVENESS: the good ids have the declared shape');
select is(pg_temp.ctt('public.tt232b', 11, E'0123456789\\'), '{7,6,true}',
  'check_text_time samples a column whose alphabet holds a backslash, 6 plausible and the malformed one not');

-- ============================ transmute's sampling step, which samples through check_text_time ============================
\set ON_ERROR_STOP 0
call pgpm.transmute('public.tt232', 'id', interval '1 month', p_obtain => 1,
  p_tt_prefix => 'k', p_tt_width => 14, p_tt_radix => 12, p_tt_unit => 'ms', p_tt_alphabet => '+-0123456789');
\set ON_ERROR_STOP 1
select is((select relkind::text from pg_class where oid = 'public.tt232'::regclass), 'p',
  'transmute converts the table: its sampling step counts the malformed row implausible instead of aborting');
select is((select array_agg(body order by body) from public.tt232),
  (select array_agg(b order by b) from (select 'good' || g as b from generate_series(1, 20) g union all select 'bad') x),
  'every row, the malformed one included, is still in tt232 after the conversion');
select ok((select count(*) from pgpm.part where parent_table = 'public.tt232'::regclass and attached) >= 1,
  'pgpm recorded tt232''s partitions');

-- and the alphabet whose bracket expression never closed
\set ON_ERROR_STOP 0
call pgpm.transmute('public.tt232b', 'id', interval '1 month', p_obtain => 1,
  p_tt_prefix => 'k', p_tt_width => 14, p_tt_radix => 11, p_tt_unit => 'ms', p_tt_alphabet => E'0123456789\\');
\set ON_ERROR_STOP 1
select is((select relkind::text from pg_class where oid = 'public.tt232b'::regclass), 'p',
  'transmute converts the table whose alphabet holds a backslash');
select is((select array_agg(body order by body) from public.tt232b),
  array['bad', 'good1', 'good2', 'good3', 'good4', 'good5', 'good6'],
  'every row of tt232b is still there after the conversion');

select * from finish();
