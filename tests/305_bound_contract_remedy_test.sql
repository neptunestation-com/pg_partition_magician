-- The fresh-bound refusal names a smaller step only when one would work (issue #1088).
--
-- THE DEFECT. _control_bound_contract refuses a monolith bound the id column's type cannot store (#952), and
-- its message always ended "Give the column a type that holds the bound ..., or use a smaller step". When the
-- newest key is the type's maximum (9999 in numeric(4,0)), the monolith's hi is the grid boundary above it,
-- 10000 or past it whatever the step, so the operator who followed the remedy (step 1) was refused with the
-- same bound, [9000, 10000). Only a wider type works there.
--
-- THE CONTRACT. A smaller step only moves the bound toward the rows, so the tightest bound any step can give
-- is the finest step's: the column's unit (1, or 100 on a numeric(p,-2)), with the same p_bound_headroom.
-- The refusal offers a smaller step, and names that finest step and the bound it gives, exactly when the
-- column's type can store that bound; otherwise it says no smaller step avoids it and names the wider type
-- alone. Each message is pinned whole.
--
-- WHY THE CASES CANNOT PASS FOR THE WRONG REASON. Every refusal is witnessed both ways: where the step
-- remedy is withheld, following it anyway (the finest step) is refused too, so withholding it is right; where
-- it is offered, following it converts the same table and the monolith is attached on exactly the bound the
-- message named, so the offer is right and the bound it quotes is the real one. The cases are asymmetric
-- (the newest key at the type's top against one step below it; a unit of 1 against 100; the high bound
-- against the low; headroom that tips the finest bound over the top), so one rule that always offered or
-- always withheld the remedy fails half of them. transmute runs through dblink as a top-level CALL, so a
-- build that did not refuse would really convert rather than die at a COMMIT inside a pgTAP function.
-- bench/bound_contract_remedy.sh runs this file against the mutants.
create extension if not exists pgtap;
create extension if not exists dblink;
set client_min_messages = warning;

select plan(21);

select dblink_connect('t305', 'dbname=' || current_database());

-- the refusal a top-level CALL of transmute ends in, or 'no error'
create function pg_temp.t305_err(p_call text) returns text language plpgsql as $$
begin
  perform dblink_exec('t305', p_call);
  return 'no error';
exception when others then
  return sqlerrm;
end $$;

-- the table's state, by identity: kind, and what pgpm would have committed
create function pg_temp.t305_state(p_rel regclass) returns text language sql as $$
  select concat_ws(' | ',
    (select relkind::text from pg_class where oid = p_rel),
    'config:' || exists (select 1 from pgpm.config where parent_table = p_rel),
    'bound:' || exists (select 1 from pg_constraint where conrelid = p_rel and conname = 'pgpm_monolith_bound'),
    'claim:' || exists (select 1 from pgpm.transmute_inflight where parent_table = p_rel))
$$;

-- the bound the monolith of a converted table is attached on
create function pg_temp.t305_monolith(p_rel regclass) returns text language sql as $$
  select pg_get_expr(c.relpartbound, c.oid)
    from pg_inherits i join pg_class c on c.oid = i.inhrelid
   where i.inhparent = p_rel and c.oid = (select monolith_oid from pgpm.config where parent_table = p_rel)
$$;

-- ======================================================================================================
-- A. The issue's case: the newest key is numeric(4,0)'s maximum, 9999. No step can avoid hi = 10000.
-- ======================================================================================================
create table public.t305_top (id numeric(4,0) primary key);
insert into public.t305_top select g from generate_series(9000, 9999) g;
select is((select max(id)::text from public.t305_top), '9999', 'LIVENESS: (A) the newest key is 9999, the top of numeric(4,0)');
select is(pg_temp.t305_err($$ call pgpm.transmute('public.t305_top', 'id', 10::bigint) $$),
  'pg_partition_magician: cannot partition t305_top on id: the monolith''s bound [9000, 10000) cannot be stored in the column, which is numeric(4,0): 10000 cannot be stored in it at all (numeric field overflow). The cutover''s ATTACH would fail on it after the bound had been committed, leaving the table rejecting every write past it. No smaller step avoids it: the finest step the column admits, 1, gives [9000, 10000), which the column cannot store either. Give the column a type that holds the bound (ALTER TABLE t305_top ALTER COLUMN id TYPE ...), then re-run transmute.',
  'A: step 10 is refused, and the refusal names the wider type alone, not a smaller step');
select alike(pg_temp.t305_err($$ call pgpm.transmute('public.t305_top', 'id', 1::bigint) $$),
  'pg_partition_magician: cannot partition t305_top on id: the monolith''s bound [9000, 10000) cannot be stored in the column%',
  'LIVENESS: (A) the withheld remedy really fails: step 1 is refused on the same bound');
select is(pg_temp.t305_state('public.t305_top'), 'r | config:false | bound:false | claim:false',
  'A: both refusals left the table as it was');
alter table public.t305_top alter column id type numeric(5,0);
select is(pg_temp.t305_err($$ call pgpm.transmute('public.t305_top', 'id', 10::bigint) $$), 'no error',
  'A CONTROL: the remedy the refusal names, a wider type, converts the same table with step 10');
select is(pg_temp.t305_monolith('public.t305_top'), 'FOR VALUES FROM (''9000'') TO (''10000'')',
  'A CONTROL: on the bound the narrower type could not store');

-- ======================================================================================================
-- B. One key short of the top (newest 9995): step 10's hi is 10000, but step 1's is 9996.
-- ======================================================================================================
create table public.t305_near (id numeric(4,0) primary key);
insert into public.t305_near select g from generate_series(9000, 9995) g;
select is(pg_temp.t305_err($$ call pgpm.transmute('public.t305_near', 'id', 10::bigint) $$),
  'pg_partition_magician: cannot partition t305_near on id: the monolith''s bound [9000, 10000) cannot be stored in the column, which is numeric(4,0): 10000 cannot be stored in it at all (numeric field overflow). The cutover''s ATTACH would fail on it after the bound had been committed, leaving the table rejecting every write past it. Give the column a type that holds the bound (ALTER TABLE t305_near ALTER COLUMN id TYPE ...), or use a smaller step (the finest step the column admits, 1, gives [9000, 9996)), then re-run transmute.',
  'B: step 10 is refused, and the refusal offers a smaller step, naming the bound the finest gives');
select is(pg_temp.t305_err($$ call pgpm.transmute('public.t305_near', 'id', 1::bigint) $$), 'no error',
  'B CONTROL: following the offered remedy (step 1) converts the same table');
select is(pg_temp.t305_monolith('public.t305_near'), 'FOR VALUES FROM (''9000'') TO (''9996'')',
  'B CONTROL: on exactly the bound the refusal named');

-- ======================================================================================================
-- C. A negative scale: numeric(4,-2) holds multiples of 100 up to 999900, so its finest step is 100.
-- ======================================================================================================
create table public.t305_ctop (id numeric(4,-2) primary key);
insert into public.t305_ctop select g * 100 from generate_series(9900, 9999) g;
select is(pg_temp.t305_err($$ call pgpm.transmute('public.t305_ctop', 'id', 1000::bigint) $$),
  'pg_partition_magician: cannot partition t305_ctop on id: the monolith''s bound [990000, 1000000) cannot be stored in the column, which is numeric(4,-2): 1000000 cannot be stored in it at all (numeric field overflow). The cutover''s ATTACH would fail on it after the bound had been committed, leaving the table rejecting every write past it. No smaller step avoids it: the finest step the column admits, 100, gives [990000, 1000000), which the column cannot store either. Give the column a type that holds the bound (ALTER TABLE t305_ctop ALTER COLUMN id TYPE ...), then re-run transmute.',
  'C: newest 999900, the top of numeric(4,-2): refused with the wider type alone, the finest step being 100');
select alike(pg_temp.t305_err($$ call pgpm.transmute('public.t305_ctop', 'id', 100::bigint) $$),
  'pg_partition_magician: cannot partition t305_ctop on id: the monolith''s bound [990000, 1000000) cannot be stored in the column%',
  'LIVENESS: (C) the withheld remedy really fails: step 100 is refused on the same bound');
create table public.t305_cnear (id numeric(4,-2) primary key);
insert into public.t305_cnear select g * 100 from generate_series(9900, 9990) g;
select is(pg_temp.t305_err($$ call pgpm.transmute('public.t305_cnear', 'id', 1000::bigint) $$),
  'pg_partition_magician: cannot partition t305_cnear on id: the monolith''s bound [990000, 1000000) cannot be stored in the column, which is numeric(4,-2): 1000000 cannot be stored in it at all (numeric field overflow). The cutover''s ATTACH would fail on it after the bound had been committed, leaving the table rejecting every write past it. Give the column a type that holds the bound (ALTER TABLE t305_cnear ALTER COLUMN id TYPE ...), or use a smaller step (the finest step the column admits, 100, gives [990000, 999100)), then re-run transmute.',
  'C: newest 999000: refused, offering a smaller step, the finest (100) giving [990000, 999100)');
select is(pg_temp.t305_err($$ call pgpm.transmute('public.t305_cnear', 'id', 100::bigint) $$), 'no error',
  'C CONTROL: following the offered remedy (step 100) converts the same table');
select is(pg_temp.t305_monolith('public.t305_cnear'), 'FOR VALUES FROM (''990000'') TO (''999100'')',
  'C CONTROL: on exactly the bound the refusal named');

-- ======================================================================================================
-- D. The low bound: the oldest key is numeric(4,0)'s minimum, -9999, and step 10 floors it to -10000.
-- ======================================================================================================
create table public.t305_low (id numeric(4,0) primary key);
insert into public.t305_low select g from generate_series(-9999, -9011) g;
select is(pg_temp.t305_err($$ call pgpm.transmute('public.t305_low', 'id', 10::bigint) $$),
  'pg_partition_magician: cannot partition t305_low on id: the monolith''s bound [-10000, -9010) cannot be stored in the column, which is numeric(4,0): -10000 cannot be stored in it at all (numeric field overflow). The cutover''s ATTACH would fail on it after the bound had been committed, leaving the table rejecting every write past it. Give the column a type that holds the bound (ALTER TABLE t305_low ALTER COLUMN id TYPE ...), or use a smaller step (the finest step the column admits, 1, gives [-9999, -9010)), then re-run transmute.',
  'D: a low bound past the minimum is refused, offering a smaller step: the finest floors to the oldest key itself');
select is(pg_temp.t305_err($$ call pgpm.transmute('public.t305_low', 'id', 1::bigint) $$), 'no error',
  'D CONTROL: following the offered remedy (step 1) converts the same table');
select is(pg_temp.t305_monolith('public.t305_low'), 'FOR VALUES FROM (''-9999'') TO (''-9010'')',
  'D CONTROL: on exactly the bound the refusal named');

-- ======================================================================================================
-- E. Headroom tips even the finest bound over the top: newest 9990, p_bound_headroom 9, so step 1 gives
--    hi = 9991 + 9 = 10000. Without the headroom the finest bound (9991) would fit, and a refusal that
--    forgot it would offer a step that fails.
-- ======================================================================================================
create table public.t305_head (id numeric(4,0) primary key);
insert into public.t305_head select g from generate_series(9900, 9990) g;
select is(pg_temp.t305_err($$ call pgpm.transmute('public.t305_head', 'id', 5::bigint, p_bound_headroom => 9) $$),
  'pg_partition_magician: cannot partition t305_head on id: the monolith''s bound [9900, 10040) cannot be stored in the column, which is numeric(4,0): 10040 cannot be stored in it at all (numeric field overflow). The cutover''s ATTACH would fail on it after the bound had been committed, leaving the table rejecting every write past it. No smaller step avoids it: the finest step the column admits, 1, gives [9900, 10000) with p_bound_headroom => 9, which the column cannot store either. Give the column a type that holds the bound (ALTER TABLE t305_head ALTER COLUMN id TYPE ...), then re-run transmute.',
  'E: step 5 with headroom 9 is refused with the wider type alone, the finest bound counting the headroom');
select alike(pg_temp.t305_err($$ call pgpm.transmute('public.t305_head', 'id', 1::bigint, p_bound_headroom => 9) $$),
  'pg_partition_magician: cannot partition t305_head on id: the monolith''s bound [9900, 10000) cannot be stored in the column%',
  'LIVENESS: (E) the withheld remedy really fails: step 1 with the same headroom is refused on the bound named');

-- ======================================================================================================
-- F. An integer type's range: smallint's newest key 32767, its maximum.
-- ======================================================================================================
create table public.t305_small (id smallint primary key);
insert into public.t305_small select g from generate_series(32000, 32767) g;
select is(pg_temp.t305_err($$ call pgpm.transmute('public.t305_small', 'id', 10::bigint) $$),
  'pg_partition_magician: cannot partition t305_small on id: the monolith''s bound [32000, 32770) cannot be stored in the column, which is smallint: 32770 cannot be stored in it at all (value "32770" is out of range for type smallint). The cutover''s ATTACH would fail on it after the bound had been committed, leaving the table rejecting every write past it. No smaller step avoids it: the finest step the column admits, 1, gives [32000, 32768), which the column cannot store either. Give the column a type that holds the bound (ALTER TABLE t305_small ALTER COLUMN id TYPE ...), then re-run transmute.',
  'F: smallint at its maximum is refused with the wider type alone');
select is(pg_temp.t305_state('public.t305_small'), 'r | config:false | bound:false | claim:false',
  'F: and the table is left as it was');

select dblink_disconnect('t305');
select * from finish();
