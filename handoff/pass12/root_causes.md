## Root causes

33 root-cause groups behind the findings, one issue each (Tier 1 first). The age and the lens are on each issue as `Age: ... | Lens: ...`.

- **RC1** (Tier 1, old): regrain(), regrain_history() and a hand regrain_step copy and swap through a REPEATABLE READ caller's snapshot, dropping rows committed after it. Claims F3-02, F3-04. Issue #1258.
- **RC2** (Tier 1, young): the readers of a retirement mark vouch for it without the dispatch record, so the archive step records a hand-detached table as covered and retention drops it once attached back. Claims F14-01. Issue #1259.
- **RC3** (Tier 1, old): archive._owned_key claims key bases as raw text, so under MinIO's leading-slash normalisation a namesake's chunk overwrites the dropped table's only copy. Claims F5-02. Issue #1260.
- **RC4** (Tier 2, old): _regrain_copy_make's LIKE ... INCLUDING CONSTRAINTS validates a NOT VALID CHECK on the copy, so a violating row wedges the regrain until regrain_cancel. Claims F3-03. Issue #1261.
- **RC5** (Tier 3, old): adopt_partition judges attachment and the pending flag through the caller's transaction snapshot, before and after its lock, and does not refuse a stricter isolation level. Claims F4-03, F11-03. Issue #1262.
- **RC6** (Tier 3, young): _snapshot_wait judges a snapshot by the cluster-wide backend_xmin, so a transaction open in another database defers every swap and the refusal names an innocent pid. Claims F13-01. Issue #1263.
- **RC7** (Tier 3, old): _over_retired_chunks reads a legacy offset-less retired ledger bound in the caller's session TimeZone. Claims F15-02. Issue #1264.
- **RC8** (Tier 3, old): check_time_monotonic casts a naive timestamp column to timestamptz in the caller's session TimeZone. Claims F2-02. Issue #1265.
- **RC9** (Tier 3, old): from_hypertable_copy resolves the key's constraint by conindid alone, so an incoming foreign key on the key pre-builds the wrong index and the key is built twice. Claims F6-02. Issue #1266.
- **RC10** (Tier 3, old): _surface_prepare drops a shape-changed surface function and recreates it, losing the operator's grants the install's header promises to keep. Claims F6-03. Issue #1267.
- **RC11** (Tier 3, young): _from_hypertable_check_arguments does not ask transmute's mixed month-and-duration step rule before the copy and swap. Claims F16r-01. Issue #1268.
- **RC12** (Tier 3, old): archive.configure accepts an endpoint with a trailing slash, after which every signed request addresses //bucket/key and is refused. Claims F19-02. Issue #1269.
- **RC13** (Tier 3, old): transmute's resume checks the claim's column and grid but not the text_time encoding, so a re-run with another encoding fails raw in the cutover. Claims F1-06. Issue #1270.
- **RC14** (Tier 3, old): _regrain_capture_names resolves the recorded capture function only in the delta's current schema, so untransmute and uninstall leave it behind after the delta is moved. Claims F3-05. Issue #1271.
- **RC15** (Tier 4, old): retain_disown's remedy, in the log row and the reference, says to drop the table by hand and omits the pgpm.part row that then wedges retention. Claims F4-02. Issue #1272.
- **RC16** (Tier 4, old): _transmute_refuse_staging_squatter hard-codes a drop table remedy whatever kind of relation holds the staging name. Claims F18-02. Issue #1273.
- **RC17** (Tier 4, young): _transmute_refuse_child_holders accepts any time label of the kind, so an operator's table at a label the grid could never mint blocks the conversion. Claims F1-05. Issue #1274.
- **RC18** (Tier 4, old): the reference says a naive timestamp column holding wall time east of UTC runs on an hourly grid, but the frontier skew refusal stops it unless p_force_frontier is passed. Claims F1-07. Issue #1275.
- **RC19** (Tier 4, young): _time_unit_breach flags a date anchor off midnight for a whole-month step whose bounds all land at midnight: the upgrade warns and set_regrain refuses for a false reason. Claims F2-03. Issue #1276.
- **RC20** (Tier 4, young): CHANGELOG.md's #1161 bullet carries a stale duplicated tail saying set_regrain refuses a run past the lock budget, where it warns. Claims F17-07, F12r-01. Issue #1277.
- **RC21** (Tier 5, young): check_quoted_splices.py never reads a FOR loop's target as an assignment and never reads a body dollar-quoted with a tag other than $$. Claims F8-01, F12-06, F8-08. Issue #1278.
- **RC22** (Tier 5, young): check_archive_object_keys.py misses a prefix bound as an EXECUTE ... USING argument, renamed through a FROM item or handed by position to a helper. Claims F8-02, F12r-07. Issue #1279.
- **RC23** (Tier 5, young): bench/ci_runs_lint_jobs.sh accepts test.sh's ci on the spelling of its lint call and never requires that ci fails when the lint track fails. Claims F11-02. Issue #1280.
- **RC24** (Tier 5, old): bench/run_fh.sh calls from_hypertable_cutover with p_regrain_batch, a parameter it does not have, so every documented hypertable benchmark run dies after its copy. Claims F8-03. Issue #1281.
- **RC25** (Tier 5, old): bench/run.sh's conservation gate counts history rows where its own comment and the README promise every row is still present. Claims F8-05. Issue #1282.
- **RC26** (Tier 5, young): tests/timescale/db/65 and 66 look for leftover scratch records under the new partitioned tables' oids, not the dropped hypertables' oids the records carry. Claims F10-02, F10-03. Issue #1283.
- **RC27** (Tier 5, old): tests/archive/db/08, 16 and 44 judge the objects they wrote back by line count, size or a PAR1 prefix, not by identity with the chunk's rows. Claims F16-02, F16-03, F16-04. Issue #1284.
- **RC28** (Tier 5, old): tests/72's row-level-security check asks only the role the policy names, so a policy replayed to every role passes. Claims F15-01. Issue #1285.
- **RC29** (Tier 5, old): tests/27 asserts that untransmute preserves all rows by a count of 100 over a fixture whose rows can be told apart. Claims F14-03. Issue #1286.
- **RC30** (Tier 5, young): check_archive_child_by_oid.py's rule 1 refuses a run-time name cast to regclass only as )::regclass, not ::pg_catalog.regclass, CAST(... AS regclass) or regclass(...). Claims F12r-08. Issue #1287.
- **RC31** (Tier 5, young): stop_check.py judges the stopping thresholds on the record header's two-decimal figures, so 0.696 precision, 0.304 fell or 0.897 coverage read as met. Claims F12r-02. Issue #1288.
- **RC32** (Tier 5, young): pass_metrics.py counts a candidate with no verdict, or an unknown verdict string, as fell, inflating the fell rate the stopping criteria read. Claims F12r-03. Issue #1289.
- **RC33** (Tier 5, young): decisions_queue.py skips a malformed line instead of refusing it, so an indented, star-bulleted or lower-case BLOCKING entry is never read and the loop continues. Claims F12r-04. Issue #1290.
