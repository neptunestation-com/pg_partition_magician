#!/bin/bash
# pv_finish.sh <pr> classify   -> classify every claim (after P1 and V reported) and list the candidates
# pv_finish.sh <pr> report "<budget text>" [--post] -> render (and post) the comment; exit 1 = blocked
F=/Users/davida.ventimiglia/.claude/jobs/8d94cdfa/tmp/fix12; cd /Users/davida.ventimiglia/Work/pg_partition_magician || exit 5
PR=$1; CMD=$2; V=$F/pv/$PR${ROUND:+_r$ROUND}
case $CMD in
  classify) scripts/review/pr_verify.sh classify --work $V/pr 2>&1 | tail -25;;
  report) scripts/review/pr_verify.sh report --work $V/pr --budget "$3" ${4:-} 2>&1 | tail -30; echo "exit=$?";;
  cleanup) scripts/review/pr_verify.sh cleanup --work $V/pr 2>&1 | tail -2;;
esac
