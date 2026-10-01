-- pgpm.schedule() REFUSES, by name, in a database without pg_cron (review pass 5 seed S3).
--
-- schedule() is the deliberate way to turn the scheduled lifecycle on, so an operator who calls it and gets
-- no error believes maintenance is scheduled. Where pg_cron is not installed nothing can be, and the only
-- honest answer is the documented exception naming pg_cron and the by-hand alternative. A schedule() that
-- returned null instead would leave the grid un-extended until the first late write is rejected (no DEFAULT
-- partition since #288). tests/31 runs where pg_cron lives and so covers only the happy path; until this file
-- nothing pinned the refusal (bench/upgrade_from_release.sh only mentions the message).
--
-- WHERE THIS RUNS. pg_cron can only be created in the database named by cron.database_name (postgres on the
-- test images), so the per-file clone test.sh gives every file but 31 and 78 is exactly a database without
-- it. The first assertion witnesses that, so the refusal below is known to be about pg_cron's absence and
-- not about anything else.
--
-- Asymmetric on purpose: unschedule() in the same database is NOT refused (there is nothing to unschedule,
-- and it says so with 0), so a schedule() that raised for some unrelated reason would still be told apart
-- from one that judged pg_cron and refused.
-- bench/schedule_without_pg_cron.sh runs this file against a mutant whose schedule() returns null when
-- pg_cron is absent (schedule_without_cron_silent), so it is also required to FAIL there.
create extension if not exists pgtap;
select plan(5);

select ok(not exists (select 1 from pg_extension where extname = 'pg_cron')
          and not exists (select 1 from pg_namespace where nspname = 'cron'),
  'LIVENESS: pg_cron is not installed in this database (no extension, no cron schema)');
select has_function('pgpm', 'schedule', array['text', 'text'],
  'LIVENESS: pgpm.schedule(text, text) is installed here');

select throws_like($$ select pgpm.schedule() $$,
  'pg_partition_magician: pg_cron is not installed in this database; enable it (create extension pg_cron) to schedule maintenance, or call pgpm.maintain_all() and pgpm.maintain_obtain_all() by hand',
  'schedule() with its defaults refuses, naming pg_cron and the by-hand alternative');
select throws_like($$ select pgpm.schedule('*/5 * * * *', '*/10 * * * *') $$,
  'pg_partition_magician: pg_cron is not installed in this database;%',
  'schedule() with explicit cadences refuses the same way');

select is(pgpm.unschedule(), 0, 'unschedule() in the same database is not refused: nothing to unschedule, 0');

select * from finish();
