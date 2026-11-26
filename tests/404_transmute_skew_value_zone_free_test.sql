-- Issue #1414 bullet 2: transmute's skew refusal names, for a uuidv7 or text_time key, the value that encodes its limit
-- (now() plus one partition step plus one hour), so that the operator deletes the rows above it. It built that value
-- by encoding the limit's ::text, which follows the session's DateStyle and TimeZone, and the encode reads the text
-- back. Under DateStyle 'SQL, DMY' in Asia/Kolkata the zone renders as the abbreviation IST, which the default
-- abbreviations read as Israel time (PostgreSQL 15 to 17, measured on 17), so the value named sat three and a half
-- hours past the limit and a delete above it kept rows the refusal is about. The limit is now encoded from
-- pgpm._ts_text, whose ISO text carries a numeric offset.
--
-- THE CONTRACT. The value the refusal names decodes to the limit, to the millisecond a uuidv7 keeps.
-- LIVENESS. The session really does render the limit in a text that reads back as another instant (skipped where the
-- server reads IST in the session's own zone), and the refusal under test is the one that fired.
--
-- bench/transmute_skew_value_zone_free.sh runs this file against bench/mutations/mutate.py's
-- transmute_skew_value_from_session_text.
set client_min_messages = warning;
create extension if not exists pgtap;
select plan(4);

create table public.sk404 (id uuid primary key, body text);
insert into public.sk404 select pgpm._ts_to_uuid(now() - (g || ' hours')::interval), 'ok' from generate_series(1, 50) g;
insert into public.sk404 values (pgpm._ts_to_uuid(now() + interval '30 days'), 'skewed');

create temporary table sk404_out (premise_rt interval, state text, msg text, named_ts timestamptz, lim timestamptz);
do $$
declare v_msg text; v_state text; v_lim timestamptz;
begin
  perform set_config('TimeZone', 'Asia/Kolkata', true);
  perform set_config('DateStyle', 'SQL, DMY', true);
  v_lim := now() + interval '1 day' + interval '1 hour';
  begin
    call pgpm.transmute('public.sk404', 'id', interval '1 day', p_obtain => 2);
    v_state := 'none';
  exception when others then
    get stacked diagnostics v_msg = message_text, v_state = returned_sqlstate;
  end;
  insert into sk404_out values ((v_lim::text)::timestamptz - v_lim, v_state, v_msg,
    pgpm._uuid_to_ts(substring(v_msg from 'sorts above ([0-9a-f-]{36}) \(the value encoding')::uuid), v_lim);
end $$;

select case when (select premise_rt <> interval '0' from sk404_out)
            then ok(true, 'LIVENESS: under SQL, DMY in Asia/Kolkata the limit''s own text reads back '
                          || (select premise_rt from sk404_out) || ' off, the shift the named value inherited')
            else skip('this server reads IST in the session''s own zone, so the limit''s text round-trips here', 1) end;
select ok((select state = 'P0001' and msg like '%sorts above % (the value encoding now() + one step + one hour%' from sk404_out),
  'LIVENESS: the uuidv7 skew refusal fired: ' || (select state || ' ' || left(coalesce(msg, ''), 120) from sk404_out));
select ok((select abs(extract(epoch from named_ts - lim)) <= 0.002 from sk404_out),
  'the value the refusal names decodes to the limit (named '
  || (select coalesce((named_ts at time zone 'UTC')::text, 'none') || ', limit ' || (lim at time zone 'UTC')::text from sk404_out) || ' UTC)');
select ok(not exists (select 1 from pgpm.config where parent_table = 'public.sk404'::regclass),
  'GUARD: the refusal converted nothing');

select * from finish();
