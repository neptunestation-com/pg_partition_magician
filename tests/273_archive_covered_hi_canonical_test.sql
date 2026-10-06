-- The archive ledger records the instant the contract check accepted, in canonical text (issue #977).
--
-- THE BUG. _archive_step held an archive_fn's covered_hi to its chunk (#454) with a ::timestamptz parse in
-- the TICK's session, then wrote the strategy's text verbatim into pgpm.archive_ledger.hi. An offset-less
-- value is a valid timestamptz input, so it was checked as one instant and stored as text that names a
-- different one in every other zone. A strategy that archived up to three hours short of the partition's hi
-- and said so without an offset passed the check in a UTC tick (short of hi, so the drop gate stayed shut);
-- retire() run from an America/New_York session re-read the same text four or five hours later, past the
-- partition's hi, judged the partition fully covered and dropped it with the rows the strategy was never
-- handed. That breaks the #500 rule _ts_text's comment states: every native time value pgpm stores, the
-- archive ledger's bounds named, reads the same instant from every session.
--
-- THE CONTRACT. The ledger row holds the canonical rendering (_ts_text) of the instant the check accepted,
-- so the coverage it records, and the drop gate it opens, mean the same in every session:
--   PART A  one tick in UTC records the strategy's first chunk; its hi is the instant the strategy archived
--           up to, canonically rendered, and from a New York session it still reads as that instant.
--   PART B  retire() from the New York session refuses the partly covered monolith, and the row the
--           strategy was never handed is still in the table (named, not counted).
--   PART C  LIVENESS of the gate: a tick from the New York session hands the strategy the rest, from where
--           the ledger honestly stands, and retires the monolith once every row went to the strategy.
--
-- ASYMMETRIC FIXTURE. Three rows: two archived by the first chunk ('early1' five hours old, 'early2' four)
-- and one past it ('late', one hour old), so a lost row and an extra one cannot cancel. The strategy records
-- every call it gets, so "what the strategy was handed" is read back by identity.
--
-- bench/archive_covered_hi_canonical.sh runs this file against bench/mutations/mutate.py's
-- archive_covered_hi_verbatim, which writes the strategy's text into the ledger verbatim again.
create extension if not exists pgtap;
set client_min_messages = warning;
set timezone = 'UTC';
set datestyle = 'ISO, MDY';

select plan(14);

create table public.ar273 (ts timestamptz not null, body text);
insert into public.ar273 values
  (now() - interval '5 hours', 'early1'),
  (now() - interval '4 hours', 'early2'),
  (now() - interval '1 hour', 'late');
create table public.ar273_archived (ts timestamptz, body text);
create table public.ar273_calls (n serial primary key, p_lo text, p_hi text, covered_text text, covered_at timestamptz);

-- The first call for a partition archives [lo, hi - 3 hours) and says how far it got as UTC wall-clock text
-- WITHOUT an offset; a later call archives the rest of its chunk and returns the p_hi it was handed.
create function public.ar273_strategy(p_parent regclass, p_child name, p_lo text, p_hi text)
returns pgpm.archive_result language plpgsql as $$
declare v pgpm.archive_result; v_cov timestamptz; v_text text;
begin
  if not exists (select 1 from public.ar273_calls) then
    v_cov := p_hi::timestamptz - interval '3 hours';
    v_text := to_char(v_cov at time zone 'UTC', 'YYYY-MM-DD HH24:MI:SS.US');
  else
    v_cov := p_hi::timestamptz;
    v_text := p_hi;
  end if;
  insert into public.ar273_archived
    select ts, body from public.ar273 where ts >= p_lo::timestamptz and ts < v_cov;
  insert into public.ar273_calls (p_lo, p_hi, covered_text, covered_at) values (p_lo, p_hi, v_text, v_cov);
  v.covered_hi := v_text;
  v.rows_archived := (select count(*) from public.ar273_archived where ts >= p_lo::timestamptz and ts < v_cov);
  return v;
end $$;

call pgpm.transmute('public.ar273', 'ts', interval '1 second', 3, p_retain => interval '0 seconds', p_paused => false);
select pgpm.set_archive_fn('public.ar273', 'public.ar273_strategy(regclass, name, text, text)');
select child_name as mono from pgpm.part
 where parent_table = 'public.ar273'::regclass and attached order by lo::timestamptz limit 1 \gset
select hi as mono_hi from pgpm.part where parent_table = 'public.ar273'::regclass and child_name = :'mono' \gset

-- ==================== (A) a UTC tick records the first chunk, canonically ====================
select pg_sleep(2.5);   -- the monolith ages past a retain of 0 on its 1 s grid
call pgpm.maintain('public.ar273');

select is((select array_agg(body order by ts) from public.ar273_archived), array['early1', 'early2'],
  'LIVENESS: the UTC tick handed the strategy the first chunk, which archived early1 and early2');
select is((select count(*)::int from public.ar273_calls), 1,
  'LIVENESS: the strategy was called once, for the monolith''s first chunk');
select ok(exists (select 1 from pgpm.part where parent_table = 'public.ar273'::regclass and child_name = :'mono'),
  'LIVENESS: in the UTC tick retain kept the monolith (coverage three hours short of its hi)');
select is((select hi from pgpm.archive_ledger where parent_table = 'public.ar273'::regclass and child_name = :'mono'),
          (select pgpm._ts_text(covered_at) from public.ar273_calls where n = 1),
  'the ledger''s hi is the canonical text of the instant the strategy archived up to, not its offset-less text');

set timezone = 'America/New_York';
select ok((select covered_text::timestamptz from public.ar273_calls where n = 1) > :'mono_hi'::timestamptz,
  'LIVENESS: in this session the strategy''s own offset-less text reads past the monolith''s hi');
select is((select hi::timestamptz from pgpm.archive_ledger where parent_table = 'public.ar273'::regclass and child_name = :'mono'),
          (select covered_at from public.ar273_calls where n = 1),
  'from a New York session the ledger''s hi still reads as the instant that was checked');
select ok(not pgpm._archive_fully_covered('public.ar273', :'mono'),
  'from a New York session the monolith is not fully covered');

-- ==================== (B) retire() from New York keeps the unarchived row ====================
select ok(not pgpm.retire('public.ar273', :'mono'),
  'retire() from a New York session does not drop the partly archived monolith');
set timezone = 'UTC';
select is((select array_agg(body order by ts) from public.ar273), array['early1', 'early2', 'late'],
  'every row, late included, is still readable through the parent');
select is((select array_agg(body order by ts) from public.ar273_archived), array['early1', 'early2'],
  'and late was never handed to the strategy');

-- ==================== (C) the rest is archived from where the ledger stands, then retired ====================
set timezone = 'America/New_York';
call pgpm.maintain('public.ar273');
set timezone = 'UTC';

select is((select p_lo::timestamptz from public.ar273_calls where n = 2), (select covered_at from public.ar273_calls where n = 1),
  'the New York tick handed the strategy the rest of the monolith, from the instant the first chunk reached');
select is((select array_agg(body order by ts) from public.ar273_archived), array['early1', 'early2', 'late'],
  'and the strategy archived late');
select ok(exists (select 1 from pgpm.log where parent_table = 'public.ar273'::regclass and action = 'retain_drop'
                   and hi = :'mono_hi'),   -- retire() logs the partition's own pgpm.part.hi
  'LIVENESS: the monolith was retired once every row had gone to the strategy');
select ok(not exists (select 1 from pgpm.part where parent_table = 'public.ar273'::regclass and child_name = :'mono'),
  'the monolith is gone, now that the ledger covers it');

select * from finish();
