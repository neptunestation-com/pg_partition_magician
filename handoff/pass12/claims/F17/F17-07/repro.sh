#!/bin/bash
# F17-07: CHANGELOG.md's #1161 bullet carries a stale second half saying "`regrain_step`'s prepare tick ... and
# `set_regrain` now refuse a run whose fine children above the retention horizon would take more than half" of
# the lock table. The code (pgpm._regrain_swap_budget with p_warn from set_regrain) only WARNS and stores the
# target, as the bullet's own first half and docs/reference.md say. The sentence is read from $TREE.
set -u
fail=0
ok()  { echo "ok - $1"; }
nok() { echo "not ok - $1"; fail=1; }
q()   { $PSQL -tAq -c "$1" 2>&1; }

PROMISE=$(perl -0777 -ne 'print "yes" if /`set_regrain`\s+now\s+refuse\s+a\s+run\s+whose\s+fine\s+children/' "$TREE/CHANGELOG.md")
echo "# CHANGELOG promises that set_regrain refuses such a run: ${PROMISE:-no}"

$PSQL -q >/dev/null 2>&1 <<'SQL'
create table public.t (id bigint primary key, v text not null);
insert into public.t values (1, 'a'), (1999999, 'b');
call pgpm.transmute('public.t', 'id', 1000::bigint, p_obtain => 1);
SQL
slots=$(q "select current_setting('max_locks_per_transaction')::int * (current_setting('max_connections')::int + current_setting('max_prepared_transactions')::int)")
mono=$(q "select lo || ',' || hi from pgpm.part where parent_table = 'public.t'::regclass and lo = '0'")
[ "$mono" = "0,2000000" ] && [ $((2 * 2000)) -gt $((slots / 2)) ] \
  && ok "LIVENESS: the monolith [0, 2000000) split to '1000' is 2000 fine children, past half of $slots lock slots at two each" \
  || { echo "not ok - LIVENESS: monolith [0,2000000) past the budget (got $mono, slots $slots)"; exit 1; }

out=$($PSQL -tAq -c "select pgpm.set_regrain('public.t', '1000')" 2>&1); rc=$?
stored=$(q "select regrain_to from pgpm.config where parent_table = 'public.t'::regclass")
warned=$(q "select count(*) from pgpm.log where parent_table = 'public.t'::regclass and action = 'warn_regrain_lock_budget'")
echo "# set_regrain exit $rc, regrain_to=$stored, warn rows=$warned"
[ "$warned" = "1" ] && ok "LIVENESS: set_regrain judged the run against the lock budget (one warn_regrain_lock_budget row)" \
                    || echo "not ok - LIVENESS: set_regrain judged the run against the lock budget (warn rows $warned)"
refused=no; [ $rc -ne 0 ] && [ -z "$stored" ] && refused=yes
if [ "$PROMISE" = "yes" ] && [ "$refused" = "no" ]; then
  nok "CHANGELOG.md's statement that set_regrain refuses a run past the lock budget matches the code (set_regrain warned and stored '$stored')"
else
  ok "CHANGELOG.md's statement about set_regrain and the lock budget matches the code"
fi
exit $fail
