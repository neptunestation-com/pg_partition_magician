#!/usr/bin/env bash
# Prove that each conservation assertion issues #1374 and #1375 rewrote FAILS against the wrong state it
# names, by planting that state in the test file right before the assertion and running the file: an
# assertion that also passes against the state it exists to reject is not evidence of anything.
#
# WHY THIS GUARD EXISTS (issues #1374 and #1375, pass 13 RC13 and RC14). The repo's oldest class (CLAUDE.md,
# "Assertions that pass for the wrong reason"): core tests asserted that rows, a constraint or a set of
# managed tables were conserved by COUNT, where the claim is WHICH ones. A lost row and a stray one cancel in
# a count, a status() that lists one table twice and another not at all keeps the count of config rows, a
# table whose UNIQUE (ts, id) is gone still counts one UNIQUE when another stands, and tests/338's "keeps its
# rows, 1 to N" sampled only ids 1, N and N+1 (tests/261, 319 and 108 a handful of ids under "every row" and
# "the rest remain"), so a table that lost the rows between them passed. Each site now names the rows (or
# parents, or the constraint by name and key) it claims, over fixtures whose rows differ from one another, so
# the wrong state cannot cancel.
#
# HOW. Per site, in a fresh database <db> in <container> cloned from a template carrying pgtap and this
# checkout's pgpm_core/install.sql (and fixtures/demo.sql, which tests/79, 105 and 108 expect beside them):
#   CONTROL   each judged file passes, every planned assertion ok, as written (once per file);
#   DEFECT    a copy of the file with the wrong state spliced in right before the site's assertion (and, where
#             a later assertion reads the same rows, undone right after it) reports at least one `not ok`
#             that is not a premise, and runs to its end. The premise rule is bench/discriminate.sh's
#             starved(), read out of that script (#1176), as bench/tests_fail_on_defect.sh reads it;
#   LIVENESS  the splice records what it left in public.g12_witness, read after the file: the wrong state was
#             really there (the row lost, the stray present, the count the old assertion read unchanged; the
#             broken status() or progress() as many rows as config, one parent short). A splice that planted
#             nothing would make the DEFECT run's failure meaningless.
# Each site's splice is judged alone, in its own run, so a mutation that puts back one site's count is caught
# by that site's DEFECT and not by another site's failure in the same file.
#
# The mutations it is required to fail against (bench/mutations/mutate.py), each one site's pre-fix shape:
#   t51_unique_constraint_by_count    t51_round_trip_rows_by_count     t52_keyless_rows_by_count
#   t67_rename_tick_rows_by_count     t69_cancelled_source_rows_by_count t70_resumed_rows_by_count
#   t74_aged_rows_by_count            t74_partly_aged_rows_by_count    t74_regrained_rows_by_count
#   t79_status_parents_by_count       t79_orphan_rows_by_count         t80_converted_rows_by_count
#   t88_text_time_rows_by_count       t91_ulid_rows_by_count           t91_ksuid_rows_by_count
#   t105_progress_parents_by_count    t105_progress_dead_parent_by_count t108_status_parents_by_count
#   t115_overshoot_rows_by_count      t115_wedged_rows_by_count        t121_aged_rows_by_count
#   t295_history_rows_by_count        t338_restored_rows_endpoints_a   t338_restored_rows_endpoints_b
#   t338_uninstalled_rows_endpoints_d t93_fan_out_by_ledger_rows       t108_rows_after_regrain_sampled
#   t261_rows_after_swap_sampled_a    t261_rows_after_swap_sampled_b   t319_rows_after_swap_sampled
#
# Usage: tests_identity_not_count.sh <container> <db> [test file]
# With no third argument it judges every site. With one it judges that file: a mutant bench/discriminate.sh
# built (<mutation>.sql) is judged at that mutation's site alone, a test file named as itself at all of its
# sites; a /repo/... path is mapped to this checkout. Files and installs reach the container over stdin, so it
# need not mount the repository; it needs pgtap (the plain core image has it) and python3 on the host.
# <db> also names the template (<db>_tmpl).
set -uo pipefail
C="${1:?container}"; DB="${2:?db}"; ONLY="${3:-}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMPL="${DB}_tmpl"
UNINSTALL="/tmp/${DB}_uninstall.sql"
fail=0
say() { printf '%s  %-62s %s\n' "$1" "$2" "$3"; }
q() { docker exec -i "$C" psql -U postgres -X "$@"; }
v() { q -d "$DB" -tAq -c "$1" </dev/null 2>&1; }
work=$(mktemp -d)
cleanup() {
  q -d postgres -q -c "drop database if exists $DB" </dev/null >/dev/null 2>&1
  q -d postgres -q -c "drop database if exists $TMPL" </dev/null >/dev/null 2>&1
  docker exec "$C" rm -f "$UNINSTALL" </dev/null >/dev/null 2>&1
  rm -rf "$work"
}
trap cleanup EXIT

# file_of <n>: the test file a site's number names, in this checkout
file_of() {
  case "$1" in
    51) echo tests/51_unique_constraint_untransmute_test.sql ;;
    52) echo tests/52_keyless_transmute_test.sql ;;
    67) echo tests/67_regrain_name_collision_test.sql ;;
    69) echo tests/69_regrain_capture_apparatus_test.sql ;;
    70) echo tests/70_transmute_phases_test.sql ;;
    74) echo tests/74_regrain_archive_gate_test.sql ;;
    79) echo tests/79_status_survives_dropped_parent_test.sql ;;
    80) echo tests/80_transmute_outgoing_fk_test.sql ;;
    88) echo tests/88_text_time_transmute_test.sql ;;
    91) echo tests/91_text_time_ulid_ksuid_transmute_test.sql ;;
    93) echo tests/93_archive_batch_test.sql ;;
    105) echo tests/105_progress_freeze_test.sql ;;
    108) echo tests/108_retain_sign_test.sql ;;
    115) echo tests/115_archive_contract_test.sql ;;
    121) echo tests/121_regrain_recheck_aged_at_swap_test.sql ;;
    295) echo tests/295_regrain_key_column_named_pgpm_seq_test.sql ;;
    261) echo tests/261_regrain_step_retarget_in_flight_test.sql ;;
    319) echo tests/319_set_regrain_restated_target_test.sql ;;
    338) echo tests/338_regrain_capture_fn_any_schema_test.sql ;;
  esac
}
SITES="t51_unique_constraint_by_count t51_round_trip_rows_by_count t52_keyless_rows_by_count
  t67_rename_tick_rows_by_count t69_cancelled_source_rows_by_count t70_resumed_rows_by_count
  t74_aged_rows_by_count t74_partly_aged_rows_by_count t74_regrained_rows_by_count
  t79_status_parents_by_count t79_orphan_rows_by_count t80_converted_rows_by_count
  t88_text_time_rows_by_count t91_ulid_rows_by_count t91_ksuid_rows_by_count
  t105_progress_parents_by_count t105_progress_dead_parent_by_count t108_status_parents_by_count
  t115_overshoot_rows_by_count t115_wedged_rows_by_count t121_aged_rows_by_count
  t295_history_rows_by_count t338_restored_rows_endpoints_a t338_restored_rows_endpoints_b
  t338_uninstalled_rows_endpoints_d t93_fan_out_by_ledger_rows t108_rows_after_regrain_sampled
  t261_rows_after_swap_sampled_a t261_rows_after_swap_sampled_b t319_rows_after_swap_sampled"
# site_n <site>: the number of the file a site lives in
site_n() { local n="${1#t}"; echo "${n%%_*}"; }

# ---- the splices -----------------------------------------------------------------------------------------------
# trig <off|on> <parent> <trigger>: SQL that disables, or re-enables ALWAYS, <trigger> on every partition of
# <parent> carrying it (retention's write block, regrain's capture), so a splice can plant its state in a frozen
# or captured partition and leave the fence as it found it.
trig() {
  local how="disable"; [ "$1" = on ] && how="enable always"
  printf '%s\n' "do \$g12t\$ declare r record; begin
  for r in select c.oid::regclass as rel from pg_inherits i join pg_class c on c.oid = i.inhrelid
            where i.inhparent = '$2'::regclass
              and exists (select 1 from pg_trigger t where t.tgrelid = c.oid and t.tgname = '$3') loop
    execute format('alter table %s $how trigger %I', r.rel, '$3');
  end loop;
end \$g12t\$;"
}
# swap_fn <status|progress>: SQL that sets the real function aside and puts in its place one that omits the
# managed table of the lowest oid and lists the one of the highest oid twice: as many rows as config, one parent
# short. unswap_fn puts the real one back.
swap_fn() {
  local sig="$1()" arg="" params=""
  if [ "$1" = progress ]; then sig="progress(regclass)"; arg="p_parent"; params="p_parent regclass default null"; fi
  printf '%s\n' "alter function pgpm.$sig rename to g12_real_$1;
do \$g12s\$ begin
  execute format('create function pgpm.$1($params) returns %s language sql as %L',
    pg_get_function_result('pgpm.g12_real_$sig'::regprocedure),
    'select * from pgpm.g12_real_$1($arg) s where s.parent::oid <> (select min(parent_table::oid) from pgpm.config)
     union all
     select * from pgpm.g12_real_$1($arg) s where s.parent::oid = (select max(parent_table::oid) from pgpm.config)');
end \$g12s\$;
create table public.g12_witness as
  select ((select count(*) from pgpm.$1()) = (select count(*) from pgpm.config))::text || ':'
         || ((select count(distinct parent) from pgpm.$1()) = (select count(*) from pgpm.config) - 1)::text as w;"
}
unswap_fn() {
  local sig="$1()"; [ "$1" = progress ] && sig="progress(regclass)"
  printf '%s\n' "drop function pgpm.$sig;
alter function pgpm.g12_real_$sig rename to $1;"
}
# witness <sql>: the splice's record of the state it planted
witness() { printf 'create table public.g12_witness as select (%s)::text as w;\n' "$1"; }
# rows_witness <table> <predicate on the count> <lost id> <stray id>: <rows>:<lost id present>:<stray present>
rows_witness() {
  witness "select count(*) || ':' || bool_or(id = $3)::text || ':' || bool_or(id = $4)::text from $1 where $2"
}

# site_def <site>: the site's file, the text its splice follows (PRE), the splice, and, where a later assertion
# reads the same rows, the text the undo follows (POST) and the undo; the witness the splice leaves (WANT).
site_def() {
  PRE=""; SPLICE=""; POST=""; UNDO=""; WANT=""; WHAT=""
  case "$1" in
    t51_unique_constraint_by_count)
      PRE="  'r', 'the table is a plain table again');
"
      SPLICE="alter table public.uq_rt drop constraint uq_rt_key;
alter table public.uq_rt add constraint uq_rt_other unique (body);
$(witness "select count(*) || ':' || string_agg(conname, ',') from pg_constraint
            where conrelid = 'public.uq_rt'::regclass and contype in ('p', 'u')")"
      WANT="1:uq_rt_other"; WHAT="uq_rt_key (ts, id) gone, another UNIQUE standing" ;;
    t51_round_trip_rows_by_count)
      PRE="  array['uq_rt_key UNIQUE (ts, id)'], 'the UNIQUE constraint survived the round trip');
"
      SPLICE="delete from public.uq_rt where id = 1;
insert into public.uq_rt (ts, id, body) select ts - interval '24 hours', 26, 'b26' from public.uq_rt where id = 25;
$(rows_witness public.uq_rt true 1 26)"
      WANT="25:false:true"; WHAT="uq_rt lost row 1 and holds a row 26" ;;
    t52_keyless_rows_by_count)
      PRE="-- by value, as a bag: the table has no key, so a duplicate is a row like any other (#1374)
"
      SPLICE="delete from public.kl where device = 40;
insert into public.kl select ts, device, val from public.kl where device = 1;
$(witness "select count(*) || ':' || count(*) filter (where device = 1) || ':' || count(*) filter (where device = 40)
             from public.kl")"
      WANT="40:2:0"; WHAT="kl holds device 1 twice and has lost device 40" ;;
    t67_rename_tick_rows_by_count)
      PRE="-- by identity (#1374): the rows lost and the rows the fixture never wrote, each named, both none
"
      SPLICE="delete from public.rnd where id = 1;
insert into public.rnd values (500, 'p1');
$(rows_witness public.rnd true 1 500)"
      WANT="401:false:true"; WHAT="rnd lost row 1 and holds a row 500" ;;
    t69_cancelled_source_rows_by_count)
      PRE="-- by identity (#1374): each row carries its own payload, so a lost row and a stray one cannot cancel
"
      SPLICE="delete from public.ca4 where id = 10;
insert into public.ca4 values (2505, 'p1');
$(rows_witness public.ca4 true 10 2505)"
      WANT="251:false:true"; WHAT="ca4 lost row 10 and holds a row 2505" ;;
    t70_resumed_rows_by_count)
      PRE="-- by identity (#1374): the rows lost and the rows the source never had, each named, both none
"
      SPLICE="delete from public.ph1 where id = 1;
insert into public.ph1 values (4999, 'v1');
$(rows_witness public.ph1 true 1 4999)"
      WANT="2500:false:true"; WHAT="ph1 lost row 1 and holds a row 4999" ;;
    t74_aged_rows_by_count)
      PRE="-- lost and the rows the fixture never wrote, each named, both none; a count of 2001 accepts a swap of one.
"
      SPLICE="$(trig off public.ag74 pgpm_write_block)
delete from public.ag74 where id = 1;
insert into public.ag74 values (2001, lpad('1', 100, 'x'));
$(trig on public.ag74 pgpm_write_block)
$(rows_witness public.ag74 true 1 2001)"
      WANT="2001:false:true"; WHAT="ag74 lost aged row 1 and holds a row 2001" ;;
    t74_partly_aged_rows_by_count)
      PRE="-- by identity, as above (#1374): first the aged rows below the horizon, then every row
"
      SPLICE="delete from public.pa74 where id = 5;
insert into public.pa74 values (0, lpad('5', 100, 'x'));
$(rows_witness public.pa74 'id < 1000' 5 0)"
      POST="'a PARTIALLY aged child keeps the rows below the horizon instead of silently dropping them');
"
      UNDO="delete from public.pa74 where id = 0;
insert into public.pa74 values (5, lpad('5', 100, 'x'));"
      WANT="999:false:true"; WHAT="pa74 lost row 5 below the horizon and holds a row 0" ;;
    t74_regrained_rows_by_count)
      PRE="'a PARTIALLY aged child keeps the rows below the horizon instead of silently dropping them');
"
      SPLICE="delete from public.pa74 where id = 1500;
insert into public.pa74 values (2500, lpad('1500', 100, 'x'));
$(rows_witness public.pa74 true 1500 2500)"
      WANT="2001:false:true"; WHAT="pa74 lost row 1500 and holds a row 2500" ;;
    t79_status_parents_by_count)
      PRE="-- status() that reports one table twice and another not at all fails it, as a count would not.
"
      SPLICE="$(swap_fn status)"
      POST="'status() returns a row for EVERY managed table -- one dead parent no longer takes them all down');
"
      UNDO="$(unswap_fn status)"
      WANT="true:true"; WHAT="status() as many rows as config, one parent short" ;;
    t79_orphan_rows_by_count)
      PRE="-- by identity (#1374): the rows lost and the rows orph79 never had, each named, both none
"
      SPLICE="delete from public.orph79_p0000000000000000000_to_0000000000000006000 where id = 1;
insert into public.orph79_p0000000000000000000_to_0000000000000006000 values (5001, 'p1');
$(rows_witness public.orph79_p0000000000000000000_to_0000000000000006000 true 1 5001)"
      WANT="5000:false:true"; WHAT="the orphan lost row 1 and holds a row 5001" ;;
    t80_converted_rows_by_count)
      PRE="-- by identity (#1374): every row as it was, each named if lost or stray, and the valid insert, once
"
      SPLICE="delete from public.ofk where id = 1;
insert into public.ofk (id, ref_id, payload) values (999, 2, 'p1');
$(rows_witness public.ofk true 1 999)"
      WANT="501:false:true"; WHAT="ofk lost row 1 and holds a row 999" ;;
    t88_text_time_rows_by_count)
      PRE="  'p', 'tt_search is a partitioned table'
);
"
      SPLICE="delete from public.tt_search where body = 'oldest';
insert into public.tt_search values (pgpm._ts_to_text_time(now() - interval '12 months', 'c', 8, 36, 'ms'), 'invented');
$(witness "select count(*) || ':' || bool_or(body = 'oldest')::text || ':' || bool_or(body = 'invented')::text
             from public.tt_search")"
      WANT="2:false:true"; WHAT="tt_search lost 'oldest' and holds an invented row" ;;
    t91_ulid_rows_by_count)
      PRE="  'text_time', 'ULID: config: control_kind = text_time'
);
"
      SPLICE="delete from public.tt_ulid where body = 'oldest';
insert into public.tt_ulid values
  (pgpm._ts_to_text_time(now() - interval '12 months', '', 10, 32, 'ms', '0123456789ABCDEFGHJKMNPQRSTVWXYZ'), 'invented');
$(witness "select count(*) || ':' || bool_or(body = 'oldest')::text || ':' || bool_or(body = 'invented')::text
             from public.tt_ulid")"
      WANT="2:false:true"; WHAT="tt_ulid lost 'oldest' and holds an invented row" ;;
    t91_ksuid_rows_by_count)
      PRE="  'text_time', 'KSUID: config: control_kind = text_time'
);
"
      SPLICE="delete from public.tt_ksuid where body = 'oldest';
insert into public.tt_ksuid values
  (pgpm._ts_to_text_time(now() - interval '12 months', '', 27, 62, 's',
     '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz', 128, timestamptz '2014-05-13 16:53:20+00'), 'invented');
$(witness "select count(*) || ':' || bool_or(body = 'oldest')::text || ':' || bool_or(body = 'invented')::text
             from public.tt_ksuid")"
      WANT="2:false:true"; WHAT="tt_ksuid lost 'oldest' and holds an invented row" ;;
    t105_progress_parents_by_count)
      PRE="-- would accept a progress() that lists one table twice and another not at all
"
      SPLICE="$(swap_fn progress)"
      POST="'progress() with no argument returns one row per managed table');
"
      UNDO="$(unswap_fn progress)"
      WANT="true:true"; WHAT="progress() as many rows as config, one parent short" ;;
    t105_progress_dead_parent_by_count)
      PRE="  1, 'LIVENESS: the dropped parent''s config row is still there, pointing at an oid with no relation');
"
      SPLICE="$(swap_fn progress)"
      POST="'progress() still returns a row for EVERY managed table with a dead parent among them');
"
      UNDO="$(unswap_fn progress)"
      WANT="true:true"; WHAT="progress() as many rows as config, one parent short" ;;
    t108_status_parents_by_count)
      PRE="-- by identity (#1374): each parent config holds, once, not merely as many rows
"
      SPLICE="$(swap_fn status)"
      POST="'status() still returns a row for every managed table');
"
      UNDO="$(unswap_fn status)"
      WANT="true:true"; WHAT="status() as many rows as config, one parent short" ;;
    t115_overshoot_rows_by_count|t115_wedged_rows_by_count)
      if [ "$1" = t115_overshoot_rows_by_count ]; then
        PRE="  'overshoot: so retire() refuses the drop; pre-fix this returned true');
"
        POST="'overshoot: all 7 rows are still in the monolith');
"
      else
        PRE="  1, 'the monolith is still a tracked partition');
"
        POST="'and still holds all 7 rows: four bad strategies and five ticks archived nothing and dropped nothing');
"
      fi
      SPLICE="$(trig off public.ac115 pgpm_write_block)
delete from public.ac115 where id = 3;
insert into public.ac115 values (8, 'p3');
$(trig on public.ac115 pgpm_write_block)
$(rows_witness public.ac115 'id < 1000' 3 8)"
      UNDO="$(trig off public.ac115 pgpm_write_block)
delete from public.ac115 where id = 8;
insert into public.ac115 values (3, 'p3');
$(trig on public.ac115 pgpm_write_block)"
      WANT="7:false:true"; WHAT="the frozen monolith lost row 3 and holds a row 8" ;;
    t121_aged_rows_by_count)
      PRE="-- by identity (#1374): the rows lost and the rows the fixture never wrote, each named, both none
"
      SPLICE="$(trig off public.rl121 pgpm_regrain_capture)
delete from public.rl121 where id = 500;
insert into public.rl121 values (0, 'p500');
$(trig on public.rl121 pgpm_regrain_capture)
$(rows_witness public.rl121 'id < 1000' 500 0)"
      POST="'(a) all 999 rows below the old horizon survive');
"
      UNDO="$(trig off public.rl121 pgpm_regrain_capture)
delete from public.rl121 where id = 0;
insert into public.rl121 values (500, 'p500');
$(trig on public.rl121 pgpm_regrain_capture)"
      WANT="999:false:true"; WHAT="rl121 lost aged row 500 and holds a row 0" ;;
    t295_history_rows_by_count)
      PRE="-- beside a stray twin
"
      SPLICE="delete from public.ps295 where id = 110 and pgpm_seq = 11;
insert into public.ps295 values (120, 999, 'x');
$(witness "select count(*) || ':' || bool_or(id = 110)::text || ':' || bool_or(id = 120 and pgpm_seq = 999)::text
             from public.ps295 where id >= 100 and id < 3000")"
      WANT="241:false:true"; WHAT="ps295 lost (110, 11) and holds a twin (120, 999)" ;;
    t338_restored_rows_endpoints_a)
      PRE="-- every row by id and payload, not the endpoints alone (#1375): a table that lost its middle rows kept 1 and N
"
      SPLICE="delete from public.a338 where id between 2 and 119;
$(witness "select count(*) || ':' || bool_or(id = 1)::text || ':' || bool_or(id = 120)::text || ':' || bool_or(id = 50)::text
             from public.a338")"
      WANT="2:true:true:false"; WHAT="a338 lost rows 2 to 119 and kept 1 and 120" ;;
    t338_restored_rows_endpoints_b)
      PRE="'(A) the restored table keeps its rows, 1 to 120');
"
      SPLICE="delete from public.b338 where id = 35;
$(witness "select count(*) || ':' || bool_or(id = 1)::text || ':' || bool_or(id = 70)::text || ':' || bool_or(id = 35)::text
             from public.b338")"
      WANT="69:true:true:false"; WHAT="b338 lost row 35 and kept 1 and 70" ;;
    t338_uninstalled_rows_endpoints_d)
      PRE="'(B) the restored table keeps its rows, 1 to 70');
"
      SPLICE="delete from public.d338 where id = 45;
$(witness "select count(*) || ':' || bool_or(id = 1)::text || ':' || bool_or(id = 90)::text || ':' || bool_or(id = 45)::text
             from public.d338")"
      WANT="89:true:true:false"; WHAT="d338 lost row 45 and kept 1 and 90" ;;
    t93_fan_out_by_ledger_rows)
      PRE="update pgpm.config set archive_batch = null where parent_table = 'public.ab93'::regclass;
call pgpm.maintain('public.ab93');
"
      SPLICE="update pgpm.archive_ledger set child_name = (select child_name from pgpm.part
                                                where parent_table = 'public.ab93'::regclass and lo = '0')
 where parent_table = 'public.ab93'::regclass
   and child_name = (select child_name from pgpm.part where parent_table = 'public.ab93'::regclass and lo = '6000');
$(witness "select count(*) || ':' || count(distinct child_name) from pgpm.archive_ledger
            where parent_table = 'public.ab93'::regclass")"
      WANT="3:2"; WHAT="three ledger rows, the monolith's twice and [6000, 7000)'s not at all" ;;
    t108_rows_after_regrain_sampled)
      PRE="  array['0', '10000', '20000'], 'the 3 below-horizon sub-ranges were skipped as aged, by lo');
"
      SPLICE="delete from public.rs108r where id = 40000;
insert into public.rs108r values (55000, 'x');
$(rows_witness public.rs108r true 40000 55000)"
      WANT="20002:false:true"; WHAT="rs108r lost row 40000 and holds a row 55000" ;;
    t261_rows_after_swap_sampled_a|t319_rows_after_swap_sampled)
      if [ "$1" = t319_rows_after_swap_sampled ]; then
        PRE="          '(A) no tick of the run was refused');
"
        tbl=public.ra319
      else
        PRE="          'no tick of the run was refused');
"
        tbl=public.rt261
      fi
      SPLICE="delete from $tbl where id = 120;
insert into $tbl values (250, 'old120');
$(rows_witness "$tbl" true 120 250)"
      WANT="201:false:true"; WHAT="${tbl#public.} lost row 120 and holds a row 250" ;;
    t261_rows_after_swap_sampled_b)
      PRE="          array['0-20', '20-40', '40-60'], 'LIVENESS: (B) the swap attached the run''s 20-grid children');
"
      SPLICE="delete from public.rh261 where id = 75;
insert into public.rh261 values (299, 'old75');
$(rows_witness public.rh261 true 75 299)"
      WANT="201:false:true"; WHAT="rh261 lost row 75 and holds a row 299" ;;
    *) return 1 ;;
  esac
}

# ---- what to judge -----------------------------------------------------------------------------------------------
# SEL: the sites to judge; FILE_<n>: the file judged for number <n> (this checkout's, or the one named).
SEL=$(tr -s ' \n' '  ' <<<"$SITES")
if [ -n "$ONLY" ]; then
  ONLY="${ONLY/#\/repo\//$ROOT/}"
  if [ ! -f "$ONLY" ]; then say FAIL "GUARD: the test file to judge exists" "$ONLY"; exit 1; fi
  base=$(basename "$ONLY" .sql)
  if site_def "$base"; then
    SEL="$base"
  else
    SEL=""
    for s in $SITES; do
      [ "$base" = "$(basename "$(file_of "$(site_n "$s")")" .sql)" ] && SEL="$SEL $s"
    done
    SEL="${SEL# }"
    if [ -z "$SEL" ]; then say FAIL "GUARD: the file to judge is one this guard knows" "$ONLY"; exit 1; fi
  fi
fi
judged_file() {  # <n>: the path judged for file number <n>
  if [ -n "$ONLY" ]; then echo "$ONLY"; else echo "$ROOT/$(file_of "$1")"; fi
}

# The premise rule is bench/discriminate.sh's starved(), read out of it rather than restated (#1176).
starved_fn=$(sed -n '/^starved() {/,/^}/p' "$ROOT/bench/discriminate.sh")
if [ -z "$starved_fn" ]; then say FAIL "GUARD: starved() was read out of bench/discriminate.sh" "not found"; exit 1; fi
eval "$starved_fn"
# >>> defect verdict: the same in every inverted wrapper; bench/wrapper_premise_rule.sh evaluates it.
# caught <the judged file's TAP output>: exit 0 when the file failed an assertion that is not a premise.
caught() { grep -qE '^not ok [0-9]+' "$1" && ! starved "$1"; }
# <<< defect verdict

# ---- the template: pgtap, this checkout's install, fixtures/demo.sql -----------------------------------------------
q -d postgres -q -c "drop database if exists $DB" </dev/null >/dev/null 2>&1
q -d postgres -q -c "drop database if exists $TMPL" </dev/null >/dev/null 2>&1
if ! { q -d postgres -q -c "create database $TMPL" </dev/null &&
       q -d "$TMPL" -q -c "create extension if not exists pgtap" </dev/null &&
       q -d "$TMPL" -v ON_ERROR_STOP=1 -q --single-transaction -f - <"$ROOT/pgpm_core/install.sql" &&
       q -d postgres -q -c "alter database $TMPL set poc.seed_count = 8000" </dev/null &&
       q -d postgres -q -c "alter database $TMPL set poc.events_count = 4000" </dev/null &&
       q -d "$TMPL" -v ON_ERROR_STOP=1 -q -f - <"$ROOT/fixtures/demo.sql" &&
       docker exec -i "$C" sh -c "cat > $UNINSTALL" <"$ROOT/pgpm_core/uninstall.sql"; } >"$work/tmpl.log" 2>&1; then
  say FAIL "fixture: the template (pgtap, install.sql, fixtures/demo.sql) was built" "$(grep -m1 ERROR "$work/tmpl.log")"
  exit 1
fi
fresh() {
  q -d postgres -q -c "drop database if exists $DB" </dev/null >/dev/null 2>&1
  q -d postgres -q -c "create database $DB template $TMPL" </dev/null >/dev/null 2>&1
}

# judge <label> <expect: pass|fail> <test file>: run the file in a fresh <db> and read its TAP.
judge() {
  local label="$1" expect="$2" file="$3" out rc planned oks notoks unreached=""
  if ! fresh; then say FAIL "fixture: $label: <db> was cloned from the template" "$DB"; fail=1; return; fi
  out=$(q -d "$DB" -v ON_ERROR_STOP=1 -v uninstall="$UNINSTALL" -tA -f - <"$file" 2>&1); rc=$?
  planned=$(sed -nE 's/^1\.\.([0-9]+)$/\1/p' <<<"$out" | head -1)
  oks=$(grep -cE '^ok [0-9]+' <<<"$out")
  notoks=$(grep -cE '^not ok [0-9]+' <<<"$out")
  if [ "$rc" != 0 ] || [ -z "$planned" ] || [ $((oks + notoks)) != "$planned" ]; then
    # A file that reached no assertion failed on its fixture: a premise, not a catch (#1177).
    [ $((oks + notoks)) -gt 0 ] || unreached="fixture: "
    say FAIL "$unreached$label: the file ran to its end" "psql exit $rc, plan ${planned:-none}, $oks ok, $notoks not ok"
    grep -E 'ERROR|^not ok' <<<"$out" | head -5 | sed 's/^/      /'
    fail=1; return
  fi
  if [ "$expect" = pass ]; then
    if [ "$notoks" = 0 ]; then say PASS "$label" "$oks/$planned ok"
    else
      say FAIL "$label" "$notoks not ok of $planned"
      grep -E '^not ok' <<<"$out" | sed 's/^/      /'; fail=1
    fi
  else
    printf '%s\n' "$out" >"$work/judged.tap"
    if caught "$work/judged.tap"; then
      say PASS "$label" "$(grep -E '^not ok' <<<"$out" | grep -vE '^not ok [0-9]+ - (LIVENESS|GUARD|fixture):' | head -1 | cut -c1-70)"
    elif [ "$notoks" -gt 0 ]; then
      say FAIL "$label" "$notoks not ok of $planned, every one a premise: the file passes for the wrong reason"
      grep -E '^not ok' <<<"$out" | sed 's/^/      /'; fail=1
    else
      say FAIL "$label" "all $planned ok against the planted state: the assertion passes for the wrong reason"; fail=1
    fi
  fi
}

# plant <src> <dst> <find> <replace> [...]: each <find> replaced exactly once. A pattern that no longer matches
# exactly once is a FAILURE, never a silently unplanted copy (the discipline of mutate.py).
plant() {
  python3 - "$@" <<'PY'
import sys
src, dst, pairs = sys.argv[1], sys.argv[2], sys.argv[3:]
t = open(src).read()
for find, repl in zip(pairs[::2], pairs[1::2]):
    n = t.count(find)
    if n != 1:
        sys.exit(f"pattern matched {n} time(s), expected 1: {find.splitlines()[0]!r}")
    t = t.replace(find, repl)
open(dst, "w").write(t)
PY
}

# ---- CONTROL, once per judged file ---------------------------------------------------------------------------------
done_files=" "
for s in $SEL; do
  n=$(site_n "$s")
  [[ "$done_files" == *" $n "* ]] && continue
  done_files="$done_files$n "
  judge "CONTROL: $(file_of "$n") passes as written" pass "$(judged_file "$n")"
done

# ---- DEFECT and LIVENESS, once per site ----------------------------------------------------------------------------
for s in $SEL; do
  n=$(site_n "$s"); site_def "$s"
  src="$(judged_file "$n")"
  pairs=("$PRE" "$PRE$SPLICE
")
  [ -n "$POST" ] && pairs+=("$POST" "$POST$UNDO
")
  if ! plant "$src" "$work/$s.sql" "${pairs[@]}" 2>"$work/plant.err"; then
    say FAIL "fixture: $s: the wrong state was spliced into $(file_of "$n")" "$(cat "$work/plant.err")"; fail=1; continue
  fi
  judge "DEFECT: $(file_of "$n") fails at $s" fail "$work/$s.sql"
  got=$(v "select w from public.g12_witness")
  if [ "$got" = "$WANT" ]; then say PASS "LIVENESS: $s: $WHAT" "$got"
  else say FAIL "LIVENESS: $s: $WHAT" "want $WANT, got: $got"; fail=1; fi
done

if [ "$fail" = 0 ]; then say PASS "every judged conservation assertion fails against its planted state" "$(wc -w <<<"$SEL" | tr -d ' ') site(s)"
else say FAIL "every judged conservation assertion fails against its planted state" "$(wc -w <<<"$SEL" | tr -d ' ') site(s)"; fi
exit "$fail"
