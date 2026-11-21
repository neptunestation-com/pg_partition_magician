-- Measurement 3 of docs/formal/phase3-design.md ("Measured before it is relied on"): for every control kind pgpm
-- supports, the baseline records exactly the rows the file wrote, by identity, and the oracle reads each row's
-- control value on pgpm's grid right (NoLostRow's horizon test decodes it: _native_of over pgpm._col_to_native).
--
-- Per kind, seven rows labelled by age (m13, m11, m8: below the horizon; m4, m2, m1, m0: within it; for the
-- id kinds the same shape on an id grid of step 10 with retain 30). Then:
--   1. fixture: baseline() over the plain table records the seven payloads, no more and no fewer
--   2. transmute, then the retention-aware regrain_history() (the time kinds on a shimmed clock, see below), which discards the aged rows with the coarse source
--      (regrain_aged) and copies the rest into fine partitions. LIVENESS: exactly m4, m2, m1, m0 and f are visible
--   3. check() names nothing for the table: every aged row decoded below the horizon inside a regrain_aged range,
--      every kept row visible
--   4. the fine partition holding m2 dropped by hand: check() names exactly m2's identity, which it can only do if
--      m2's control value decoded at or past the horizon
-- Run in a session zone far from UTC and a non-ISO DateStyle, so a rendering that followed the session would show.
create extension if not exists pgtap;

select plan(52);

set timezone = 'America/Los_Angeles';
set datestyle = 'SQL, DMY';

create schema bk;

-- the seven ages, in months, and their payloads
create function bk.ages() returns table (age int, payload text) language sql immutable as $$
  values (13, 'm13'), (11, 'm11'), (8, 'm8'), (4, 'm4'), (2, 'm2'), (1, 'm1'), (0, 'm0');
$$;
-- the instant of an age: whole months back, mid-month-safe; m0 an hour ago
create function bk.at(p_age int) returns timestamptz language sql stable as $$
  select case when p_age = 0 then pg_catalog.now() - interval '1 hour' else pg_catalog.now() - make_interval(months => p_age) end;
$$;
-- the id of an age on the id grid: with f at 125, the horizon is floor(125 - 60) = 60
create function bk.id_of(p_age int) returns int language sql immutable as $$
  select case p_age when 13 then 3 when 11 then 15 when 8 then 27 when 4 then 65 when 2 then 77 when 1 then 84 else 88 end;
$$;
create table bk.made (name text primary key, cols text, expr text);
-- create bk.<name> with the control column ctl of type p_type, the key p_key, and one row per age, the control value
-- the expression p_expr over $1 (the age's instant) and $2 (its id)
create function bk.mk(p_name text, p_cols text, p_key text, p_expr text) returns void language plpgsql as $$
declare r record;
begin
  insert into bk.made values (p_name, p_cols, p_expr);
  execute format('create table bk.%I (%s, payload text not null, primary key (%s))', p_name, p_cols, p_key);
  for r in select * from bk.ages() loop
    if p_cols like 'id int,%' then
      execute format('insert into bk.%I (id, ctl, payload) values ($2, (%s), $3)', p_name, p_expr)
        using bk.at(r.age), bk.id_of(r.age), r.payload;
    else
      execute format('insert into bk.%I (ctl, payload) values ((%s), $3)', p_name, p_expr)
        using bk.at(r.age), bk.id_of(r.age), r.payload;
    end if;
  end loop;
end $$;
-- after the conversion, one row past the monolith ('f': 40 days ahead, id 125) so the monolith is frozen and
-- regrain_history() takes it; recorded with wrote()
create function bk.future(p_name text) returns bigint language plpgsql as $$
declare m bk.made;
begin
  select * into m from bk.made where name = p_name;
  if m.cols like 'id int,%' then
    execute format('insert into bk.%I (id, ctl, payload) values ($2, (%s), ''f'')', p_name, m.expr)
      using pg_catalog.now() + interval '40 days', 125;
  else
    execute format('insert into bk.%I (ctl, payload) values ((%s), ''f'')', p_name, m.expr)
      using pg_catalog.now() + interval '40 days', 125;
  end if;
  return pgpm_formal.wrote(format('bk.%I', p_name)::regclass, 'payload = ''f''');
end $$;
create function bk.ledger(p_rel regclass) returns text language sql as $$
  select string_agg(row_data ->> 'payload', ' ' order by row_data ->> 'payload')
    from pgpm_formal.ledger where parent_oid = p_rel and not deleted;
$$;
create function bk.visible(p_rel regclass) returns text language plpgsql as $$
declare v text;
begin
  execute format('select string_agg(payload, '' '' order by payload) from %s', p_rel) into v;
  return v;
end $$;
create function bk.found(p_rel text) returns text language sql as $$
  select coalesce(string_agg(invariant || ' ' || identity, '; ' order by identity), '') from pgpm_formal.check()
   where parent_table = to_regclass(p_rel);
$$;
create function bk.drop_holding(p_rel regclass, p_payload text) returns text language plpgsql as $$
declare v regclass;
begin
  execute format('select tableoid::regclass from %s where payload = $1', p_rel) into v using p_payload;
  execute format('drop table %s', v);
  return v::text;
end $$;
create function bk.ident(p_rel text, p_payload text) returns text language sql as $$
  select 'NoLostRow ' || identity from pgpm_formal.ledger l
   where l.parent_oid = (select parent_oid from pgpm_formal.ledger_parent where parent_name = p_rel)
     and l.row_data ->> 'payload' = p_payload;
$$;

-- ==================================================================== int and bigint ids
select bk.mk('k_int', 'ctl int', 'ctl', '$2');
select is(pgpm_formal.baseline('bk.k_int'), 7::bigint, 'fixture: int: the baseline records seven rows');
select is(bk.ledger('bk.k_int'), 'm0 m1 m11 m13 m2 m4 m8', 'int: the baseline records the seven rows written, by payload');
call pgpm.transmute('bk.k_int', 'ctl', 10, p_retain => 60, p_obtain => 5);
select is(bk.future('k_int'), 1::bigint, 'fixture: k_int: the row past the monolith is written and recorded');
select pgpm.regrain_history('bk.k_int');
select is(bk.visible('bk.k_int'), 'f m0 m1 m2 m4', 'LIVENESS: int: the aged rows are gone and the rest visible');
select is(bk.found('bk.k_int'), '', 'int: check() names nothing');
select bk.drop_holding('bk.k_int', 'm2');
select is(bk.found('bk.k_int'), bk.ident('bk.k_int', 'm2'), 'int: check() names exactly the row the hand drop removed');

select bk.mk('k_big', 'ctl bigint', 'ctl', '$2');
select is(pgpm_formal.baseline('bk.k_big'), 7::bigint, 'fixture: bigint: the baseline records seven rows');
select is(bk.ledger('bk.k_big'), 'm0 m1 m11 m13 m2 m4 m8', 'bigint: the baseline records the seven rows written, by payload');
call pgpm.transmute('bk.k_big', 'ctl', 10, p_retain => 60, p_obtain => 5);
select is(bk.future('k_big'), 1::bigint, 'fixture: k_big: the row past the monolith is written and recorded');
select pgpm.regrain_history('bk.k_big');
select is(bk.visible('bk.k_big'), 'f m0 m1 m2 m4', 'LIVENESS: bigint: the aged rows are gone and the rest visible');
select bk.drop_holding('bk.k_big', 'm2');
select is(bk.found('bk.k_big'), bk.ident('bk.k_big', 'm2'), 'bigint: check() names exactly the row the hand drop removed');

-- The time kinds' frontier is the clock, so a monolith holding a row of this month is never frozen and the regrain
-- below would refuse it. As tests/311 does, a clk.now() shim ahead of pg_catalog in search_path moves the clock
-- pgpm reads (its unqualified now()) two months on, for the regrain and the checks after it, never for the
-- conversion. Under it the horizon is floor(now - 8 months) on the shimmed clock, six months back on the real one:
-- m13, m11 and m8 below it, m4 and newer within.
create schema clk;
create function clk.now() returns timestamptz language sql stable as $$ select pg_catalog.now() + interval '2 months' $$;
set search_path = clk, pg_catalog, public;
select is(now(), pg_catalog.now() + interval '2 months', 'LIVENESS: the clk.now() shim is what an unqualified now() resolves to');
reset search_path;

-- ==================================================================== time: timestamptz, timestamp, date
select bk.mk('k_tstz', 'id int, ctl timestamptz', 'id, ctl', '$1');
select is(pgpm_formal.baseline('bk.k_tstz'), 7::bigint, 'fixture: timestamptz: the baseline records seven rows');
select is(bk.ledger('bk.k_tstz'), 'm0 m1 m11 m13 m2 m4 m8', 'timestamptz: the baseline records the seven rows written, by payload');
call pgpm.transmute('bk.k_tstz', 'ctl', interval '1 month', p_retain => interval '8 months', p_obtain => 3);
select is(bk.future('k_tstz'), 1::bigint, 'fixture: k_tstz: the row past the monolith is written and recorded');
set search_path = clk, pg_catalog, public;
select pgpm.regrain_history('bk.k_tstz');
select is(bk.visible('bk.k_tstz'), 'f m0 m1 m2 m4', 'LIVENESS: timestamptz: the aged rows are gone and the rest visible');
select is(bk.found('bk.k_tstz'), '', 'timestamptz: check() names nothing');
select bk.drop_holding('bk.k_tstz', 'm2');
select is(bk.found('bk.k_tstz'), bk.ident('bk.k_tstz', 'm2'), 'timestamptz: check() names exactly the row the hand drop removed');
reset search_path;

select bk.mk('k_ts', 'id int, ctl timestamp', 'id, ctl', '$1 at time zone ''UTC''');
select is(bk.ledger('bk.k_ts'), null, 'fixture: timestamp: nothing is recorded before the baseline');
select pgpm_formal.baseline('bk.k_ts');
select is(bk.ledger('bk.k_ts'), 'm0 m1 m11 m13 m2 m4 m8', 'timestamp: the baseline records the seven rows written, by payload');
call pgpm.transmute('bk.k_ts', 'ctl', interval '1 month', p_retain => interval '8 months', p_obtain => 3);
select is(bk.future('k_ts'), 1::bigint, 'fixture: k_ts: the row past the monolith is written and recorded');
set search_path = clk, pg_catalog, public;
select pgpm.regrain_history('bk.k_ts');
select is(bk.visible('bk.k_ts'), 'f m0 m1 m2 m4', 'LIVENESS: timestamp: the aged rows are gone and the rest visible');
select bk.drop_holding('bk.k_ts', 'm2');
select is(bk.found('bk.k_ts'), bk.ident('bk.k_ts', 'm2'), 'timestamp: check() names exactly the row the hand drop removed');
reset search_path;

select bk.mk('k_date', 'id int, ctl date', 'id, ctl', '($1 at time zone ''UTC'')::date');
select pgpm_formal.baseline('bk.k_date');
select is(bk.ledger('bk.k_date'), 'm0 m1 m11 m13 m2 m4 m8', 'date: the baseline records the seven rows written, by payload');
call pgpm.transmute('bk.k_date', 'ctl', interval '1 month', p_retain => interval '8 months', p_obtain => 3);
select is(bk.future('k_date'), 1::bigint, 'fixture: k_date: the row past the monolith is written and recorded');
set search_path = clk, pg_catalog, public;
select pgpm.regrain_history('bk.k_date');
select is(bk.visible('bk.k_date'), 'f m0 m1 m2 m4', 'LIVENESS: date: the aged rows are gone and the rest visible');
select is(bk.found('bk.k_date'), '', 'date: check() names nothing');
select bk.drop_holding('bk.k_date', 'm2');
select is(bk.found('bk.k_date'), bk.ident('bk.k_date', 'm2'), 'date: check() names exactly the row the hand drop removed');
reset search_path;

-- ==================================================================== uuidv7
select bk.mk('k_uuid', 'ctl uuid', 'ctl', 'pgpm._ts_to_uuid($1)');
select pgpm_formal.baseline('bk.k_uuid');
select is(bk.ledger('bk.k_uuid'), 'm0 m1 m11 m13 m2 m4 m8', 'uuidv7: the baseline records the seven rows written, by payload');
call pgpm.transmute('bk.k_uuid', 'ctl', interval '1 month', p_retain => interval '8 months', p_obtain => 3);
select is(bk.future('k_uuid'), 1::bigint, 'fixture: k_uuid: the row past the monolith is written and recorded');
set search_path = clk, pg_catalog, public;
select pgpm.regrain_history('bk.k_uuid');
select is(bk.visible('bk.k_uuid'), 'f m0 m1 m2 m4', 'LIVENESS: uuidv7: the aged rows are gone and the rest visible');
select is(bk.found('bk.k_uuid'), '', 'uuidv7: check() names nothing');
select bk.drop_holding('bk.k_uuid', 'm2');
select is(bk.found('bk.k_uuid'), bk.ident('bk.k_uuid', 'm2'), 'uuidv7: check() names exactly the row the hand drop removed');
reset search_path;

-- ==================================================================== text_time: cuid v1, ULID, KSUID, ObjectId
select bk.mk('k_cuid', 'ctl text collate "C"', 'ctl', 'pgpm._ts_to_text_time($1, ''c'', 8, 36, ''ms'')');
select pgpm_formal.baseline('bk.k_cuid');
select is(bk.ledger('bk.k_cuid'), 'm0 m1 m11 m13 m2 m4 m8', 'cuid: the baseline records the seven rows written, by payload');
call pgpm.transmute('bk.k_cuid', 'ctl', interval '1 month', p_retain => interval '8 months', p_obtain => 3,
  p_tt_prefix => 'c', p_tt_width => 8, p_tt_radix => 36, p_tt_unit => 'ms');
select is(bk.future('k_cuid'), 1::bigint, 'fixture: k_cuid: the row past the monolith is written and recorded');
set search_path = clk, pg_catalog, public;
select pgpm.regrain_history('bk.k_cuid');
select is(bk.visible('bk.k_cuid'), 'f m0 m1 m2 m4', 'LIVENESS: cuid: the aged rows are gone and the rest visible');
select bk.drop_holding('bk.k_cuid', 'm2');
select is(bk.found('bk.k_cuid'), bk.ident('bk.k_cuid', 'm2'), 'cuid: check() names exactly the row the hand drop removed');
reset search_path;

select bk.mk('k_ulid', 'ctl text collate "C"', 'ctl',
  'pgpm._ts_to_text_time($1, '''', 10, 32, ''ms'', ''0123456789ABCDEFGHJKMNPQRSTVWXYZ'')');
select pgpm_formal.baseline('bk.k_ulid');
select is(bk.ledger('bk.k_ulid'), 'm0 m1 m11 m13 m2 m4 m8', 'ULID: the baseline records the seven rows written, by payload');
call pgpm.transmute('bk.k_ulid', 'ctl', interval '1 month', p_retain => interval '8 months', p_obtain => 3,
  p_tt_prefix => '', p_tt_width => 10, p_tt_radix => 32, p_tt_unit => 'ms',
  p_tt_alphabet => '0123456789ABCDEFGHJKMNPQRSTVWXYZ');
select is(bk.future('k_ulid'), 1::bigint, 'fixture: k_ulid: the row past the monolith is written and recorded');
set search_path = clk, pg_catalog, public;
select pgpm.regrain_history('bk.k_ulid');
select is(bk.visible('bk.k_ulid'), 'f m0 m1 m2 m4', 'LIVENESS: ULID: the aged rows are gone and the rest visible');
select bk.drop_holding('bk.k_ulid', 'm2');
select is(bk.found('bk.k_ulid'), bk.ident('bk.k_ulid', 'm2'), 'ULID: check() names exactly the row the hand drop removed');
reset search_path;

select bk.mk('k_ksuid', 'ctl text collate "C"', 'ctl',
  'pgpm._ts_to_text_time($1, '''', 27, 62, ''s'', ''0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz'', 128, timestamptz ''2014-05-13 16:53:20+00'')');
select pgpm_formal.baseline('bk.k_ksuid');
select is(bk.ledger('bk.k_ksuid'), 'm0 m1 m11 m13 m2 m4 m8', 'KSUID: the baseline records the seven rows written, by payload');
call pgpm.transmute('bk.k_ksuid', 'ctl', interval '1 month', p_retain => interval '8 months', p_obtain => 3,
  p_tt_prefix => '', p_tt_width => 27, p_tt_radix => 62, p_tt_unit => 's',
  p_tt_alphabet => '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz',
  p_tt_discard_bits => 128, p_tt_epoch => timestamptz '2014-05-13 16:53:20+00');
select is(bk.future('k_ksuid'), 1::bigint, 'fixture: k_ksuid: the row past the monolith is written and recorded');
set search_path = clk, pg_catalog, public;
select pgpm.regrain_history('bk.k_ksuid');
select is(bk.visible('bk.k_ksuid'), 'f m0 m1 m2 m4', 'LIVENESS: KSUID: the aged rows are gone and the rest visible');
select is(bk.found('bk.k_ksuid'), '', 'KSUID: check() names nothing');
select bk.drop_holding('bk.k_ksuid', 'm2');
select is(bk.found('bk.k_ksuid'), bk.ident('bk.k_ksuid', 'm2'), 'KSUID: check() names exactly the row the hand drop removed');
reset search_path;

select bk.mk('k_oid', 'ctl text collate "C"', 'ctl', 'pgpm._ts_to_text_time($1, '''', 8, 16, ''s'')');
select pgpm_formal.baseline('bk.k_oid');
select is(bk.ledger('bk.k_oid'), 'm0 m1 m11 m13 m2 m4 m8', 'ObjectId: the baseline records the seven rows written, by payload');
call pgpm.transmute('bk.k_oid', 'ctl', interval '1 month', p_retain => interval '8 months', p_obtain => 3,
  p_tt_prefix => '', p_tt_width => 8, p_tt_radix => 16, p_tt_unit => 's');
select is(bk.future('k_oid'), 1::bigint, 'fixture: k_oid: the row past the monolith is written and recorded');
set search_path = clk, pg_catalog, public;
select pgpm.regrain_history('bk.k_oid');
select is(bk.visible('bk.k_oid'), 'f m0 m1 m2 m4', 'LIVENESS: ObjectId: the aged rows are gone and the rest visible');
select is(bk.found('bk.k_oid'), '', 'ObjectId: check() names nothing');
select bk.drop_holding('bk.k_oid', 'm2');
select is(bk.found('bk.k_oid'), bk.ident('bk.k_oid', 'm2'), 'ObjectId: check() names exactly the row the hand drop removed');
reset search_path;

-- across every kind: what the aged rows were excused by
select is(
  (select count(distinct parent_table)::int from pgpm.log where action = 'regrain_aged'
      and parent_table::text like 'bk.k\_%'),
  10, 'LIVENESS: every kind''s aged rows were discarded by a logged retention-aware regrain');

select * from finish();
