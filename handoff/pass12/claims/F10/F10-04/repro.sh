#!/usr/bin/env bash
# set_regrain's lock-budget warning (_regrain_swap_budget(..., p_catalog_only, p_warn)) counts through the same
# _regrain_fine_count as the prepare tick, which leaves out the aged prefix whenever retain is set, though the
# copy skips that prefix only with no archive_fn (#278). So with an archive_fn set, set_regrain stores a target
# whose run will attach 2 cap + 4 children without the WARNING or the warn_regrain_lock_budget row its contract
# (tests/315 header) promises for a run past the line. Control: the same table WITHOUT the archive_fn's effect
# on the copy is not needed; the liveness below shows the run is past the line and that the copy keeps the prefix.
set -u
fail=0
$PSQL -q -v ON_ERROR_STOP=1 -f - >/dev/null 2>&1 <<'SQL'
create table public.f10b (id bigint primary key, a text);
do $$
declare cap bigint := (current_setting('max_locks_per_transaction')::bigint
        * (current_setting('max_connections')::bigint + current_setting('max_prepared_transactions')::bigint)) / 4;
        p bigint;
begin
  p := (cap / 2 + 1) * 100;
  insert into public.f10b values (0, 'first'), (4 * p - 1, 'last');
  create table public.f10b_p (p bigint, cap bigint);
  insert into public.f10b_p values (p, cap);
end $$;
SQL
P=$($PSQL -tAc "select p from public.f10b_p"); CAP=$($PSQL -tAc "select cap from public.f10b_p")
$PSQL -q -v ON_ERROR_STOP=1 -f - >/dev/null 2>&1 <<SQL
call pgpm.transmute('public.f10b', 'id', ${P}::bigint, p_obtain => 2, p_retain => ${P}::bigint);
insert into public.f10b values (4 * ${P} + 1, 'frontier');
create function public.f10_strat(p_parent regclass, p_child name, p_lo text, p_hi text)
returns pgpm.archive_result language plpgsql as \$f\$
declare v pgpm.archive_result; begin v.covered_hi := p_hi; v.rows_archived := 0; v.s3_key := 'k'; return v; end \$f\$;
select pgpm.set_archive_fn('public.f10b', 'public.f10_strat(regclass,name,text,text)'::regprocedure);
SQL
n=$($PSQL -tAc "select (hi::numeric / 100)::bigint from pgpm.part where parent_table = 'public.f10b'::regclass and attached and lo = '0'")
if [ -n "$n" ] && [ "$n" -gt "$CAP" ]; then echo "ok - LIVENESS: the monolith is $n sub-ranges of 100, past the line of $CAP"; else echo "not ok - LIVENESS: the monolith is past the line (got '$n' vs cap '$CAP')"; fail=1; fi
af=$($PSQL -tAc "select archive_fn is not null from pgpm.config where parent_table = 'public.f10b'::regclass")
if [ "$af" = "t" ]; then echo "ok - LIVENESS: an archive_fn is set, so regrain_step's copy keeps the aged prefix (#278)"; else echo "not ok - LIVENESS: archive_fn set"; fail=1; fi
out=$($PSQL -c "select pgpm.set_regrain('public.f10b', '100')" 2>&1)
st=$($PSQL -tAc "select regrain_to from pgpm.config where parent_table = 'public.f10b'::regclass")
if [ "$st" = "100" ]; then echo "ok - LIVENESS: set_regrain stored the target 100"; else echo "not ok - LIVENESS: set_regrain stored the target (got '$st')"; fail=1; fi
w=$($PSQL -tAc "select count(*) from pgpm.log where parent_table = 'public.f10b'::regclass and action = 'warn_regrain_lock_budget'")
if echo "$out" | grep -q "WARNING:.*set_regrain(f10b, 100) stores the target" && [ "$w" = "1" ]; then
  echo "ok - set_regrain warned of the run past the lock-table line"
else
  echo "not ok - set_regrain stored a target whose run attaches $n children (line $CAP) with no WARNING and $w warn_regrain_lock_budget rows"
  fail=1
fi
exit $fail
