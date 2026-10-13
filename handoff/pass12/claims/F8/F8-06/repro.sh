#!/usr/bin/env bash
# F8-06: bench/upgrade_in_place.sh prints its assertion 7, "the pre-existing managed table must still be
# maintainable" after the upgrade (an upgrade that can no longer obtain "is not an upgrade anyone wants"), as a
# LIVENESS: line. bench/discriminate.sh's starved() reads a run whose every failure is LIVENESS:/GUARD:/fixture:
# as a starved fixture, so a mutant whose only effect is that the upgraded install no longer obtains is refused
# as unverified rather than counted as caught: the guard's one check of that property is unreadable as a catch.
# The failure line is evaluated from $TREE/bench/upgrade_in_place.sh and judged by $TREE's starved().
# Present = starved() reads the guard's failed post-upgrade obtain check as a starved fixture.
set -u
fail=0
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
fn=$(sed -n '/^starved() {/,/^}/p' "$TREE/bench/discriminate.sh")
line=$(grep -m1 -F 'LIVENESS: maintain_obtain() minted nothing after the upgrade' "$TREE/bench/upgrade_in_place.sh")
if [ -n "$fn" ] && [ -n "$line" ]; then echo "ok - LIVENESS: (A) starved() and the guard's assertion-7 failure line were read from the tree"
else echo "not ok - LIVENESS: (A) starved() and the guard's assertion-7 failure line were read from the tree"; exit 1; fi
eval "$fn"
CHILDREN_AFTER="up_t_p0000000000000000000,up_t_p0000000000000000100"
# The guard's run against a mutant that breaks only post-upgrade obtain: every other check passes.
{ printf 'PASS  %-58s %s\n' "the upgrade backfilled child_oid, to each child's own oid" "3/3"
  printf 'PASS  %-58s %s\n' "rows survived, by identity" "b,c"
  eval "$(sed -E 's/^ +//' <<<"$line")"; } > "$W/mutant.log"
# The instrument can say no: the same run with that failure unprefixed is a catch.
sed 's/FAIL  LIVENESS: /FAIL  /' "$W/mutant.log" > "$W/control.log"
if grep -q '^FAIL  LIVENESS: maintain_obtain() minted nothing' "$W/mutant.log" && ! starved "$W/control.log"; then
  echo "ok - LIVENESS: (B) starved() counts the same failure as a catch when it is unprefixed"
else echo "not ok - LIVENESS: (B) starved() counts the same failure as a catch when it is unprefixed"; fail=1; fi
if starved "$W/mutant.log"; then
  echo "not ok - a run whose only failure is 'the upgraded install no longer obtains' is read as a catch, not as a starved fixture"
  fail=1
else
  echo "ok - a run whose only failure is 'the upgraded install no longer obtains' is read as a catch"
fi
exit "$fail"
