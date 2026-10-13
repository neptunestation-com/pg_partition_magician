## Per finder (coverage, model, budget)

Coverage is `scripts/review/coverage.py`'s score of each finder's ledger against its slice (functions for an install.sql slice, files for a tests, bench or docs slice, both for the mixed S6 and S8a, the explicit unit list for a re-run), taken before classification as step 4b requires; a first run below 0.9 was completed by a re-run on its unread units (the `r` rows), the one exception being S8c's 197 label-only files (see the notes). Tokens are the harness's per-agent counts, round 2 included.

| finder | slice | model | tokens | coverage | claims (round 2) | seed hits | findings | known and open | fell | precision | strict |
|---|---|---|---|---|---|---|---|---|---|---|---|
| F1 | S1 | opus | 347623 | 1.0 | 7(3) | 4 | 3 | 0 | 0 | 1.00 | 1.00 |
| F2 | S2 | opus | 245227 | 1.0 | 3(1) | 1 | 2 | 0 | 0 | 1.00 | 1.00 |
| F3 | S3 | opus | 297321 | 1.0 | 5(2) | 1 | 4 | 0 | 0 | 1.00 | 1.00 |
| F4 | S4 | opus | 237623 | 1.0 | 3(1) | 1 | 2 | 0 | 0 | 1.00 | 1.00 |
| F5 | S5 | opus | 285250 | 1.0 | 3(1) | 1 | 1 | 0 | 1 | 0.67 | 0.67 |
| F6 | S6 | opus | 283235 | 1.0 | 3(1) | 1 | 2 | 0 | 0 | 1.00 | 1.00 |
| F7 | S7a | opus | 540302 | 0.941 | 3(2) | 1 | 0 | 0 | 2 | 0.33 | 0.33 |
| F8 | S7b | opus | 374453 | 0.286 | 8(2) | 1 | 5 | 0 | 2 | 0.75 | 0.75 |
| F9 | S8a | opus | 370320 | 1.0 | 6(2) | 6 | 0 | 0 | 0 | 1.00 | 1.00 |
| F10 | S8b | opus | 412882 | 0.974 | 4(1) | 2 | 2 | 0 | 0 | 1.00 | 1.00 |
| F11 | S8c | opus | 246803 | 0.104 | 3(1) | 1 | 2 | 0 | 0 | 1.00 | 1.00 |
| F12 | S8d | opus | 256843 | 0.233 | 6(2) | 3 | 1 | 2 | 0 | 1.00 | 0.67 |
| F13 | S9 | opus | 620350 | 1.0 | 3(3) | 0 | 1 | 1 | 1 | 0.67 | 0.33 |
| F14 | S10 | opus | 557851 | 0.907 | 3(2) | 0 | 2 | 0 | 1 | 0.67 | 0.67 |
| F15 | S11 | opus | 503467 | 0.929 | 2(1) | 0 | 2 | 0 | 0 | 1.00 | 1.00 |
| F16 | S12 | opus | 511586 | 0.793 | 4(3) | 0 | 3 | 1 | 0 | 1.00 | 0.75 |
| F17 | S13 | opus | 484605 | 0.917 | 7(1) | 6 | 1 | 0 | 0 | 1.00 | 1.00 |
| F18 | S1 | fable | 305363 | 1.0 | 5(2) | 3 | 1 | 1 | 0 | 1.00 | 0.80 |
| F19 | S5 | fable | 260566 | 1.0 | 4(1) | 1 | 1 | 1 | 1 | 0.75 | 0.50 |
| F11r2 |  |  |  |  | 0(0) | 0 | 0 | 0 | 0 | 0.00 | 0.00 |
| F11r | S8c-r | opus | 328789 | 0.968 | 1(0) | 1 | 0 | 0 | 0 | 1.00 | 1.00 |
| F16r | S12-r | opus | 264517 | 1.0 | 1(0) | 0 | 1 | 0 | 0 | 1.00 | 1.00 |
| F8r | S7b-r | opus | 409572 | 1.0 | 1(0) | 1 | 0 | 0 | 0 | 1.00 | 1.00 |
| F12r | S8d-r | opus | 465813 | 1.0 | 8(0) | 1 | 6 | 1 | 0 | 1.00 | 0.88 |

## Coordinator notes

### Lenses rotated

Six lenses, the five least recently used by the cycle rule (`stop_check.py`'s line: all five last used in pass 10, two passes out) beside fresh surface: time and zones, boundary arithmetic and types, operator error, failure injection, contracts versus documentation. Out: identity and names, concurrency and locks, upgrade and install paths, tests that pass for the wrong reason, resource cliffs, which are pass 13's set and complete the cycle. Five of six differ from pass 11. The yield by the lens each finder named, of the 42 verified finding claims: 14 through fresh surface, 13 through contracts versus documentation, 11 through operator error, 3 through time and zones, 1 through boundary arithmetic and types. Operator error found two of the three Tier 1 root causes (a REPEATABLE READ caller of `regrain()` and of a hand `regrain_step`; the leading-slash prefix under MinIO) and the Tier 2 came under fresh surface; the tests-that-pass-for-the-wrong-reason lens was out, and still 19 Tier 5 findings came through contracts versus documentation and fresh surface, because the bench, tests and lint briefs read a header as a contract.

### Fresh surface, split by kind

The pass-11 lesson (#1184): one fresh-surface slice of 241 units never met the coverage gate after four re-runs. This pass split it by kind: S8a the 76 install units (F9, 1.00 on its first run, four seed hits and no new finding), S8b the 151 test files (F10, 0.97 at the depth the brief set, three claims), S8c the 289 bench files (F11, 0.10 on its first run, then F11r on the 62 files changed by more than a label, 0.97; the 197 label-only files were not re-run, by a budget decision recorded below), S8d the 32 documents, scripts, workflows and skills (F12, 0.23, then F12r on the 23 unread, 1.00). The install hunks met the gate at once, which is what the split was for; the bench and docs halves did not, and the lesson is that a fresh-surface slice of files is sized by files changed by more than a label, not by files touched.

### Seeds

Nine seeds, four novel, three from the late-survivor set and two from the catalogue's pass-11 fix mutations. Every seed was found: S1 (untransmute_detach_pending_unchecked) by 4 claims from F1, F17, F18, F9; S2 (archive_whole_unfiltered_and_unheld) by 6 claims from F12, F17, F6, F9; S3 (obtain_unbuilt_cell_unlogged) by 6 claims from F1, F17, F18, F4, F9; S4 (novel_naive_grid_zone_off_dst_only) by 2 claims from F2, F9; S5 (novel_regrain_fine_count_skips_archived_prefix) by 4 claims from F10, F3, F9; S6 (novel_retire_pending_detach_guard_rows_by_count) by 2 claims from F11, F8; S7 (novel_reference_untransmute_detach_remedy_unfinalized) by 2 claims from F1, F17; S8 (to_s3_cursor_type_typmod_dropped) by 7 claims from F11r, F12, F12r, F19, F5, F7, F8r; S9 (restore_one_step_no_backoff) by 3 claims from F1, F18, F9. The split: suite-caught 4 of 4 (S1 by tests/312, S3 by tests/190, 214, 293 and 298, S8 by tests/archive/db/51, S9 by tests/322), read-caught 5 of 5 (S2 the operator script, S4 the zone test, S5 the lock-budget count, S6 the bench count, S7 the documented remedy); late-survivor 3 of 3 (S1 and S3 suite-caught, S2 read-caught). The three late-survivor seeds are the first planted from the set and the first measured on their own: all three found, by three to five finders each. The two catalogue seeds in `pgpm_archive/install.sql` and `pgpm_core/install.sql` were reached through the tree's own lint as much as through reading: the archive cursor's typmod seed (S8) makes `scripts/check_archive_child_by_oid.py` refuse the line it changes, so `bench/lint_child_by_oid_inverse.sh` and the Lint job go red on the seeded tree, and three finders (F7, F11r, F12) found it by running the lint before reading `to_s3`; a seed that trips a lint is as loud as one a test catches, and the next pass's suite check should run the repository's lints beside the pgTAP suite and seal a lint-caught seed as such. The late-survivor seeds (the untransmute gate, the operator script, the squatted cell) were found by four, three and four finders; two of the three were named by the method document in the tree (`docs/adversarial-review.md` lists the late-survivor set's shapes), which F17 noticed and said so; the document stays in the tree (its lens catalogue is the finders' brief) but the next pass should plant late-survivor seeds the catalogue does not name by shape, or stub the "Seeding" section.

### Round 2, aimed at the late-survivor shapes

Every finder got the round-2 brief with the six long-surviving shapes named (a gate blind to a pending detach, a read before a lock trusted after it, a judgement without a lock under in-flight DDL, a sibling copy of a fixed mechanism, an older-install state, a derived name assumed free). Round 2 produced 32 claims, among them the Tier 1 `regrain_step` swap under REPEATABLE READ (F3-04, from F3's own H1, shape 3), the Tier 3 `adopt_partition` snapshot reads (F4-03 and F11-03, shape 3, built independently by two finders), the Tier 3 cluster-wide `backend_xmin` (F13-01, from a test's own flake), and 6 Tier 5 test and lint shapes. The shapes the brief named produced the round's Tier 1 and both Tier 3 code findings; the labelling hypotheses it did not name produced the fell claims (F7-02, F7-03, F8-06, F8-07: a guard's reading of a label where the pipeline never pairs the two).

### Model-tier split (two slices, two models, same brief)

S1 (conversion) and S5 (the archive module), the two slices with the most once-read units in pass 11's ledgers, ran on opus (F1, F5) and fable (F18, F19). On S1 both found the three seeds there (S1, S3's obtain site, S9) and the reference's remedy seed (F1); F1 added three findings in round 2 (a Tier 4 label refusal, a Tier 3 resume gap, a Tier 4 reference claim) and F18 one Tier 4 (the staging squatter's `drop table` for any relkind, rebuilt by its verifier) and a re-find of #1216. On S5 both found the cursor seed; F5 found the Tier 1 (MinIO's key normalisation) and F19 a Tier 3 (the trailing-slash endpoint) and the re-find of #814; F19 spent 260k tokens to F5's 285k. Neither model dominated: on both slices the two found the same seeds and different findings, as in passes 5 and 11.

### Coverage

Every code slice (S1 to S6) and the install-hunks slice S8a met the gate on the first run (1.00 each); S7a 0.94, S8b 0.97 at the depth its brief set, S9 1.00, S10 0.91, S11 0.93, S13 0.92. Four first runs fell below it and were completed by a re-run on exactly their unread units: S7b (F8 0.29, F8r 1.00 on the 142 unread), S8d (F12 0.23, F12r 1.00 on the 23 unread), S12 (F16 0.79, F16r 1.00 on the 24 unread), and S8c (F11 0.10, F11r 0.97 on the 62 files changed by more than a label; the 197 label-only files not re-run, the one gap, read whole by their home slices S7a and S7b). The record's coverage line reads the per-finder minimum (0.10, F11's first run) because `coverage.py` scores ledgers, not slices; by slice after the re-runs every slice but S8c is at or above 0.9. The re-runs found three of the pass's claims (F11r's and F8r's seed hits, F16r's Tier 3 hypertable argument rule, F12r's eight claims incl. the CHANGELOG residue and five Tier 5 tooling and lint findings).

### Budget, measured

- Finders: 19 in round 1 plus round 2 (7,141,670 tokens by the harness's per-agent counts), re-runs F11r, F16r, F12r, F8r (1,468,691 tokens); F11r2, the 197 label-only bench files of S8c, was not run: at 11,115,976 tokens the pass was at its 10M ceiling, those files are read whole by their home slices S7a (0.94) and S7b (after F8r, 1.00), and F11 had checked every `LIVENESS:` line the diff added to them; the gap is recorded in the per-finder table.
- Verifiers: 55 runs (one per candidate, 6 of them storing a rebuilt reproduction), 2,505,615 tokens, mean about 45,556.
- Hunt start 15:40Z on 2026-10-12, last verdict 16:22:39Z; 11,115,976 agent tokens against the 10M cap (the coordinator, the classifier and the suite check not counted). Cost per verified finding claim (42): 264,666 tokens; per Tier 1 claim (4): 2,778,994.

### Environment and incidents

- The review tree carried `docs/reviews/` for the first ten minutes of the hunt (the build script removes only `bench/mutations/`; pass 11 stubbed the records by hand before the hunt, this pass only after F4's grep met two of them); four finders reported a grep that printed lines from a record and none read one. `build_review_tree.sh` should stub `docs/reviews/` itself.
- The slice line ranges were taken from the tree before the seeds were planted, so after planting the units past a seed's lines fell outside their one-line ranges and F4's ledger scored 43 of 62; regenerated from the seeded tree before any gate was read. `mk_slices.py` must run after `plant_seeds.py`.
- The harness's 20-concurrent-agent cap was met at 15:52Z with 17 finders (two in round 2) and three verifiers live; the two S8c re-runs did not launch and were queued (`agent_queue.txt`), verifiers first, then round 2, then re-runs.
- F8-04 (the bench count seed, found by F8 beside F11) classified as a candidate whose pristine run failed only its liveness: the reproduction read the check's line from the tree and the pristine line is the identity check, so the premise "the guard's survival check was read from the tree" fails there. Reattributed by the coordinator to S6 on the sealed lines (the pass-9 rule), not sent to a verifier.
- The core suite check ran 47 (and a further 20 for S2, which the coordinator's --only list had left out of the first run) minutes beside the hunt (seven seeds, one at a time, the harness loaded by nineteen finders); the archive check 15 minutes.
