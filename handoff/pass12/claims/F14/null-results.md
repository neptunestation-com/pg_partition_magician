# F14 null results (pass 12, slice S10: tests/184 to 289 plus 18, 25, 27)

Coverage: 98 of 108 files read in full (see coverage.md); 274 and 281 to 289 were not read (budget).

## Pre-pass

Grep over the slice for `count(*)`, `sum(`, `length(`, `throws_ok(`, `is(..., 0,` and `|| null`: 250
count/length hits and 27 throws_ok hits. Verdicts, grouped:

- **throws_ok, all 27** (185:267, 188:63/105, 189:59, 190:127, 194:161, 198:187, 204:160, 207:49, 217:66/124,
  225:131/154, 227:139, 235:115, 236:81, 25:43, 250:88, 262:104, 265:78, 268:297, 269:120, 27:93/127,
  276:86/91, 280:50): every one is the four-argument form with a SQLSTATE (or a full message). The ones
  around committing procedures (25:43 `call pgpm.transmute`) pin P0001; I checked by experiment that a
  transmute that does not refuse dies 2D000 inside a pgTAP-style function, so the pin discriminates. The rest
  wrap DML, functions or dblink. Sound.
- **count(*) of exact log actions on one parent** (187:136, 190:90/94/121, 195:140/207, 197:79/107/144/213-224,
  198:139, 205:139, 210:73/106, 212:53, 215:86, 218:100, 228:107, 241:275-323, 242:118, 243:136, 244:158,
  245:112, 252:70/104, 263:81/126, 265:63, 277:89, 286:152/171/283/285): exact action, exact parent, mostly
  with lo/hi or method; each is a count of a uniquely identified event, paired with liveness. Sound.
- **count(*) used as a premise inside a LIVENESS or GUARD** (184:111, 197:69, 198:71/72/98/179, 203:64/72,
  206:176/186, 211:51/98, 216:88, 217:130, 241:173-189, 242:79-84, 243:45/99, 244:80/96, 245:54/74, 251:106,
  264:35/52/54, 278:37/53, 279:37, 280:35/45/54, 284:99, 287:71): premises, not verdicts. Sound.
- **count of rows as the verdict**: 27:37 ("all rows are preserved", 100), 262:126 (199), 249:137/151,
  260:91/127, 223:94/104, 221:72, 225:167, 209:99/104. 249 and 262 count rows identified by a unique value or
  sit behind an identity assertion; 209 and 223 are bounded by an identity check beside them; 221:72 follows
  an identity list of index names. 260:91/127 (`count(public.ny) = count(ny_before)`, labelled LIVENESS) is
  implied by the except-both-ways identity check before it and witnesses nothing extra (both empty would pass
  both), but the cell() assertions pin specific rows, so not exploitable. 27:37 is cardinality only, but
  untransmute moves no data and the identity reseed assertion beside it discriminates. Hypothesis-grade at
  most; not claimed.
- **length / octet_length** (208:99, 225:204, 238:61/79/112, 257:84/85, 216:60/99 are CHECK definitions):
  fixtures sized at the 63-byte line, witnesses. Sound.
- **is(..., 0, ...)** (184:110, 190:136, 196:109/119, 202:36, 227:61, 234:117/128, 237:169, 264:95,
  265:48/106, 267:248, 276:103, 278:81, 280:94/146, 281:98): each zero is paired with a nonzero liveness on
  the same fixture (the gate's 0 with its later 1, a second obtain's 0 after the first's n). Sound.
- **`|| null`**: no hit in the slice.

## Lens: fresh surface

- 184, 190, 194, 233, 241 (changed by more than a label): read against their headers; held.
- 280 Part C and the dispatch record: 280 models "pgpm's own retirement in flight" as `retiring_at` alone. The
  lever made `detach_dispatched_oid` the only voucher for a mark (retire(), _detach_reap, _retain_recall,
  _disown_unvouched_retirements), but `_part_built` (install.sql:2188), `_part_detached_by_hand` and
  `_archive_hold_partition` still vouch for any mark. Claimed as **F14-01** (Tier 3).
- 229, 246 (disarm rules) read against the dispatch record: their assertions are about the job's command and
  still hold.
- 241 Part Z classification: checked that adopt_partition (now taking the regrain lock) reads no user rows.
- 219 Part F probe: checked every `cfg.control_column` reader in pgpm_core and the three `pcfg` loads in
  pgpm_archive are followed by `_control_followed`; the probe covers pg_proc in schema pgpm only, which is
  where all core loads are.
- 236, 262, 267 headers vs #1073 (SECURITY DEFINER capture): 236 and 262 say so; 267's STAGE A line "the
  parent's writers, whom the capture trigger writes as" is stale. No assertion depends on it.

## Lens: time and zones

Zone-sensitive files and what each does not vary: 195 (Lagos to London, one month boundary pair; no DST
transition month inside the window), 199 (UTC, Kolkata, New York LMT era; DateStyle SQL/DMY and Chatham for
read-back only), 209 and 238 and 260 (New York, Los Angeles, Kolkata half-hour; fixed-offset zones such as
Asia/Tokyo not exercised, and no repeated or missing hour inside a clamped cell), 213 and 231 (Dublin and
Kolkata IST under SQL DateStyle; the defect is unreachable on PG 18, as their headers say), 273 (the strategy
returns offset-less UTC wall text and the first tick runs in UTC, so a tick in another zone parsing the same
offset-less text is not exercised; the file asserts canonical storage, which held), 230/231/253/266/273/279
(1-second grids timed with pg_sleep; sound at harness speed). No claim.

## Lens: boundary arithmetic and types

208 and 225 and 238 and 257 sit exactly at the 63-byte line; 212 builds against half the shared lock table
from the server's own settings; 233's regrain to "2 years" depends on the harness's lock-table size (the
yearly target is refused at stock settings, so a larger `max_locks_per_transaction` would change which branch
the file exercises, not its verdicts); 247/269 NaN and Infinity; 252/277 scale and precision through domains;
268 numeric(6,-2) and numeric(4,0) overflow. Held.

## Lens: operator error

248/249/268 null arguments (the sweep enumerates every public routine at test time; a committing procedure
that does not refuse dies 2D000, which the verdict counts as not refused, so it discriminates); 210/252/277
step spellings; 263/264/278/280 hand DROP/DETACH/RENAME of partitions; 197/204/220/237/239/240 SET SCHEMA.
Remedies are typed from the messages in 18, 184, 189, 205, 223, 224, 225, 259, 267, 269, 276 and they run.

## Lens: failure injection

185/186/205/259 inject via event triggers inside the cutover and witness the window opened by a sequence
nextval (non-transactional); 192 cuts a sweep with statement_timeout and counts entries in a sequence; 198
terminates detaching backends; 233 raises after VALIDATE; 228 a raising strategy; 263 a SHARE UPDATE EXCLUSIVE
holder. Sibling failures not driven: 228 does not drive a strategy that returns null or a covered_hi past hi
(other files' subject); 263 drives only the write-block lock timeout, not a raise from retire()'s crossing
DELETE in the same loop. No claim.

## Lens: contracts versus documentation

Header-vs-assertion checked for every read file. 190 (E)'s comment says each probe call is its own
transaction; both calls of each pair run in one statement, which still discriminates (a step that ANALYZEs
every time gives [true, true]). 27's "the identity sequence is reseeded ... at max+1" describes the outcome,
not the rule (untransmute carries the parent's sequence position, tests/186); the fixture cannot tell the two
apart, and both are correct here.

## Hypotheses (not counted)

1. `_part_built` / `_part_detached_by_hand` / `_archive_hold_partition` vouching for an unvouched mark also
   reaches the write-block step (`_enforce_write_blocks` acts on the operator's detached table in the same
   tick) and status()/progress() (`_part_built` counts the detached table as a partition until retire()
   disowns the mark). Same root as F14-01; not built separately.
2. tests/273 does not cover a maintain tick run in a non-UTC session handed an offset-less covered_hi: the
   tick's `::timestamptz` parse would read the strategy's UTC wall text as local time (4 to 5 hours off in New
   York) before canonicalising it. Whether pgpm should refuse an offset-less covered_hi is a contract question
   for docs/reference.md's archive_fn section; mechanism: `_archive_step`'s covered_hi parse in the tick's
   TimeZone.
3. tests/233 changes which regrain branch it exercises if the harness's `max_locks_per_transaction *
   (max_connections + max_prepared_transactions)` grows past what the yearly target needs (the comment pins
   "stock settings"); the file then still passes on a different path.

## Round 2

Built first, under the precedence rule for pre-pass lines left as hypotheses about count-weakened assertions:

- **F14-02** (Tier 5): tests/260:91 (and its twin at 127). The "LIVENESS: ... the comparison above was over
  something" premise is count(public.ny) = count(ny_before). `repro.sh` reads the statement from `$TREE` and
  shows it passes over an empty fixture.
- **F14-03** (Tier 5): tests/27:37, "all rows are preserved" as count(*) = 100. `repro.sh` reads the statement
  from `$TREE` and shows it passes over 100 rows, none of them the fixture's b1 to b100.

No other pre-pass line was left as a hypothesis. Every other count, length or zero line was judged sound in
round 1 because it identifies its rows or events.

Hypotheses not built:

1. The write-block step and status()/progress() vouching for an unvouched retirement mark. This is the same
   root (`_part_built` line 2188) and the same fix as F14-01, so it is not filed again as a separate claim.
2. An offset-less covered_hi parsed in a non-UTC tick. Not attempted: it needs a contract decision on what
   zone an offset-less covered_hi means, and that did not fit in the budget.
3. tests/233's branch depends on the lock-table size. Not attempted: it is environmental, not a defect pgpm or
   the test can be shown to have on the harness.
