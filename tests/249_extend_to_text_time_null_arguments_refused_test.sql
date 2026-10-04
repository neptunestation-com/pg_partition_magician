-- extend_to, and transmute's uuidv7 and text_time arguments, refuse a null that has no null meaning, up
-- front, naming it (issue #896; transmute's other arguments are tests/248).
--
--   A. extend_to(p_max => null) made every cap test (`v_needed + v_edge > p_max`) null, so the dry count
--      neither exited nor refused, and a typo'd p_value was walked grid step by grid step under a FOR KEY
--      SHARE on the config row, where any non-null p_max refuses it at once. Its other two arguments had
--      no check either.
--   B. transmute(p_force_uuidv7 => null) skipped the uuidv7 plausibility refusal (`... and not
--      p_force_uuidv7` is null), so a column that samples as implausible was converted, as => true does.
--   C. transmute(p_tt_epoch => null) encoded every bound as the zero id, so phase 1 committed an
--      unsatisfiable CHECK (id >= 'c00000000' AND id < 'c00000000') on the live table and the table
--      rejected every write until an abort. p_force_text_time => null has p_force_uuidv7's shape, and
--      p_tt_discard_bits => null passed its `< 0` check.
--
-- INSTRUMENT, as tests/248: transmute's refused calls run through dblink, so a build that does not refuse
-- really commits its phases and the state assertions see the damage. extend_to is a function, so it runs
-- in place; its null-cap call is made against a value 2,000 steps out, which a build that walks it
-- leaves at its lock-budget refusal (a different message) in milliseconds rather than at a timeout. A null
-- p_value is worse on such a build: the walk's target is null, so it never ends, and it creates partitions
-- until the shared lock table is full ("out of shared memory", about 18 s here). A 5 s statement_timeout
-- ends it first; query_canceled escapes throws_like, so that build fails this file there.
--
-- WITNESSES. A: the same value with a number for p_max is refused by the dry count, and a near value is
-- extended, so the fixture is live in both directions. B: the default refuses this very column, and the
-- sampler reads it as implausible. C: the column decodes as well-formed cuid, and converts with the
-- default epoch. Every negative is paired with the condition its null would have exploited.
create extension if not exists pgtap;
create extension if not exists dblink;
set timezone = 'UTC';

select plan(25);

-- ======================= A. extend_to =======================
create table public.e_id (id bigint primary key);
insert into public.e_id values (1), (2);
call pgpm.transmute('public.e_id', 'id', 10::bigint, p_obtain => 2, p_paused => true);
create table e_parts as
  select string_agg('[' || lo || ',' || hi || ')', ' ' order by lo::numeric) as cells
    from pgpm.part where parent_table = 'public.e_id'::regclass and attached;

select throws_like($$ select pgpm.extend_to('public.e_id', '20000', 1000) $$,
  'pg_partition_magician: extend_to(e_id, 20000) would need more than 1000 new partitions%',
  'A WITNESS: with p_max => 1000 the far value is refused at once by the dry count');
set statement_timeout = '5s';
select throws_like($$ select pgpm.extend_to('public.e_id', '20000', null) $$,
  'pg_partition_magician: extend_to does not accept null for p_max: %',
  'A: p_max => null is refused, naming it, not read as no cap');
select throws_like($$ select pgpm.extend_to('public.e_id', null) $$,
  'pg_partition_magician: extend_to does not accept null for p_value: %',
  'A: a null p_value is refused, naming it');
reset statement_timeout;
select throws_like($$ select pgpm.extend_to(null, '25') $$,
  'pg_partition_magician: extend_to does not accept null for p_parent: %',
  'A: a null p_parent is refused, naming it');
select throws_like($$ select pgpm.extend_to(null, null, null) $$,
  'pg_partition_magician: extend_to does not accept null for p_parent, p_value, p_max: %',
  'A: three nulls are refused together, all named, in the signature''s order');
select is((select string_agg('[' || lo || ',' || hi || ')', ' ' order by lo::numeric) from pgpm.part
            where parent_table = 'public.e_id'::regclass and attached),
  (select cells from e_parts), 'A: no refused call changed e_id''s partitions');
select is((select cells from e_parts), '[0,10) [10,20) [20,30)',
  'A WITNESS: those are the monolith and the two forward cells the conversion built');

-- LIVENESS: a near value with a number for p_max is extended
select is(pgpm.extend_to('public.e_id', '45', 5), 2, 'A LIVENESS: extend_to(e_id, 45, 5) creates two partitions');
select is((select string_agg('[' || lo || ',' || hi || ')', ' ' order by lo::numeric) from pgpm.part
            where parent_table = 'public.e_id'::regclass and attached),
  '[0,10) [10,20) [20,30) [30,40) [40,50)', 'A LIVENESS: the grid now reaches the cell holding 45');

-- ======================= B. p_force_uuidv7 => null on a column that samples as implausible =======================
-- uuids whose leading 48 bits encode instants in 2001: they decode, far from now, and far from the
-- 48-bit ceiling the other uuidv7 refusal checks
create table public.u_uu (id uuid not null primary key);
insert into public.u_uu
  select (lpad(to_hex((extract(epoch from timestamptz '2001-01-01' + g * interval '1 hour') * 1000)::bigint), 12, '0')
          || '7000' || '8000' || lpad(to_hex(g), 12, '0'))::uuid
    from generate_series(1, 50) g;

select ok((select fraction from pgpm.check_uuidv7('public.u_uu', 'id', 1000)) < 0.5,
  'B WITNESS: u_uu samples as implausible (below the 0.5 floor)');
select throws_like(
  $$ select dblink_exec('dbname=' || current_database(),
       $c$ call pgpm.transmute('public.u_uu', 'id', interval '1 month') $c$) $$,
  'pg_partition_magician: only 0.0% of 50 sampled id values decode to plausible recent timestamps%',
  'B WITNESS: with the default p_force_uuidv7 (false) the conversion is refused for this column');
select throws_like(
  $$ select dblink_exec('dbname=' || current_database(),
       $c$ call pgpm.transmute('public.u_uu', 'id', interval '1 month', p_force_uuidv7 => null) $c$) $$,
  'pg_partition_magician: transmute does not accept null for p_force_uuidv7: %',
  'B: p_force_uuidv7 => null is refused, naming it, not read as true');
select ok(not exists (select 1 from pgpm.config where parent_table = 'public.u_uu'::regclass)
          and not exists (select 1 from pgpm.transmute_inflight where parent_table = 'public.u_uu'::regclass)
          and not exists (select 1 from pg_constraint where conrelid = 'public.u_uu'::regclass and conname = 'pgpm_monolith_bound'),
  'B: u_uu is not converted, claimed or bounded');

-- LIVENESS: => true overrides the refusal knowingly, which is what the null did
call pgpm.transmute('public.u_uu', 'id', interval '1 month', p_force_uuidv7 => true, p_obtain => 1);
select is((select control_kind from pgpm.config where parent_table = 'public.u_uu'::regclass), 'uuidv7',
  'B LIVENESS: p_force_uuidv7 => true converts u_uu on a uuidv7 grid');

-- ======================= C. the text_time arguments =======================
create table public.t_tt (id text collate "C" primary key, v int);
insert into public.t_tt
  select pgpm._ts_to_text_time(now() - i * interval '1 day', 'c', 8, 36, 'ms') || md5(i::text), i
    from generate_series(0, 300) i;

select is((select fraction from pgpm.check_text_time('public.t_tt', 'id', 'c', 8, 36, 'ms')), 1.0000::numeric,
  'C WITNESS: t_tt is well-formed cuid that decodes plausibly under the default epoch');
select throws_like(
  $$ select dblink_exec('dbname=' || current_database(),
       $c$ call pgpm.transmute('public.t_tt', 'id', interval '1 month',
                               p_tt_prefix => 'c', p_tt_width => 8, p_tt_radix => 36, p_tt_unit => 'ms',
                               p_tt_epoch => null, p_force_text_time => true) $c$) $$,
  'pg_partition_magician: transmute does not accept null for p_tt_epoch: %',
  'C: p_tt_epoch => null is refused, naming it');
select throws_like(
  $$ select dblink_exec('dbname=' || current_database(),
       $c$ call pgpm.transmute('public.t_tt', 'id', interval '1 month',
                               p_tt_prefix => 'c', p_tt_width => 8, p_tt_radix => 36, p_tt_unit => 'ms',
                               p_force_text_time => null) $c$) $$,
  'pg_partition_magician: transmute does not accept null for p_force_text_time: %',
  'C: p_force_text_time => null is refused, naming it');
select throws_like(
  $$ select dblink_exec('dbname=' || current_database(),
       $c$ call pgpm.transmute('public.t_tt', 'id', interval '1 month',
                               p_tt_prefix => 'c', p_tt_width => 8, p_tt_radix => 36, p_tt_unit => 'ms',
                               p_tt_discard_bits => null) $c$) $$,
  'pg_partition_magician: transmute does not accept null for p_tt_discard_bits: %',
  'C: p_tt_discard_bits => null is refused, naming it');
select ok(not exists (select 1 from pg_constraint where conrelid = 'public.t_tt'::regclass and conname = 'pgpm_monolith_bound')
          and not exists (select 1 from pgpm.transmute_inflight where parent_table = 'public.t_tt'::regclass)
          and not exists (select 1 from pgpm.config where parent_table = 'public.t_tt'::regclass),
  'C: no refused call left a bound, a claim or a registration on t_tt');
select lives_ok(
  format($$ insert into public.t_tt values (%L, -1) $$, pgpm._ts_to_text_time(now(), 'c', 8, 36, 'ms') || 'zzzz'),
  'C: t_tt still accepts a current write after the refused calls');
select is((select count(*)::int from public.t_tt where v = -1), 1, 'C: and holds it');

-- LIVENESS: converts with the default epoch, discard bits and p_force_text_time, the alphabet left null
call pgpm.transmute('public.t_tt', 'id', interval '1 month',
                    p_tt_prefix => 'c', p_tt_width => 8, p_tt_radix => 36, p_tt_unit => 'ms', p_obtain => 1);
select is((select relkind::text from pg_class where oid = 'public.t_tt'::regclass), 'p',
  'C LIVENESS: t_tt converts with every text_time argument set');
select is((select text_time_epoch = timestamptz '1970-01-01 00:00:00+00' and text_time_discard_bits = 0
                  and text_time_alphabet is null
             from pgpm.config where parent_table = 'public.t_tt'::regclass), true,
  'C LIVENESS: registered with the default epoch and discard bits, and the null (default) alphabet');
select lives_ok(
  format($$ insert into public.t_tt values (%L, -2) $$, pgpm._ts_to_text_time(now(), 'c', 8, 36, 'ms') || 'yyyy'),
  'C LIVENESS: the converted t_tt takes a current write');
select is((select count(*)::int from public.t_tt where v in (-1, -2)), 2,
  'C LIVENESS: and holds both current writes');

select * from finish();
