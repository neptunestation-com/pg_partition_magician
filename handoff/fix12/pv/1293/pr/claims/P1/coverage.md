# P1 coverage ledger (PR #1293)

- pgpm_core/install.sql:14287-14294 | read: yes | the comment hunk promising the SET clause; compared against the function header below it (clause absent on this tree): P1-01
- pgpm.check_time_monotonic | read: yes | whole function; header has no SET timezone clause, proconfig null after install; built and ran the zone-dependence reproduction (P1-01), checked timestamptz/date/text-with-offset/fall-back cases by reading
- CHANGELOG.md | read: yes | the #1265 entry; its guarantee is what P1-01 asserts and this tree does not keep
- bench/check_time_monotonic_session_zone.sh | read: yes | whole file; install-under-ON_ERROR_STOP, pg_prove, separate reached-count liveness, drop; nothing to claim
- docs/reference.md | read: yes | the check_time_monotonic section and the new 3481-3485 paragraph, plus check_uuidv7/check_text_time sections and every DateStyle/TimeZone mention; the new paragraph is the contract P1-01 reproduces against
- test.sh | read: yes | the perf guard list hunk at 1268 and the shard loop that runs it; pgpm_perf373 unique in the file
- tests/335_check_time_monotonic_session_zone_test.sql | read: yes | whole file; every negative paired with a liveness line, asymmetric fixtures, parts A/B/C fail on this tree, D/E zone-independent as intended; no wrong-reason pass found
