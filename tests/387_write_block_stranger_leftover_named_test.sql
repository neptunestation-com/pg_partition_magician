-- The write-block step names an older install's block on an unanchored row's stranger, with the statement that lifts
-- it (issue #1415, bullet 4).
--
-- THE GAP. A pgpm.part row with no oid of its own (an install older than #421 left it, or its backfill could not
-- resolve it) is refused the write block when the table under its name is a partition of the parent over ANOTHER
-- range (#1365: _unanchored_stranger), logged fail_write_block_identity "refusing to write-block it". But an install
-- older than #1392 blocked that same table by the name alone, and the upgrade leaves the block: the operator's
-- partition stays read-only while every tick's refusal says pgpm is NOT blocking it, and names no way out. The
-- identity refusal of an anchored row already names such a leftover with its lift (_stale_write_block_note, #1435);
-- pgpm does not lift it itself, since it cannot tell it from a block kept on a table detached by hand, and this path
-- now follows the same rule: the refusal names the block and the statement that lifts it.
--
-- THE STATE an older install leaves, made by hand on this one: the row unanchored (child_oid null, as the issue's
-- reproduction leaves it on an install from 13a261e), the operator's table under the row's name attached over another
-- range, and pgpm's own trigger on it, ENABLE ALWAYS, exactly as _install_write_block creates it.
--
-- ASYMMETRIC FIXTURE. Two parents. a387's stranger carries the leftover block and holds 9801, 9802; b387's stranger
-- carries none and holds 9851. Only a387's refusal names a block, and neither block is lifted or added.
-- bench/retain_edges_tap.sh runs this file against the mutant whose refusal names no block.
create extension if not exists pgtap;
set client_min_messages = warning;
select plan(9);

create table public.a387 (id bigint primary key, payload text);
insert into public.a387 values (181, 'a'), (182, 'b');
call pgpm.transmute('public.a387', 'id', 100, p_obtain => 6, p_retain => 300, p_paused => true);
insert into public.a387 values (600, 'frontier');
create table public.b387 (id bigint primary key, payload text);
insert into public.b387 values (183, 'c');
call pgpm.transmute('public.b387', 'id', 100, p_obtain => 6, p_retain => 300, p_paused => true);
insert into public.b387 values (650, 'frontier');

-- [100, 200)'s row made unanchored, its partition dropped, and the operator's table put under its name over another
-- range; on a387 with the block an older install put on it by that name
create function pg_temp.stranger(p_rel text, p_block boolean, p_ids int[]) returns name language plpgsql as $f$
declare n name;
begin
  select child_name into n from pgpm.part where parent_table = format('public.%I', p_rel)::regclass and lo = '100';
  update pgpm.part set child_oid = null where parent_table = format('public.%I', p_rel)::regclass and lo = '100';
  execute format('drop table public.%I', n);
  execute format('create table public.%I (id bigint primary key, payload text)', n);
  execute format('insert into public.%I select i, ''operator'' from unnest(%L::int[]) i', n, p_ids);
  execute format('alter table public.%I attach partition public.%I for values from (%s) to (%s)',
                 p_rel, n, p_ids[1] / 100 * 100, p_ids[1] / 100 * 100 + 100);
  if p_block then   -- what an install older than #1392 put on it, by the name
    execute format('create trigger pgpm_write_block before insert or update or delete on public.%I'
                   ' for each row execute function pgpm._write_block_raise()', n);
    execute format('alter table public.%I enable always trigger pgpm_write_block', n);
  end if;
  return n;
end $f$;
select pg_temp.stranger('a387', true, array[9801, 9802]) as a_cell \gset
select pg_temp.stranger('b387', false, array[9851]) as b_cell \gset

select is((select string_agg(c.relname || ':' || pgpm._unanchored_stranger(p.parent_table, c.oid, p.lo, p.hi)::text, ',' order by c.relname)
             from pgpm.part p join pg_class c on c.oid in (to_regclass('public.' || :'a_cell'), to_regclass('public.' || :'b_cell'))
            where p.child_oid is null and p.child_name = c.relname),
  :'a_cell' || ':true,' || :'b_cell' || ':true',
  'LIVENESS: each row is unanchored and the table under its name is its stranger');
select is((select string_agg(c.relname || ':' || t.tgenabled::text, ',' order by c.relname) from pg_trigger t join pg_class c on c.oid = t.tgrelid
            where t.tgname = 'pgpm_write_block' and c.relname in (:'a_cell', :'b_cell')),
  :'a_cell' || ':A', 'LIVENESS: a387''s stranger alone carries pgpm''s block, ENABLE ALWAYS, as an older install left it');

select pgpm._enforce_write_blocks('public.a387');
select pgpm._enforce_write_blocks('public.b387');

select is((select string_agg(parent_table::text || ':' || lo, ',' order by parent_table::text) from pgpm.log
            where action = 'fail_write_block_identity'),
  'a387:100,b387:100', 'LIVENESS: each tick refused to write-block the stranger, logged fail_write_block_identity');
select matches((select method from pgpm.log where action = 'fail_write_block_identity' and parent_table = 'public.a387'::regclass),
  'refusing to write-block it\. public\.' || :'a_cell' || ' carries a write block \(trigger pgpm_write_block\) that pgpm will not lift',
  'a387: the refusal says the table carries pgpm''s block');
select ok(strpos((select method from pgpm.log where action = 'fail_write_block_identity' and parent_table = 'public.a387'::regclass),
                 'drop trigger if exists pgpm_write_block on public.' || :'a_cell' || ';') > 0,
  'a387: and spells the statement that lifts it');
select is((select method from pgpm.log where action = 'fail_write_block_identity' and parent_table = 'public.b387'::regclass),
  format('public.%s is a partition of b387 over another range than this row''s [100, 200), and the row records no oid of its own; refusing to write-block it', :'b_cell'),
  'b387: a stranger with no block is refused with nothing more to name');
select is((select string_agg(c.relname, ',' order by c.relname) from pg_trigger t join pg_class c on c.oid = t.tgrelid
            where t.tgname = 'pgpm_write_block' and c.relname in (:'a_cell', :'b_cell')),
  :'a_cell', 'pgpm neither lifts the leftover block nor blocks the other stranger');

-- the remedy, run as the operator would
select format('drop trigger if exists pgpm_write_block on public.%I', :'a_cell') \gexec
select lives_ok($$insert into public.a387 values (9803, 'written')$$, 'once lifted by the named statement, the table takes writes');
select is((select array_agg(id order by id) from public.a387 where id between 9800 and 9899), array[9801, 9802, 9803]::bigint[],
  'and holds its rows and the new one');

select * from finish();
