# Pass-12 fix phase plan (2026-10-12)

Issues: #1258 to #1290 (33 groups, pass 12) plus the re-found bullets with reproductions: #769 (bullet 2, F13-02), #814 (the archive bullet, F19-03), #1180 (three spellings, F12r-06), #1216 (F18-05), #1232 (F16-01), #1236 (B08-01 and B08-02, F12-03 and F12-05).

Numbers: core tests 329 to 343; archive tests 52 to 54; timescale tests 68 and 69; guard databases pgpm_perf366 to 396. Scratch $W/fix/<G>/. Branch fix/<slug>. Pass-12 claims at $CLAUDE_JOB_DIR/tmp/pass12/claims/<finder>/<claim>/.

| G | issues | tier | wave | track | tests | guards | branch |
|---|---|---|---|---|---|---|---|
| G1 | #1258 | 1 | 1 | C | tests/329_<slug>_test.sql | pgpm_perf366 | fix/regrain-refuses-strict-isolation |
| G2 | #1259 | 1 | 1 | C | tests/330_<slug>_test.sql | pgpm_perf367 | fix/retirement-mark-readers-need-dispatch-record |
| G3 | #1260 | 1 | 1 | CA | tests/archive/db/52_<slug>_test.sql | pgpm_perf368 | fix/archive-key-bases-canonical |
| G4 | #1261 | 2 | 1 | C | tests/331_<slug>_test.sql | pgpm_perf369 | fix/regrain-copy-leaves-not-valid-checks-unvalidated |
| G5 | #1262 | 3 | 1 | C | tests/332_<slug>_test.sql | pgpm_perf370 | fix/adopt-partition-judges-as-of-lock |
| G6 | #1263 | 3 | 1 | C | tests/333_<slug>_test.sql | pgpm_perf371 | fix/snapshot-wait-this-database-only |
| G7 | #1264 | 3 | 1 | C | tests/334_<slug>_test.sql | pgpm_perf372 | fix/over-retired-chunks-legacy-bound-zone |
| G8 | #1265 | 3 | 1 | C | tests/335_<slug>_test.sql | pgpm_perf373 | fix/check-time-monotonic-naive-column |
| G9 | #1266 | 3 | 1 | CT | tests/timescale/db/68_<slug>_test.sql | pgpm_perf374 | fix/hypertable-copy-key-constraint-by-conrelid |
| G10 | #1267 | 3 | 1 | C | tests/336_<slug>_test.sql | pgpm_perf375 | fix/surface-prepare-keeps-grants |
| G11 | #1268, #1232 (part) | 3 | 1 | CT | tests/timescale/db/69_<slug>_test.sql | pgpm_perf376 | fix/from-hypertable-asks-mixed-interval-rule |
| G12 | #1269 | 3 | 1 | CA | tests/archive/db/53_<slug>_test.sql | pgpm_perf377 | fix/archive-configure-endpoint-canonical |
| G13 | #1270 | 3 | 1 | C | tests/337_<slug>_test.sql | pgpm_perf378 | fix/transmute-resume-checks-text-time-encoding |
| G14 | #1271 | 3 | 1 | C | tests/338_<slug>_test.sql | pgpm_perf379 | fix/regrain-capture-function-by-oid-any-schema |
| G15 | #1272 | 4 | 2 | C | tests/339_<slug>_test.sql | pgpm_perf380 | fix/retain-disown-remedy-names-the-row |
| G16 | #1273 | 4 | 2 | C | tests/340_<slug>_test.sql | pgpm_perf381 | fix/staging-squatter-remedy-by-relkind |
| G17 | #1274, #1216 (part) | 4 | 2 | C | tests/341_<slug>_test.sql | pgpm_perf382 | fix/child-holders-label-rule-by-grid |
| G18 | #1275, #1277 | 4 | 2 | C | none | pgpm_perf383 | fix/reference-east-of-utc-claim-and-changelog-residue |
| G19 | #1276 | 4 | 2 | C | tests/342_<slug>_test.sql | pgpm_perf384 | fix/time-unit-breach-month-step-date-anchor |
| G20 | #1278, #1236 (part) | 5 | 2 | C | none | pgpm_perf385 | fix/quoted-splices-lint-reads-every-body-and-assignment (rule) |
| G21 | #1279 | 5 | 2 | C | none | pgpm_perf386 | fix/object-keys-lint-follows-parameters-and-from-items (rule) |
| G22 | #1287, #1180 (part) | 5 | 2 | C | none | pgpm_perf387 | fix/child-by-oid-lint-cast-spellings (rule) |
| G23 | #1280 | 5 | 2 | C | none | pgpm_perf388 | fix/ci-lint-guard-requires-failure-propagation |
| G24 | #1281, #1282 | 5 | 2 | CT | none | pgpm_perf389, pgpm_perf390 | fix/bench-harness-cutover-call-and-conservation-identity |
| G25 | #1283 | 5 | 2 | CT | none | pgpm_perf391 | fix/timescale-tests-scratch-check-by-hypertable-oid |
| G26 | #1284 | 5 | 2 | CA | none | pgpm_perf392 | fix/archive-tests-read-objects-back-by-identity |
| G27 | #1285, #1286 | 5 | 2 | C | none | pgpm_perf393 | fix/tests-72-and-27-by-identity |
| G28 | #1288, #1289, #1290 | 5 | 2 | C | none | pgpm_perf394 | fix/review-tooling-thresholds-unverified-and-queue-parse |
| G29 | #769 (part) | 3 | 1 | C | tests/343_<slug>_test.sql | pgpm_perf395 | fix/transmute-refuses-negative-infinity-oldest |
| G30 | #814 (part) | 3 | 1 | CA | tests/archive/db/54_<slug>_test.sql | pgpm_perf396 | fix/archive-direct-call-reads-bounds-pinned |

Waves: wave 1 = G1 to G14, G29, G30 (the Tier 1 to 3 install-touching fixes, launched twelve at a time under the 20-agent cap with eight slots kept for per-PR verification); wave 2 = G15 to G28. Rule PRs (G20, G21, G22) land FIRST in their batch (`rule` in landq.txt); G27 owns tests_fail_on_defect.sh's dispatch and lands before G25 and G26.
