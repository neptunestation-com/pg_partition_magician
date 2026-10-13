# transmute's resume checks the claim's column and grid but not the text_time encoding, so a re-run with another encoding fails raw in the cutover (pass 12 RC13)

Tier: 3

Age: old | Lens: operator error

Found in adversarial review pass 12 at `bd55f84021fc4173034d156a41bc91a3f882560d`, root-cause group RC13: F1-06.

## F1-06

- finder: F1
- location: `pgpm_core/install.sql:10850`
- lens: operator error
- tier: 3
- scenario: a text_time transmute re-run with another encoding (here p_tt_epoch one day earlier) takes over the earlier attempt's claim, which checks the column (#628) and the grid (#574) but not the encoding, skips phase 1 because a pgpm_monolith_bound CHECK in the old encoding exists, and the cutover's ATTACH with bounds in the new encoding scans the table under ACCESS EXCLUSIVE and dies raw (partition constraint violated) after the bound and claim are committed; it should be refused up front in pgpm's words, as a resume on another column is
- root cause (verifier): transmute's resume checks the claim's column (#628) and grid (#574) but not the text_time encoding (p_tt_prefix/width/radix/unit/alphabet/discard_bits/epoch): it skips phase 1 on the old-encoding pgpm_monolith_bound CHECK and the cutover's ATTACH in the new encoding scans under ACCESS EXCLUSIVE and dies raw (partition constraint violated) after the bound and claim committed. Reproduced 3/3 on the pristine tree with the finder's repro unchanged (held locks, not timing); not documented (guide.md 'A timeout is safe to retry' and reference.md's resume refusals name only the column and grid); no open issue covers the encoding.

Reproduction: `repro.sql`, the finder's, run unchanged by the verifier.

```sql
-- F1-06: a resumed text_time transmute trusts the claim's bound and the pgpm_monolith_bound CHECK an earlier
-- attempt committed, and checks the resume's column (#628) and grid (#574) but not its ENCODING: a re-run
-- with another p_tt_epoch (or prefix, width, radix, unit, alphabet, discard bits) skips phase 1 (a CHECK by
-- that name exists, in the old encoding) and the cutover ATTACHes with bounds in the new one, which the CHECK
-- does not imply: the ATTACH scans the table under ACCESS EXCLUSIVE and dies raw on the rows outside it,
-- after the bound and claim were committed. Expected: refused up front in pgpm's words, like #628's column.
create extension if not exists pgtap;
create extension if not exists dblink;
select plan(5);
set timezone = 'UTC';

create table public.f1tt (id text collate "C" not null primary key, v int);
insert into public.f1tt
select pgpm._encode('text_time', pgpm._ts_text(now() - i * interval '1 hour'), 'c', 8, 36, 'ms', null, 0,
                    '1970-01-01 00:00:00+00', 'UTC') || 'x' || lpad(i::text, 4, '0'), i
  from generate_series(1, 20) i;

-- first attempt, in session T: phase 1 commits, phase 2's VALIDATE times out behind holder H
select dblink_connect('f1t', 'dbname=' || current_database() || ' application_name=f1tt_transmute');
select dblink_exec('f1t', $q$set timezone = 'UTC'$q$);
select dblink_connect('f1x', 'dbname=' || current_database() || ' application_name=f1tt_reader');
select dblink_connect('f1h', 'dbname=' || current_database() || ' application_name=f1tt_holder');
select dblink_exec('f1x', 'begin');
select * from dblink('f1x', 'select count(*) from public.f1tt') as t(n bigint);    -- ACCESS SHARE held
select dblink_send_query('f1t', $q$call pgpm.transmute('public.f1tt', 'id', interval '1 day', p_obtain => 2, p_lock_timeout => '4s', p_tt_prefix => 'c', p_tt_width => 8, p_tt_radix => 36, p_tt_unit => 'ms')$q$);
do $$ begin
  for i in 1 .. 200 loop
    perform pg_stat_clear_snapshot();
    exit when exists (select 1 from pg_locks l join pg_stat_activity a on a.pid = l.pid
                       where a.application_name = 'f1tt_transmute' and l.relation = 'public.f1tt'::regclass
                         and l.mode = 'AccessExclusiveLock' and not l.granted);
    perform pg_sleep(0.02);
  end loop; end $$;
select dblink_send_query('f1h', 'begin; lock table public.f1tt in share update exclusive mode');
do $$ begin
  for i in 1 .. 200 loop
    perform pg_stat_clear_snapshot();
    exit when exists (select 1 from pg_locks l join pg_stat_activity a on a.pid = l.pid
                       where a.application_name = 'f1tt_holder' and l.relation = 'public.f1tt'::regclass
                         and l.mode = 'ShareUpdateExclusiveLock' and not l.granted);
    perform pg_sleep(0.02);
  end loop; end $$;
select dblink_exec('f1x', 'commit');
create function pg_temp.f1_result(c text) returns text language plpgsql as $f$
declare v_out text := 'completed'; n int;
begin
  for i in 1 .. 6 loop
    begin
      select count(*) into n from dblink_get_result(c) as t(r text);
    exception when others then
      v_out := 'raised: ' || sqlerrm;
    end;
    exit when dblink_is_busy(c) = 0 and n is not distinct from 0 and i > 1;
  end loop;
  return v_out;
end $f$;
select pg_temp.f1_result('f1t') as first \gset
select pg_temp.f1_result('f1h') as h \gset
select dblink_exec('f1h', 'commit');

select ok(exists (select 1 from pgpm.transmute_inflight where parent_table = 'public.f1tt'::regclass)
          and exists (select 1 from pg_constraint where conrelid = 'public.f1tt'::regclass and conname = 'pgpm_monolith_bound')
          and not exists (select 1 from pgpm.config where parent_table = 'public.f1tt'::regclass),
          'LIVENESS: the first attempt left its claim and its bound CHECK (phase 2 timed out: ' || :'first' || ')');

-- the re-run, from the claim's own session, with another p_tt_epoch (one day earlier)
select dblink_send_query('f1t', $q$call pgpm.transmute('public.f1tt', 'id', interval '1 day', p_obtain => 2, p_tt_prefix => 'c', p_tt_width => 8, p_tt_radix => 36, p_tt_unit => 'ms', p_tt_epoch => '1969-12-31 00:00:00+00')$q$);
select pg_temp.f1_result('f1t') as second \gset
select dblink_disconnect('f1t'); select dblink_disconnect('f1x'); select dblink_disconnect('f1h');

select pass('fixture: the re-run, from the claim''s own session, returned: ' || :'second');
select ok(:'second' like 'raised: pg_partition_magician:%',
          'a resume under another text_time encoding is refused in pgpm''s words, before the cutover: ' || :'second');
select is((select array_agg(v order by v) from public.f1tt), (select array_agg(g order by g) from generate_series(1, 20) g),
          'LIVENESS: rows 1..20 are all still in f1tt');
select ok(exists (select 1 from pgpm.transmute_inflight where parent_table = 'public.f1tt'::regclass),
          'LIVENESS: the claim is still there for an abort');
select * from finish();
```

Acceptance: the reproduction(s) above fail on bd55f84021fc4173034d156a41bc91a3f882560d and must pass on the fixing commit; the fix carries a bench/ guard and a bench/mutations entry proven by ./test.sh discriminate.



