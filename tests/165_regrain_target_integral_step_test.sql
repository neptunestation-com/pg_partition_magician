-- Issue #641 (first bullet, reproduced in review pass 4 as F3-04): set_regrain refuses a fractional target
-- step on an integer control column, at call time and at every other regrain entry point.
--
-- #582 made fractional id labels distinct, so a numeric key can regrain toward '0.5'. Nothing checked that
-- the column could hold such a bound: on a bigint column set_regrain('2.5') passed the #588 forward test,
-- the #341 width comparison and the #510 name check, and every maintain tick after the prepare failed
-- creating the first fine child (invalid input syntax for type bigint: "0.0") and logged skip_regrain,
-- with the capture trigger left taxing every write into the source. transmute's id step is a bigint by
-- signature, so an integer grid can only have been built with a whole step; _regrain_step_shape holds a
-- regrain target to the same rule on int2, int4 and int8 columns, and leaves numeric alone.
--
-- Every refusal is pinned to its message and paired with a liveness witness that the same entry point
-- accepts a whole step on the same table (and a fractional one on a numeric column); a refused call must
-- leave a VALID target in place, not null; and the ticks at the end are paired with the split they
-- completed, by which cells exist and which rows sit in them. bench/regrain_target_integral.sh runs this
-- file against the mutant regrain_step_fraction_on_integer.
create extension if not exists pgtap;
select plan(18);

-- ================================ a bigint grid with a frozen monolith ================================
create table public.fib (id bigint primary key, payload text);
insert into public.fib select g, 'orig' || g from generate_series(1, 30) g;
call pgpm.transmute('public.fib', 'id', 10, p_paused => false);
insert into public.fib values (95, 'frontier');
select pgpm.obtain('public.fib');
select is((select lo || '-' || hi from pgpm.part where parent_table = 'public.fib'::regclass and attached
            order by lo::numeric limit 1), '0-40',
  'LIVENESS: a frozen coarse monolith [0, 40) exists for auto-regrain to pick');
select is((select format_type(atttypid, atttypmod) from pg_attribute
            where attrelid = 'public.fib'::regclass and attname = 'id'), 'bigint',
  'LIVENESS: the control column is bigint');

select lives_ok($$ select pgpm.set_regrain('public.fib', '5') $$,
  'LIVENESS: set_regrain accepts a whole finer step (5)');
select throws_like($$ select pgpm.set_regrain('public.fib', '2.5') $$,
  'pg_partition_magician: regrain target step 2.5 for fib is not a whole number, but its control column id is int8%',
  'set_regrain refuses a fractional step on a bigint column');
select throws_like($$ select pgpm.set_regrain('public.fib', '0.5') $$,
  'pg_partition_magician: regrain target step 0.5 for fib is not a whole number, but its control column id is int8%',
  'set_regrain refuses a fractional step below one');
select is((select regrain_to from pgpm.config where parent_table = 'public.fib'::regclass), '5',
  'the refused calls left the valid target in place');
select lives_ok($$ select pgpm.set_regrain('public.fib', '5.000') $$,
  'LIVENESS: a whole step written with a zero fraction is a whole number, and is accepted');

-- the operator-driven entry points go through the same check
select throws_like($$ select pgpm.regrain_step('public.fib', 'fib_p0000000000000000000_to_0000000000000000040', '2.5') $$,
  'pg_partition_magician: regrain target step 2.5 for fib is not a whole number%',
  'regrain_step refuses the fractional step before it reads or mutates anything');
create function pg_temp.try_regrain(p_parent regclass, p_child name, p_step text) returns text language plpgsql as $f$
begin
  return 'swapped:' || pgpm.regrain(p_parent, p_child, p_step);
exception when others then return 'refused: ' || sqlerrm;
end $f$;
select alike(pg_temp.try_regrain('public.fib', 'fib_p0000000000000000000_to_0000000000000000040', '2.5'),
  'refused: pg_partition_magician: regrain target step 2.5 for fib is not a whole number%',
  'regrain() refuses it too');
select is((select count(*) from pgpm.part where parent_table = 'public.fib'::regclass and not attached), 0::bigint,
  'the refusals minted no fine child');

-- the ticks, with the whole target recorded: the split completes
select lives_ok($$ select pgpm.set_regrain('public.fib', '5') $$, 'fixture: the whole target again');
set client_min_messages = warning;
do $$ declare v text; begin
  for i in 1..60 loop
    call pgpm.maintain('public.fib', v);
    exit when exists (select 1 from pgpm.log where parent_table = 'public.fib'::regclass
                       and action = 'regrain' and method = 'copy_swap_drop');
  end loop;
end $$;
reset client_min_messages;
select ok(exists (select 1 from pgpm.log where parent_table = 'public.fib'::regclass
                   and action = 'regrain' and method = 'copy_swap_drop'),
  'LIVENESS: auto-regrain completed the split of the monolith');
select is((select array_agg(lo || '-' || hi order by lo::numeric) from pgpm.part
            where parent_table = 'public.fib'::regclass and attached and lo::numeric < 40),
          array['0-5', '5-10', '10-15', '15-20', '20-25', '25-30', '30-35', '35-40'],
  'the monolith became exactly the eight 5-wide cells of [0, 40)');
select is((select string_agg(id || ':' || payload, ',' order by id) from public.fib where id < 40),
          (select string_agg(g || ':orig' || g, ',' order by g) from generate_series(1, 30) g),
  'every row of the monolith survived the split, each with its own payload');
select is((select count(*) from pgpm.log where parent_table = 'public.fib'::regclass and action = 'skip_regrain'), 0::bigint,
  'no tick logged skip_regrain');

-- ===================== the rule is the column's: int4 refuses, numeric accepts =====================
create table public.fi4 (id int primary key, payload text);
insert into public.fi4 select g, 'x' from generate_series(1, 30) g;
call pgpm.transmute('public.fi4', 'id', 10, p_paused => false);
select throws_like($$ select pgpm.set_regrain('public.fi4', '2.5') $$,
  'pg_partition_magician: regrain target step 2.5 for fi4 is not a whole number, but its control column id is int4%',
  'set_regrain refuses a fractional step on an int4 column');

create table public.fnu (id numeric primary key, payload text);
insert into public.fnu select g, 'x' from generate_series(1, 30) g;
call pgpm.transmute('public.fnu', 'id', 10, p_paused => false);
select lives_ok($$ select pgpm.set_regrain('public.fnu', '2.5') $$,
  'set_regrain accepts a fractional step on a numeric column (#582)');
select is((select regrain_to from pgpm.config where parent_table = 'public.fnu'::regclass), '2.5',
  'and records it');

select * from finish();
