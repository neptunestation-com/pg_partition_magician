-- An ICU collation with numeric ordering (locale 'und-u-kn-true', a stock PostgreSQL feature and a
-- possible database default on 15+) compares a RUN of decimal digits by its numeric value, so
-- 'ck9abcde' sorts before 'ck10000' although bytewise, and in base-36 place value, it sorts after. The
-- text_time bounds are ordered by place value, and a RANGE partition on a text column compares under
-- the column's collation, so under such a collation cuid rows are routed to the wrong month: late
-- November rows land in the December partition (and retain drops them a month early) and some February
-- rows are rejected with "no partition found" (issue #568). _check_text_time_collation used to probe only
-- adjacent digit pairs padded as '<d>zzz...' < '<d+1>000...', which a numeric ordering satisfies (1 is
-- less than 2000...), so the column was accepted. It now also probes the opposite padding
-- ('<d>000...' < '<d+1>zzz...') and a lower cell's string extended by a suffix character against the
-- next cell's bound, and refuses the collation on any of them.
--
-- Every refusal here is paired with a witness that the condition it denies was present: the collation
-- really orders the two literal cuid fragments against bytewise order, and each refused fixture really
-- contains rows that sort outside their own month's bounds under it. The positive controls (the same
-- rows on collate "C", a cuid column on en_US.utf8, and on ICU without numeric ordering) show the new
-- probes do not refuse the collations the documented alphabets rely on.
-- bench/text_time_numeric_collation.sh runs this file against a mutant that removes the two new probe
-- shapes, and requires it to fail there.
create extension if not exists pgtap;
set timezone = 'UTC';

select plan(17);

create collation if not exists public.tt_num (provider = icu, locale = 'und-u-kn-true');
create collation if not exists public.tt_icu (provider = icu, locale = 'und');

-- ---------------------------------------------------------------------------------------- witnesses
select ok(
  ('ck9abcde' collate public.tt_num) < ('ck10000' collate public.tt_num)
  and not (('ck9abcde' collate "C") < ('ck10000' collate "C")),
  'witness: the numeric collation orders cuid fragments against bytewise order (digit runs by value)'
);

-- cuid (prefix 'c', 8 base-36 digits of epoch ms) with an asymmetric, distinct suffix per row. 1700 rows
-- every 6 hours over the last 14 months, which crosses several points where a digit run changes length.
create table public.tt_cuid_num (id text collate public.tt_num primary key, body text);
insert into public.tt_cuid_num (id, body)
select pgpm._ts_to_text_time(now() - interval '14 months' + g * interval '6 hours', 'c', 8, 36, 'ms')
         || 'x' || lpad(g::text, 7, '0'), 'r' || g
  from generate_series(1, 1700) g;

-- rows that sort OUTSIDE their own month's [lo, hi) under the column's collation: the defect itself
create function public.cuid_misordered(p_id text) returns boolean language sql stable as $$
  select not ((p_id collate public.tt_num) >= (pgpm._ts_to_text_time(m, 'c', 8, 36, 'ms') collate public.tt_num)
          and (p_id collate public.tt_num) <  (pgpm._ts_to_text_time(m + interval '1 month', 'c', 8, 36, 'ms') collate public.tt_num))
    from (select date_trunc('month', pgpm._text_time_to_ts(p_id, 'c', 8, 36, 'ms')) as m) x
$$;
select cmp_ok(
  (select count(*) from public.tt_cuid_num where public.cuid_misordered(id)), '>', 0::bigint,
  'witness: the cuid fixture contains rows that sort outside their own month under the numeric collation'
);

-- ------------------------------------------------------------------ refusal of a cuid column under it
select throws_like(
  $$ call pgpm.transmute('public.tt_cuid_num', 'id', interval '1 month',
       p_tt_prefix => 'c', p_tt_width => 8, p_tt_radix => 36, p_tt_unit => 'ms') $$,
  $p$pg_partition_magician: column %tt_cuid_num.id has collation tt_num%digit '1' (value 1)%digit '2' (value 2)%alter table %tt_cuid_num alter column id type text collate "C"%$p$,
  'transmute refuses a cuid column on a numeric-ordering ICU collation, naming the collation, a misordered digit pair and the collate "C" remedy'
);
select throws_like(
  $$ call pgpm.transmute('public.tt_cuid_num', 'id', interval '1 month',
       p_tt_prefix => 'c', p_tt_width => 8, p_tt_radix => 36, p_tt_unit => 'ms', p_force_text_time => true) $$,
  'pg_partition_magician: column %tt_cuid_num.id has collation tt_num%collate "C"%',
  'p_force_text_time does not bypass the numeric-collation refusal'
);
select is(
  (select relkind::text from pg_class where oid = 'public.tt_cuid_num'::regclass),
  'r', 'the refused table is left untouched (still a plain table)'
);
select is(
  (select count(*) from pgpm.config where parent_table = 'public.tt_cuid_num'::regclass),
  0::bigint, 'the refused table was never registered'
);
select throws_like(
  $$ select * from pgpm.check_text_time('public.tt_cuid_num', 'id', 'c', 8, 36, 'ms', 1000) $$,
  $p$pg_partition_magician: column %tt_cuid_num.id has collation tt_num%digit '1' (value 1)%digit '2' (value 2)%collate "C"%$p$,
  'check_text_time reports the same refusal instead of a plausible fraction'
);

-- ------------------------------------------ refusal of a decimal alphabet: the suffix extends the run
-- With a pure-decimal alphabet both paddings are digits, so the two padded probes agree with place
-- value; what breaks is a value's own suffix. A row's timestamp digits followed by its digit suffix
-- are one run, numerically larger than any bound, so every row sorts after the next month's bound.
create table public.tt_dec_num (id text collate public.tt_num primary key, body text);
insert into public.tt_dec_num (id, body)
select pgpm._ts_to_text_time(now() - interval '100 days' + g * interval '1 day', '', 13, 10, 'ms')
         || lpad(g::text, 4, '0'), 'd' || g
  from generate_series(1, 90) g;
select cmp_ok(
  (select count(*) from public.tt_dec_num t
    where (t.id collate public.tt_num)
       >= (pgpm._ts_to_text_time(date_trunc('month', pgpm._text_time_to_ts(t.id, '', 13, 10, 'ms')) + interval '1 month',
                                 '', 13, 10, 'ms') collate public.tt_num)),
  '>', 0::bigint,
  'witness: decimal rows with a digit suffix sort at or after the NEXT month''s bound under the numeric collation'
);
select throws_like(
  $$ select * from pgpm.check_text_time('public.tt_dec_num', 'id', '', 13, 10, 'ms', 1000) $$,
  $p$pg_partition_magician: column %tt_dec_num.id has collation tt_num%digit '0' (value 0)%digit '1' (value 1)%collate "C"%$p$,
  'a decimal text_time column under the numeric collation is refused too'
);

-- ------------------------------------------------ positive controls: collations the probes must accept
-- The same rows on collate "C": no row sorts outside its month there, and the conversion succeeds with
-- every id kept, by identity.
create table public.tt_cuid_c (id text collate "C" primary key, body text);
insert into public.tt_cuid_c select id, body from public.tt_cuid_num;
select is(
  (select count(*) from public.tt_cuid_c c
    where not ((c.id collate "C") >= pgpm._ts_to_text_time(date_trunc('month', pgpm._text_time_to_ts(c.id, 'c', 8, 36, 'ms')), 'c', 8, 36, 'ms')
           and (c.id collate "C") <  pgpm._ts_to_text_time(date_trunc('month', pgpm._text_time_to_ts(c.id, 'c', 8, 36, 'ms')) + interval '1 month', 'c', 8, 36, 'ms'))),
  0::bigint, 'collate "C": every fixture row sorts inside its own month'
);
call pgpm.transmute('public.tt_cuid_c', 'id', interval '1 month', p_obtain => 2,
  p_tt_prefix => 'c', p_tt_width => 8, p_tt_radix => 36, p_tt_unit => 'ms');
select is(
  (select relkind::text from pg_class where oid = 'public.tt_cuid_c'::regclass),
  'p', 'collate "C": the same cuid rows convert'
);
select is(
  (select array_agg(id order by id collate "C") from public.tt_cuid_c),
  (select array_agg(id order by id collate "C") from public.tt_cuid_num),
  'collate "C": every id survived the conversion, by identity'
);

-- cuid is single-case, so en_US.utf8 and ICU without numeric ordering order it the way place value does;
-- the new probes must not refuse either (the guide says single-case alphabets need nothing there).
create table public.tt_cuid_en (id text collate "en_US.utf8" primary key, body text);
insert into public.tt_cuid_en select id, body from public.tt_cuid_num;
create table public.tt_cuid_icu (id text collate public.tt_icu primary key, body text);
insert into public.tt_cuid_icu select id, body from public.tt_cuid_num;
select is(
  (select count(*) from public.tt_cuid_icu c
    where not ((c.id collate public.tt_icu) >= (pgpm._ts_to_text_time(date_trunc('month', pgpm._text_time_to_ts(c.id, 'c', 8, 36, 'ms')), 'c', 8, 36, 'ms') collate public.tt_icu)
           and (c.id collate public.tt_icu) <  (pgpm._ts_to_text_time(date_trunc('month', pgpm._text_time_to_ts(c.id, 'c', 8, 36, 'ms')) + interval '1 month', 'c', 8, 36, 'ms') collate public.tt_icu))),
  0::bigint, 'witness: under ICU und (no numeric ordering) every fixture row sorts inside its own month'
);
select cmp_ok(
  (select fraction from pgpm.check_text_time('public.tt_cuid_en', 'id', 'c', 8, 36, 'ms', 1000)),
  '>=', 0.95::numeric, 'cuid on en_US.utf8: check_text_time samples it as plausible rather than refusing'
);
select cmp_ok(
  (select fraction from pgpm.check_text_time('public.tt_cuid_icu', 'id', 'c', 8, 36, 'ms', 1000)),
  '>=', 0.95::numeric, 'cuid on ICU und: check_text_time samples it as plausible rather than refusing'
);
call pgpm.transmute('public.tt_cuid_icu', 'id', interval '1 month', p_obtain => 2,
  p_tt_prefix => 'c', p_tt_width => 8, p_tt_radix => 36, p_tt_unit => 'ms');
select is(
  (select relkind::text from pg_class where oid = 'public.tt_cuid_icu'::regclass),
  'p', 'cuid on ICU und: converts (the VALIDATE scan passes)'
);
select is(
  (select array_agg(id order by id collate "C") from public.tt_cuid_icu),
  (select array_agg(id order by id collate "C") from public.tt_cuid_num),
  'cuid on ICU und: every id survived the conversion, by identity'
);

select * from finish();
