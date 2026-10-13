author:	dventimisupabase
association:	member
edited:	false
status:	none
--
Re-found in adversarial review pass 7 (pinned `4060f6b`), classified **known and open** against this issue by the verifier: F4-01. Recorded here with the built reproduction(s); not counted as a new finding. Each reproduction fails on `4060f6b` and must pass on the commit that closes this issue (its `LIVENESS:` lines prove the fixture reached the state). Pass record: `docs/reviews/2026-10-02-pass7.md`.

### F4-01 (finder F4, `pgpm_core/install.sql:2128`, lens: fresh surface, claimed tier 2)

**Scenario:** #788 moved _next_archive_chunk off bare ::text but _crossing_keys still renders a timestamptz referencing key with ::text; under DateStyle SQL/Postgres in a zone with an ambiguous abbreviation (Asia/Kolkata 'IST' parses as +02) retire()'s crossing DELETE matches nothing, the FK's declared ON DELETE CASCADE is never applied, retain_crossing logs '0 row(s) deleted' and the dispatched DETACH CONCURRENTLY can never succeed, so the partition is never retired; the key should be read through pgpm._ts_text so the DELETE removes the referenced row

**Verifier:** Same function and same mechanism as #814's first bullet: _crossing_keys renders the referencing FK column with bare ::text (pristine install.sql:2128, array_agg(distinct %I::text)) and retire's crossing DELETE (2496) parses it back with %L::text[]::<type>[] in the same session, so a session setting leaks into compared text (#788's class). #814 records it as an unverified fixer observation. The claim adds a built reproduction that reaches it on the pristine tree unchanged (5 LIVENESS checks pass, 3 defect checks fail) and a consequence: Asia/Kolkata with DateStyle 'SQL, MDY' renders 'IST', which parses as +02, so the DELETE matches nothing, the declared ON DELETE CASCADE is not applied, retain_crossing logs '0 row(s) deleted', and the dispatched DETACH CONCURRENTLY can never succeed, so the partition is never retired (Tier 2 by consequence). The finder's repro.sql was used as-is; no rebuild.

<details><summary>Reproduction <code>repro.sql</code> (install: pgpm_core/install.sql)</summary>

```sql
-- retire()'s crossing step (_crossing_keys) reads the referencing control values back with a bare
-- ::text, which under a DateStyle that renders zone abbreviations (SQL, Postgres) does not round-trip
-- (#788's class): Asia/Kolkata renders 'IST', which PostgreSQL < 18 parses as Israel (+02). The DELETE
-- that is meant to apply the FK's declared ON DELETE then matches nothing, the referencing rows stay,
-- and the dispatched DETACH CONCURRENTLY can never succeed, so the partition is never retired.
--
-- Fixture: a time grid of 1-second cells, retain 1 second. The doomed cell holds two rows (id 10,
-- referenced by ref 100 ON DELETE CASCADE, and id 11, unreferenced); a later, kept cell holds id 20,
-- referenced by ref 200. After retire() the declared CASCADE must have removed ref 100 and id 10,
-- and nothing else.
create extension if not exists pgtap;
set client_min_messages = warning;
set timezone = 'UTC';
select plan(8);

-- stand-in for pg_cron (only the postgres database has it on the harness), as tests/194 and 204 do
create schema cron;
create table cron.job (jobid bigint primary key, jobname text, database text, command text);
create function cron.alter_job(job_id bigint, schedule text default null, command text default null,
                               database text default null, username text default null, active boolean default null)
returns void language sql as $$
  update cron.job set command = coalesce(alter_job.command, job.command) where jobid = job_id
$$;
insert into cron.job values (1, 'pgpm_detach', current_database(), 'select 1');

create table public.ck (id bigint, created_at timestamptz, payload text, primary key (id, created_at));
insert into public.ck values (1, now(), 'seed');
call pgpm.transmute('public.ck', 'created_at', '1 second'::interval, p_obtain => 30,
                    p_retain => '1 second'::interval, p_paused => false);

select lo::timestamptz as mono_lo from pgpm.part where parent_table = 'public.ck'::regclass
 order by lo::timestamptz limit 1 \gset
select child_name as doomed, lo as d_lo, hi as d_hi from pgpm.part
 where parent_table = 'public.ck'::regclass and lo::timestamptz = :'mono_lo'::timestamptz + interval '2 seconds' \gset

insert into public.ck values
  (10, :'mono_lo'::timestamptz + interval '2.5 seconds', 'doomed, referenced'),
  (11, :'mono_lo'::timestamptz + interval '2.25 seconds', 'doomed, unreferenced'),
  (20, :'mono_lo'::timestamptz + interval '25.5 seconds', 'kept, referenced');
create table public.ck_ref (id bigint primary key, ck_id bigint, ck_at timestamptz,
  foreign key (ck_id, ck_at) references public.ck (id, created_at) on delete cascade);
insert into public.ck_ref values
  (100, 10, :'mono_lo'::timestamptz + interval '2.5 seconds'),
  (200, 20, :'mono_lo'::timestamptz + interval '25.5 seconds');

select pg_sleep(6);   -- the doomed cell's hi (mono_lo + 3 s) is now at least a second behind the clock

-- the session a tick may run in: a zone whose abbreviation is ambiguous, and an abbreviating DateStyle
set timezone = 'Asia/Kolkata';
set datestyle = 'SQL, MDY';

select ok(not pgpm._native_gt('time', :'d_hi', (select pgpm._retain_boundary(c) from pgpm.config c where parent_table = 'public.ck'::regclass)),
  'LIVENESS: the doomed cell is wholly past the retention horizon');
select ok((select array_length(pgpm._crossing_keys('public.ck', :'d_lo', :'d_hi'), 1)) = 1,
  'LIVENESS: exactly one referencing key crosses the doomed cell');

select is(pgpm.retire('public.ck', :'doomed'), false, 'LIVENESS: retire() takes the referenced path (dispatch, drop on a later call)');
select is((select command from cron.job where jobname = 'pgpm_detach'),
  format('alter table public.ck detach partition public.%I concurrently', :'doomed'),
  'LIVENESS: retire() reached the dispatch, so the crossing step ran before it');
select ok(exists (select 1 from pgpm.log where parent_table = 'public.ck'::regclass and action = 'retain_crossing' and lo = :'d_lo'),
  'LIVENESS: the crossing step logged retain_crossing for the doomed cell');

-- the defect checks
select is((select array_agg(id order by id) from public.ck_ref), array[200]::bigint[],
  'the declared ON DELETE CASCADE removed exactly ref 100, which pointed into the doomed cell');
select is((select array_agg(id order by id) from public.ck), array[1, 11, 20]::bigint[],
  'the crossing DELETE removed exactly the referenced doomed row (id 10)');
select is((select method from pgpm.log where parent_table = 'public.ck'::regclass and action = 'retain_crossing' and lo = :'d_lo'),
  '1 referenced key(s), 1 row(s) deleted to honour the declared ON DELETE',
  'retain_crossing reports the one row it deleted');

select * from finish();
```

</details>

--
author:	dventimisupabase
association:	member
edited:	false
status:	none
--
Closure evidence from the pass-7 fix phase for the bullets pass 7 reproduced on this issue. Fix: PR #864 (merged). Each reproduction below was re-run against `main` at `9f2efa6` by `scripts/review/classify_claims.py` in a fresh database, the same harness that verified it on the pinned commit.

| claim | result | note |
|---|---|---|
| F4-01 | passes | reproduction no longer fails on `9f2efa6` (PR #864) |

Acceptance in the tree:
- F4-01 (PR #864): `tests/231_crossing_keys_datestyle_test.sql` (pgTAP), guard `bench/crossing_keys_datestyle.sh`, mutation(s) `crossing_keys_bare_text` proven to be caught by `./test.sh discriminate`.

Bullets of this issue that pass 7 did not reproduce are untouched by this phase; the verification pass before the pass-8 pin (see `docs/adversarial-review.md`, "The backlog is verified before the pin") decides whether anything is left here.

--
author:	dventimisupabase
association:	member
edited:	false
status:	none
--
Re-found in adversarial review pass 12 (pinned `bd55f840`), classified **known and open** against this issue by the verifier: F19-03. Recorded here with the built reproduction(s); not counted as a new finding. Each reproduction fails on `bd55f840` and must pass on the commit that closes this issue (its `LIVENESS:` lines prove the fixture reached the state). Pass record: `docs/reviews/2026-10-12-pass12.md`.

### F19-03 (finder F19, `pgpm_archive/install.sql:2763`, lens: time and zones, claimed tier 3)

**Scenario:** In one direct strategy call the range read, the empty-range check and the recorded-chunk check parse p_lo under the session's DateStyle while archive._object_stem parses it under its pinned 'ISO, MDY', so from a 'SQL, DMY' session '02/01/2024 00:00:00+00' archives the 2 January rows under the 1 February chunk's key; the object should be keyed by the instant the call read (or the spelling refused).

**Verifier:** Reproduces on both trees (liveness 1-4 pass on pristine, 5-7 fail: the Jan 2 row is PUT at f19d.ev_2024020100000000). Same mechanism as #814's open bullet 'pgpm_archive/install.sql:2445: the S3 key's time label is built from p_lo::timestamptz::text, so the same chunk gets a different key from sessions with a different DateStyle or zone': line 2445 at pass 6 (ae5dddc) is archive._object_stem with the identical set datestyle = 'ISO, MDY' pin, so the only way that bullet holds is the stem parsing p_lo under its pinned DateStyle while the session (range read, empty-range and recorded-chunk checks) parses it under its own, which is this claim. The bullet is neither struck nor marked fixed. Were it not open, it would be Tier 3: docs/reference.md says the stem is the chunk's lo and the key does not depend on the session.

<details><summary>Reproduction <code>repro.sql</code> (install: tests/archive/fixtures.sql, pgpm_core/install.sql, pgpm_archive/install.sql)</summary>

```sql
-- A direct strategy call reads its range under the SESSION's DateStyle (archive._refuse_empty_range,
-- pgpm._encode in archive._encode_upload_ndjson_single, archive._refuse_recorded_chunk_overwrite all
-- parse p_lo there) but names its object by archive._object_stem, which parses the same p_lo under its
-- own pinned 'ISO, MDY'. Under DateStyle 'SQL, DMY' the lo '02/01/2024 00:00:00+00' is read as 2 January
-- (the rows the object holds) and keyed 2024020100000000 (1 February): the object's name misstates its
-- contents, and it sits at the key the real 1 February chunk is archived to.
create extension if not exists pgtap;
select plan(7);

create schema f19d;
create table f19d.ev (ts timestamptz not null, payload text not null, primary key (ts, payload));
insert into f19d.ev values ('2024-01-02 12:00:00+00', 'jan2'), ('2024-02-01 12:00:00+00', 'feb1');
call pgpm.transmute('f19d.ev', 'ts', interval '1 day', p_paused => true);
select pgpm.obtain('f19d.ev');
select 'f19-03-' || current_database() || '/' as p \gset
select archive.configure('f19d.ev', 'archive-test-bucket', p_endpoint => 'http://minio:9000', p_prefix => :'p');

create function f19d.req(p_method text, p_key text) returns http_response language sql as $$
  select archive.s3_signed_request(p_method, 'http://minio:9000', 'archive-test-bucket', 'us-east-1', p_key, '',
                                   'text/plain', '', 'minioadmin', 'minioadmin') $$;
-- the strategy's s3_key and rows_archived, or the error it raised
create function f19d.try(p_lo text, p_hi text) returns text language plpgsql as $$
declare r pgpm.archive_result;
begin
  r := pgpm.archive_to_s3_ndjson('f19d.ev', null, p_lo, p_hi);
  return r.s3_key || ' rows=' || coalesce(r.rows_archived::text, 'null');
exception when others then return 'ERR: ' || sqlerrm;
end $$;

set datestyle = 'SQL, DMY';
select is(pgpm._ts_text('02/01/2024 00:00:00+00'::timestamptz), '2024-01-02 00:00:00+00',
  'LIVENESS: under DateStyle SQL, DMY the session reads 02/01/2024 as 2 January');
select is((select string_agg(payload, ',') from f19d.ev where ts >= '02/01/2024 00:00:00+00' and ts < '03/01/2024 00:00:00+00'),
  'jan2', 'LIVENESS: the range [02/01/2024, 03/01/2024) as this session reads it holds the row jan2 alone');
select archive._object_stem('time', pgpm._ts_text('02/01/2024 00:00:00+00'::timestamptz)) as stem_read \gset
select is(:'stem_read'::text, '2024010200000000', 'LIVENESS: the stem of the instant the session reads is 2 January');

select f19d.try('02/01/2024 00:00:00+00', '03/01/2024 00:00:00+00') as result \gset
select alike(:'result'::text, '% rows=1', 'LIVENESS: the strategy archived one row of that range (or refused the spelling)')
 where not :'result' like 'ERR:%'
union all select pass('LIVENESS: the strategy refused the spelling') where :'result' like 'ERR:%';

-- the defect: the object is keyed by another day than the one the call read
select ok(:'result'::text like 'ERR:%' or :'result'::text like :'p'::text || 'f19d.ev_' || :'stem_read'::text || '.ndjson rows=%',
  format('the chunk read as [2024-01-02, 2024-01-03) is keyed by the stem of 2 January, not 1 February (got %s)', :'result'));
select is((f19d.req('GET', :'p' || 'f19d.ev_2024020100000000.ndjson')).status, 404,
  'no object holding the 2 January row lands at the 1 February chunk''s key');
select is((f19d.req('GET', :'p' || 'f19d.ev_2024010200000000.ndjson')).content, '{"ts":"2024-01-02T12:00:00+00:00","payload":"jan2"}',
  'the object at the 2 January key holds the row jan2')
 where not :'result' like 'ERR:%'
union all select pass('fixture: refused, nothing to read back') where :'result' like 'ERR:%';
reset datestyle;
select (f19d.req('DELETE', :'p' || 'f19d.ev_2024020100000000.ndjson')).status as c1 \gset
select (f19d.req('DELETE', :'p' || 'f19d.ev_2024010200000000.ndjson')).status as c2 \gset

select * from finish();
```

</details>

--
