# P1 coverage ledger: PR #1305

- pgpm_core/install.sql:5137-5143 | read: yes | the "THE GRID'S CLOCK" header comment; states the rule the function body does not implement (v_tz is the caller's TimeZone), see P1-01
- pgpm._native_bound_key | read: yes | probed from UTC/ISO,MDY and Asia/Kolkata/SQL,DMY sessions with abbreviation-carrying, DateStyle-shaped, Postgres/German-style and bare-date legacy text: identical keys; settings restored after a call and after a raise; id branch unchanged
- pgpm._over_retired_chunks | read: yes | P1-01: v_tz := current_setting('TimeZone') instead of c.partition_tz, so every key is on the caller's clock; tests/334 fails 5/16 on the tree, tests/317 passes 13/13; floor read and #973 CTE shape unchanged
- pgpm.retain | read: yes | consumes _over_retired_chunks by child_name into v_held only; no bound comparison of its own against retired rows; unchanged by the PR
- pgpm._archive_step | read: yes | consumes _over_retired_chunks by child_name (v_held, skip_archive_retired_range); its orphan-discard query still casts unretired bounds in the caller's session (body's disclaimed adjacent class, hypothesis 1)
- CHANGELOG.md | read: yes | the #1264 entry promises the grid's clock and the same answer from every session; the code on this tree does not keep it (same root cause as P1-01, not filed separately)
- bench/over_retired_chunks_grid_zone.sh | read: yes | pgTAP wrapper over tests/334 in retain_recall_moved_parent.sh's shape; cannot run here (no /repo mount); its test file is red on this tree so the guard is live
- docs/reference.md | read: yes | the retired-chunk paragraph's new sentence ("never in the caller's TimeZone or DateStyle") is the intended rule, contradicted by the code (P1-01)
- test.sh | read: yes | the guard registered once as pgpm_perf372 in the sharded perf list; no duplicate database name
- tests/334_over_retired_chunks_grid_zone_test.sql | read: yes | ran on the tree: 11/16, failing exactly the five cross-session checks (5, 7, 9, 11, 16) the body says fail on base; its LIVENESS witnesses and part F all pass
