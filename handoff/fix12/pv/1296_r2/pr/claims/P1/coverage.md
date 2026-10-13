# P1 coverage ledger, PR #1296 round 2

- pgpm_core/install.sql:7639-7652 | read: yes | the function comment's "never listed" and "WHAT IT CANNOT TELL APART" paragraphs; consistent with the intended code, promises "any database"
- pgpm_core/install.sql:7699-7706 | read: yes | the BUDGET paragraph: the holder clause's placement before the pid list and maintain's keep; matches the maintain hunk
- pgpm._snapshot_wait | read: yes | whole function; holder query filtered to this database (a.datid = v_db) is P1-01; own-xid path, holder ordering, bounded clause, transient holder-end race (null result)
- pgpm.maintain | read: yes | whole procedure; the skip_regrain keep (greatest(200, strpos(...))) bounded and ends at the clause's `)`; every other left(sqlerrm, 200) site; probed under a patched copy (249-char row)
- archive._pq_encode_column_data | read: yes | only a comment mentions pgpm.maintain; no call; nothing on this surface
- pgpm._regrain_snapshot_wait | read: yes | passes config.regrain_written_xid and the 'regrain swap' wording; unchanged
- pgpm.maintain_all | read: yes | no handler around maintain by design; the skip row is maintain's own; unchanged
- pgpm.from_hypertable_cutover | read: yes | the _snapshot_wait call site and its lock_timeout setup (1776-1818) and every sqlerrm site of the file (none truncates the deferral); the rest of the 780-line procedure is outside the change and was not re-read
- CHANGELOG.md | read: yes | the #1263 bullet; consistent with docs and the intended code
- bench/snapshot_wait_foreign_floor_holder.sh | read: yes | whole; install-fail reported, ran-count liveness, _x cleanup; held
- docs/reference.md | read: yes | the four touched regions and the surrounding snapshot-wait section (1960-2075, 997-1006); promise "any database" is the one P1-01 breaks
- test.sh | read: yes | the alone bucket (310-345), prove_one, the perf guard list (1280); held
- tests/333_snapshot_wait_foreign_floor_holder_test.sql | read: yes | whole; run three times on the tree and patched copies (8, 9, 32 fail on the tree; LIVENESS 6 flaked once under the patch, hypothesis)
