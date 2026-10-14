-- A resumed text_time transmute refuses an encoding other than the one its recorded bound was written in
-- (issue #1270).
--
-- A failure between transmute's phases leaves a claim in pgpm.transmute_inflight and a validated
-- pgpm_monolith_bound CHECK on the table, and the documented remedy is to re-run transmute, which resumes
-- from that bound (#275) in its zone (#506), on a grid it lies on (#574), on the column it constrains
-- (#628). On a text_time key the CHECK's two literals are the bound ENCODED (p_tt_prefix, p_tt_width,
-- p_tt_radix, p_tt_unit, p_tt_alphabet, p_tt_discard_bits, p_tt_epoch), and the claim did not record the
-- encoding. A re-run with another one took the claim over, skipped phases 1 and 2 (a validated constraint
-- by that name exists), and attached the monolith with the bound encoded the NEW way: the CHECK does not
-- imply that partition bound, so the cutover's ATTACH scanned the whole table under ACCESS EXCLUSIVE and,
-- here, died raw on the rows outside it, after the bound and the claim had been committed.
--
-- The contract: the claim records the encoding, and a resume under another one is refused before anything
-- is committed, naming both; a resume under the SAME encoding resumes, however it is spelled (the epoch is
-- an instant, so another offset for it is the same encoding, and an alphabet left null is the default one
-- written out). The remedy the refusal names, transmute_abort and a re-run, is typed below and converts.
--
-- Fixture, twice (ttenc, ttabt): twenty classic-cuid-shaped ids (prefix 'c', 8 base-36 digits of
-- milliseconds since 1970, then a suffix) one hour apart back from now, and a referencing table holding ONE
-- of them. The re-run's epoch is one day earlier, which decodes every id one day later: still plausible
-- (the shape check samples them as recent), so nothing but the refusal stops it, and the ATTACH would fail
-- on the rows below the bound's lo encoded that way rather than pass.
--
-- The failing first conversions run in a dblink session (a committing procedure cannot run inside
-- throws_ok, and pg_prove runs this file under ON_ERROR_STOP). Each fails deterministically in the
-- cutover: this session holds ACCESS SHARE on the REFERENCING table, which the incoming-FK drop needs
-- ACCESS EXCLUSIVE on, while phases 1 and 2 touch only the table being converted and so commit the claim.
-- bench/transmute_resume_text_time_encoding.sh runs this file against a mutant with the refusal removed
-- (transmute_resume_any_encoding), so it is also required to FAIL there.
create extension if not exists pgtap;
create extension if not exists dblink;
select plan(21);
set timezone = 'UTC';

-- two tables in the same state: ttenc for the refusals and the same-encoding resume, ttabt for the remedy
create function pg_temp.mk(p_rel text) returns void language plpgsql as $f$
begin
  execute format('create table public.%I (id text collate "C" not null primary key, v int)', p_rel);
  execute format($i$insert into public.%I
    select pgpm._encode('text_time', pgpm._ts_text(now() - g * interval '1 hour'), 'c', 8, 36, 'ms', null, 0,
                        '1970-01-01 00:00:00+00', 'UTC') || 'x' || lpad(g::text, 4, '0'), g
      from generate_series(1, 20) g$i$, p_rel);
  execute format('create table public.%I (rid int primary key, id text collate "C" references public.%I)',
                 p_rel || '_ref', p_rel);
  execute format('insert into public.%I select 1, id from public.%I where v = 7', p_rel || '_ref', p_rel);
end $f$;
select pg_temp.mk('ttenc');
select pg_temp.mk('ttabt');

-- session A: phases 1 and 2 commit the bound and the claim, the cutover times out on the referencing
-- table, A ends. Once per table, with both referencing tables locked by this session.
select dblink_connect('a', 'dbname=' || current_database());
select dblink_exec('a', $c$ set timezone = 'UTC' $c$);
begin;
lock table public.ttenc_ref, public.ttabt_ref in access share mode;
select throws_ok(
  $$ select dblink_exec('a', $c$ call pgpm.transmute('public.ttenc', 'id', interval '1 day', p_obtain => 2,
                                                     p_incoming_fks => 'preserve', p_lock_timeout => '300ms',
                                                     p_tt_prefix => 'c', p_tt_width => 8, p_tt_radix => 36,
                                                     p_tt_unit => 'ms') $c$) $$,
  '55P03', NULL,
  'LIVENESS: the first conversion of ttenc fails in the cutover, on the lock this session holds on the referencing table');
select throws_ok(
  $$ select dblink_exec('a', $c$ call pgpm.transmute('public.ttabt', 'id', interval '1 day', p_obtain => 2,
                                                     p_incoming_fks => 'preserve', p_lock_timeout => '300ms',
                                                     p_tt_prefix => 'c', p_tt_width => 8, p_tt_radix => 36,
                                                     p_tt_unit => 'ms') $c$) $$,
  '55P03', NULL,
  'LIVENESS: and so does the first conversion of ttabt');
commit;
select dblink_disconnect('a');
select is((select text_time_encoding from pgpm.transmute_inflight where parent_table = 'public.ttenc'::regclass),
  '{"unit": "ms", "epoch": 0, "radix": 36, "width": 8, "prefix": "c", "alphabet": "0123456789abcdefghijklmnopqrstuvwxyz", "discard_bits": 0}'::jsonb,
  'the failed attempt''s claim records the encoding its bound was written in');
select is((select string_agg(k.relname || ' ' || c.convalidated, ', ' order by k.relname)
             from pg_constraint c join pg_class k on k.oid = c.conrelid
            where c.conname = 'pgpm_monolith_bound' and k.relname in ('ttenc', 'ttabt')),
  'ttabt true, ttenc true',
  'LIVENESS: each left a VALIDATED pgpm_monolith_bound CHECK, so a resume skips phases 1 and 2');
create temp table claim0 as
  select lo, hi, pg_get_constraintdef(c.oid) as chk
    from pgpm.transmute_inflight i, pg_constraint c
   where i.parent_table = 'public.ttenc'::regclass
     and c.conrelid = 'public.ttenc'::regclass and c.conname = 'pgpm_monolith_bound';
select ok(exists (select 1 from public.ttenc t
                   where t.id < pgpm._encode('text_time', (select lo from claim0), 'c', 8, 36, 'ms', null, 0,
                                             '1969-12-31 00:00:00+00', 'UTC')),
  'LIVENESS: some row lies below the bound''s lo encoded with the re-run''s epoch, so an ATTACH that way could not pass');

-- the first attempts' session has ended (tests/101's stand-in: its backend's exit is asynchronous)
update pgpm.transmute_inflight set owner_pid = null, owner_backend_start = null
 where parent_table in ('public.ttenc'::regclass, 'public.ttabt'::regclass);

-- a re-run with the epoch one day earlier: refused up front, naming both encodings and the remedy
select throws_like(
  $$ call pgpm.transmute('public.ttenc', 'id', interval '1 day', p_obtain => 2, p_incoming_fks => 'preserve',
                         p_tt_prefix => 'c', p_tt_width => 8, p_tt_radix => 36, p_tt_unit => 'ms',
                         p_tt_epoch => '1969-12-31 00:00:00+00') $$,
  '%cannot resume the transmute of ttenc with text_time encoding {%"epoch": -86400,%}: the bound [%) an earlier attempt recorded (and put in the pgpm_monolith_bound CHECK) is encoded with {%"epoch": 0,%}%transmute_abort(ttenc)%',
  'a resume under another p_tt_epoch is refused, naming both encodings and the remedy');
select is((select lo || ' ' || hi || ' ' || coalesce(owner_pid::text, 'no owner') from pgpm.transmute_inflight
            where parent_table = 'public.ttenc'::regclass),
  (select lo || ' ' || hi || ' no owner' from claim0),
  'the refusals left the claim exactly as it was: same bound, not taken over');
select is((select pg_get_constraintdef(oid) from pg_constraint
            where conrelid = 'public.ttenc'::regclass and conname = 'pgpm_monolith_bound'),
  (select chk from claim0), 'and the recorded bound on the table');
select is((select relkind::text from pg_class where oid = 'public.ttenc'::regclass), 'r', 'the table is still a plain table');
select ok(not exists (select 1 from pgpm.config where parent_table = 'public.ttenc'::regclass), 'nothing was registered');

-- the SAME encoding, spelled otherwise (the epoch at another offset, the default alphabet written out): resumes
call pgpm.transmute('public.ttenc', 'id', interval '1 day', p_obtain => 2, p_incoming_fks => 'preserve',
                    p_tt_prefix => 'c', p_tt_width => 8, p_tt_radix => 36, p_tt_unit => 'ms',
                    p_tt_alphabet => '0123456789abcdefghijklmnopqrstuvwxyz', p_tt_epoch => '1970-01-01 01:00:00+01');
select is((select relkind::text from pg_class where oid = 'public.ttenc'::regclass), 'p',
  'LIVENESS: the re-run in the same encoding completed the conversion');
select is((select count(*)::int from pgpm.log where parent_table = 'public.ttenc'::regclass and action = 'transmute_resume'), 1,
  'LIVENESS: it RESUMED on the recorded bound');
select is((select p.lo || ' ' || p.hi from pgpm.part p join claim0 c on p.lo = c.lo
            where p.parent_table = 'public.ttenc'::regclass and p.attached),
  (select lo || ' ' || hi from claim0), 'the monolith is the recorded bound');
select is((select array_agg(v order by v) from public.ttenc), (select array_agg(g order by g) from generate_series(1, 20) g),
  'rows 1..20 are all in the converted table');
select is((select string_agg(t.v::text, ' ') from public.ttenc_ref r join public.ttenc t using (id)), '7',
  'the referencing row survived the conversion and still references row 7');
select ok(not exists (select 1 from pgpm.transmute_inflight where parent_table = 'public.ttenc'::regclass),
  'the completed conversion released the claim');

-- the remedy the refusal names, typed: on ttabt, the re-run in the new epoch is refused the same way, and
-- after transmute_abort the same call converts the table fresh, in that encoding
select throws_like(
  $$ call pgpm.transmute('public.ttabt', 'id', interval '1 day', p_obtain => 2, p_incoming_fks => 'preserve',
                         p_tt_prefix => 'c', p_tt_width => 8, p_tt_radix => 36, p_tt_unit => 'ms',
                         p_tt_epoch => '1969-12-31 00:00:00+00') $$,
  '%cannot resume the transmute of ttabt with text_time encoding {%"epoch": -86400,%}%transmute_abort(ttabt)%',
  'ttabt: the resume in the new epoch is refused too');
select ok(pgpm.transmute_abort('public.ttabt'), 'the remedy: transmute_abort abandons the half-done conversion');
call pgpm.transmute('public.ttabt', 'id', interval '1 day', p_obtain => 2, p_incoming_fks => 'preserve',
                    p_tt_prefix => 'c', p_tt_width => 8, p_tt_radix => 36, p_tt_unit => 'ms',
                    p_tt_epoch => '1969-12-31 00:00:00+00');
select is((select k.relkind::text || ' ' || c.text_time_epoch from pg_class k, pgpm.config c
            where k.oid = 'public.ttabt'::regclass and c.parent_table = 'public.ttabt'::regclass),
  'p 1969-12-31 00:00:00+00', 'and the re-run then converts the table, registered in the new encoding');
select is((select count(*)::int from pgpm.log where parent_table = 'public.ttabt'::regclass and action = 'transmute_resume'), 0,
  'it started over rather than resuming');
select is((select array_agg(v order by v) from public.ttabt), (select array_agg(g order by g) from generate_series(1, 20) g),
  'rows 1..20 are all in ttabt');

select * from finish();
