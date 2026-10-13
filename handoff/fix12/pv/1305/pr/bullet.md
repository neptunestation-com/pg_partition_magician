# _over_retired_chunks reads a legacy offset-less retired ledger bound in the caller's session TimeZone (pass 12 RC7)

Tier: 3

Age: old | Lens: time and zones

Found in adversarial review pass 12 at `bd55f84021fc4173034d156a41bc91a3f882560d`, root-cause group RC7: F15-02.

## F15-02

- finder: F15
- location: `pgpm_core/install.sql:5180`
- lens: time and zones
- tier: 3
- scenario: _over_retired_chunks casts an offset-less retired ledger bound (an older install's row) with ::timestamptz in the caller's TimeZone, so a partition held over a retired chunk from a UTC session (pg_cron's maintain) is not held from an Asia/Kolkata session (a hand _archive_step or retain()), which then archives it over the retired range; it should read such a bound in the grid's registered partition_tz and give every session the same answer, as its header promises
- root cause (verifier): _over_retired_chunks casts a legacy offset-less retired ledger hi (a pre-#977 strategy's covered_hi stored verbatim, a state the #977 and _native_order_key comments acknowledge and no upgrade normalises) with ::timestamptz in the caller's TimeZone, so the #1141 hold depends on the session: held from UTC, not held from Asia/Kolkata, which breaks tests/317's stated contract (same answer from any session's TimeZone); Tier 3 because in the reproduced shape the unheld partition is archived under its own lo/key (acts where it should hold, nothing overwritten). Rebuilt: the original also wrote the chunk's lo offset-less, which no install writes (lo is always part.lo or the rendered max(hi)); the rebuild gives lo pgpm's canonical text with a GUARD and still fails on pristine with every liveness passing. Not known-open (#1030 bullet 4 is the IMMUTABLE labels, struck).

Reproduction: `repro.verified.sql`, the verifier's rebuilt reproduction. It supersedes the finder's `repro.sql`, which the verifier had to change before it proved the defect.

```sql
-- F15-02 (verifier's rebuild: the retired chunk's lo carries an offset, as every lo pgpm writes does; only the
-- hi is offset-less, the shape a pre-#977 install left from a strategy's covered_hi).
-- F15-02: pgpm._over_retired_chunks reads an offset-less retired ledger bound in the CALLER's TimeZone, so the
-- same call holds a partition from a UTC session (pg_cron's maintain) and not from an Asia/Kolkata one (a hand
-- _archive_step / retain()), or the reverse. Its own header (tests/317) promises the same answer "from any
-- session's TimeZone and DateStyle". Fixture: the grid is registered in UTC; one retired chunk, recorded
-- without an offset (a pre-#500 ledger row, or a strategy's offset-less covered_hi kept by an older install),
-- ends 3 hours past the first attached partition's lo on the UTC wall clock: 2.5 hours BEFORE it in Kolkata.
create extension if not exists pgtap;
set client_min_messages = warning;
set timezone = 'UTC';
select plan(6);

create schema f15b;
create table f15b.t (id bigint generated always as identity, ts timestamptz not null, primary key (id, ts));
insert into f15b.t (ts) select timestamptz '2026-01-05 00:00:00+00' + g * interval '1 hour' from generate_series(1, 90) g;
call pgpm.transmute('f15b.t', 'ts', interval '1 month', p_obtain => 2, p_paused => true);
select pgpm.set_archive_fn('f15b.t', 'pgpm._archive_noop(regclass,name,text,text)'::regprocedure);

select child_name as p0, lo as p0_lo from pgpm.part where parent_table = 'f15b.t'::regclass and attached
 order by lo::timestamptz limit 1 \gset
-- the chunk: [lo - 4h, lo + 3h). Its lo is pgpm's canonical text, with an offset (every chunk lo an install has
-- written: the child's lo or the rendered max(hi)); only its hi, a pre-#977 strategy's covered_hi stored verbatim,
-- is UTC wall-clock text with no offset.
select pgpm._ts_text(:'p0_lo'::timestamptz - interval '4 hours') as c_lo,
       to_char((:'p0_lo'::timestamptz at time zone 'UTC') + interval '3 hours', 'YYYY-MM-DD HH24:MI:SS') as c_hi \gset
insert into pgpm.archive_ledger (parent_table, lo, hi, child_name, s3_key, retired_at, child_oid)
values ('f15b.t', :'c_lo', :'c_hi', 'gone_f15', 'obj/f15', now(), 4290000099);

select is((select partition_tz from pgpm.config where parent_table = 'f15b.t'::regclass), 'UTC',
  'LIVENESS: the grid is registered in UTC');
select ok(pgpm._native_order_key(:'c_lo') is not null,
  'GUARD: the retired chunk''s lo carries an offset (pgpm''s canonical text)');
select ok(:'c_hi' !~ '[+-][0-9]{2}(:[0-9]{2})?$' and pgpm._native_order_key(:'c_hi') is null,
  'LIVENESS: the retired chunk''s hi carries no offset (no order key), the shape an older ledger row has');
select is((select string_agg(child_name::text, ',') from pgpm._over_retired_chunks('f15b.t')), :'p0',
  'LIVENESS: from a UTC session the first attached partition is held over the retired chunk');

set timezone = 'Asia/Kolkata';
select ok(:'c_hi'::timestamptz < :'p0_lo'::timestamptz,
  'LIVENESS: read in Asia/Kolkata the same chunk text ends before that partition''s lo');
select is((select string_agg(child_name::text, ',') from pgpm._over_retired_chunks('f15b.t')), :'p0',
  'from an Asia/Kolkata session the same call holds the same partition (it does not: the offset-less bound is read in the session zone, not the grid''s)');
set timezone = 'UTC';

select * from finish();
```

Acceptance: the reproduction(s) above fail on bd55f84021fc4173034d156a41bc91a3f882560d and must pass on the fixing commit; the fix carries a bench/ guard and a bench/mutations entry proven by ./test.sh discriminate.



