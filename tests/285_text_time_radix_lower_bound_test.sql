-- Issue #990: a supplied p_tt_alphabet still needs a radix of at least 2.
--
-- The radix check had a range (2-36) only for the default alphabet; a supplied one was checked for length
-- (= the radix) and repeats, nothing else. So p_tt_radix => 1 with p_tt_alphabet => 'x' passed transmute's
-- preflight, and _radix_encode's loop (v := div(v, 1), which is v) never ended: transmute, forced past the
-- shape sample, spun at the frontier encode until statement_timeout instead of refusing. A radix 0 with an
-- empty alphabet passed the same way. transmute now refuses any radix below 2, before anything is touched.
--
-- statement_timeout is set around every call that a defective preflight would let reach the encoder, so a
-- regression fails this file in seconds instead of hanging the suite. pgTAP's throws_* do not catch the
-- cancel (query_canceled is outside OTHERS), which would end the file at the first one, so each call runs
-- through _attempt, which reports a cancel as a result an assertion can name.
create extension if not exists pgtap;

select plan(6);

-- cuid-shaped values in a one-character alphabet: 'c', eight 'x', then a counter. Twenty rows.
create table public.one_char (id text collate "C" primary key, v int);
insert into public.one_char select 'c' || repeat('x', 8) || lpad(i::text, 6, '0'), i from generate_series(1, 20) i;

-- 1: LIVENESS. Everything about this shape other than its radix is accepted: check_text_time, the
-- read-only diagnostic, decodes every sampled row with it. So a refusal below is the radix's.
select is(
  (select sampled from pgpm.check_text_time('public.one_char', 'id', 'c', 8, 1, 'ms', 1000, 'x')),
  20::bigint,
  'check_text_time samples all twenty rows under radix 1 with alphabet ''x'''
);

-- The error a statement raised, its SQLSTATE first; 'completed' if it raised none.
create function pg_temp._attempt(p_sql text) returns text language plpgsql as $f$
begin
  execute p_sql;
  return 'completed';
exception
  when query_canceled then return sqlstate || ' ' || sqlerrm;
  when others then return sqlstate || ' ' || sqlerrm;
end;
$f$;

set statement_timeout = '10s';

-- 2-3: the refusals, pinned to their SQLSTATE and message (a transmute that did not refuse would spin into
-- the timeout, 57014, or die at its first COMMIT inside the function with 2D000; neither matches).
select alike(
  pg_temp._attempt($$ call pgpm.transmute('public.one_char', 'id', interval '1 month',
       p_tt_prefix => 'c', p_tt_width => 8, p_tt_radix => 1, p_tt_unit => 'ms', p_tt_alphabet => 'x',
       p_force_text_time => true) $$),
  'P0001 pg_partition_magician: p_tt_radix must be at least 2 (got 1)%',
  'transmute refuses radix 1 with a supplied one-character alphabet, promptly'
);

select alike(
  pg_temp._attempt($$ call pgpm.transmute('public.one_char', 'id', interval '1 month',
       p_tt_prefix => 'c', p_tt_width => 8, p_tt_radix => 0, p_tt_unit => 'ms', p_tt_alphabet => '',
       p_force_text_time => true) $$),
  'P0001 pg_partition_magician: p_tt_radix must be at least 2 (got 0)%',
  'transmute refuses radix 0 with a supplied empty alphabet'
);

reset statement_timeout;

-- 4: the refusals touched nothing: a plain, unmanaged table with its twenty rows.
select results_eq(
  $$ select (select c.relkind::text from pg_class c where c.oid = 'public.one_char'::regclass),
            (select count(*) from pgpm.config where parent_table = 'public.one_char'::regclass)::int,
            (select count(*) from public.one_char)::int $$,
  $$ values ('r', 0, 20) $$,
  'the refused transmutes left public.one_char a plain, unmanaged table holding its twenty rows'
);

-- 5-6: the lower bound is 2, not "the default alphabet only": a supplied two-character alphabet converts.
-- Milliseconds in binary (42 digits) behind a 'b' prefix, three rows.
create table public.two_char (id text collate "C" primary key, v int);
insert into public.two_char
  select pgpm._ts_to_text_time(t, 'b', 42, 2, 'ms', 'ab') || 'zz', 3
    from generate_series(now() - interval '60 days', now(), interval '30 days') t;

set statement_timeout = '60s';
call pgpm.transmute('public.two_char', 'id', interval '1 month', p_obtain => 2,
  p_tt_prefix => 'b', p_tt_width => 42, p_tt_radix => 2, p_tt_unit => 'ms', p_tt_alphabet => 'ab');
reset statement_timeout;

select results_eq(
  $$ select (select c.relkind::text from pg_class c where c.oid = 'public.two_char'::regclass),
            (select count(*) from public.two_char)::int $$,
  $$ values ('p', 3) $$,
  'transmute converts public.two_char under a supplied radix-2 alphabet, its three rows kept'
);
select results_eq(
  $$ select text_time_radix, text_time_alphabet from pgpm.config where parent_table = 'public.two_char'::regclass $$,
  $$ values (2, 'ab') $$,
  'public.two_char is managed with radix 2 and the alphabet ''ab'''
);

select * from finish();
