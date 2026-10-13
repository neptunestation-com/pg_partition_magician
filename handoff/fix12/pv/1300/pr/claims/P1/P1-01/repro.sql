-- P1-01: the resume take-over in pgpm._transmute reads the claim's text_time_encoding (v_claim_tt_encoding)
-- but never compares it with this call's, so a re-run under another p_tt_epoch takes the claim over, skips
-- phases 1 and 2 (a validated pgpm_monolith_bound CHECK by that name exists, in the OLD encoding) and the
-- cutover's ATTACH, with bounds encoded the NEW way, scans the table under ACCESS EXCLUSIVE and dies raw
-- on the rows outside it. Expected (PR #1300's contract): refused up front, in pgpm's words, naming the
-- encodings and the remedy, with the claim, the CHECK and the table untouched.
--
-- Fixture (tests/337's shape): twenty cuid-shaped ids (prefix 'c', 8 base-36 ms digits, epoch 1970), one
-- hour apart back from now, and a referencing table holding one of them. The first attempt runs in a
-- dblink session while this session holds ACCESS SHARE on the referencing table, so phases 1 and 2 commit
-- the bound and the claim and the cutover's incoming-FK drop times out. The re-run (epoch one day earlier)
-- runs in a second dblink session so the error it raises is observed as raised, not as the 2D000 a
-- committing procedure dies with inside a pgTAP function.
create extension if not exists pgtap;
create extension if not exists dblink;
select plan(7);
set timezone = 'UTC';

create table public.p1enc (id text collate "C" not null primary key, v int);
insert into public.p1enc
select pgpm._encode('text_time', pgpm._ts_text(now() - g * interval '1 hour'), 'c', 8, 36, 'ms', null, 0,
                    '1970-01-01 00:00:00+00', 'UTC') || 'x' || lpad(g::text, 4, '0'), g
  from generate_series(1, 20) g;
create table public.p1enc_ref (rid int primary key, id text collate "C" references public.p1enc);
insert into public.p1enc_ref select 1, id from public.p1enc where v = 7;

select dblink_connect('a', 'dbname=' || current_database());
select dblink_exec('a', $c$ set timezone = 'UTC' $c$);
begin;
lock table public.p1enc_ref in access share mode;
select throws_ok(
  $$ select dblink_exec('a', $c$ call pgpm.transmute('public.p1enc', 'id', interval '1 day', p_obtain => 2,
                                                     p_incoming_fks => 'preserve', p_lock_timeout => '300ms',
                                                     p_tt_prefix => 'c', p_tt_width => 8, p_tt_radix => 36,
                                                     p_tt_unit => 'ms') $c$) $$,
  '55P03', NULL,
  'LIVENESS: the first conversion fails in the cutover, on the lock this session holds on the referencing table');
commit;
select dblink_disconnect('a');

select is((select text_time_encoding ->> 'epoch' from pgpm.transmute_inflight where parent_table = 'public.p1enc'::regclass), '0',
  'LIVENESS: the first attempt left its claim, recording epoch 0 as the encoding its bound was written in');
select is((select convalidated::text from pg_constraint
            where conrelid = 'public.p1enc'::regclass and conname = 'pgpm_monolith_bound'), 'true',
  'LIVENESS: and a VALIDATED pgpm_monolith_bound CHECK, so a resume skips phases 1 and 2');
select ok(exists (select 1 from public.p1enc t
                   where t.id < pgpm._encode('text_time', (select lo from pgpm.transmute_inflight where parent_table = 'public.p1enc'::regclass),
                                             'c', 8, 36, 'ms', null, 0, '1969-12-31 00:00:00+00', 'UTC')),
  'LIVENESS: some row lies below the bound''s lo encoded with the re-run''s epoch, so an ATTACH that way cannot pass');

-- the first attempt's session has ended (its backend's exit is asynchronous, so stand in for it)
update pgpm.transmute_inflight set owner_pid = null, owner_backend_start = null
 where parent_table = 'public.p1enc'::regclass;

-- the re-run with the epoch one day earlier, from a fresh session, its outcome captured as text
create function pg_temp.rerun() returns text language plpgsql as $f$
begin
  perform dblink_connect('b', 'dbname=' || current_database());
  perform dblink_exec('b', $c$ set timezone = 'UTC' $c$);
  begin
    perform dblink_exec('b', $c$ call pgpm.transmute('public.p1enc', 'id', interval '1 day', p_obtain => 2,
                                                     p_incoming_fks => 'preserve',
                                                     p_tt_prefix => 'c', p_tt_width => 8, p_tt_radix => 36,
                                                     p_tt_unit => 'ms', p_tt_epoch => '1969-12-31 00:00:00+00') $c$);
    perform dblink_disconnect('b');
    return 'completed';
  exception when others then
    perform dblink_disconnect('b');
    return 'raised: ' || sqlerrm;
  end;
end $f$;
select pg_temp.rerun() as second \gset

select pass('fixture: the re-run with p_tt_epoch one day earlier returned: ' || :'second');
select ok(:'second' like 'raised: %pg_partition_magician: cannot resume the transmute of%encoding%',
  'a resume under another text_time encoding is refused up front in pgpm''s words (got: ' || :'second' || ')');
select ok(:'second' not like '%violated by some row%',
  'the re-run did not reach the cutover''s ATTACH (which scans under ACCESS EXCLUSIVE and dies on the rows outside the re-encoded bound)');
select * from finish();
