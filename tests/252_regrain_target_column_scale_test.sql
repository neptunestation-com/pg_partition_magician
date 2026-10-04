-- Issue #899 (review pass 8, F3-05): a regrain target step finer than the control column's declared scale
-- is refused at call time and at every other regrain entry point, as a fractional step on a bigint key is.
--
-- _regrain_step_shape refused a non-integral step only when the column's TYPE NAME was int2, int4 or int8
-- (#641). A numeric(12,0) key holds whole numbers just the same, but its type name is 'numeric', so
-- set_regrain stored '0.5', the run copied every sub-range, and at the swap ATTACH PARTITION coerced each
-- fine bound to the key's typmod ('0.5' and '1.0' both to 1) and failed 'empty range bound' on every tick,
-- with the capture trigger and the TRUNCATE refusal left on the source until the operator cancelled. The
-- rule is now the column's effective scale: numeric(p,0) holds whole numbers, numeric(p,1) tenths, and a
-- domain is judged by its base type and the typmod it carries.
--
-- Every refusal is pinned to its message and paired with a liveness witness that the same entry point
-- accepts a step the column can hold on the same table; a refused call must leave the valid target in
-- place; the completed splits are checked by which cells exist and which rows sit in them. Fixtures are
-- asymmetric: 47 whole rows in a [0, 60) numeric(12,0) monolith split into cells of 9, 10, 10, 10, 8 and
-- 0 rows; 9 half-step rows in a [0, 6) numeric(12,1) monolith, the last half-cell empty.
-- bench/regrain_target_column_scale.sh runs this file against the mutants regrain_step_scale_by_typname
-- and regrain_step_shape_domain_blind.
create extension if not exists pgtap;
select plan(27);

-- ============================ a numeric(12,0) grid with a frozen monolith ============================
create table public.wn (id numeric(12, 0) primary key, payload text);
insert into public.wn select g, 'orig' || g from generate_series(1, 47) g;
call pgpm.transmute('public.wn', 'id', 20, p_paused => false);
insert into public.wn values (190, 'frontier');
select pgpm.obtain('public.wn');
select is((select lo || '-' || hi from pgpm.part where parent_table = 'public.wn'::regclass and attached
            order by lo::numeric limit 1), '0-60',
  'LIVENESS: a frozen coarse monolith [0, 60) exists for auto-regrain to pick');
select is((select format_type(atttypid, atttypmod) from pg_attribute
            where attrelid = 'public.wn'::regclass and attname = 'id'), 'numeric(12,0)',
  'LIVENESS: the control column is numeric(12,0), whose type name is numeric');

select lives_ok($$ select pgpm.set_regrain('public.wn', '10') $$,
  'LIVENESS: set_regrain accepts a whole finer step (10) on the numeric(12,0) column');
select throws_like($$ select pgpm.set_regrain('public.wn', '0.5') $$,
  'pg_partition_magician: regrain target step 0.5 for wn is finer than its control column id can hold: it is numeric(12,0), which keeps whole numbers only%multiple of 1',
  'set_regrain refuses a fractional step (0.5) on a numeric(12,0) column, naming the column''s scale');
select throws_like($$ select pgpm.set_regrain('public.wn', '2.5') $$,
  'pg_partition_magician: regrain target step 2.5 for wn is finer than its control column id can hold%',
  'set_regrain refuses 2.5 as well');
select is((select regrain_to from pgpm.config where parent_table = 'public.wn'::regclass), '10',
  'the refused calls left the valid target in place');

-- the operator-driven entry points go through the same check
select throws_like($$ select pgpm.regrain_step('public.wn', 'wn_p0000000000000000000_to_0000000000000000060', '0.5') $$,
  'pg_partition_magician: regrain target step 0.5 for wn is finer than its control column id can hold%',
  'regrain_step refuses 0.5 before it reads or mutates anything');
create function pg_temp.try_regrain(p_parent regclass, p_child name, p_step text) returns text language plpgsql as $f$
begin
  return 'swapped:' || pgpm.regrain(p_parent, p_child, p_step);
exception when others then return 'refused: ' || sqlerrm;
end $f$;
select alike(pg_temp.try_regrain('public.wn', 'wn_p0000000000000000000_to_0000000000000000060', '0.5'),
  'refused: pg_partition_magician: regrain target step 0.5 for wn is finer than its control column id can hold%',
  'regrain() refuses it too');
select is((select count(*) from pgpm.part where parent_table = 'public.wn'::regclass and not attached), 0::bigint,
  'the refusals minted no fine child');

-- a target an older install could have stored is refused at the tick, before anything is copied, with the
-- refusal's own words rather than the swap's 'empty range bound'
update pgpm.config set regrain_to = '0.5' where parent_table = 'public.wn'::regclass;
set client_min_messages = warning;
call pgpm.maintain('public.wn', null);
reset client_min_messages;
select ok(exists (select 1 from pgpm.log where parent_table = 'public.wn'::regclass and action = 'skip_regrain'
                   and method like '%regrain target step 0.5 for wn is finer than its control column id can hold%'),
  'a stored 0.5 makes the tick log skip_regrain with the refusal (LIVENESS for the three below)');
select is((select count(*) from pgpm.log where parent_table = 'public.wn'::regclass and action = 'skip_regrain'
            and method like '%empty range bound%'), 0::bigint,
  'and never the swap''s empty range bound');
select is((select count(*) from pgpm.part where parent_table = 'public.wn'::regclass and not attached), 0::bigint,
  'the refused tick minted no fine child');
select is((select count(*) from pg_trigger
            where tgrelid = 'public.wn_p0000000000000000000_to_0000000000000000060'::regclass
              and tgname in ('pgpm_regrain_capture', 'pgpm_regrain_truncate_guard')), 0::bigint,
  'and left neither the capture trigger nor the TRUNCATE refusal on the source');

-- the ticks, with a whole target recorded: the split completes
delete from pgpm.log where parent_table = 'public.wn'::regclass and action = 'skip_regrain';
select lives_ok($$ select pgpm.set_regrain('public.wn', '10') $$, 'fixture: the whole target again');
set client_min_messages = warning;
do $$ declare v text; begin
  for i in 1..60 loop
    call pgpm.maintain('public.wn', v);
    exit when exists (select 1 from pgpm.log where parent_table = 'public.wn'::regclass
                       and action = 'regrain' and method = 'copy_swap_drop');
  end loop;
end $$;
reset client_min_messages;
select ok(exists (select 1 from pgpm.log where parent_table = 'public.wn'::regclass
                   and action = 'regrain' and method = 'copy_swap_drop'),
  'LIVENESS: auto-regrain completed the split of the numeric(12,0) monolith');
select is((select array_agg(lo || '-' || hi order by lo::numeric) from pgpm.part
            where parent_table = 'public.wn'::regclass and attached and lo::numeric < 60),
          array['0-10', '10-20', '20-30', '30-40', '40-50', '50-60'],
  'the monolith became exactly the six 10-wide cells of [0, 60)');
select is((select string_agg(tableoid::regclass::text || '=' || n, ',' order by tableoid::regclass::text)
             from (select tableoid, count(*) n from public.wn where id < 60 group by tableoid) s),
          'wn_p0000000000000000000=9,wn_p0000000000000000010=10,wn_p0000000000000000020=10,'
          'wn_p0000000000000000030=10,wn_p0000000000000000040=8',
  'each row sits in the cell its key belongs to (9, 10, 10, 10, 8, and none past 47)');
select is((select count(*) from pgpm.log where parent_table = 'public.wn'::regclass and action = 'skip_regrain'), 0::bigint,
  'no tick logged skip_regrain');

-- ============ numeric(12,1): tenths are held, so 0.5 is accepted and completes, 0.05 is not ============
create table public.tn (id numeric(12, 1) primary key, payload text);
insert into public.tn select g / 2.0, 'half' || g from generate_series(1, 9) g;
call pgpm.transmute('public.tn', 'id', 2, p_paused => false);
insert into public.tn values (19, 'frontier');
select pgpm.obtain('public.tn');
select throws_like($$ select pgpm.set_regrain('public.tn', '0.05') $$,
  'pg_partition_magician: regrain target step 0.05 for tn is finer than its control column id can hold: it is numeric(12,1), which keeps 1 decimal place(s)%multiple of 0.1',
  'set_regrain refuses 0.05 on a numeric(12,1) column');
select lives_ok($$ select pgpm.set_regrain('public.tn', '0.5') $$,
  'and accepts 0.5, which the column can hold');
set client_min_messages = warning;
do $$ declare v text; begin
  for i in 1..60 loop
    call pgpm.maintain('public.tn', v);
    exit when exists (select 1 from pgpm.log where parent_table = 'public.tn'::regclass
                       and action = 'regrain' and method = 'copy_swap_drop');
  end loop;
end $$;
reset client_min_messages;
select is((select array_agg(lo || '-' || hi order by lo::numeric) from pgpm.part
            where parent_table = 'public.tn'::regclass and attached and lo::numeric < 6),
          array['0.0-0.5', '0.5-1.0', '1.0-1.5', '1.5-2.0', '2.0-2.5', '2.5-3.0',
                '3.0-3.5', '3.5-4.0', '4.0-4.5', '4.5-5.0', '5.0-5.5', '5.5-6.0'],
  'the 0.5 regrain of the [0, 6) monolith completed into its twelve half-cells');
select is((select string_agg(tableoid::regclass::text || '=' || id || ':' || payload, ',' order by id)
             from public.tn where id < 6),
          (select string_agg(format('tn_p%s=%s:half%s',
                                    lpad(trunc(g / 2.0)::text, 19, '0') || case when g % 2 = 1 then '_5' else '' end,
                                    round(g / 2.0, 1), g), ',' order by g)
             from generate_series(1, 9) g),
  'every half-step row survived, each in its own half-cell with its own payload');

-- ===== a domain is judged by what it stores: its base type and typmod, through a domain over a domain =====
-- No entry point registers a domain-typed key today (transmute refuses one), so these parents are
-- registered by hand: the rule must not depend on that refusal staying where it is.
create domain public.wn_dom as numeric(12, 0);
create domain public.wn_dom2 as public.wn_dom;
create table public.dwn (id public.wn_dom2 not null) partition by range (id);
create domain public.big_dom as bigint;
create table public.dbg (id public.big_dom not null) partition by range (id);
insert into pgpm.config (parent_table, control_column, control_kind, partition_step, partition_anchor)
  values ('public.dwn', 'id', 'id', '20', '0'), ('public.dbg', 'id', 'id', '20', '0');
select lives_ok($$ select pgpm.set_regrain('public.dwn', '10') $$,
  'LIVENESS: set_regrain accepts a whole step on a domain over a domain over numeric(12,0)');
select throws_like($$ select pgpm.set_regrain('public.dwn', '0.5') $$,
  'pg_partition_magician: regrain target step 0.5 for dwn is finer than its control column id can hold: it is numeric(12,0), which keeps whole numbers only%',
  'and refuses 0.5 there, reading the scale through both domains');
select lives_ok($$ select pgpm.set_regrain('public.dbg', '10') $$,
  'LIVENESS: set_regrain accepts a whole step on a domain over bigint');
select throws_like($$ select pgpm.set_regrain('public.dbg', '2.5') $$,
  'pg_partition_magician: regrain target step 2.5 for dbg is not a whole number, but its control column id is int8%',
  'and refuses 2.5 there with the integer rule (#641)');
select throws_like($$ select pgpm.set_regrain('public.dbg', '10.0') $$,
  'pg_partition_magician: regrain target step 10.0 for dbg is a whole number written with a fractional part, but its control column id is int8%',
  'and 10.0 with the spelling rule (#784)');

select * from finish();
