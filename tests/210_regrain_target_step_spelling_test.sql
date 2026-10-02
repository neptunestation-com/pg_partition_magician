-- Issue #784 (review pass 6, F3-02): a whole-number regrain target written with a fractional part
-- ('10.0', '5.000') is refused on an integer control column, at call time and at every other regrain
-- entry point, and the message names the spelling to use instead.
--
-- #641's rule in _regrain_step_shape tested the step's VALUE (p_step::numeric <> trunc(p_step::numeric)),
-- which '10.0' passes, while the grid's arithmetic carries the step's numeric SCALE into every bound it
-- renders: the fine cells of a '10.0' grid are bounded '0.0', '10.0', ..., which is invalid input for a
-- bigint, so set_regrain stored the target and every auto-regrain tick after the prepare failed creating
-- the first fine cell and logged skip_regrain, with the capture trigger left on the source: the wedge the
-- #641 rule exists to prevent. The rule is now about the text: on int2, int4 and int8 a step whose numeric
-- has any scale is refused ('10' is the spelling the grid can write), and numeric columns are untouched.
--
-- Every refusal is pinned to its message and paired with a liveness witness that the same entry point
-- accepts the canonical spelling on the same table; a refused call must leave the valid target in place;
-- the ticks are paired with the split they completed, by which cells exist and which rows sit in them.
-- The fixture is asymmetric: 47 rows in a [0, 60) monolith of a 20-wide grid, split into six 10-wide
-- cells holding 9, 10, 10, 10, 8 and 0 rows. bench/regrain_target_step_spelling.sh runs this file
-- against the mutant regrain_step_scale_on_integer.
create extension if not exists pgtap;
select plan(22);

-- ================================ a bigint grid with a frozen monolith ================================
create table public.fsc (id bigint primary key, payload text);
insert into public.fsc select g, 'orig' || g from generate_series(1, 47) g;
call pgpm.transmute('public.fsc', 'id', 20, p_paused => false);
insert into public.fsc values (190, 'frontier');
select pgpm.obtain('public.fsc');
select is((select lo || '-' || hi from pgpm.part where parent_table = 'public.fsc'::regclass and attached
            order by lo::numeric limit 1), '0-60',
  'LIVENESS: a frozen coarse monolith [0, 60) exists for auto-regrain to pick');
select is((select format_type(atttypid, atttypmod) from pg_attribute
            where attrelid = 'public.fsc'::regclass and attname = 'id'), 'bigint',
  'LIVENESS: the control column is bigint');

select lives_ok($$ select pgpm.set_regrain('public.fsc', '10') $$,
  'LIVENESS: set_regrain accepts the canonical spelling of a whole finer step (10)');
select throws_like($$ select pgpm.set_regrain('public.fsc', '10.0') $$,
  'pg_partition_magician: regrain target step 10.0 for fsc is a whole number written with a fractional part, but its control column id is int8%write it as 10%',
  'set_regrain refuses a whole step written with a fraction (10.0) on a bigint column, naming the spelling to use');
select throws_like($$ select pgpm.set_regrain('public.fsc', '5.000') $$,
  'pg_partition_magician: regrain target step 5.000 for fsc is a whole number written with a fractional part%write it as 5%',
  'set_regrain refuses 5.000 as well');
select throws_like($$ select pgpm.set_regrain('public.fsc', '2.5') $$,
  'pg_partition_magician: regrain target step 2.5 for fsc is not a whole number, but its control column id is int8%',
  'a step that is not whole keeps its own #641 refusal');
select is((select regrain_to from pgpm.config where parent_table = 'public.fsc'::regclass), '10',
  'the refused calls left the valid target in place');

-- the operator-driven entry points go through the same check
select throws_like($$ select pgpm.regrain_step('public.fsc', 'fsc_p0000000000000000000_to_0000000000000000060', '10.0') $$,
  'pg_partition_magician: regrain target step 10.0 for fsc is a whole number written with a fractional part%',
  'regrain_step refuses 10.0 before it reads or mutates anything');
create function pg_temp.try_regrain(p_parent regclass, p_child name, p_step text) returns text language plpgsql as $f$
begin
  return 'swapped:' || pgpm.regrain(p_parent, p_child, p_step);
exception when others then return 'refused: ' || sqlerrm;
end $f$;
select alike(pg_temp.try_regrain('public.fsc', 'fsc_p0000000000000000000_to_0000000000000000060', '10.0'),
  'refused: pg_partition_magician: regrain target step 10.0 for fsc is a whole number written with a fractional part%',
  'regrain() refuses it too');
select is((select count(*) from pgpm.part where parent_table = 'public.fsc'::regclass and not attached), 0::bigint,
  'the refusals minted no fine child');

-- a target an older install could have stored is refused at the tick, before anything is minted, with
-- the refusal's own words rather than the raw bigint input error
update pgpm.config set regrain_to = '10.0' where parent_table = 'public.fsc'::regclass;
set client_min_messages = warning;
call pgpm.maintain('public.fsc', null);
reset client_min_messages;
select ok(exists (select 1 from pgpm.log where parent_table = 'public.fsc'::regclass and action = 'skip_regrain'
                   and method like '%regrain target step 10.0 for fsc is a whole number written with a fractional part%'),
  'a stored 10.0 makes the tick log skip_regrain with the refusal (LIVENESS for the two below)');
select is((select count(*) from pgpm.log where parent_table = 'public.fsc'::regclass and action = 'skip_regrain'
            and method like '%invalid input syntax%'), 0::bigint,
  'and never the raw invalid-input error');
select is((select count(*) from pgpm.part where parent_table = 'public.fsc'::regclass and not attached), 0::bigint,
  'the refused tick minted no fine child');

-- the ticks, with the canonical target recorded: the split completes
delete from pgpm.log where parent_table = 'public.fsc'::regclass and action = 'skip_regrain';
select lives_ok($$ select pgpm.set_regrain('public.fsc', '10') $$, 'fixture: the canonical target again');
set client_min_messages = warning;
do $$ declare v text; begin
  for i in 1..60 loop
    call pgpm.maintain('public.fsc', v);
    exit when exists (select 1 from pgpm.log where parent_table = 'public.fsc'::regclass
                       and action = 'regrain' and method = 'copy_swap_drop');
  end loop;
end $$;
reset client_min_messages;
select ok(exists (select 1 from pgpm.log where parent_table = 'public.fsc'::regclass
                   and action = 'regrain' and method = 'copy_swap_drop'),
  'LIVENESS: auto-regrain completed the split of the monolith');
select is((select array_agg(lo || '-' || hi order by lo::numeric) from pgpm.part
            where parent_table = 'public.fsc'::regclass and attached and lo::numeric < 60),
          array['0-10', '10-20', '20-30', '30-40', '40-50', '50-60'],
  'the monolith became exactly the six 10-wide cells of [0, 60), every bound written as a bigint');
select is((select string_agg(id || ':' || payload, ',' order by id) from public.fsc where id < 60),
          (select string_agg(g || ':orig' || g, ',' order by g) from generate_series(1, 47) g),
  'every row of the monolith survived the split, each with its own payload');
select is((select string_agg(tableoid::regclass::text || '=' || n, ',' order by tableoid::regclass::text)
             from (select tableoid, count(*) n from public.fsc where id < 60 group by tableoid) s),
          'fsc_p0000000000000000000=9,fsc_p0000000000000000010=10,fsc_p0000000000000000020=10,'
          'fsc_p0000000000000000030=10,fsc_p0000000000000000040=8',
  'each row sits in the cell its key belongs to (9, 10, 10, 10, 8, and none past 47)');
select is((select count(*) from pgpm.log where parent_table = 'public.fsc'::regclass and action = 'skip_regrain'), 0::bigint,
  'no tick logged skip_regrain');

-- ===================== the rule is the column's: int2 and int4 refuse, numeric accepts =====================
create table public.fs2 (id smallint primary key, payload text);
insert into public.fs2 select g, 'x' from generate_series(1, 30) g;
call pgpm.transmute('public.fs2', 'id', 20, p_paused => false);
select throws_like($$ select pgpm.set_regrain('public.fs2', '10.0') $$,
  'pg_partition_magician: regrain target step 10.0 for fs2 is a whole number written with a fractional part, but its control column id is int2%',
  'set_regrain refuses 10.0 on an int2 column');

create table public.fs4 (id int primary key, payload text);
insert into public.fs4 select g, 'x' from generate_series(1, 30) g;
call pgpm.transmute('public.fs4', 'id', 20, p_paused => false);
select throws_like($$ select pgpm.set_regrain('public.fs4', '10.0') $$,
  'pg_partition_magician: regrain target step 10.0 for fs4 is a whole number written with a fractional part, but its control column id is int4%',
  'set_regrain refuses 10.0 on an int4 column');

create table public.fsn (id numeric primary key, payload text);
insert into public.fsn select g, 'x' from generate_series(1, 30) g;
call pgpm.transmute('public.fsn', 'id', 20, p_paused => false);
select lives_ok($$ select pgpm.set_regrain('public.fsn', '10.0') $$,
  'set_regrain accepts 10.0 on a numeric column, where 0.0 is a valid bound');

select * from finish();
