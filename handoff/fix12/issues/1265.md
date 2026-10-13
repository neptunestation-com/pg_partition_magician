# check_time_monotonic casts a naive timestamp column to timestamptz in the caller's session TimeZone (pass 12 RC8)

Tier: 3

Age: old | Lens: time and zones

Found in adversarial review pass 12 at `bd55f84021fc4173034d156a41bc91a3f882560d`, root-cause group RC8: F2-02.

## F2-02

- finder: F2
- location: `pgpm_core/install.sql:14298`
- lens: time and zones
- tier: 3
- scenario: check_time_monotonic casts a naive timestamp time column to timestamptz in the caller's session zone before comparing adjacent pairs, so a column whose values increase with the id (01:50, 02:30, 03:15 on 2026-03-08) reports fraction 0.5 from an America/New_York session (02:30 is in the spring-forward gap and casts past 03:15 EDT) and 1.0 from UTC; it should compare the column's own values (or cast in one fixed zone) so the documented fraction of non-decreasing pairs does not depend on who runs it
- root cause (verifier): check_time_monotonic compares %I::timestamptz, casting a naive timestamp column in the caller's session TimeZone, so wall times in that zone's spring-forward gap reorder (02:30 reads as 03:30 EDT, past 03:15) and the fraction docs/reference.md defines as 'adjacent pairs (ordered by the id) whose time is non-decreasing' depends on who runs it (1.0 from UTC, 0.5 from America/New_York; a decreasing pair across the gap reads as non-decreasing the same way). Reproduced on pristine and review by the classifier; not documented as zone-dependent; distinct from #1144 bullet 2 (check_text_time/check_uuidv7 plausibility floor) and #1030 (archive IMMUTABLE helpers) by mechanism. Tier 3: a documented contract not kept, in an advisory heuristic, without loss.

Reproduction: `repro.sql`, the finder's, run unchanged by the verifier.

```sql
-- F2-02: check_time_monotonic casts the time column to timestamptz in the SESSION's zone before comparing,
-- so a naive timestamp column whose values are non-decreasing in id order is reported as decreasing when a
-- pair straddles a spring-forward gap of the caller's zone: '02:30' (a wall time New York skipped on
-- 2026-03-08) reads as 03:30 EDT, after '03:15' EDT. The documented result is the fraction of adjacent pairs
-- whose time is non-decreasing; the column's own values are, and the answer changes with the session's zone.
create extension if not exists pgtap;
set client_min_messages = warning;
select plan(4);
create table public.mono (id bigint primary key, t timestamp not null);
insert into public.mono values (1, '2026-03-08 01:50:00'), (2, '2026-03-08 02:30:00'), (3, '2026-03-08 03:15:00');

select is((select string_agg(id::text || '=' || t::text, ',' order by id) from public.mono),
  '1=2026-03-08 01:50:00,2=2026-03-08 02:30:00,3=2026-03-08 03:15:00',
  'LIVENESS: three rows whose naive time increases with the id');
set timezone = 'UTC';
select is((select fraction from pgpm.check_time_monotonic('public.mono', 'id', 't')), 1.0000::numeric,
  'LIVENESS: from a UTC session both adjacent pairs are reported non-decreasing');
set timezone = 'America/New_York';
select ok((timestamp '2026-03-08 02:30:00')::timestamptz > (timestamp '2026-03-08 03:15:00')::timestamptz,
  'LIVENESS: in America/New_York 02:30 on 2026-03-08 is inside the spring-forward gap and casts past 03:15');
select is((select fraction from pgpm.check_time_monotonic('public.mono', 'id', 't')), 1.0000::numeric,
  'from an America/New_York session the same column is reported fully monotonic too');
select * from finish();
```

Acceptance: the reproduction(s) above fail on bd55f84021fc4173034d156a41bc91a3f882560d and must pass on the fixing commit; the fix carries a bench/ guard and a bench/mutations entry proven by ./test.sh discriminate.



