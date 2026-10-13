-- F9-01: untransmute drops a partition pending a concurrent detach, with its rows (the #1157 refusal is not asked).
\set ON_ERROR_STOP 1
create extension if not exists pgtap;
create extension if not exists dblink;

create table public.f9u (id bigint primary key, v text);
insert into public.f9u select g, 'mono' from generate_series(1, 50) g;
call pgpm.transmute('public.f9u', 'id', 100, p_obtain => 2);
-- one row in a forward partition: outside the original monolith [0, 100)
insert into public.f9u values (150, 'forward');

select format('dbname=%s user=postgres', current_database()) as cs \gset
-- session b holds a snapshot-bearing lock on the parent, so the detach's second phase waits for it
select dblink_connect('b', :'cs');
select dblink_exec('b', 'begin');
select * from dblink('b', 'select count(*) from public.f9u') as t(n bigint);
-- session c starts a DETACH ... CONCURRENTLY and dies in its wait (statement_timeout), leaving the flag set
select dblink_connect('c', :'cs');
select dblink_exec('c', 'set statement_timeout = ''1s''');
select dblink_exec('c', 'alter table public.f9u detach partition public.f9u_p0000000000000000100 concurrently', false);
select dblink_exec('b', 'commit');
select dblink_disconnect('b');
select dblink_disconnect('c');

select plan(4);
select ok((select i.inhdetachpending from pg_inherits i
            where i.inhparent = 'public.f9u'::regclass and i.inhrelid = 'public.f9u_p0000000000000000100'::regclass),
          'LIVENESS: f9u_p0000000000000000100 is pending a concurrent detach (pg_inherits.inhdetachpending)');
select ok(exists (select 1 from only public.f9u_p0000000000000000100 where id = 150),
          'LIVENESS: the pending partition holds the row id 150, outside the monolith');

-- the reverse: must refuse (the partition's rows are outside the monolith, invisible through the parent)
create temp table f9_outcome (refused boolean, msg text);
do $$
begin
  perform pgpm.untransmute('public.f9u');
  insert into f9_outcome values (false, null);
exception when others then
  insert into f9_outcome values (true, sqlerrm);
end $$;

select ok((select refused from f9_outcome),
          'untransmute refuses while a partition is pending a concurrent detach');
create function pg_temp.f9_row_150() returns boolean language plpgsql as $f$
declare v boolean := false;
begin
  if to_regclass('public.f9u_p0000000000000000100') is not null then
    execute 'select exists (select 1 from public.f9u_p0000000000000000100 where id = 150)' into v;
  end if;
  if not v and to_regclass('public.f9u') is not null then
    execute 'select exists (select 1 from public.f9u where id = 150)' into v;
  end if;
  return v;
end $f$;
select ok(pg_temp.f9_row_150(),
          'the row id 150 still exists (in the pending partition or the table) after the untransmute call');
select * from finish();
