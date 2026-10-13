#!/bin/bash
# ACC-03 rebuilt by the claims verifier (round 2). The finder's repro.sh typed the half-remedy (the cutover alone after
# the ALTER, which the cutover's shape check rightly refuses) and its LIVENESS line grepped for round 1's message text,
# so it could pass on no head that keeps the shape check. This version pins the contract instead: on the two-phase
# path, the timestamp(p) refusal from_hypertable_cutover raises (#1232) must name the re-copy, and its remedy, TYPED
# AS THE MESSAGE PRINTS IT, must migrate the table with every row. "Typed as printed" is decided from the message:
#   names a re-run of from_hypertable_copy -> ALTER, from_hypertable_copy, then the cutover
#   else names from_hypertable_cutover      -> ALTER, then the cutover
#   else names transmute                    -> ALTER, then transmute (the pre-#1232 remedy)
# Fixture: u1, a keyless timestamptz(0) hypertable holding v = 1,2,3, copied, then cut over with '500 milliseconds'.
set -u
fail=0
q() { $PSQL -X -tA -v ON_ERROR_STOP=1 -c "$1"; }
qe() { $PSQL -X -tA -c "$1" 2>&1; }
check() { if [ "$2" = "$3" ]; then echo "ok - $1"; else echo "not ok - $1 (got '$2', want '$3')"; fail=1; fi; }
state() { q "select (select count(*) from timescaledb_information.hypertables where hypertable_name = 'u1') || '/' || (select string_agg(v::text, ',' order by v) from public.u1) || '/' || (pgpm._from_hypertable_scratch('public.u1', 'hypertable_dest') is not null)::text"; }

q "create extension if not exists timescaledb" >/dev/null 2>&1
q "create table public.u1 (ts timestamptz(0) not null, v int)" >/dev/null
q "select create_hypertable('public.u1', 'ts', chunk_time_interval => interval '1 day')" >/dev/null
q "insert into public.u1 select date_trunc('second', now() - g * interval '20 hours'), g from generate_series(1, 3) g" >/dev/null
q "call pgpm.from_hypertable_copy('public.u1', 'ts')" >/dev/null 2>&1
check "fixture: u1 is a timestamptz(0) hypertable holding 1,2,3 with its copy recorded" "$(state)" "1/1,2,3/true"

out=$(qe "call pgpm.from_hypertable_cutover('public.u1', 'ts', interval '500 milliseconds', p_predrain => false)")
msg=$(echo "$out" | grep -m1 'ERROR:')
echo "$msg" | grep -o 'widen the column.*' | cut -c1-400 | sed 's/^/# remedy: /'
check "LIVENESS: the cutover refused '500 milliseconds' on the timestamptz(0) key, offering to widen the column with the ALTER TABLE" \
  "$(echo "$msg" | grep -c 'keeps whole seconds only.*ALTER TABLE u1 ALTER COLUMN ts TYPE timestamp with time zone')" "1"
check "LIVENESS: u1 is still a hypertable, its copy still recorded, holding 1,2,3" "$(state)" "1/1,2,3/true"

recopy=$(echo "$msg" | grep -cE 're-?run(ning)? (pgpm\.)?from_hypertable_copy')
check "the refusal names re-running from_hypertable_copy (the copy keeps the type it was made with)" "$recopy" "1"

alt=$(qe "alter table public.u1 alter column ts type timestamp with time zone")
check "GUARD: the ALTER TABLE the message gives ran on the hypertable" "$(echo "$alt" | grep -c ERROR)" "0"
if [ "$recopy" = 1 ]; then
  echo "# typing: from_hypertable_copy, then from_hypertable_cutover"
  r1=$(qe "call pgpm.from_hypertable_copy('public.u1', 'ts')")
  r2=$(qe "call pgpm.from_hypertable_cutover('public.u1', 'ts', interval '500 milliseconds', p_obtain => 2)")
elif echo "$msg" | grep -q 'pgpm.from_hypertable_cutover'; then
  echo "# typing: from_hypertable_cutover alone"
  r1=""
  r2=$(qe "call pgpm.from_hypertable_cutover('public.u1', 'ts', interval '500 milliseconds', p_obtain => 2)")
else
  echo "# typing: transmute"
  r1=""
  r2=$(qe "call pgpm.transmute('public.u1', 'ts', interval '500 milliseconds', 2)")
fi
echo "$r1$r2" | grep -m1 ERROR | cut -c1-260 | sed 's/^/# re-run: /'
check "the remedy as printed runs without a refusal" "$(echo "$r1$r2" | grep -c ERROR)" "0"
check "u1 is migrated by the remedy as printed: partitioned, registered, holding 1,2,3" \
  "$(q "select (select relkind::text from pg_class where oid = 'public.u1'::regclass) || '/' || (select count(*) from pgpm.config where parent_table = 'public.u1'::regclass) || '/' || coalesce((select string_agg(v::text, ',' order by v) from public.u1), '')")" "p/1/1,2,3"
exit $fail
