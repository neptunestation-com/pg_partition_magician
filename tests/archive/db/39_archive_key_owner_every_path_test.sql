-- Every object key the archive module writes names ONE relation, on every path that writes one (issue
-- #872, bullet 5; the class of #822 and #711).
--
-- #822 gave the automatic path's chunk keys an owner: archive.object_key_owner records which relation a key
-- base belongs to, and any other relation that computes the same base gets its oid in the key, so it can
-- never PUT over an object an earlier relation wrote. The synchronous exports did not get it.
-- archive._child_object_key keyed archive.to_s3 and archive.to_s3_parquet by <prefix><schema>.<child><ext>
-- and both PUT unconditionally, so after the documented to_s3-then-drop workflow (and
-- pgpm.forget_missing()), a new table that took the dropped table's name exported its same-named
-- partition OVER the dropped table's export, the only copy of those rows.
--
-- Now one function assembles every key and takes the claim, and every path asks it. This file is the
-- behavioural half of that lever: each path that writes an object (the two synchronous exports, the
-- NDJSON one plain and compressed, and the two archive_fn transports) exports a relation, the relation
-- is dropped and forgotten, a namesake exports the same partition, and the first relation's object is
-- asserted still there by identity: its exact key, and its rows or its bytes. The namesake's object is
-- asserted at its own exact key, the oid shape. Part 0 is the catalog half: it enumerates every S3 write
-- the module's functions make and requires the key each one gets to come from the key helpers, so a new
-- write site that builds its own key fails here even before anyone writes a namesake case for it (#914).
-- (scripts/check_archive_object_keys.py is the source-level half: the key is assembled in exactly one
-- function.)
--
-- Fixtures are asymmetric, so a replaced object cannot pass an identity check: each first relation holds
-- rows 1:old and 2:old, each namesake row 1:new. The prefix carries current_database() because the bucket
-- outlives a test database, and every key is cleared and witnessed absent before the work that writes it.
set client_min_messages = warning;
select plan(49);

create schema t39;

create function t39.req(p_method text, p_key text) returns http_response language sql as $$
  select archive.s3_signed_request(p_method, 'http://minio:9000', 'archive-test-bucket', 'us-east-1', p_key, '',
                                   'text/plain', '', 'minioadmin', 'minioadmin') $$;

-- DELETE the key, then report the GET status: 404 means nothing sits there before the work below.
create function t39.clear(p_key text) returns int language plpgsql as $$
begin
  perform t39.req('DELETE', p_key);
  return (t39.req('GET', p_key)).status;
end $$;

-- What an NDJSON object holds, as sorted 'id:payload' items (null when there is no object): identity.
create function t39.rows(p_key text) returns text language plpgsql as $$
declare v http_response := t39.req('GET', p_key);
begin
  if v.status <> 200 then return null; end if;
  return (select string_agg((l::jsonb ->> 'id') || ':' || (l::jsonb ->> 'payload'), ',' order by (l::jsonb ->> 'id')::bigint)
            from regexp_split_to_table(v.content, e'\n') l where l <> '');
end $$;

-- An object's bytes (null when there is none); text_to_bytea undoes the extension's reinterpretation of the
-- body, as in tests/archive/db/16, so a gzip or Parquet object compares byte for byte.
create function t39.bytes(p_key text) returns bytea language plpgsql as $$
declare v http_response := t39.req('GET', p_key);
begin
  if v.status <> 200 then return null; end if;
  return text_to_bytea(v.content);
end $$;

-- A managed table named t39.<p_name>, one [0, 10000) partition holding p_rows; returns nothing. The two
-- generations of each name are built by this one function, so they differ only in their rows.
create function t39.mk(p_name name, p_rows text[]) returns void language plpgsql as $$
begin
  execute format('create table t39.%I (id bigint primary key, payload text not null)', p_name);
  execute format('insert into t39.%I select i, ($1)[i] from generate_subscripts($1, 1) i', p_name) using p_rows;
end $$;

-- The documented retirement of a table: drop it, let pgpm.forget_missing() clear it, drop its connection
-- settings. Returns the partitions forget_missing() reported forgotten for it.
create function t39.retire_table(p_name name) returns int language plpgsql as $$
declare v_oid oid := format('t39.%I', p_name)::regclass::oid; v_n int;
begin
  execute format('drop table t39.%I cascade', p_name);
  select f.partitions_forgotten into v_n from pgpm.forget_missing() f where f.parent_oid = v_oid;
  delete from archive.config c where c.parent_table::oid = v_oid;
  return v_n;
end $$;

select current_database() || '/t39/' as p \gset

-- ======================= PART 0: every S3 write takes its key from a key helper =======================
--
-- The catalog half, by enumeration rather than by spelling (#914). The scan this replaces looked for the
-- literal 'PUT' and for a helper's name anywhere in a body, so a site that passed the verb in a variable,
-- named a helper in a comment, or took one key from a helper and PUT a second object at an inline key
-- passed it while writing a real object at a key nothing claimed. This one lexes every function body of
-- the module (comments dropped, each literal one token) and enumerates the S3 requests themselves:
--
--   * the TRANSPORTS are the functions that call the http extension's request functions (each of its
--     functions that returns http_response) directly. Each must take its method and key as p_method and
--     p_key, so that every call to it can be read; a function calling the extension any other way is
--     refused, its key being out of reach;
--   * every call to a transport is a WRITE unless its method argument is the literal 'GET', 'HEAD' or
--     'DELETE' (a verb in a variable or an expression is a write, and so is 'POST', which creates and
--     completes a multipart upload). The key argument of every write must be a local variable whose every
--     assignment (`:=`, or `select ... into` it alone) is one call to archive._object_key or
--     archive._child_object_key (or the variable itself), followed by nothing but literal suffixes: not a
--     parameter, not an expression, not a loop variable, and not prefixed (`'mirror/' || ...`), since only
--     a suffix stays under the base the helper claimed;
--   * a transport or a request function named inside a string literal (dynamic SQL) is refused, since the
--     key such a request gets cannot be followed.
--
-- The scan is witnessed both ways before it is believed: it finds the module's transports and the writes
-- of the four functions known to PUT an object, it reads their GET and DELETE requests as reads, it
-- refuses a planted site of every shape the old scan passed, and it passes a planted site that does it
-- right. This section is self-contained (it is run on its own by the #914 reproduction).
create schema if not exists t39;

-- A body's tokens: k[i] is I (an identifier, lowercased, qualified names whole), S (a literal, t[i] its
-- text) or O (anything else); comments are dropped. A dollar-quoted literal inside a body is one S token.
create or replace function t39.p0_lex(p_src text, out k text[], out t text[]) language plpgsql immutable as $f$
declare v_tok text; v_tag text;
begin
  k := '{}'; t := '{}';
  for v_tok in
    select m[1] from regexp_matches(p_src,
      '''(?:[^'']|'''')*''|\$(?:[A-Za-z_][A-Za-z_0-9]*)?\$|\$[0-9]+|--[^\n]*|/\*(?:[^*]|\*+[^*/])*\*+/|"(?:[^"]|"")*"'
      '|[A-Za-z_][A-Za-z_0-9$]*(?:\.[A-Za-z_][A-Za-z_0-9$]*)*|:=|=>|::|\|\||<>|<=|>=|!=|[^[:space:]]', 'g')
      with ordinality x(m, o) order by o
  loop
    if v_tag is not null then
      if v_tok = v_tag then v_tag := null; end if;
      continue;
    end if;
    if v_tok ~ '^\$([A-Za-z_][A-Za-z_0-9]*)?\$$' then
      v_tag := v_tok; k := k || 'S'::text; t := t || ''::text;
    elsif left(v_tok, 2) in ('--', '/*') then
      null;
    elsif left(v_tok, 1) = '''' then
      k := k || 'S'::text; t := t || replace(substr(v_tok, 2, length(v_tok) - 2), '''''', '''');
    elsif v_tok ~ '^[A-Za-z_"]' then
      k := k || 'I'::text; t := t || lower(v_tok);
    else
      k := k || 'O'::text; t := t || v_tok;
    end if;
  end loop;
end $f$;

-- The index of the parenthesis that closes the one at p_open, or 0.
create or replace function t39.p0_close(k text[], t text[], p_open int) returns int language plpgsql immutable as $f$
declare d int := 0; j int := p_open;
begin
  while j <= cardinality(t) loop
    if k[j] = 'O' and t[j] = '(' then d := d + 1;
    elsif k[j] = 'O' and t[j] = ')' then d := d - 1; if d = 0 then return j; end if;
    end if;
    j := j + 1;
  end loop;
  return 0;
end $f$;

-- Null when the local p_var only ever holds a key a helper made: it has at least one assignment, and each
-- is one call to a key helper, or p_var itself, followed by nothing but literal suffixes (`|| '.gz'`: a
-- suffix keeps the key under the base the helper claimed, where a prefix or any other expression would
-- not). Otherwise why not.
create or replace function t39.p0_key_unsafe(k text[], t text[], p_var text) returns text language plpgsql immutable as $f$
declare
  n int := cardinality(t); j int := 0; i int; a int; e int; d int; p int; v_assigned boolean := false;
begin
  while j < n loop
    j := j + 1;
    continue when k[j] <> 'I' or t[j] <> p_var;
    if t[j - 1] in ('for', 'foreach') then
      return format('%s is a loop variable', p_var);
    end if;
    -- an INTO target list, walked back over "x, y," to INTO or INTO STRICT
    i := j - 1;
    while i > 2 and t[i] = ',' and k[i - 1] = 'I' loop i := i - 2; end loop;
    if t[i] = 'strict' then i := i - 1; end if;
    if t[i] = 'into' and coalesce(t[i - 1], '') not in ('insert', 'merge') then
      -- only as the one target of `select <helper>(...) [|| 'suffix' ...] into [strict] p_var;`
      a := i - 1;
      while a > 1 and not (k[a] = 'O' and t[a] = ';') and not (k[a] = 'I' and t[a] in ('begin', 'then', 'else', 'loop')) loop
        a := a - 1;
      end loop;
      p := null;
      if t[a + 1] = 'select' and k[a + 2] = 'I' and t[a + 2] in ('archive._object_key', 'archive._child_object_key')
         and t[a + 3] = '(' then
        p := t39.p0_close(k, t, a + 3) + 1;
        while p < i and k[p] = 'O' and t[p] = '||' and k[p + 1] = 'S' loop p := p + 2; end loop;
      end if;
      if p is distinct from i or j <> i + 1 + (t[i + 1] = 'strict')::int or t[j + 1] <> ';' then
        return format('%s is written by INTO, from something that is not a key a helper made', p_var);
      end if;
      v_assigned := true;
      continue;
    end if;
    -- a statement that begins with it: a declaration or an assignment
    if j = 1 or t[j - 1] in (';', 'begin', 'then', 'else', 'loop', 'declare', 'diagnostics') then
      a := null; d := 0; e := j + 1;
      while e <= n loop
        if k[e] = 'O' and t[e] = '(' then d := d + 1;
        elsif k[e] = 'O' and t[e] = ')' then d := d - 1;
        elsif d = 0 and k[e] = 'O' and t[e] = ';' then exit;
        elsif d = 0 and a is null and ((k[e] = 'O' and t[e] in (':=', '=')) or (k[e] = 'I' and t[e] = 'default')) then a := e;
        end if;
        e := e + 1;
      end loop;
      if a is not null then
        p := null;
        if k[a + 1] = 'I' and t[a + 1] in ('archive._object_key', 'archive._child_object_key') and t[a + 2] = '(' then
          p := t39.p0_close(k, t, a + 2) + 1;
        elsif k[a + 1] = 'I' and t[a + 1] = p_var then
          p := a + 2;
        end if;
        while p is not null and p < e and k[p] = 'O' and t[p] = '||' and k[p + 1] = 'S' loop p := p + 2; end loop;
        if p is distinct from e then
          return format('%s is assigned %s, which is not a key a helper made', p_var, array_to_string(t[a + 1 : e - 1], ' '));
        end if;
        v_assigned := true;
      end if;
    end if;
  end loop;
  return case when v_assigned then null else format('%s is never assigned from a key helper', p_var) end;
end $f$;

-- Every S3 request in the functions p_oids, one row each: the function, the call, and a verdict that
-- starts with 'ok' (a transport's own request, or a write whose key a helper made), 'read' (a GET, HEAD or
-- DELETE) or 'REFUSED' (a write, or a request, whose key this scan cannot trace to a key helper).
create or replace function t39.p0_audit(p_oids oid[]) returns table(fn text, call text, verdict text)
language plpgsql stable as $f$
declare
  v_req text[]; v_names text[] := '{}'; v_mpos int[] := '{}'; v_kpos int[] := '{}'; v_lit text;
  r record; lx record; k text[]; t text[]; n int; j int; c int; i int; d int; s int;
  v_starts int[]; v_ends int[]; v_args text[]; v_ix int; v_m int; v_kp int; v_verb text; v_key text; v_why text;
begin
  -- the http extension's request functions, bare and schema-qualified
  select array_agg(x) into v_req from (
    select q.x from pg_proc p join pg_depend dp on dp.classid = 'pg_proc'::regclass and dp.objid = p.oid and dp.deptype = 'e'
      join pg_extension e on e.oid = dp.refobjid and e.extname = 'http'
      cross join lateral (values (p.proname::text), (p.pronamespace::regnamespace::text || '.' || p.proname)) q(x)
     where p.prorettype = 'http_response'::regtype) s;
  -- the transports: the module's functions that call one of those directly
  for r in select p.oid, p.pronamespace::regnamespace::text as nsp, p.proname::text as name, p.proargnames, p.prosrc
             from pg_proc p where p.pronamespace in ('archive'::regnamespace, 'pgpm'::regnamespace)
  loop
    lx := t39.p0_lex(r.prosrc);
    if exists (select 1 from generate_subscripts(lx.t, 1) g
                where lx.k[g] = 'I' and lx.t[g] = any(v_req) and lx.t[g + 1] = '(') then
      v_names := v_names || array[r.nsp || '.' || r.name, r.name];
      v_mpos := v_mpos || array_fill(array_position(r.proargnames, 'p_method'), array[2]);
      v_kpos := v_kpos || array_fill(array_position(r.proargnames, 'p_key'), array[2]);
    end if;
  end loop;
  v_lit := '(^|[^A-Za-z0-9_.])(' || (select string_agg(regexp_replace(x, '([.$])', '\\\1', 'g'), '|') from unnest(v_names || v_req) x)
        || ')\s*\(';

  for r in select p.oid, p.oid::regprocedure::text as sig, p.proargnames, p.prosrc from pg_proc p where p.oid = any(p_oids) loop
    lx := t39.p0_lex(r.prosrc); k := lx.k; t := lx.t; n := cardinality(t);
    j := 0;
    while j < n loop
      j := j + 1;
      if k[j] = 'S' and t[j] ~ v_lit then
        fn := r.sig; call := 'a string literal';
        verdict := format('REFUSED: a literal names %s(: a request built as dynamic SQL, whose key cannot be followed',
                          (regexp_match(t[j], v_lit))[2]);
        return next; continue;
      end if;
      continue when k[j] <> 'I' or coalesce(t[j + 1], '') <> '(';
      if t[j] = any(v_req) then
        fn := r.sig; call := t[j] || '()';
        verdict := case when 'p_method' = any(r.proargnames) and 'p_key' = any(r.proargnames)
                        then 'ok: a transport''s own request, for its callers'' p_method and p_key'
                        else 'REFUSED: calls the http extension directly, with no p_method and p_key a caller''s key can be traced through' end;
        return next; continue;
      end if;
      v_ix := array_position(v_names, t[j]);
      continue when v_ix is null;
      -- the arguments, split at the commas of this call's own level
      c := t39.p0_close(k, t, j + 1);
      v_starts := array[j + 2]; v_ends := '{}'; d := 0; i := j + 2;
      while i < c loop
        if k[i] = 'O' and t[i] = '(' then d := d + 1;
        elsif k[i] = 'O' and t[i] = ')' then d := d - 1;
        elsif d = 0 and k[i] = 'O' and t[i] = ',' then v_ends := v_ends || (i - 1); v_starts := v_starts || (i + 1);
        end if;
        i := i + 1;
      end loop;
      v_ends := v_ends || (c - 1);
      v_m := v_mpos[v_ix]; v_kp := v_kpos[v_ix]; v_verb := null; v_key := null;
      for s in 1 .. cardinality(v_starts) loop   -- named notation, when the call uses it
        if k[v_starts[s]] = 'I' and t[v_starts[s] + 1] in ('=>', ':=') then
          if t[v_starts[s]] = 'p_method' then v_m := s; v_starts[s] := v_starts[s] + 2; end if;
          if t[v_starts[s]] = 'p_key' then v_kp := s; v_starts[s] := v_starts[s] + 2; end if;
        end if;
      end loop;
      fn := r.sig; call := t[j] || '()';
      if v_m is null or v_kp is null or v_m > cardinality(v_starts) or v_kp > cardinality(v_starts) then
        verdict := 'REFUSED: a call to a transport whose method and key arguments this scan cannot find';
        return next; continue;
      end if;
      if v_starts[v_m] = v_ends[v_m] and k[v_starts[v_m]] = 'S' and upper(t[v_starts[v_m]]) in ('GET', 'HEAD', 'DELETE') then
        verdict := 'read: ' || upper(t[v_starts[v_m]]);
        return next; continue;
      end if;
      v_verb := array_to_string(t[v_starts[v_m] : v_ends[v_m]], ' ');
      if v_starts[v_kp] = v_ends[v_kp] and k[v_starts[v_kp]] = 'I' and position('.' in t[v_starts[v_kp]]) = 0 then
        v_key := t[v_starts[v_kp]];
        if v_key = any(r.proargnames) then
          v_why := format('its key is the function''s own parameter %s, which this scan does not follow to a key helper', v_key);
        else
          v_why := t39.p0_key_unsafe(k, t, v_key);
        end if;
      else
        v_why := format('its key is %s, not a local assigned from a key helper', array_to_string(t[v_starts[v_kp] : v_ends[v_kp]], ' '));
      end if;
      verdict := case when v_why is null then format('ok: a write (%s) at %s, which a key helper made', v_verb, v_key)
                      else format('REFUSED: a write (%s): %s', v_verb, v_why) end;
      return next;
    end loop;
  end loop;
end $f$;

-- Seven sites the old scan passed or would, one per shape, and one that does it right; never run, only read.
create or replace function t39.p0_plant_named(p_parent regclass) returns int language plpgsql as $f$
-- the key is NOT taken from archive._object_key(...) here: it is assembled inline, unclaimed
declare v_key text := current_database() || '/t39/' || p_parent::text || '.ndjson';
begin
  return (archive.s3_signed_request('PUT', 'http://minio:9000', 'archive-test-bucket', 'us-east-1', v_key, '',
          'text/plain', '{"id":1}', 'minioadmin', 'minioadmin')).status;
end $f$;
create or replace function t39.p0_plant_varverb(p_parent regclass) returns int language plpgsql as $f$
declare v_verb text := 'P' || 'UT'; v_key text := current_database() || '/t39/' || p_parent::text || '.v.ndjson';
begin
  return (archive.s3_signed_request(v_verb, 'http://minio:9000', 'archive-test-bucket', 'us-east-1', v_key, '',
          'text/plain', '{"id":2}', 'minioadmin', 'minioadmin')).status;
end $f$;
create or replace function t39.p0_plant_second(p_parent regclass) returns int language plpgsql as $f$
declare v_claimed text := archive._child_object_key(p_parent, current_database() || '/t39/', 'c', '.ndjson');
        v_key text := current_database() || '/t39/' || p_parent::text || '.manifest.json';
begin
  perform archive.s3_signed_request('PUT', 'http://minio:9000', 'archive-test-bucket', 'us-east-1', v_claimed, '',
          'text/plain', '{"id":3}', 'minioadmin', 'minioadmin');
  return (archive.s3_signed_request('PUT', 'http://minio:9000', 'archive-test-bucket', 'us-east-1', v_key, '',
          'text/plain', '{"id":3}', 'minioadmin', 'minioadmin')).status;
end $f$;
create or replace function t39.p0_plant_prefixed(p_parent regclass) returns int language plpgsql as $f$
declare v_key text;
begin
  v_key := 'mirror/' || archive._child_object_key(p_parent, current_database() || '/t39/', 'c', '.ndjson');
  return (archive.s3_signed_request_bytea(p_method => 'PUT', p_endpoint => 'http://minio:9000', p_bucket => 'archive-test-bucket',
          p_region => 'us-east-1', p_key => v_key, p_query => '', p_ctype => 'text/plain', p_payload => '\x00'::bytea,
          p_key_id => 'minioadmin', p_secret => 'minioadmin')).status;
end $f$;
create or replace function t39.p0_plant_into(p_parent regclass) returns int language plpgsql as $f$
declare v_key text;
begin
  select c.relname || '.ndjson' into v_key from pg_class c where c.oid = p_parent;
  return (archive.s3_signed_request('PUT', 'http://minio:9000', 'archive-test-bucket', 'us-east-1', v_key, '',
          'text/plain', '{"id":6}', 'minioadmin', 'minioadmin')).status;
end $f$;
create or replace function t39.p0_plant_direct(p_parent regclass) returns int language plpgsql as $f$
begin
  return (http_put('http://minio:9000/archive-test-bucket/' || p_parent::text, '{"id":5}', 'text/plain')).status;
end $f$;
create or replace function t39.p0_plant_dynamic(p_parent regclass) returns int language plpgsql as $f$
declare v int;
begin
  execute format('select (archive.s3_signed_request(%L, %L, %L, %L, %L, '''', ''text/plain'', ''{}'', ''minioadmin'', ''minioadmin'')).status',
                 'PUT', 'http://minio:9000', 'archive-test-bucket', 'us-east-1', p_parent::text || '.ndjson') into v;
  return v;
end $f$;
create or replace function t39.p0_plant_right(p_parent regclass) returns int language plpgsql as $f$
declare v_verb text := 'PUT'; v_key text; v_chunk text;
begin
  v_key := archive._child_object_key(p_parent, current_database() || '/t39/', 'c', '.ndjson');
  v_key := v_key || '.gz';
  select archive._object_key(p_parent, current_database() || '/t39/', 'id', '0', '.parquet') into strict v_chunk;
  perform archive.s3_signed_request('GET', 'http://minio:9000', 'archive-test-bucket', 'us-east-1', p_parent::text, '',
          'text/plain', '', 'minioadmin', 'minioadmin');
  perform archive.s3_signed_request_bytea('PUT', 'http://minio:9000', 'archive-test-bucket', 'us-east-1', v_chunk, '',
          'application/vnd.apache.parquet', '\x00'::bytea, 'minioadmin', 'minioadmin');
  return (archive.s3_signed_request(v_verb, 'http://minio:9000', 'archive-test-bucket', 'us-east-1', v_key, '',
          'text/plain', '{"id":7}', 'minioadmin', 'minioadmin')).status;
end $f$;

drop table if exists t39_p0_module, t39_p0_plants;
create temp table t39_p0_module as select * from t39.p0_audit((select array_agg(p.oid) from pg_proc p
                        where p.pronamespace in ('archive'::regnamespace, 'pgpm'::regnamespace)));
create temp table t39_p0_plants as select * from t39.p0_audit((select array_agg(p.oid) from pg_proc p
                        where p.pronamespace = 't39'::regnamespace and p.proname like 'p0\_plant\_%'));

select set_eq($$select split_part(fn, '(', 1) from t39_p0_module where verdict like 'ok: a transport%'$$,
              array['archive.s3_signed_request', 'archive.s3_signed_request_bytea'],
  'LIVENESS: the scan finds the module''s transports, the two signers, and no other caller of the http extension');
select ok(array['archive._encode_upload_ndjson_single', 'archive._encode_upload_parquet', 'archive.to_s3', 'archive.to_s3_parquet']
            <@ (select array_agg(split_part(fn, '(', 1)) from t39_p0_module where verdict ~ '^(ok|REFUSED): a write'),
  'LIVENESS: the scan enumerates a write in each of the four functions known to PUT an object (judged below)');
select set_eq($$select verdict from t39_p0_module where fn like 'archive.\_s3\_abort\_uploads\_at(%'$$,
              array['read: GET', 'read: DELETE'],
  'LIVENESS: the scan reads archive._s3_abort_uploads_at''s listing GET and its abort DELETE as reads, not writes');
select set_eq($$select split_part(fn, '(', 1) from t39_p0_plants where verdict like 'REFUSED%'$$,
              array['t39.p0_plant_named', 't39.p0_plant_varverb', 't39.p0_plant_second', 't39.p0_plant_prefixed',
                    't39.p0_plant_into', 't39.p0_plant_direct', 't39.p0_plant_dynamic'],
  'LIVENESS: the scan refuses a planted write of every shape: a helper named in a comment, a verb in a variable, '
  'a second write at an inline key, a prefixed helper key, a key selected INTO, the http extension called '
  'directly, dynamic SQL');
select set_eq($$select verdict from t39_p0_plants where fn like 't39.p0\_plant\_right(%'$$,
              array['ok: a write (v_verb) at v_key, which a key helper made', 'read: GET',
                    'ok: a write (PUT) at v_chunk, which a key helper made'],
  'LIVENESS: the scan passes a planted site whose writes take their keys from a helper (a literal suffix, an INTO)');
select is((select array_agg(fn || ' ' || call || ': ' || verdict order by fn) from t39_p0_module
            where verdict like 'REFUSED%'),
          null::text[],
  'every S3 write the module makes takes its key from archive._object_key or archive._child_object_key');

-- ======================= PART A: archive.to_s3, plain NDJSON =======================

select t39.mk('ev', array['old', 'old']);
call pgpm.transmute('t39.ev', 'id', 10000::bigint);
select archive.configure('t39.ev', 'archive-test-bucket', p_endpoint => 'http://minio:9000', p_prefix => :'p');
select 't39.ev'::regclass::oid as a1_oid \gset
select child_name as a_child from pgpm.part where parent_table = 't39.ev'::regclass and lo = '0' \gset
select is(t39.clear(:'p' || 't39.' || :'a_child' || '.ndjson'), 404,
  'LIVENESS: no object at <prefix>t39.<child>.ndjson before the first table exports');
select archive.to_s3('t39.ev', :'a_child', '0', '10000');
select is(t39.rows(:'p' || 't39.' || :'a_child' || '.ndjson'), '1:old,2:old',
  'archive.to_s3: the first relation to export a child keeps the shape it always had, <prefix><schema>.<child>.ndjson');
select is((select parent_oid from archive.object_key_owner where key_base = :'p' || 't39.' || :'a_child'), :a1_oid::oid,
  'archive.to_s3: the export claimed <prefix>t39.<child> for the first table');

select ok(t39.retire_table('ev') > 0, 'LIVENESS: forget_missing() cleared the dropped first table');
select t39.mk('ev', array['new']);
call pgpm.transmute('t39.ev', 'id', 10000::bigint);
select archive.configure('t39.ev', 'archive-test-bucket', p_endpoint => 'http://minio:9000', p_prefix => :'p');
select 't39.ev'::regclass::oid as a2_oid \gset
select isnt(:a2_oid::oid, :a1_oid::oid, 'LIVENESS: the table that took the name is a different relation');
select is((select child_name from pgpm.part where parent_table = 't39.ev'::regclass and lo = '0'), :'a_child'::name,
  'LIVENESS: its [0, 10000) partition has the first table''s child name');
select is(t39.clear(:'p' || 't39.' || :'a_child' || '.' || :'a2_oid' || '.ndjson'), 404,
  'LIVENESS: no object at <prefix>t39.<child>.<oid>.ndjson before the namesake exports');
select archive.to_s3('t39.ev', :'a_child', '0', '10000');
select is(t39.rows(:'p' || 't39.' || :'a_child' || '.' || :'a2_oid' || '.ndjson'), '1:new',
  'archive.to_s3: the namesake''s export is at its own key, <prefix>t39.<child>.<oid>.ndjson, holding its row 1:new');
select is(t39.rows(:'p' || 't39.' || :'a_child' || '.ndjson'), '1:old,2:old',
  'archive.to_s3: the dropped table''s export, the only copy of rows 1:old and 2:old, is still at its key');

-- ======================= PART B: archive.to_s3, compressed =======================

select t39.mk('gz', array['old', 'old']);
call pgpm.transmute('t39.gz', 'id', 10000::bigint);
select archive.configure('t39.gz', 'archive-test-bucket', p_endpoint => 'http://minio:9000', p_prefix => :'p', p_compress => true);
select 't39.gz'::regclass::oid as b1_oid \gset
select child_name as b_child from pgpm.part where parent_table = 't39.gz'::regclass and lo = '0' \gset
-- what each generation's object must be, byte for byte: one gzip member over its NDJSON lines
select encode(archive._pq_gzip_compress_dynamic(convert_to(
         '{"id":1,"payload":"old"}' || e'\n' || '{"id":2,"payload":"old"}' || e'\n', 'UTF8')), 'hex') as b_old_hex \gset
select encode(archive._pq_gzip_compress_dynamic(convert_to('{"id":1,"payload":"new"}' || e'\n', 'UTF8')), 'hex') as b_new_hex \gset
select is(t39.clear(:'p' || 't39.' || :'b_child' || '.ndjson.gz'), 404,
  'LIVENESS: no object at <prefix>t39.<child>.ndjson.gz before the first table exports');
select archive.to_s3('t39.gz', :'b_child', '0', '10000');
select is(encode(t39.bytes(:'p' || 't39.' || :'b_child' || '.ndjson.gz'), 'hex'), :'b_old_hex',
  'archive.to_s3 compressed: the first relation''s object is the gzip of rows 1:old and 2:old at <prefix>t39.<child>.ndjson.gz');

select ok(t39.retire_table('gz') > 0, 'LIVENESS: forget_missing() cleared the dropped first compressed table');
select t39.mk('gz', array['new']);
call pgpm.transmute('t39.gz', 'id', 10000::bigint);
select archive.configure('t39.gz', 'archive-test-bucket', p_endpoint => 'http://minio:9000', p_prefix => :'p', p_compress => true);
select 't39.gz'::regclass::oid as b2_oid \gset
select is((select child_name from pgpm.part where parent_table = 't39.gz'::regclass and lo = '0'), :'b_child'::name,
  'LIVENESS: the compressed namesake''s partition has the first table''s child name');
select is(t39.clear(:'p' || 't39.' || :'b_child' || '.' || :'b2_oid' || '.ndjson.gz'), 404,
  'LIVENESS: no object at <prefix>t39.<child>.<oid>.ndjson.gz before the namesake exports');
select archive.to_s3('t39.gz', :'b_child', '0', '10000');
select is(encode(t39.bytes(:'p' || 't39.' || :'b_child' || '.' || :'b2_oid' || '.ndjson.gz'), 'hex'), :'b_new_hex',
  'archive.to_s3 compressed: the namesake''s object is the gzip of its row 1:new, at <prefix>t39.<child>.<oid>.ndjson.gz');
select is(encode(t39.bytes(:'p' || 't39.' || :'b_child' || '.ndjson.gz'), 'hex'), :'b_old_hex',
  'archive.to_s3 compressed: the dropped table''s object is still at its key, byte for byte');

-- ======================= PART C: archive.to_s3_parquet =======================

select t39.mk('pq', array['old', 'old']);
call pgpm.transmute('t39.pq', 'id', 10000::bigint);
select archive.configure('t39.pq', 'archive-test-bucket', p_endpoint => 'http://minio:9000', p_prefix => :'p');
select 't39.pq'::regclass::oid as c1_oid \gset
select child_name as c_child from pgpm.part where parent_table = 't39.pq'::regclass and lo = '0' \gset
select encode(archive._pq_to_parquet(format('t39.%I', :'c_child')::regclass, false), 'hex') as c_old_hex \gset
select is(t39.clear(:'p' || 't39.' || :'c_child' || '.parquet'), 404,
  'LIVENESS: no object at <prefix>t39.<child>.parquet before the first table exports');
select archive.to_s3_parquet('t39.pq', :'c_child', '0', '10000');
select is(encode(t39.bytes(:'p' || 't39.' || :'c_child' || '.parquet'), 'hex'), :'c_old_hex',
  'archive.to_s3_parquet: the first relation''s file is at <prefix>t39.<child>.parquet, byte for byte');

select ok(t39.retire_table('pq') > 0, 'LIVENESS: forget_missing() cleared the dropped first Parquet table');
select t39.mk('pq', array['new']);
call pgpm.transmute('t39.pq', 'id', 10000::bigint);
select archive.configure('t39.pq', 'archive-test-bucket', p_endpoint => 'http://minio:9000', p_prefix => :'p');
select 't39.pq'::regclass::oid as c2_oid \gset
select is((select child_name from pgpm.part where parent_table = 't39.pq'::regclass and lo = '0'), :'c_child'::name,
  'LIVENESS: the Parquet namesake''s partition has the first table''s child name');
select encode(archive._pq_to_parquet(format('t39.%I', :'c_child')::regclass, false), 'hex') as c_new_hex \gset
select isnt(:'c_new_hex'::text, :'c_old_hex'::text, 'LIVENESS: the two generations encode to different Parquet files');
select is(t39.clear(:'p' || 't39.' || :'c_child' || '.' || :'c2_oid' || '.parquet'), 404,
  'LIVENESS: no object at <prefix>t39.<child>.<oid>.parquet before the namesake exports');
select archive.to_s3_parquet('t39.pq', :'c_child', '0', '10000');
select is(encode(t39.bytes(:'p' || 't39.' || :'c_child' || '.' || :'c2_oid' || '.parquet'), 'hex'), :'c_new_hex',
  'archive.to_s3_parquet: the namesake''s file is at its own key, <prefix>t39.<child>.<oid>.parquet');
select is(encode(t39.bytes(:'p' || 't39.' || :'c_child' || '.parquet'), 'hex'), :'c_old_hex',
  'archive.to_s3_parquet: the dropped table''s file is still at its key, byte for byte');

-- ======================= PART D: the archive_fn NDJSON transport =======================

select t39.mk('an', array['old', 'old']);
call pgpm.transmute('t39.an', 'id', 10000::bigint, p_retain => 5000::bigint, p_paused => false);
insert into t39.an values (45000, 'frontier');   -- horizon 40000: [0, 10000) is aged
select archive.configure('t39.an', 'archive-test-bucket', p_endpoint => 'http://minio:9000', p_prefix => :'p');
select pgpm.set_archive_fn('t39.an', 'pgpm.archive_to_s3_ndjson(regclass,name,text,text)'::regprocedure);
select 't39.an'::regclass::oid as d1_oid \gset
select is(t39.clear(:'p' || 't39.an_0.ndjson'), 404, 'LIVENESS: no object at <prefix>t39.an_0.ndjson before the first table archives');
call pgpm.maintain('t39.an');
select is((select s3_key from pgpm.archive_ledger where parent_table = :d1_oid::oid::regclass and lo = '0'), :'p' || 't39.an_0.ndjson',
  'archive_to_s3_ndjson: the first relation keeps the shape it always had, <prefix><schema>.<table>_<stem>.ndjson');
select is(t39.rows(:'p' || 't39.an_0.ndjson'), '1:old,2:old',
  'archive_to_s3_ndjson: that object holds the first table''s rows 1:old and 2:old');

select ok(t39.retire_table('an') > 0, 'LIVENESS: forget_missing() cleared the dropped first NDJSON-archived table');
select t39.mk('an', array['new']);
call pgpm.transmute('t39.an', 'id', 10000::bigint, p_retain => 5000::bigint, p_paused => false);
insert into t39.an values (45000, 'frontier');
select archive.configure('t39.an', 'archive-test-bucket', p_endpoint => 'http://minio:9000', p_prefix => :'p');
select pgpm.set_archive_fn('t39.an', 'pgpm.archive_to_s3_ndjson(regclass,name,text,text)'::regprocedure);
select 't39.an'::regclass::oid as d2_oid \gset
select is(t39.clear(:'p' || 't39.an.' || :'d2_oid' || '_0.ndjson'), 404,
  'LIVENESS: no object at <prefix>t39.an.<oid>_0.ndjson before the namesake archives');
call pgpm.maintain('t39.an');
select is((select rows_archived from pgpm.archive_ledger where parent_table = :d2_oid::oid::regclass and lo = '0'), 1::bigint,
  'LIVENESS: the namesake archived its own [0, 10000), one row');
select is((select s3_key from pgpm.archive_ledger where parent_table = :d2_oid::oid::regclass and lo = '0'),
          :'p' || 't39.an.' || :'d2_oid' || '_0.ndjson',
  'archive_to_s3_ndjson: the namesake is keyed with its oid, <prefix>t39.an.<oid>_0.ndjson');
select is(t39.rows(:'p' || 't39.an.' || :'d2_oid' || '_0.ndjson'), '1:new',
  'archive_to_s3_ndjson: the namesake''s object holds exactly its row 1:new');
select is(t39.rows(:'p' || 't39.an_0.ndjson'), '1:old,2:old',
  'archive_to_s3_ndjson: the dropped table''s only copy of rows 1:old and 2:old is still at its key');

-- ======================= PART E: the archive_fn Parquet transport =======================

select t39.mk('ap', array['old', 'old']);
call pgpm.transmute('t39.ap', 'id', 10000::bigint, p_retain => 5000::bigint, p_paused => false);
insert into t39.ap values (45000, 'frontier');
select archive.configure('t39.ap', 'archive-test-bucket', p_endpoint => 'http://minio:9000', p_prefix => :'p');
select pgpm.set_archive_fn('t39.ap', 'pgpm.archive_to_s3_parquet(regclass,name,text,text)'::regprocedure);
select 't39.ap'::regclass::oid as e1_oid \gset
select is(t39.clear(:'p' || 't39.ap_0.parquet'), 404, 'LIVENESS: no object at <prefix>t39.ap_0.parquet before the first table archives');
call pgpm.maintain('t39.ap');
select is((select rows_archived from pgpm.archive_ledger where parent_table = :e1_oid::oid::regclass and lo = '0'), 2::bigint,
  'LIVENESS: the first Parquet-archived table archived its two rows');
select is((select s3_key from pgpm.archive_ledger where parent_table = :e1_oid::oid::regclass and lo = '0'), :'p' || 't39.ap_0.parquet',
  'archive_to_s3_parquet: the first relation keeps the shape it always had, <prefix><schema>.<table>_<stem>.parquet');
select encode(t39.bytes(:'p' || 't39.ap_0.parquet'), 'hex') as e_old_hex \gset
select ok(:'e_old_hex' like '50415231%', 'LIVENESS: the first table''s Parquet file (PAR1) is in the bucket');

select ok(t39.retire_table('ap') > 0, 'LIVENESS: forget_missing() cleared the dropped first Parquet-archived table');
select t39.mk('ap', array['new']);
call pgpm.transmute('t39.ap', 'id', 10000::bigint, p_retain => 5000::bigint, p_paused => false);
insert into t39.ap values (45000, 'frontier');
select archive.configure('t39.ap', 'archive-test-bucket', p_endpoint => 'http://minio:9000', p_prefix => :'p');
select pgpm.set_archive_fn('t39.ap', 'pgpm.archive_to_s3_parquet(regclass,name,text,text)'::regprocedure);
select 't39.ap'::regclass::oid as e2_oid \gset
select is(t39.clear(:'p' || 't39.ap.' || :'e2_oid' || '_0.parquet'), 404,
  'LIVENESS: no object at <prefix>t39.ap.<oid>_0.parquet before the namesake archives');
call pgpm.maintain('t39.ap');
select is((select rows_archived from pgpm.archive_ledger where parent_table = :e2_oid::oid::regclass and lo = '0'), 1::bigint,
  'LIVENESS: the Parquet namesake archived its own [0, 10000), one row');
select is((select s3_key from pgpm.archive_ledger where parent_table = :e2_oid::oid::regclass and lo = '0'),
          :'p' || 't39.ap.' || :'e2_oid' || '_0.parquet',
  'archive_to_s3_parquet: the namesake is keyed with its oid, <prefix>t39.ap.<oid>_0.parquet');
select ok(encode(t39.bytes(:'p' || 't39.ap.' || :'e2_oid' || '_0.parquet'), 'hex') like '50415231%'
          and encode(t39.bytes(:'p' || 't39.ap.' || :'e2_oid' || '_0.parquet'), 'hex') <> :'e_old_hex',
  'archive_to_s3_parquet: the namesake''s key holds a Parquet file of its own, not a copy of the first');
select is(encode(t39.bytes(:'p' || 't39.ap_0.parquet'), 'hex'), :'e_old_hex',
  'archive_to_s3_parquet: the dropped table''s file is still at its key, byte for byte');

select * from finish();
