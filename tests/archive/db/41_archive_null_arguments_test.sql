-- pgpm_archive refuses a null argument with no meaning, and an archive_fn strategy refuses an empty or
-- inverted range, before anything is read or sent (#969 bullet 9; lever phase #966, the shared preflight).
--
-- THE DEFECT. The shared preflight's null sweep (tests/268, tests/timescale/db/50) covered pgpm_core and
-- pgpm_hypertable, and pgpm_archive's routines were outside it. Neither archive_fn strategy checked its
-- bounds: pgpm.archive_to_s3_ndjson / _parquet with a null p_lo died raw on archive.object_key_claim's NOT
-- NULL, and with a null p_hi read no row and PUT an EMPTY object over the key an earlier call had archived
-- [lo, hi) to (the key is derived from p_lo alone), returning covered_hi = null. The same empty overwrite was
-- reachable with no null at all, by a direct call for [lo, lo). After retire() drops the partition that
-- object is the only copy of its rows.
--
-- EXHAUSTIVENESS. Part A enumerates pgpm_archive's public routines from pg_proc AT TEST TIME: every routine of
-- schema archive whose name does not start with '_', and every one of schema pgpm the module created (its oid
-- is above the archive schema's: in this database the core is installed first and the module after it, and
-- the module creates its schema before any routine, so a routine with a higher oid in pgpm is the module's).
-- Each is called with null in each argument position (every other argument a type-correct sample, or its
-- default), and pgpm's own refusal naming exactly that argument is required. A public routine the module adds
-- later without the check fails the sweep by construction. The arguments whose null is a documented meaning
-- are the case table t41_documented; those must NOT be refused, and an entry naming an argument that does not
-- exist fails too, so the table cannot rot. A planted control schema proves the verdict can fail. The sweep
-- runs with every HTTP request sent to a proxy that refuses connections (pgsql-http's CURLOPT_PROXY), so a
-- call that is not refused (a documented null, or a mutant) cannot reach S3, or anything else.
--
-- Part B is the reproduction (A969-9) as identity: [1, 10) archived by each strategy to MinIO, then every
-- refused call (null p_hi, null p_lo, [1, 1), [1, 0)) aimed at the same key, then the objects read back: the
-- NDJSON one still holds rows 1 to 9 by id and payload, the Parquet one still has the ETag its PUT returned.
-- Controls: [9, 10) of an id grid is a range (9 < 10 as numbers, though '9' > '10' as text) and archives row
-- 9, and [10, 20) archives rows 10 to 19, so the range check refuses only what is empty.
-- bench/archive_null_arguments.sh runs this file against the module's mutants.
set client_min_messages = warning;
select plan(22);

create schema t41;

-- ======================================================================================================
-- The sweep's instrument
-- ======================================================================================================
-- the table every swept call names: plain, unmanaged, with no archive.config row, so a call that is not
-- refused acts on nothing
create table t41.sweep (id bigint primary key);

-- a type-correct sample for every argument type a public routine takes; an unknown type is an ERROR, never
-- a skipped case, so a routine with a new argument type cannot leave the sweep silently
create function pg_temp.t41_sample(p_type oid) returns text language plpgsql as $$
begin
  return case p_type
    when 'regclass'::regtype then quote_literal('t41.sweep') || '::regclass'
    when 'name'::regtype     then quote_literal('id') || '::name'
    when 'text'::regtype     then quote_literal('1') || '::text'
    when 'integer'::regtype  then '1::integer'
    when 'bigint'::regtype   then '1::bigint'
    when 'boolean'::regtype  then 'false'
    when 'bytea'::regtype    then quote_literal('\x01') || '::bytea'
  end;
end $$;

-- how pgpm names a routine in its refusal: bare in schema pgpm, schema-qualified anywhere else
create function pg_temp.t41_label(p_oid oid) returns text language sql stable as $$
  select case when n.nspname = 'pgpm' then p.proname::text else n.nspname || '.' || p.proname end
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace where p.oid = p_oid
$$;

-- pgpm_archive's public routines, as defined in the header
create function pg_temp.t41_module() returns setof oid language sql stable as $$
  select p.oid from pg_proc p
   where p.proname !~ '^_'
     and (p.pronamespace = 'archive'::regnamespace
          or (p.pronamespace = 'pgpm'::regnamespace and p.oid > 'archive'::regnamespace::oid))
$$;

-- every (routine, input argument) of the routines p_oids, called with null in that position
create function pg_temp.t41_sweep(p_oids oid[])
returns table (routine text, arg text, state text, msg text) language plpgsql as $$
declare
  r record; v_names text[]; v_types oid[]; v_n int; v_args text[]; v_call text; i int; j int; v_sample text;
begin
  for r in select p.oid, p.pronamespace::regnamespace::text as nsp, p.proname::text as proname, p.prokind,
                  p.pronargs, p.pronargdefaults, p.proargnames, p.proargmodes, p.proallargtypes,
                  string_to_array(p.proargtypes::text, ' ')::oid[] as intypes   -- oidvector is 0-based
             from pg_proc p where p.oid = any (p_oids)
            order by pg_temp.t41_label(p.oid), p.oid loop
    if r.proargmodes is null then
      v_names := r.proargnames[1:r.pronargs];
      v_types := r.intypes;
    else
      select array_agg(r.proargnames[k] order by k), array_agg(r.proallargtypes[k] order by k)
        into v_names, v_types
        from generate_subscripts(r.proargmodes, 1) k
       where r.proargmodes[k] in ('i', 'b', 'v');
    end if;
    v_n := coalesce(array_length(v_types, 1), 0);
    for i in 1 .. v_n loop
      v_args := '{}';
      for j in 1 .. v_n loop
        if j = i then
          v_args := v_args || format('%I => null::%s', v_names[j], format_type(v_types[j], null));
        elsif j <= v_n - r.pronargdefaults then
          v_sample := pg_temp.t41_sample(v_types[j]);
          if v_sample is null then
            raise exception 't41 sweep: no sample for %.% argument % of type %',
              r.nsp, r.proname, v_names[j], format_type(v_types[j], null);
          end if;
          v_args := v_args || format('%I => %s', v_names[j], v_sample);
        end if;   -- a later argument with a default is left to it
      end loop;
      v_call := format(case when r.prokind = 'p' then 'call %I.%I(%s)' else 'select %I.%I(%s)' end,
                       r.nsp, r.proname, array_to_string(v_args, ', '));
      routine := pg_temp.t41_label(r.oid); arg := v_names[i];
      begin
        execute v_call;
        state := '00000'; msg := null;
      exception when others then
        get stacked diagnostics state = returned_sqlstate, msg = message_text;
      end;
      return next;
    end loop;
  end loop;
end $$;

-- pgpm's own null refusal, naming exactly the one argument that was null
create function pg_temp.t41_refused(p_routine text, p_arg text, p_state text, p_msg text)
returns boolean language sql immutable as $$
  select coalesce(p_state = 'P0001'
                  and starts_with(p_msg, 'pg_partition_magician: ' || p_routine || ' does not accept null for ' || p_arg || ':'),
                  false)
$$;

-- the arguments whose null is a documented meaning (docs/reference.md, "Null arguments")
create temp table t41_documented (routine text, arg text, documented text);
insert into t41_documented values
  ('archive.configure', 'p_endpoint', 'null = AWS S3 (virtual-hosted), an URL for an S3-compatible store'),
  ('archive.s3_signed_request', 'p_endpoint', 'null = AWS S3 (virtual-hosted)'),
  ('archive.s3_signed_request_bytea', 'p_endpoint', 'null = AWS S3 (virtual-hosted)'),
  ('archive.to_s3', 'p_lo', 'not read: the export is the whole partition'),
  ('archive.to_s3', 'p_hi', 'not read: the export is the whole partition'),
  ('archive.to_s3_parquet', 'p_lo', 'not read: the export is the whole partition'),
  ('archive.to_s3_parquet', 'p_hi', 'not read: the export is the whole partition'),
  ('archive_to_s3_ndjson', 'p_child', 'not read: the chunk is read through the parent'),
  ('archive_to_s3_parquet', 'p_child', 'not read: the chunk is read through the parent');

-- the fence: every request of the sweep goes to a proxy that refuses connections
do $$ begin perform http_set_curlopt('CURLOPT_PROXY', 'http://127.0.0.1:9'); end $$;
create temp table t41_fence as
  select (select count(*) from pg_temp.t41_module()) as n,
         (select msg from pg_temp.t41_sweep(array(select 'archive.s3_signed_request'::regproc::oid)) s
           where s.arg = 'p_endpoint') as endpoint_null_msg;
create temp table t41_swept as select * from pg_temp.t41_sweep(array(select pg_temp.t41_module()));
do $$ begin perform http_reset_curlopt(); end $$;

-- ======================================================================================================
-- A. The null sweep over every public routine of pgpm_archive
-- ======================================================================================================
create schema t41_ctl;
create function t41_ctl.unchecked(p_parent regclass, p_force boolean default false) returns int
language plpgsql as $$ begin if not p_force then return 0; end if; return 1; end $$;
create function t41_ctl.misnamed(p_parent regclass, p_force boolean default false) returns int
language plpgsql as $$
begin
  perform pgpm._refuse_null_arguments('t41_ctl.misnamed', json_build_object('p_parent', p_parent));
  if not p_force then return 0; end if; return 1;
end $$;
create function t41_ctl.checked(p_parent regclass, p_force boolean default false) returns int
language plpgsql as $$
begin
  perform pgpm._refuse_null_arguments('t41_ctl.checked', json_build_object('p_parent', p_parent, 'p_force', p_force));
  return 0;
end $$;
select is(
  (select string_agg(routine || '.' || arg || '=' || pg_temp.t41_refused(routine, arg, state, msg)::text, ', '
                     order by routine, arg)
     from pg_temp.t41_sweep(array(select p.oid from pg_proc p where p.pronamespace = 't41_ctl'::regnamespace))),
  't41_ctl.checked.p_force=true, t41_ctl.checked.p_parent=true, t41_ctl.misnamed.p_force=false, t41_ctl.misnamed.p_parent=true, t41_ctl.unchecked.p_force=false, t41_ctl.unchecked.p_parent=false',
  'A CONTROL: the verdict refuses a routine with no null check, and one whose check leaves an argument out');

select is(
  (select array_agg(n order by n collate "C") from unnest(array['archive.configure.p_bucket', 'archive.unconfigure.p_parent',
             'archive.s3_url_encode.p_raw', 'archive.s3_signed_request.p_key', 'archive.s3_signed_request_bytea.p_payload',
             'archive.to_s3.p_child', 'archive.to_s3_parquet.p_parent', 'archive_to_s3_ndjson.p_lo',
             'archive_to_s3_ndjson.p_hi', 'archive_to_s3_parquet.p_hi']) n
    where n in (select routine || '.' || arg from t41_swept))::text
  || ' / ' || ((select count(*) from t41_swept) >= 48 and (select count(distinct routine) from t41_swept) >= 9)::text,
  '{archive.configure.p_bucket,archive.s3_signed_request.p_key,archive.s3_signed_request_bytea.p_payload,archive.s3_url_encode.p_raw,archive.to_s3.p_child,archive.to_s3_parquet.p_parent,archive.unconfigure.p_parent,archive_to_s3_ndjson.p_hi,archive_to_s3_ndjson.p_lo,archive_to_s3_parquet.p_hi} / true',
  'LIVENESS: (A) the sweep enumerated both schemas'' routines from the catalog (at least 9, 48 argument positions), the issue''s included');
select is(
  (select string_agg(p.proname, ',' order by p.proname) from pg_proc p
    where p.pronamespace = 'pgpm'::regnamespace and p.oid in (select pg_temp.t41_module())
      and p.proname in ('transmute', 'maintain', 'set_archive_fn', 'archive_to_s3_ndjson', 'archive_to_s3_parquet'))
  || ' / ' || (select count(*) > 30 from pg_proc p where p.pronamespace = 'pgpm'::regnamespace and p.proname !~ '^_'
                 and p.oid < 'archive'::regnamespace::oid)::text,
  'archive_to_s3_ndjson,archive_to_s3_parquet / true',
  'LIVENESS: (A) the oid boundary takes the module''s routines in schema pgpm and none of the core''s, which are there below it');
select is(
  (select array_agg(d.routine || '.' || d.arg order by d.routine, d.arg) from t41_documented d
    where not exists (select 1 from t41_swept s where s.routine = d.routine and s.arg = d.arg)),
  null,
  'A: every documented-null entry names a real argument of a real public routine (the table cannot rot)');
select is(
  (select array_agg(s.routine || '.' || s.arg || ' -> ' || s.state || ' ' || coalesce(left(s.msg, 140), '(no error)')
                    order by s.routine, s.arg)
     from t41_swept s
    where not exists (select 1 from t41_documented d where d.routine = s.routine and d.arg = s.arg)
      and not pg_temp.t41_refused(s.routine, s.arg, s.state, s.msg)),
  null,
  'A: every public routine of pgpm_archive refuses a null with no documented meaning up front, naming it');
select is(
  (select array_agg(s.routine || '.' || s.arg order by s.routine, s.arg)
     from t41_swept s join t41_documented d on d.routine = s.routine and d.arg = s.arg
    where s.msg like '%does not accept null for%'),
  null,
  'A: no argument whose null is documented is refused for its null');
select ok((select n >= 9 and endpoint_null_msg like 'Failed to connect to 127.0.0.1 port 9%' from t41_fence),
  'LIVENESS: (A) the fence held: a documented-null call that went on to send its request reached the refusing proxy, not S3');

-- ======================================================================================================
-- B. The reproduction (A969-9), as identity: nothing overwrites an archived chunk's object
-- ======================================================================================================
create function t41.req(p_method text, p_key text) returns http_response language sql as $$
  select archive.s3_signed_request(p_method, 'http://minio:9000', 'archive-test-bucket', 'us-east-1', p_key, '',
                                   'text/plain', '', 'minioadmin', 'minioadmin') $$;
-- what an NDJSON object holds, as sorted 'id:payload' items (null when there is no object)
create function t41.rows(p_key text) returns text language plpgsql as $$
declare v http_response := t41.req('GET', p_key);
begin
  if v.status <> 200 then return null; end if;
  return (select string_agg((l::jsonb ->> 'id') || ':' || (l::jsonb ->> 'payload'), ',' order by (l::jsonb ->> 'id')::bigint)
            from regexp_split_to_table(v.content, e'\n') l where l <> '');
end $$;
-- an object's bytes (null when there is none), as tests/archive/db/40 reads a binary object
create function t41.bytes(p_key text) returns bytea language plpgsql as $$
declare v http_response := t41.req('GET', p_key);
begin
  if v.status <> 200 then return null; end if;
  return text_to_bytea(v.content);
end $$;

-- a strategy's answer for [lo, hi) as '<rows> <key>', or the error it raised, so a refusal fails an assertion
-- rather than the file
create function t41.try(p_fmt text, p_lo text, p_hi text) returns text language plpgsql as $$
declare r pgpm.archive_result;
begin
  execute format('select * from pgpm.archive_to_s3_%s(%L, %L, %L, %L)', p_fmt, 't41.ev', 'unused', p_lo, p_hi) into r;
  return r.rows_archived || ' ' || r.s3_key;
exception when others then
  return sqlerrm;
end $$;

select current_database() || '/t41/' || txid_current() || '/' as p \gset
create table t41.ev (id bigint primary key, payload text not null);
insert into t41.ev select g, 'r' || g from generate_series(1, 30) g;
call pgpm.transmute('t41.ev', 'id', 10::bigint, p_paused => true);
select archive.configure('t41.ev', 'archive-test-bucket', p_endpoint => 'http://minio:9000', p_prefix => :'p');

create temp table good_nd as select * from pgpm.archive_to_s3_ndjson('t41.ev', 'unused', '1', '10');
create temp table good_pq as select * from pgpm.archive_to_s3_parquet('t41.ev', 'unused', '1', '10');
create temp table good_pq_bytes as select t41.bytes((select s3_key from good_pq)) as b;

select is((select rows_archived from good_nd) || ' / ' || t41.rows((select s3_key from good_nd)),
  '9 / 1:r1,2:r2,3:r3,4:r4,5:r5,6:r6,7:r7,8:r8,9:r9',
  'LIVENESS: (B) the NDJSON strategy archived [1, 10), and its object holds rows 1 to 9');
select ok((select rows_archived = 9 from good_pq)
          and (select octet_length(b) > 0 and md5(b) = btrim((select etag from good_pq), '"') from good_pq_bytes),
  'LIVENESS: (B) the Parquet strategy archived [1, 10), and the bytes read back are the ones its PUT wrote (their md5 is its ETag)');
select is(archive._object_key('t41.ev'::regclass, :'p', 'id', '1', '.ndjson') || ' ' || archive._object_key('t41.ev'::regclass, :'p', 'id', '1', '.parquet'),
  (select s3_key from good_nd) || ' ' || (select s3_key from good_pq),
  'LIVENESS: (B) a call with lo 1 addresses those very objects, whatever its hi (the key is derived from lo alone)');

select throws_like($$ select * from pgpm.archive_to_s3_ndjson('t41.ev', 'unused', '1', null) $$,
  'pg_partition_magician: archive_to_s3_ndjson does not accept null for p_hi:%', 'B: archive_to_s3_ndjson refuses a null p_hi, naming it');
select throws_like($$ select * from pgpm.archive_to_s3_ndjson('t41.ev', 'unused', null, '10') $$,
  'pg_partition_magician: archive_to_s3_ndjson does not accept null for p_lo:%', 'B: archive_to_s3_ndjson refuses a null p_lo, naming it');
select throws_like($$ select * from pgpm.archive_to_s3_parquet('t41.ev', 'unused', '1', null) $$,
  'pg_partition_magician: archive_to_s3_parquet does not accept null for p_hi:%', 'B: archive_to_s3_parquet refuses a null p_hi, naming it');
select throws_like($$ select * from pgpm.archive_to_s3_parquet('t41.ev', 'unused', null, '10') $$,
  'pg_partition_magician: archive_to_s3_parquet does not accept null for p_lo:%', 'B: archive_to_s3_parquet refuses a null p_lo, naming it');
select throws_like($$ select * from pgpm.archive_to_s3_ndjson('t41.ev', 'unused', '1', '1') $$,
  'pg_partition_magician: archive_to_s3_ndjson refuses the range [1, 1) of t41.ev -- it is empty or inverted%',
  'B: archive_to_s3_ndjson refuses the empty range [1, 1), which has no null in it');
select throws_like($$ select * from pgpm.archive_to_s3_ndjson('t41.ev', 'unused', '1', '0') $$,
  'pg_partition_magician: archive_to_s3_ndjson refuses the range [1, 0) of t41.ev -- it is empty or inverted%',
  'B: archive_to_s3_ndjson refuses the inverted range [1, 0)');
select throws_like($$ select * from pgpm.archive_to_s3_parquet('t41.ev', 'unused', '1', '1') $$,
  'pg_partition_magician: archive_to_s3_parquet refuses the range [1, 1) of t41.ev -- it is empty or inverted%',
  'B: archive_to_s3_parquet refuses the empty range [1, 1)');

select is(t41.rows((select s3_key from good_nd)), '1:r1,2:r2,3:r3,4:r4,5:r5,6:r6,7:r7,8:r8,9:r9',
  'B: the NDJSON object [1, 10) was archived to still holds rows 1 to 9');
select ok(t41.bytes((select s3_key from good_pq)) = (select b from good_pq_bytes),
  'B: the Parquet object [1, 10) was archived to still holds the bytes its PUT wrote');

select is(t41.try('ndjson', '9', '10') || ' / ' || coalesce(t41.rows(archive._object_key('t41.ev'::regclass, :'p', 'id', '9', '.ndjson')), '(no object)'),
  '1 ' || archive._object_key('t41.ev'::regclass, :'p', 'id', '9', '.ndjson') || ' / 9:r9',
  'B CONTROL: [9, 10) is a range of an id grid (compared as numbers, not as text, where ''9'' > ''10''): it archives row 9');
select is(t41.try('parquet', '10', '20'), '10 ' || archive._object_key('t41.ev'::regclass, :'p', 'id', '10', '.parquet'),
  'B CONTROL: [10, 20) is not refused, and archives its 10 rows');
select is((select count(*) from pgpm.archive_ledger where parent_table = 't41.ev'::regclass), 0::bigint,
  'B GUARD: no ledger row was written by these direct calls');

select * from finish();
