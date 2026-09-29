-- archive._pq_huffman_lengths runs three times per GZIP encode (the literal/length, distance and
-- code-length alphabets), and it used to build its merge queue in a temp table it created and dropped
-- on every call. A dropped relation's locks are held to transaction end, so every call left ~15
-- entries in the SHARED lock table until commit, ~44 per encode. pgpm._archive_step archives one
-- chunk of each of up to archive_batch partitions in ONE transaction and a compressed Parquet chunk
-- runs one encode per column, so a tick over 25 partitions of a 29-column table (~725 encodes)
-- exhausted the cluster's lock table at the default max_locks_per_transaction (53200 out of shared
-- memory, for every session while it lasted), logged skip_archive, archived nothing and did the same
-- again every tick (issue #587). archive.to_s3 with compress on hit the same cliff at ~600 members.
--
-- The contract: an encode takes no lock-table entry of its own, so the number a transaction holds does
-- not grow with the number of encodes it runs. The issue's reproduction proves the cliff end to end
-- and takes ~35 s filling the cluster's lock table; this file measures the cause directly instead,
-- from inside one transaction (pg_locks shows a backend's own locks live, and they are held to
-- transaction end, which is exactly what makes them accumulate). t22.lock_growth runs a statement N
-- times in ONE call, so one transaction, after one warm-up run whose one-time locks (catalogs, the
-- functions' first plans) are not the per-call growth being measured, and returns the lock entries
-- present afterwards that were not present before, by identity.
--
-- Each zero is paired with its witnesses: the instrument DOES see a dropped temp table's held locks
-- (the control below, the exact mechanism of the defect), the lengths the zero-growth calls return
-- are a real, exactly complete multi-symbol code, and the encode is the DYNAMIC Huffman path (the one
-- that calls _pq_huffman_lengths), not the fixed-Huffman rung. The known-answer vectors pin that the
-- lengths, and one full GZIP member byte for byte, are what the temp-table implementation produced,
-- so the change of data structure changed no archived byte.
select plan(15);

create schema t22;

-- Lock entries held by this backend, one text key per entry, by identity.
create function t22.my_locks() returns text[] language sql as $$
  select coalesce(array_agg(k order by k), '{}') from (
    select concat_ws('|', locktype, database, relation, page, tuple, virtualxid, transactionid,
                     classid, objid, objsubid, mode) as k
      from pg_locks where pid = pg_backend_pid()) s
$$;

-- Run p_sql once to warm up, then p_reps more times, all in the caller's one transaction; return the
-- lock entries the p_reps runs added.
create function t22.lock_growth(p_sql text, p_reps int) returns int language plpgsql as $$
declare v_before text[]; v_after text[]; i int;
begin
  execute p_sql;
  v_before := t22.my_locks();
  for i in 1..p_reps loop
    execute p_sql;
  end loop;
  v_after := t22.my_locks();
  return (select count(*) from unnest(v_after) k where k <> all (v_before))::int;
end $$;

-- The control's statement: the defect's own mechanism, a temp table created and dropped in one call.
create function t22.temp_table_round_trip() returns int language plpgsql as $$
begin
  create temp table t22_probe (node_id int4 primary key, freq bigint) on commit drop;
  drop table t22_probe;
  return 1;
end $$;

-- A 286-symbol literal/length histogram with every symbol used and no two frequencies alike, so the
-- merge sequence is long and the tie rule never decides it.
create table t22.freqs as
  select array_agg(((g * 7919) % 100003 + 1)::bigint order by g) as f from generate_series(1, 286) g;

-- The payload: text with repeats at several distances, so the encoder emits matches and literals and
-- all three alphabets are non-trivial. Built in memory on every call, as the archive path builds a
-- column's bytes, not read from a table: a stored copy is compressed in place, and fed from one the
-- encodes in a single statement slowed by two orders of magnitude after the fifth (measured: three in
-- 0.5 s, six in 39 s), a cost that has nothing to do with what this file measures.
create function t22.payload() returns bytea language sql as $$
  select convert_to(
    (select string_agg('row ' || g || ' ' || (g * 7919 % 1000) || ' ' || repeat(chr(97 + g % 26), g % 5), E'\n')
       from generate_series(1, 2000) g), 'UTF8')
$$;

-- 1-2. The instrument: it sees this backend's locks at all, and it sees the defect's mechanism.
select cmp_ok(cardinality(t22.my_locks()), '>', 0,
  'witness: pg_locks shows this backend''s own lock entries from inside its transaction');
select cmp_ok(t22.lock_growth('select t22.temp_table_round_trip()', 5), '>=', 5,
  'control: five temp tables created and dropped in one transaction leave their lock entries held '
  'to its end (the defect''s mechanism, so a zero below is not an instrument that sees nothing)');

-- 3-5. archive._pq_huffman_lengths itself: twenty calls, no lock entry added, and a real code.
select is(t22.lock_growth('select archive._pq_huffman_lengths((select f from t22.freqs), 15)', 20), 0,
  'twenty _pq_huffman_lengths calls in one transaction add no lock-table entry');
select is((select count(*) from unnest(archive._pq_huffman_lengths((select f from t22.freqs), 15)) l where l > 0),
  286::bigint, 'witness: those calls assign a code length to all 286 symbols');
select is((select sum(power(2, 15 - l)::bigint) from unnest(archive._pq_huffman_lengths((select f from t22.freqs), 15)) l
            where l > 0),
  32768::numeric, 'witness: and the code they return is exactly complete within 15 bits (Kraft sum 2^15)');

-- 6-7. The whole GZIP encode, the unit the issue counts (three Huffman builds each).
select is(t22.lock_growth('select archive._pq_gzip_compress_dynamic(t22.payload())', 10), 0,
  'ten dynamic-Huffman GZIP encodes in one transaction add no lock-table entry');
select is((get_byte(archive._pq_gzip_compress_dynamic(t22.payload()), 10) >> 1) & 3, 2,
  'witness: that encode''s first DEFLATE block is BTYPE=10, dynamic Huffman, the path that builds three codes');

-- 8-15. Known answers, computed with the temp-table implementation at db64096: the new data
-- structure must build the same codes, ties included.
select is(archive._pq_huffman_lengths(array[5,9,12,13,16,45]::bigint[], 15), array[4,4,3,3,3,1],
  'known answer: the textbook six-symbol code');
select is(archive._pq_huffman_lengths(array[1,1,2,2]::bigint[], 15), array[2,2,2,2],
  'known answer: a tie between equal groups goes to the earliest-created one ({3,3,2,1} if it went to the newest)');
select is(archive._pq_huffman_lengths(array[0,3,0,1,1]::bigint[], 15), array[0,1,0,2,2],
  'known answer: unused symbols get length 0 and the used ones a code among themselves');
select is(archive._pq_huffman_lengths(array[0,0,7,0]::bigint[], 15), array[0,0,1,0],
  'known answer: a lone used symbol gets length 1');
select is(archive._pq_huffman_lengths(array[0,0,0]::bigint[], 15), array[0,0,0],
  'known answer: no used symbol, no code');
select is(archive._pq_huffman_lengths(
    (with recursive f(i, a, b) as (select 1, 1::bigint, 1::bigint union all select i + 1, b, a + b from f where i < 27)
     select array_agg(a order by i) from f), 15),
  array[15,15,15,15,15,15,15,15,15,15,15,15,15,15,15,15,11,10,9,8,7,6,5,4,3,2,1],
  'known answer: the 27-symbol Fibonacci worst case, length-limited to 15');
select is(archive._pq_huffman_lengths(array[40,0,3,9,1,1,1,1,1,1,1,1,1,1,1,1,0,5,2]::bigint[], 7),
  array[1,0,4,3,6,6,6,6,6,6,6,6,6,6,5,5,0,4,5],
  'known answer: a code-length-code alphabet length-limited to 7');
select is(md5(archive._pq_gzip_compress_dynamic(t22.payload())), 'e10b5a42bec1cc484fd20db8152b20c5',
  'known answer: the payload''s GZIP member is byte for byte what the temp-table implementation produced');

select * from finish();
