-- F3-05: _regrain_capture_names resolves the recorded capture function only in the DELTA's current schema
-- (p.pronamespace = the delta's nsp). reference.md says a delta moved by SET SCHEMA mid-regrain goes on working;
-- once it has been moved, the function (still in the parent's schema) resolves to null, and untransmute (which
-- drops `v_cnsp.v_cfn` only when it is not null) drops the delta and leaves the capture function behind.
-- Without the move the same sequence drops both.
create extension if not exists pgtap;
select plan(5);
create table public.h4 (id bigint primary key, payload text);
insert into public.h4 select g, 'x' from generate_series(1, 100) g;
call pgpm.transmute('public.h4', 'id', 1000);
select pgpm.obtain('public.h4');
insert into public.h4 values (1500, 'frontier');
select pgpm.regrain_step('public.h4', (select child_name from pgpm.part where parent_table = 'public.h4'::regclass
                                        and attached order by lo::numeric limit 1), '100');
select pgpm.regrain_cancel('public.h4');
create schema f305other;
alter table public.h4_pgpm_regrain_delta set schema f305other;
delete from public.h4 where id = 1500;   -- every row back in the monolith, so untransmute's door is open

select is((select regrain_capture_fn_oid from pgpm.config where parent_table = 'public.h4'::regclass),
  'public.h4_pgpm_regrain_capture()'::regprocedure::oid,
  'LIVENESS: (A) the capture function public.h4_pgpm_regrain_capture() is the one pgpm.config recorded');
select is((select n.nspname::text from pg_class c join pg_namespace n on n.oid = c.relnamespace
            where c.oid = (select regrain_delta_oid from pgpm.config where parent_table = 'public.h4'::regclass)),
  'f305other', 'LIVENESS: (A) the recorded delta now sits in f305other');
select lives_ok($$ select pgpm.untransmute('public.h4') $$, 'LIVENESS: (B) untransmute hands the table back');
select is((select count(*)::int from pg_class where relname = 'h4_pgpm_regrain_delta'), 0,
  'LIVENESS: (B) and drops the recorded delta');
select is((select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and p.proname = 'h4_pgpm_regrain_capture'), 0,
  'untransmute drops the recorded capture function public.h4_pgpm_regrain_capture() too');
select * from finish();
