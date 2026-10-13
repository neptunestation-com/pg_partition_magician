# _from_hypertable_check_arguments does not ask transmute's mixed month-and-duration step rule before the copy and swap (pass 12 RC11)

Tier: 3

Age: young | Lens: operator error

Found in adversarial review pass 12 at `bd55f84021fc4173034d156a41bc91a3f882560d`, root-cause group RC11: F16r-01.

## F16r-01

- finder: F16r
- location: `pgpm_hypertable/install.sql:439`
- lens: operator error
- tier: 3
- scenario: from_hypertable / from_hypertable_cutover with a mixed month + duration p_interval ('1 mon 1 day') copy, commit the swap (hypertable dropped, incoming FK dropped) and only then hit transmute's 'mixed month + duration interval unsupported', leaving a plain unmanaged table; _from_hypertable_check_arguments should ask that transmute rule before the copy/swap as it does the sign rules (#1085), and '1 mon -40 days' is refused by the frontier check with a delete-the-newest-rows remedy, which tests/timescale/db/58 lines 78-81 pin as correct
- root cause (verifier): _from_hypertable_check_arguments (pgpm_hypertable/install.sql:434) does not ask transmute's mixed month + duration step rule (pgpm._grid_floor, pgpm_core/install.sql:1638), which _refuse_bad_transmute_arguments reads as positive, so from_hypertable and from_hypertable_cutover with p_interval '1 mon 1 day' copy, commit the swap (hypertable and incoming FK dropped) and are refused only at the handoff, leaving a plain unmanaged table (rows intact); and '1 mon -40 days' reaches the frontier check, whose limit lies in the past, and is refused with a delete-the-newest-rows remedy (tests/timescale/db/58 pins only the 'cannot migrate hypertable' prefix). Breaks docs/reference.md's '`transmute`'s argument rules are asked first' contract. Reproduced unchanged on the pristine tree (by the classifier and by hand: mx_a and mx_b left relkind r, 0 FKs, unregistered). Not known-open: #1221 is the #455 session-zone rule and #1232 is _time_unit_contract's remedy text, different rules on the same pre-swap contract. Tier 3, as #1221: no row lost, the documented handoff remedy finishes it, but the call acts where it should refuse.

Reproduction: `repro.sh`, the finder's, run unchanged by the verifier.

```bash
#!/bin/bash
# from_hypertable / from_hypertable_cutover do not ask transmute's "mixed month + duration" step rule before
# the swap. transmute refuses such a p_interval (pgpm._grid_floor: 'mixed month + duration interval
# unsupported'), but pgpm._from_hypertable_check_arguments asks only _refuse_bad_transmute_arguments and
# _time_unit_contract, neither of which knows that rule. So the copy runs, the swap commits (hypertable dropped,
# incoming key dropped), and only the handoff refuses: a plain, unmanaged table is left under the name, which
# is exactly the #1085 shape docs/reference.md says is asked "first ... with the hypertable untouched".
# Fixture: three keyed hypertables, each referenced by one row of its own referencing table.
#   a: from_hypertable with '1 mon 1 day'        -> must be refused with a still a hypertable, FK in place
#   b: copied, then from_hypertable_cutover '1 mon 1 day' -> same
#   c: the control, from_hypertable with '1 month' -> migrates (the harness and the path work)
# and the frontier refusal of '1 mon -40 days', which names a remedy that deletes rows (#1085's other half).
set -u
fail=0
q() { $PSQL -X -tA -v ON_ERROR_STOP=1 -c "$1"; }
qe() { $PSQL -X -tA -c "$1" 2>&1; }   # a statement expected to fail: its output, error included

q "create extension if not exists timescaledb" >/dev/null 2>&1
for t in a b c; do
  q "create table public.mx_$t (id bigint not null, ts timestamptz not null, v int, primary key (id, ts))" >/dev/null
  q "select create_hypertable('public.mx_$t', 'ts', chunk_time_interval => interval '1 day')" >/dev/null
  q "insert into public.mx_$t select g, now() - g * interval '20 hours', g * 10 from generate_series(1, 3) g" >/dev/null
  q "create table public.mx_${t}_ref (rid int primary key, h_id bigint, h_ts timestamptz,
       constraint mx_${t}_ref_fk foreign key (h_id, h_ts) references public.mx_$t (id, ts))" >/dev/null
  q "insert into public.mx_${t}_ref select 1, id, ts from public.mx_$t where id = 2" >/dev/null
done
q "call pgpm.from_hypertable_copy('public.mx_b', 'ts')" >/dev/null

state() {   # hypertable?/incoming key present?/registered?/rows
  q "select (select count(*) from timescaledb_information.hypertables where hypertable_name = '$1')
            || '/' || (select count(*) from pg_constraint where conname = '$1_ref_fk')
            || '/' || (select count(*) from pgpm.config where parent_table = to_regclass('public.$1'))
            || '/' || (select string_agg(id::text, ',' order by id) from public.$1)"
}
check() {   # $1 label, $2 got, $3 want
  if [ "$2" = "$3" ]; then echo "ok - $1"; else echo "not ok - $1 (got '$2', want '$3')"; fail=1; fi
}

check "LIVENESS: (A) mx_a and mx_b are hypertables, each referenced by its key, unregistered, holding 1,2,3" \
  "$(state mx_a) $(state mx_b)" "1/1/0/1,2,3 1/1/0/1,2,3"

out_a=$(qe "call pgpm.from_hypertable('public.mx_a', 'ts', interval '1 mon 1 day')")
out_b=$(qe "call pgpm.from_hypertable_cutover('public.mx_b', 'ts', interval '1 mon 1 day')")
echo "$out_a" | grep -m1 ERROR | sed 's/^/# a: /'
echo "$out_b" | grep -m1 ERROR | sed 's/^/# b: /'
check "LIVENESS: (B) both calls with p_interval '1 mon 1 day' were refused" \
  "$(echo "$out_a" | grep -c 'ERROR:  pg_partition_magician:')/$(echo "$out_b" | grep -c 'ERROR:  pg_partition_magician:')" "1/1"

check "from_hypertable refused '1 mon 1 day' before its copy: mx_a is still a hypertable, its incoming key in place" \
  "$(state mx_a)" "1/1/0/1,2,3"
check "from_hypertable_cutover refused '1 mon 1 day' before its swap: mx_b is still a hypertable, its incoming key in place" \
  "$(state mx_b)" "1/1/0/1,2,3"

out_n=$(qe "call pgpm.from_hypertable('public.mx_c', 'ts', interval '1 mon -40 days')")
echo "$out_n" | grep -m1 ERROR | cut -c1-200 | sed 's/^/# c: /'
check "LIVENESS: (C) the '1 mon -40 days' call on mx_c was refused" \
  "$(echo "$out_n" | grep -c 'ERROR:  pg_partition_magician:')" "1"
check "a '1 mon -40 days' step is not refused by the frontier check with a remedy that deletes the newest rows" \
  "$(echo "$out_n" | grep -c 'Delete or correct the rows')" "0"

q "call pgpm.from_hypertable('public.mx_c', 'ts', interval '1 month', p_paused => true)" >/dev/null 2>&1
check "LIVENESS: (D) the control mx_c migrates with a pure month step: partitioned, registered, its key back, every row" \
  "$(q "select (select relkind::text from pg_class where oid = 'public.mx_c'::regclass)
              || '/' || (select count(*) from pgpm.config where parent_table = 'public.mx_c'::regclass)
              || '/' || (select count(*) from pg_constraint where conname = 'mx_c_ref_fk')
              || '/' || (select string_agg(id::text, ',' order by id) from public.mx_c)")" "p/1/1/1,2,3"
exit $fail
```

Acceptance: the reproduction(s) above fail on bd55f84021fc4173034d156a41bc91a3f882560d and must pass on the fixing commit; the fix carries a bench/ guard and a bench/mutations entry proven by ./test.sh discriminate.



