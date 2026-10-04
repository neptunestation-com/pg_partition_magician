-- End-to-end pgpm.transmute for the two formats that needed the alphabet/discard_bits/epoch extension
-- (tests/88 already covers cuid v1, the case that needed none of them). Mirrors tests/88's shape for
-- each: refusal on a bad param, successful conversion, row conservation, and the #325 drought-immunity
-- property carrying over to both, asserted as tests/85 asserts it for uuidv7 (#881): a witness that the
-- data really is stale, then the frontier _frontier_native returns and a FORWARD partition past the
-- monolith, both read before the live insert. "A partition covers now()" alone holds even with text_time
-- dropped from _frontier_native's greatest(decoded, now()), because transmute's monolith takes its upper
-- bound from its OWN inline greatest() and so covers now() by itself on the day of the transmute.
create extension if not exists pgtap;

select plan(15);

-- ==================================================================== ULID (Crockford base32, ms)
create table public.tt_ulid (id text primary key, body text);
insert into public.tt_ulid (id, body) values
  (pgpm._ts_to_text_time(now() - interval '13 months', '', 10, 32, 'ms', '0123456789ABCDEFGHJKMNPQRSTVWXYZ'), 'oldest'),
  (pgpm._ts_to_text_time(now() - interval '11 months', '', 10, 32, 'ms', '0123456789ABCDEFGHJKMNPQRSTVWXYZ'), 'newest');

create temporary table _before_ulid as select count(*) as n from public.tt_ulid;

-- LIVENESS WITNESS: the drought is really present (every check below would pass on a fresh fixture).
select cmp_ok(
  now() - (select max(pgpm._decode('text_time', id, '', 10, 32, 'ms', '0123456789ABCDEFGHJKMNPQRSTVWXYZ')::timestamptz) from public.tt_ulid),
  '>', interval '2 months',
  'ULID: the newest backfilled row is well outside the 2-month (p_obtain x step) lookahead'
);

select throws_like(
  $$ call pgpm.transmute('public.tt_ulid', 'id', interval '1 month',
       p_tt_prefix => '', p_tt_width => 10, p_tt_radix => 32, p_tt_unit => 'ms',
       p_tt_alphabet => '0123456789ABCDEFGH') $$,   -- deliberately too short for radix 32
  'pg_partition_magician:%does not match%',
  'transmute refuses an alphabet whose length does not match p_tt_radix'
);

call pgpm.transmute('public.tt_ulid', 'id', interval '1 month', p_obtain => 2,
  p_tt_prefix => '', p_tt_width => 10, p_tt_radix => 32, p_tt_unit => 'ms',
  p_tt_alphabet => '0123456789ABCDEFGHJKMNPQRSTVWXYZ');

select is(
  (select control_kind from pgpm.config where parent_table = 'public.tt_ulid'::regclass),
  'text_time', 'ULID: config: control_kind = text_time'
);
select is(
  (select count(*) from public.tt_ulid)::bigint, (select n from _before_ulid)::bigint,
  'ULID: row count conserved across the migration'
);

select pgpm.resume('public.tt_ulid');
call pgpm.maintain('public.tt_ulid');

select ok(
  exists (select 1 from pgpm.part where parent_table = 'public.tt_ulid'::regclass and attached
            and lo::timestamptz <= now() and hi::timestamptz > now()),
  'ULID: a partition covers now() after one maintenance tick, despite an 11-month-stale frontier'
);
select ok(
  pgpm._frontier_native('public.tt_ulid'::regclass)::timestamptz >= now(),
  'ULID: the frontier obtain measures by is at or past now(), not the 11-month-stale data maximum'
);
select ok(
  exists (select 1 from pgpm.part p where p.parent_table = 'public.tt_ulid'::regclass and p.attached
            and p.lo::timestamptz <= now() + interval '1 month' and p.hi::timestamptz > now() + interval '1 month'
            and p.lo::timestamptz >= (select m.hi::timestamptz from pgpm.part m
                                       join pgpm.config c on c.parent_table = m.parent_table and c.monolith_oid = m.child_oid
                                      where m.parent_table = p.parent_table)),
  'ULID: a forward partition past the monolith covers now() + 1 month, inside the 2-month lookahead'
);
select lives_ok(
  $$ insert into public.tt_ulid (id, body) values
       (pgpm._ts_to_text_time(now(), '', 10, 32, 'ms', '0123456789ABCDEFGHJKMNPQRSTVWXYZ'), 'live') $$,
  'ULID: a fresh row stamped at now() is accepted'
);

-- ==================================================================== KSUID (base62, s, custom epoch)
-- collate "C": base62 is mixed-case, and a RANGE partition on text compares under the column's
-- collation, which for en_US (this database's default) is not the bytewise order the bounds are
-- computed in. transmute refuses the default-collation column; tests/122 owns that refusal and the
-- random-payload routing proof. The two values here carry a zero payload and ARE the month bounds, so
-- they could not have caught the misordering either way.
create table public.tt_ksuid (id text collate "C" primary key, body text);
insert into public.tt_ksuid (id, body) values
  (pgpm._ts_to_text_time(now() - interval '13 months', '', 27, 62, 's',
     '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz', 128, timestamptz '2014-05-13 16:53:20+00'), 'oldest'),
  (pgpm._ts_to_text_time(now() - interval '11 months', '', 27, 62, 's',
     '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz', 128, timestamptz '2014-05-13 16:53:20+00'), 'newest');

create temporary table _before_ksuid as select count(*) as n from public.tt_ksuid;

-- LIVENESS WITNESS: the drought is really present (every check below would pass on a fresh fixture).
select cmp_ok(
  now() - (select max(pgpm._decode('text_time', id, '', 27, 62, 's',
     '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz', 128, timestamptz '2014-05-13 16:53:20+00')::timestamptz) from public.tt_ksuid),
  '>', interval '2 months',
  'KSUID: the newest backfilled row is well outside the 2-month (p_obtain x step) lookahead'
);

call pgpm.transmute('public.tt_ksuid', 'id', interval '1 month', p_obtain => 2,
  p_tt_prefix => '', p_tt_width => 27, p_tt_radix => 62, p_tt_unit => 's',
  p_tt_alphabet => '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz',
  p_tt_discard_bits => 128, p_tt_epoch => timestamptz '2014-05-13 16:53:20+00');

select is(
  (select control_kind from pgpm.config where parent_table = 'public.tt_ksuid'::regclass),
  'text_time', 'KSUID: config: control_kind = text_time'
);
select is(
  (select count(*) from public.tt_ksuid)::bigint, (select n from _before_ksuid)::bigint,
  'KSUID: row count conserved across the migration'
);

select pgpm.resume('public.tt_ksuid');
call pgpm.maintain('public.tt_ksuid');

select ok(
  exists (select 1 from pgpm.part where parent_table = 'public.tt_ksuid'::regclass and attached
            and lo::timestamptz <= now() and hi::timestamptz > now()),
  'KSUID: a partition covers now() after one maintenance tick, despite an 11-month-stale frontier'
);
select ok(
  pgpm._frontier_native('public.tt_ksuid'::regclass)::timestamptz >= now(),
  'KSUID: the frontier obtain measures by is at or past now(), not the 11-month-stale data maximum'
);
select ok(
  exists (select 1 from pgpm.part p where p.parent_table = 'public.tt_ksuid'::regclass and p.attached
            and p.lo::timestamptz <= now() + interval '1 month' and p.hi::timestamptz > now() + interval '1 month'
            and p.lo::timestamptz >= (select m.hi::timestamptz from pgpm.part m
                                       join pgpm.config c on c.parent_table = m.parent_table and c.monolith_oid = m.child_oid
                                      where m.parent_table = p.parent_table)),
  'KSUID: a forward partition past the monolith covers now() + 1 month, inside the 2-month lookahead'
);
select lives_ok(
  $$ insert into public.tt_ksuid (id, body) values
       (pgpm._ts_to_text_time(now(), '', 27, 62, 's',
          '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz', 128, timestamptz '2014-05-13 16:53:20+00'),
        'live') $$,
  'KSUID: a fresh row stamped at now() is accepted'
);

select * from finish();
