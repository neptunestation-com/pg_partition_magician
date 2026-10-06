# Reference

Every public function and catalog object in `pg_partition_magician`, described **as built**. The schema
is `pgpm`. This is the authoritative surface; the [user guide](guide.md) explains the concepts and how the
pieces fit.

The mental model in one breath: `transmute` converts a live table into a native `RANGE`-partitioned one
by renaming the original aside and attaching it, with **zero row movement**, as one bounded **monolith**
child (covering `[grid_floor(min), B)`), and laying down a **forward grid** of real, bounded partitions
above it. There is no `DEFAULT`: a write no partition covers is refused. Going forward, `obtain` keeps the
grid ahead of the write frontier, `retain` drops whole partitions past a policy, and `regrain` splits the
coarse monolith into finer partitions on demand. `pg_cron` runs two procedures: `maintain_obtain` (just
`obtain`, on its own cadence) and `maintain` (everything else).

Conventions used below: `p_parent` is the partitioned parent (a `regclass`); a native grid value is a
`timestamptz` for the `time`, `uuidv7` and `text_time` kinds and a `numeric` for the `id` kind; "the
frontier" is `now()` for `time`, `max(control)` for `id`, and `greatest(max(control), now())` for
`uuidv7`/`text_time` (both are time grids fed by data, so neither falls behind the clock).

**Null arguments.** Every public routine (of `pgpm_core`, of `pgpm_hypertable` and of `pgpm_archive`) refuses a null argument
that has no meaning, before it reads or commits anything, naming it: `pg_partition_magician: <routine> does
not accept null for <argument>: ...`. PL/pgSQL reads a null with three-valued logic, so before this a null
`p_force` made `suspend_incoming_fks` drop the live keys it should have left alone, and a null `p_paused`
reached `from_hypertable`'s handoff only after its swap had dropped the hypertable. The arguments whose null
IS a meaning say so where they are described: `transmute`'s `p_retain` (keep everything) and its `text_time`
shape arguments; `from_hypertable`'s and `from_hypertable_cutover`'s `p_retain` (the source's `drop_chunks`
interval); `from_hypertable_drain_appends_step`'s `p_watermark`; `from_hypertable_time_estimate`'s
`p_copy_mibps`; the `p_target_step` of `regrain`, `regrain_step`, `regrain_history` and `set_regrain`;
`regrain_step`'s `p_batch`; `set_retain`'s `p_retain`; `set_archive_fn`'s `p_archive_fn`; `progress`'s
`p_parent`; `restore_incoming_fks`'s `p_ids`; `check_text_time`'s `p_alphabet`; and the `p_status` that
`maintain` and `maintain_obtain` return. In `pgpm_archive`, the `p_endpoint` of `archive.configure`,
`archive.s3_signed_request` and `archive.s3_signed_request_bytea` (AWS S3 itself), and the arguments a
routine does not read: the `p_lo` and `p_hi` of `archive.to_s3` and `archive.to_s3_parquet` (the export is
the whole partition) and the `p_child` of `pgpm.archive_to_s3_ndjson` and `pgpm.archive_to_s3_parquet` (the
chunk is read through the parent). Before this a strategy's null `p_hi` read no row and wrote an empty object
over the chunk the same `p_lo` had archived (see [Real S3 archive strategies](#real-s3-archive-strategies)).

## Conversion

### `transmute` (time / uuidv7 / text_time grid)

```sql
pgpm.transmute(
  p_parent regclass, p_control name, p_interval interval,
  p_obtain int default 30, p_retain interval default null,
  p_regrain_batch int default 5000, p_anchor timestamptz default '2000-01-01 00:00:00+00',
  p_paused boolean default true, p_incoming_fks text default 'error',
  p_force_uuidv7 boolean default false,
  p_bound_headroom int default 0,
  p_lock_timeout text default '5s',
  p_tt_prefix text default null, p_tt_width int default null,
  p_tt_radix int default null, p_tt_unit text default null,
  p_force_text_time boolean default false,
  p_tt_alphabet text default null, p_tt_discard_bits int default 0,
  p_tt_epoch timestamptz default '1970-01-01 00:00:00+00',
  p_force_frontier boolean default false
)
```

A **`PROCEDURE`**: invoke it with `CALL`, not `SELECT`, and it returns nothing. The new parent keeps the
original's name, so `p_parent` still resolves to it afterwards.

It `COMMIT`s between its phases, so like [`from_hypertable`](#from_hypertable) it must be called at the
**top level**: a plain `CALL`, never inside a surrounding transaction or an atomic block. A schema-migration
tool that wraps each migration in a transaction (Prisma, Flyway, Liquibase, Rails, Alembic) will therefore
fail it with `invalid transaction termination`. Convert as an operator-driven step instead.

Converts `p_parent` into a partitioned table and registers it. The control column's type selects
the kind: a `uuid` column is treated as **uuidv7** (time-ordered; ULIDs stored as `uuid` included), a
`text`/`varchar` column is treated as **text_time** (a general opaque-sortable-TEXT id -- classic `cuid`
is the motivating case -- decoded via a declared `<prefix><fixed-width base-N encoded epoch>` shape; see
`p_tt_prefix`/`p_tt_width`/`p_tt_radix`/`p_tt_unit` below), and a `timestamptz`/`timestamp`/`date` column
is **time**.

The grid is computed in the **zone of the session that runs the call**, recorded in
`pgpm.config.partition_tz` and used for every boundary and partition name from then on, whatever zone
maintenance's session runs in. Month and year boundaries fall at midnight on the 1st in that zone (at the
first instant of that day where the zone's clocks skipped midnight, and at the second of the two
midnights where a fall-back repeated it, so the hour between belongs to the previous month's partition);
day and shorter steps are a fixed
number of seconds from the anchor, named by the UTC date or hour they start at. For UTC-aligned boundaries, run `set timezone = 'UTC'` first. The call refuses a session zone that is
not a name in `pg_timezone_names` (a POSIX rule or a bare abbreviation), and the zone can be changed
afterwards only with [`set_partition_tz`](#set_partition_tz).

A `timestamp` or `date` control column carries no zone, so its grid is computed on the column's **own
wall clock** whatever the session's zone: a day is `[D 00:00, D+1 00:00)` in the column's values, an hour
`[H:00, H+1:00)`, a month `[1st 00:00, next 1st 00:00)`, and every bound literal is that reading. That is
the UTC lattice, so `partition_tz` is recorded as `UTC` for such a column and cannot be changed. pgpm's
write frontier for it is `now()` read on that same clock, so an application writing local wall time from
a zone east of UTC runs ahead of the frontier by its offset; the forward slack `obtain x partition_step`
covers that on a day or coarser grid with any `obtain` of at least 1, and on an hourly grid needs `obtain`
greater than the offset in hours.

The cutover moves no rows, and runs in **three transactions** so that none of its locks scales with the
row count: add the monolith's bound `CHECK` as `NOT VALID` (catalog only, instant); commit, which drops
that statement's `ACCESS EXCLUSIVE`; `VALIDATE` it, the one `O(rows)` read, under `SHARE UPDATE EXCLUSIVE`,
which blocks neither reads nor writes; commit; then one metadata-only transaction renames the original to
a coarse-child name, creates the partitioned parent, attaches the original as the bounded **monolith**
child via the now-validated `CHECK` (scan-skipping), and builds the forward grid. The table registers
**paused**; nothing happens until you `resume` it and maintenance runs.

The trade for the split is that the bound `CHECK` is live for the whole conversion rather than for one
locked statement, so a write outside `[lo, hi)` is rejected for that span (`p_bound_headroom` buys room at
the top), and a conversion that dies between transactions leaves the `CHECK` behind. See
[`transmute_abort`](#transmute_abort).

The new parent also takes over everything `CREATE TABLE ... LIKE` does not carry: the **owner**, table and
**column-level grants**, **row level security** (both `ENABLE` and `FORCE`), every **policy**, table and
column **comments**, **row triggers**, each in the enabled state it had (`DISABLE`, `ENABLE ALWAYS`
and `ENABLE REPLICA` are kept, on the parent and on the clone every partition receives), and
**publication membership**: the parent is added to every publication that names the table, with the same
row filter and column list, so every partition is published through it (the monolith keeps its own
membership as well; `untransmute` hands back the managed table's, see below). The parent takes the
table's **replica identity** too (`FULL`, `NOTHING`, or `USING INDEX`, mapped to the parent's index that
the original index is attached under), and every partition pgpm mints afterwards (obtain's, `extend_to`'s,
a regrain's fine children) takes the parent's as it is then, because PostgreSQL gives a new partition none
of its parent's: without it a keyless `FULL` table in a publication fails every `UPDATE` and `DELETE` of a
row past the monolith. A change to the parent's identity made later reaches the partitions minted after
it, not the ones that already exist. A parent whose `USING INDEX` index was dropped (PostgreSQL allows it
and treats the table as `NOTHING`) gives its new partitions `NOTHING`, and logs
`warn_replica_identity_nothing` naming the first of them. The reused **key keeps its constraint name** on the parent, so
`INSERT ... ON CONFLICT ON CONSTRAINT <name>` and DDL naming the key keep working; the monolith's copy is
renamed `pgpm_key_<index oid>` to make way, and an `untransmute` hands the original name back. Every other
**unique constraint** (one whose key includes the control column, beside the reused key) is carried the
same way: as a constraint on the parent, under its own name and with its definition (`NULLS NOT DISTINCT`,
`INCLUDE`, the index's storage parameters) and its deferrability, so `ON CONFLICT ON CONSTRAINT <name>` and a
deferred check keep working on every partition; its monolith copy is renamed `pgpm_key_<index oid>` and
handed back by `untransmute` too. A bare unique index is carried as a partitioned index `<index>_pgpm`. The
parent is created in the table's **tablespace**, so every partition pgpm mints from it lands there as well
(a table in the database default stays there). That needs `CREATE` on the tablespace: `transmute` refuses a
caller without it, and the role that runs maintenance needs it too, since it creates the forward partitions.
A sequence the table
**owns** through a column (a `serial`, or an explicit `OWNED BY`) is handed to the same column of the
parent, so retention can drop the monolith like any other partition. All of it is
captured before the rename and re-applied inside
the same transaction as the cutover, so the parent is never reachable without its policies. Each is read
under the lock that stops it changing before the rename. The owner, the RLS flags and the policies are read
once the staging copy of the table holds `ACCESS SHARE`, which excludes changing any of them. The triggers,
the comments, the secondary indexes and outgoing keys to carry, and where the identity sequence resumes are
read under the table's `ACCESS EXCLUSIVE` lock, taken as the cutover's outage begins. So a trigger, index,
key or comment another session creates, drops or changes while the conversion runs is either in place
before the read or waits until the cutover commits, and an id the sequence hands a writer while the
conversion runs is never issued again; the parent carries what the table had at the rename. The grants
are the one thing no lock on the table holds still, because `GRANT` and `REVOKE` take none, so they are read
after the rename and the attach instead: those rewrite the catalog rows every `GRANT` or `REVOKE` on the
table must rewrite too, so one committed before that is carried, and one that has not committed waits for
the cutover and then fails with `tuple concurrently updated` rather than landing on the monolith alone. The
primary key, unique constraints, identity columns and the control column's `NOT NULL` the conversion
planned from are checked again once the staging copy holds `ACCESS SHARE`; if any changed while the
conversion ran, the cutover refuses and rolls back to the resumable state `transmute_abort` describes, and
a re-run plans from the table as it is. Partitions
minted later, by `obtain` or a regrain, are given the parent's owner too rather than being
owned by whichever role runs maintenance.

The parent ends with **exactly the table's grants**, not more. It is a new table, created by the role
running the conversion, so it is born with that role's `ALTER DEFAULT PRIVILEGES` (on Supabase, privileges
for `anon` and `authenticated` in `public`). The cutover revokes everything the parent was born holding,
from every role and its owner, before it replays the table's table and column grants, so a privilege
revoked on the table is not held on the parent. A table no grant was ever made on (a `NULL` ACL) gives the
parent its owner's full privileges and nothing for anyone else. Each grant keeps its **grantor**: one a role
made through its grant option is replayed as that role (`SET ROLE`), after the grant that gave it the
option, so the role that made it can still revoke it on the parent. That needs the session running
`transmute` to be able to become each such role (a superuser can, any other role only one it is a member
of) and the role to hold `USAGE` on the schema; a table with a grant by a role it cannot become is refused
before anything is committed, naming the roles. Run the conversion as a member of each, or have each revoke
its grants and the owner make them. `from_hypertable`'s swap and `untransmute` carry grants the same way, and
refuse the same way inside their own transaction, which then rolls back whole.

Policies live on the parent, and only on the parent: a parent policy governs parent-routed reads into a
partition, and reaching a partition directly needs grants that live on the parent anyway. Each is created
on the parent after the renames, once the parent bears the table's name, because a policy's expression
can name the table itself: a correlated subquery's reference to the outer row (`m.tenant = t.org`, or
`org` written unqualified, which PostgreSQL stores qualified by the table's name) and a subquery over the
table both mean the parent, and see every partition. So the policies are re-created inside the cutover's
brief `ACCESS EXCLUSIVE` window, beside the triggers, where the rest of the parent's configuration is
applied before it begins; on an empty partitioned table each is a catalog write.

A partition pgpm mints (by `obtain`, `extend_to`, the conversion's forward grid or a regrain) holds its
owner's default privileges and **no grant for any other role**, whatever the maintaining role's `ALTER
DEFAULT PRIVILEGES` gave it when it was created: a read or write routed through the parent is checked
against the parent's grants alone, so no role needs one on a partition, and one the parent's policies
filter would read a partition unfiltered. The monolith is the original table and keeps its own grants, row
security and policies. A regrain's fine child holds that ACL, and the parent's owner, from the tick that
creates it, before its first row is copied in, not only once its sub-range is complete: between ticks a
role the maintaining role's default privileges name would otherwise read every row copied so far.

Every other relation pgpm makes for its own use beside a table (a regrain's delta and capture function,
`from_hypertable`'s copy, delta and capture function) is a **scratch relation**, and follows the same rule:
it is owned like the table and holds no grant beyond its owner's from the transaction that creates it (a
delta also grants `INSERT` to the roles that write the table, which its capture trigger writes as). pgpm
records each one, by its oid, in the transaction that creates it (`pgpm.config.regrain_delta_oid` and
`regrain_capture_fn_oid`, `pgpm.part.child_oid`, [`pgpm.scratch`](#pgpmscratch)) and finds it again only
through that record: a table, function or trigger of yours that happens to carry one of pgpm's working
names is never emptied, dropped, replaced, drained into or swapped in. Where pgpm would have to mint under
a name you hold, it refuses, naming your relation, before anything is created.

One shape is refused rather than carried: a `FOR EACH ROW` trigger with a transition table
(`REFERENCING OLD/NEW TABLE`), which PostgreSQL does not permit on a partitioned table. Rewrite it as a
statement trigger, which can carry a transition table, or drop it. So is membership in a publication with
`publish_via_partition_root = false` that names the table with a row filter or a column list, which
PostgreSQL does not allow on a partitioned table: set `publish_via_partition_root = true` on it, or drop
the filter and column list, then re-run. So is a publication naming the table that the role running
`transmute` does not own (the cutover has to add the new parent to it, which only its owner may do): run
the conversion as a role that owns it, or have its owner hand it over. So is an **exclusion constraint**
(`EXCLUDE`): its index cannot be attached under a partitioned copy, and PostgreSQL before 17 allows no
exclusion constraint on a partitioned table at all, so drop it if the table can do without it. All three are
refused before anything is committed. Three more shapes the cutover could not convert are refused the
same way, before anything is committed, naming the constraint or column: a `NOT VALID` `CHECK` (or, on
PostgreSQL 18, a `NOT VALID` `NOT NULL`) constraint, because the parent would get a validated copy the
table cannot be attached under (`VALIDATE CONSTRAINT` it first, which blocks no reader or writer, or drop
it); on PostgreSQL 18, a `NOT ENFORCED` `CHECK` constraint, named `NOT ENFORCED` (pgpm does not carry one
across the conversion, and PostgreSQL 18 can neither validate one nor alter a `CHECK`'s enforceability:
drop it, or re-create it as an enforced `CHECK`); a `CHECK ... NO INHERIT` constraint, which PostgreSQL does not allow on a partitioned table (drop it,
or re-create it without `NO INHERIT`); and a generated control column, which PostgreSQL cannot partition
by (partition on a plain column). The trigger refusal is asked again under the cutover's lock, so a
trigger of that shape created while the conversion runs is refused the same way. So is every object that
names the table by its oid rather than its name: a **view** or **materialized view** over it, a **rule** whose
action uses it (on the table itself or on another), a SQL-standard function body (`BEGIN ATOMIC`) that reads
it, and another table's **policy** that queries it. The cutover renames the original table, and that oid with
it, into the monolith partition, so each of them would follow it there and silently see the monolith's rows
alone, missing every row written to a forward partition. The refusal names them all at once. Drop them,
convert, then re-create them against the converted table (`pg_get_viewdef`, `pg_get_ruledef` and
`pg_get_functiondef` give their definitions), where they name the new parent and see every partition. The
table's **row type** goes with the oid as well, so an object typed by it is refused the same way and named
with the rest: a function taking a row of the table (or an array of rows), another table's column of that
type, or a domain over it. Converted, each would stay bound to the monolith: the function would stop taking
the table's rows, the column would reject them, and the monolith could never be dropped. The
table's own policies are not among them: they are carried, re-created on the parent once it has the
table's name, so one that queries the table reads the parent. This one too is asked before anything is
committed and again under the cutover's lock, which `CREATE VIEW` (and the rest) has to wait for. **Outgoing** foreign keys (this table
referencing another) are carried onto the new parent automatically, so they keep enforcing across every
partition; a `NOT VALID` one is refused rather than carried, because re-adding it at the parent could not
then be metadata-only. That refusal, and the refusals of a `UNIQUE` index that cannot be carried (below)
and of an exclusion constraint, are asked again under the cutover's lock, so a key or index of that shape added while the conversion runs rolls
the cutover back to the resumable state `transmute_abort` describes rather than being left on the monolith.
**Incoming** keys are governed by `p_incoming_fks` below. An identity column is carried onto the parent in
the form it had (`ALWAYS` or `BY DEFAULT`) and with its sequence's options (`INCREMENT BY`,
`MINVALUE`/`MAXVALUE`, `START WITH`, `CACHE`, `CYCLE`), read under the cutover's lock and under a lock on
the sequence itself, which `ALTER SEQUENCE` has to wait for (it takes no lock on the table), so a change
committed while the conversion runs is either carried or waits until the cutover commits. Its new sequence
takes the original's name (`t_id_seq`, or whatever the original was renamed to), not the staging parent's
`t_pgpm_new_id_seq`, so a `setval`, `GRANT ... ON SEQUENCE` or `ALTER SEQUENCE` naming it keeps working. It
is set from three values read under
the cutover's lock: the original sequence's own next value, and the column's largest and smallest ids. The
largest and smallest are re-read there only when an index leading with the column answers them, which also
covers an explicit id written meanwhile; otherwise the ones read before phase 1 stand in, so no scan runs
under the lock. From the next value it moves along the sequence's lattice (`start + k * increment`, downward
for a negative increment) until it clears every id already in the table, so auto-generated ids never
collide, never re-issue a value the sequence had already moved past (including one it handed a writer while
the conversion ran), and keep the spacing you declared. An exhausted sequence stays exhausted. `untransmute`
restores it the same way, under its own lock and the sequence's.

Parameters:

- `p_control` -- the partition-key column. It **must be `NOT NULL`** (a partition key cannot be null;
  `pgpm` never scans to enforce it). A key is not required: if the **primary key** includes the control
  column, `pgpm` reuses it in place and never rewrites it; if there is no primary key and a **unique
  constraint** includes the control column, that is reused instead (either way with its deferrability:
  a `DEFERRABLE` or `INITIALLY DEFERRED` key stays so on the parent and on every partition, the forward
  ones included); if there is neither, the table is partitioned **keyless** (no key synthesized). A
  **primary key that *excludes* the control column is refused** (no rewrite), whatever other unique
  constraints the table has: it could not be carried onto the parent, and `pgpm` will not adopt a
  different key and leave it behind on the monolith, where it would enforce nothing for new rows. The error names the constraint and the control column. A *bare*
  unique index is refused too (promote it to a constraint first). Column **order** within the key
  is free: PostgreSQL requires only that the key *contain* the partition key, and `pgpm` reads the key for
  identity, never for ordering. Choose it for your own reads (see
  [the guide](guide.md#the-cutover-moves-no-rows)). Note: `regrain` is unavailable
  on a keyless monolith, so its history stays as one coarse child unless a key is added before transmute.
- `p_interval` -- the grid width (`interval '1 day'`, `'1 month'`, `'1 year'`, ...). Cast a bare literal:
  `interval '1 month'` (it disambiguates from the `bigint` overload).
- `p_obtain` -- how many partitions to keep ahead of the frontier.
- `p_retain` -- drop partitions older than this `interval`; `null` keeps everything. Must not be
  negative: a negative interval is refused before anything is committed, because it would put the
  retention horizon past the partition taking writes and the first maintenance tick would drop every
  partition. Negative means any field: none of the interval's months, days or time may be below zero,
  so a mixed-sign value such as `'-1 year 360 days'` is refused too (it compares equal to zero, yet
  taken off the calendar it moves the horizon five or six days into the future). `interval '0'` is
  allowed and keeps only the partition taking writes.
- `p_regrain_batch` -- rows per regrain COPY microbatch.
- `p_anchor` -- the grid origin the boundaries align to (month and year steps count from its month in
  the session's zone; day and shorter steps count seconds from the instant).
- `p_paused` -- register paused (the default); `false` goes live immediately.
- `p_incoming_fks` -- `'error'` (the default: refuse if any incoming FK exists, asked again under the
  cutover's lock, so a key added while the conversion runs is refused there rather than left referencing
  the monolith) or `'preserve'` (drop each
  for the conversion and re-add it against the new parent, which `maintain` does on a later tick, or
  `restore_incoming_fks` does now). `'drop'` is also accepted, but it is **not** a third behavior: it takes
  the same path as `'preserve'`, so the keys are recorded and restored just the same. The drop happens in
  the cutover, the last of the conversion's three transactions, in the same transaction that records the
  key, so a conversion that fails or is abandoned before then leaves every incoming FK exactly where it
  was, and one that fails in the cutover rolls the drop back with it. Referential integrity on the
  referencing table is off only between a completed cutover and the restore. A key declared on a
  partitioned referencing table is dropped, recorded and restored once, at that partitioned table; its
  per-partition copies go and come back with it. A **`NOT VALID`** incoming key is refused under
  `'preserve'` and `'drop'` alike, before anything is committed and again under the cutover's lock,
  naming every such key: `maintain` validates each key it re-adds, which is right for a key that was valid
  when the cutover dropped it (any orphan then arose while it was down) and wrong for one you left
  unvalidated, which it would either promote silently or fail to validate over the rows you tolerated and
  retry every five minutes for good. Validate it first (`ALTER TABLE <referencing table> VALIDATE
  CONSTRAINT <name>`) or drop it, then re-run, as for a `NOT VALID` outgoing key.
- `p_force_uuidv7` -- skip the uuidv7 plausibility refusal (see below).
- `p_tt_prefix`, `p_tt_width`, `p_tt_radix`, `p_tt_unit` -- **text_time only**, and all four are required
  together when the control column is `text`/`varchar`. They describe the column's shape: a constant
  literal prefix (`''` if none, `'c'` for classic `cuid`), the fixed character width of the
  encoded-count field (`8`), the base it's encoded in (`36`), and the time unit it counts (`'ms'` or
  `'s'`). See [`check_text_time`](#check_text_time) and the [ready-to-use recipes](guide.md#pick-the-kind)
  for cuid v1, ULID, KSUID and MongoDB ObjectId.
- `p_tt_alphabet` -- **text_time only**, optional. The digit-to-character mapping, one character per
  value `0..p_tt_radix-1`, in order. `null` (the default) uses the contiguous `0123456789abcdefghi...z`
  convention, valid for `p_tt_radix` up to 36; a radix above that, or a different character set
  entirely (ULID's Crockford base32 skips I/L/O/U; KSUID's base62 is digits then uppercase then
  lowercase), requires spelling the alphabet out explicitly. Its length must equal `p_tt_radix`.
  A mixed-case alphabet (KSUID's) needs the control column on a bytewise collation (`collate "C"`):
  RANGE bounds on a `text` column compare under the column's collation, and `en_US` sorts `a` before `P`
  where base62 puts it after. `transmute` refuses otherwise, naming the collation and the first
  misordered digit pair; see [`check_text_time`](#check_text_time) and the
  [guide](guide.md#pick-the-kind).
- `p_tt_discard_bits` -- **text_time only**, default `0`. After decoding the whole
  `p_tt_prefix`-plus-`p_tt_width`-characters field as one number, discard this many of its low-order
  bits before treating what remains as the time count. `0` (the default) means the decoded field *is*
  the count already (cuid, ULID); KSUID needs `128`, since it base-`62`-encodes its entire 160-bit
  payload (32-bit timestamp + 128 bits of random) as a single number, not the timestamp alone.
- `p_tt_epoch` -- **text_time only**, default `'1970-01-01 00:00:00+00'` (standard Unix epoch). The
  zero-point the decoded count is measured from. Only formats with a non-standard epoch (KSUID:
  `'2014-05-13 16:53:20+00'`) need to set this.
- `p_force_text_time` -- skip the text_time plausibility refusal (see below).
- `p_bound_headroom` -- push the monolith's upper bound `hi` this many grid steps further out. The bound
  `CHECK` refuses writes at or past `hi` for the whole conversion, so raise this if the frontier could
  cross `hi` while the validation scan runs. `0` (the default) puts `hi` at the first grid boundary above
  the frontier. **This `hi` is not scoped to the conversion: it becomes the monolith's permanent, attached
  partition bound at cutover.** There is no way to widen the write ceiling for the conversion without
  also widening the monolith's permanent range by the same amount. The monolith cannot be regrained until
  the frontier has passed that same `hi` (see [`regrain_step`](#regrain_step)), so headroom sized to
  cover a write-ceiling window lasting seconds to minutes also delays regrain eligibility for the
  *entire* monolith by the same number of grid steps -- a full extra week on a weekly grid, for
  `p_bound_headroom => 1` -- even though almost all of its rows are, by the time the frontier reaches
  that point, unambiguously historical. Weigh that against the write-ceiling risk headroom is actually
  buying; raising it is not free.
- `p_lock_timeout` -- how long each phase waits for a lock before giving up (`'5s'` by default; any
  `lock_timeout` value). This bounds a wait, it does not shorten one: the locks themselves are brief. It
  matters because a *pending* `ACCESS EXCLUSIVE` request blocks every lock request queued behind it, so
  without a bound one long-running query stalls the whole table for as long as it runs. A bad value is
  refused before anything is committed. On timeout, a failure in phase 1 leaves the table untouched, and
  one in the cutover leaves the recorded, resumable state [`transmute_abort`](#transmute_abort) and
  `maintain_all`'s sweep handle; either way, re-run `transmute` to retry, from the same session or a new
  one. The claim a failed attempt leaves records your session as its owner, and that session may resume
  or abort it; only a conversion still running in a *different* live session is refused.
- `p_force_frontier` -- **time, uuidv7 and text_time.** For these kinds the frontier is the newer of the
  column's maximum and `now()` (for `time`, so that `hi` lies past every row the table holds, a scheduled
  or future-dated one included), so one row minted by a client with a wrong clock sets the frontier, and with
  it the monolith's permanent `hi`, as far ahead as that clock was wrong: every row written until then lands
  in the monolith, `status()` shows nothing abnormal, and the monolith cannot be regrained nor anything
  behind it dropped until the clock really passes `hi`. The plausibility sampling cannot see it (one bad row
  in 402 is fraction 0.9975). So `transmute` refuses, before anything is committed, when the column's newest
  value decodes to more than **one partition step plus one hour** past `now()`, naming that value, its
  decoded timestamp, the `hi` it would have imposed and the `hi` the clock alone would give. The allowance
  is measured from `now()`, never from a `p_bound_headroom`-widened bound: headroom is you asking for a
  farther `hi`, and it does not also widen what the data may impose. A few minutes of ordinary clock skew is
  always inside the allowance. The remedy is to delete or correct those rows (the message names the value
  every offending row sorts above) and re-run; `p_force_frontier => true` accepts the far `hi` knowingly,
  with a `NOTICE` restating what it costs. See [`check_uuidv7`](#check_uuidv7) and
  [`check_text_time`](#check_text_time), whose `newest_decoded`/`newest_in_future` show the maximum before
  you convert.

Refuses up front (leaving the table untouched) when: an argument whose null has no meaning is null
(every argument except `p_retain`, whose null keeps everything, the `text_time` shape arguments
`p_tt_prefix`, `p_tt_width`, `p_tt_radix` and `p_tt_unit`, null outside `text_time` and required inside it,
and `p_tt_alphabet`, whose null is the default alphabet): the message names each null argument, so a `p_force_*` override, `p_incoming_fks`,
`p_regrain_batch`, `p_paused` or `p_tt_epoch` passed as null is refused rather than read as `true`, as
absent, or as a bound no row satisfies; the step is not positive (a negative or zero
interval or `bigint`), or is not a whole number of days or months on a `date` control column (a finer
step's bounds truncate to dates); `p_obtain` is negative or null (the rule [`set_obtain`](#set_obtain)
applies); the call resumes an earlier attempt's claim and that claim's recorded bound is not on this
call's grid (its `lo` or `hi` is not a boundary of `p_step` and `p_anchor` in the zone the bound was
computed in: re-run with the step and anchor of the attempt that recorded it, or abort it), or was
recorded on another control column (the bound's `CHECK` is on that column, so it cannot certify this one's
partition bound and the cutover would scan the whole table under `ACCESS EXCLUSIVE`: re-run on the column
that attempt used, which a rename in between does not change, or abort it); the table is already converted (it has a `pgpm.config`
row: `transmute` converts a table once, and a retry whose earlier cutover did commit has nothing to resume),
is not a plain table (partitioned, a view, a foreign table), or is a partition, an inheritance child or an
inheritance parent; a relation of any kind already holds the name the monolith will take
(`<table>_p<lo>_to_<hi>`, typically a monolith detached from an earlier conversion of a table by that name)
or a child-partition name (`<table>_p<label>`, any name pgpm could give a fine child, an id label past 19
digits or with a fraction included: an orphan from an interrupted regrain, or a sequence or
view that happens to be named that way); a type that is not a table's row type (an enum, domain or range
type) holds the monolith's name, the staging name `<table>_pgpm_new` or a child-partition name (a table's
row type takes its name, so the cutover's `CREATE TABLE` and `RENAME`, and every later partition's
`CREATE TABLE`, need it free as a type too); a key (primary key or unique constraint) exists but
excludes `p_control`, or only a *bare* unique index includes it (promote it to a constraint first); the
control column is `float`/`double` (imprecise boundaries); a `time`-kind control column
is not a timestamp/date, a `uuidv7` control is not `uuid`, or a `text_time` control is not `text`/`varchar`;
a `uuid` control samples as overwhelmingly random (UUIDv4) and `p_force_uuidv7` is not set; a `text_time`
control is missing any of `p_tt_prefix`/`p_tt_width`/`p_tt_radix`/`p_tt_unit`, has a `p_tt_radix` outside
2-36 with no `p_tt_alphabet` supplied, a `p_tt_alphabet` whose length does not match `p_tt_radix` or that
repeats a character, a non-positive `p_tt_width`, a negative `p_tt_discard_bits`, an alphabet the control
column's collation does not order the way base-`p_tt_radix` place value does (KSUID's base62 on an
`en_US` column, or any alphabet with digits under an ICU collation with numeric ordering such as
`und-u-kn-true`; put the column on `collate "C"`, which `p_force_text_time` does not override), or
samples as not matching the declared shape and `p_force_text_time` is not set; a `time`, `uuidv7` or `text_time` control's newest
value lies (or decodes to) more than one partition step plus one hour past `now()` and `p_force_frontier` is not set
(a future-dated row would pin the monolith's permanent `hi` there); a `time` control's newest value is
`infinity`, which no partition can hold (`p_force_frontier` does not override this); a `numeric` `id`
control holds `NaN`, `Infinity` or `-Infinity`, for the same reason (delete or correct those rows and re-run); an `id`
control column cannot hold the grid's bounds: a `numeric` with a negative scale holds only multiples of its
unit (100 for `numeric(6,-2)`), so a `p_step` or `p_anchor` that is not one is refused, since the cutover's
`ATTACH` (and each forward partition's) would round a bound between two of them; and a monolith bound the
column's type cannot store (past a `numeric`'s precision or an integer type's range, such as `10000` on a
`numeric(4,0)` key) is refused, since the `ATTACH` would fail on it after the bound had been committed; a
resumed claim's recorded bound is not finite or cannot be stored in the column (an older install could
record one, such as `hi = NaN` for a key that held a `NaN` row): call [`transmute_abort`](#transmute_abort), then re-run, which
computes a fresh bound; on PostgreSQL 18, a foreign key on or to the table is `NOT ENFORCED`, in either
direction (pgpm carries a key only as an enforced one: drop it, or `ALTER TABLE <table> ALTER CONSTRAINT
<name> ENFORCED`, which checks every row, then re-run); row-level security
would filter the caller's reads of the table (`row_security_active()` is true: a non-superuser owner without
`BYPASSRLS` on a table with `FORCE ROW LEVEL SECURITY`, or a caller that is not the owner), because the
bound is read from the rows the caller can see (run it as a role with `BYPASSRLS`; an owner on a table
that only `ENABLE`s row-level security is not filtered and converts as before); a non-PK `UNIQUE` secondary index does not include the
partition key (global uniqueness could not be enforced); an incoming FK exists and `p_incoming_fks` is
`'error'`; a standalone table matching the child-partition naming already exists (an orphan from an
interrupted run); a name the conversion derives from the table's (the monolith's `<rel>_p<lo>_to_<hi>`, a
fine cell's `<rel>_p<lo>`, the staging `<rel>_pgpm_new`) would exceed PostgreSQL's 63-byte identifier
limit, which pgpm never truncates (the message names the offending name and says how many bytes to shorten
the table name by; the budget is under [Partition naming](#partition-naming)); a secondary index's name is
longer than 58 bytes, so the `<index>_pgpm` name of its partitioned copy would not fit (PostgreSQL's own
auto-names reach 63; the message names each such index, and `ALTER INDEX ... RENAME TO` a shorter name
clears it; an index behind a unique constraint is exempt, since the parent takes the constraint's own name);
the table is in a tablespace the caller has no `CREATE` on (the message names it); or a relation already
occupies one of the `<index>_pgpm` names the conversion needs for the partitioned copies of the table's
secondary indexes (also usually a leftover from an interrupted run), or the `pgpm_key_<index oid>` name the
monolith's copy of the key, or of a unique constraint, takes.

```sql
call pgpm.transmute('public.search_history', 'id', interval '1 month',
                      p_tt_prefix => 'c', p_tt_width => 8, p_tt_radix => 36, p_tt_unit => 'ms');
```

(that's cuid v1; ULID, KSUID and MongoDB ObjectId need `p_tt_alphabet` and/or `p_tt_discard_bits`/
`p_tt_epoch` too -- see the [ready-to-use recipes](guide.md#pick-the-kind) for all four.)

```sql
call pgpm.transmute('public.events', 'created_at', interval '1 month',
                      p_obtain => 7, p_retain => interval '90 days');
```

### `transmute` (integer / id grid)

```sql
pgpm.transmute(
  p_parent regclass, p_control name, p_step bigint,
  p_obtain int default 30, p_retain bigint default null,
  p_regrain_batch int default 5000, p_anchor bigint default 0,
  p_paused boolean default true, p_incoming_fks text default 'error',
  p_bound_headroom int default 0,
  p_lock_timeout text default '5s'
)
```

The **id** overload, for `int`/`bigint`/`numeric` keys (including Snowflake-style ids). Also a
`PROCEDURE`. Identical to the time overload except the grid width is a `bigint` `p_step`, `p_retain` is a
`bigint` count of ids (not negative, as for the time overload: a negative count is refused up front, and
`0` keeps only the partition taking writes), and `p_anchor` is a `bigint`. There is no `p_force_uuidv7`.

```sql
call pgpm.transmute('public.events', 'id', 10000000, p_obtain => 2);
```

### `transmute_abort`

```sql
pgpm.transmute_abort(p_parent regclass, p_lock_timeout text default '5s') returns boolean
```

Abandons a conversion that died between transactions, dropping the `pgpm_monolith_bound` `CHECK` it left
on the table and clearing its `pgpm.transmute_inflight` row. Returns `false` if there is no in-flight
conversion to abandon, and raises if one is still running in another session. Your own session's failed
attempt is always yours to abort: the claim it left records your session as its owner, which is not
"another session". That is all there is to undo: incoming foreign keys are dropped only by the cutover,
so a conversion that never got there left them in place, and there is nothing for this to re-add.

**The wait for the table's lock is bounded.** Dropping the bound takes `ACCESS EXCLUSIVE` on your live
table, and a pending request for it blocks every later read and write of the table, so `p_lock_timeout`
(`'5s'` by default, the same default as `transmute`'s) bounds the wait. When it expires the call raises
`pg_partition_magician: transmute_abort(...) could not take ACCESS EXCLUSIVE on ... within ...`, SQLSTATE
`55P03` (`lock_not_available`), and changes nothing: the bound and the claim are as they were. Retry when
the transaction holding the table has finished, or pass a longer value. A bad value is refused before
anything is read.

It **abandons; it does not resume**. Finishing a half-done conversion of a live table unattended is a
larger action than pgpm will take on your behalf. To try again, call `transmute` again, from a session in
any zone: it finds the recorded row and reuses the bound already on the table, and the zone that bound was
computed in, rather than recomputing one against a frontier that has since moved. Give it the same step and
anchor as the attempt that recorded the bound (or any other step whose grid that bound lies on): a re-run
whose grid the bound is not on is refused, since registering it would leave a hole past the monolith.

You mostly will not need to call this. Every `maintain_all` tick sweeps for abandoned conversions and
undoes them, and it decides "abandoned" from whether the session that claimed the conversion is still
connected rather than from a timeout, so a long validation scan is never mistaken for a dead one and an
operator whose session is still open keeps the right to retry. Both this function and the sweep find the
table by the identity the claim recorded, not by its name, so a half-converted table that was renamed or
moved to another schema after its conversion failed is still found and has its bound dropped; the sweep
forgets a claim without acting only when that table no longer exists at all. The sweep waits at most 5 s
for the table's lock: behind a longer transaction it logs `skip_transmute_reap` and tries again next tick,
rather than queue every read and write of the table behind its own `ACCESS EXCLUSIVE` request.

### `untransmute`

```sql
pgpm.untransmute(p_parent regclass) returns regclass
```

Reverses a `transmute`, returning the restored ordinary table. It is a **clean, metadata-only reverse
while the monolith is still intact and holds the whole table**: it detaches the monolith, drops the
childless parent (cascading any empty forward partitions), renames the monolith
back and hands its key the name the parent's carried (the conversion had renamed the monolith's copy
`pgpm_key_<index oid>`), restores identity (its sequence under the name the parent's carried, not the
monolith's `t_p<label>_id_seq`), the ownership of any `serial` sequence, the row triggers (each in the enabled
state the parent had) and any preserved incoming FKs (`NOT VALID`, see below), and clears `pgpm` state. The
monolith is the original table itself, found by the oid `transmute` recorded for it
(`pgpm.config.monolith_oid`), never by its position in the grid. A caller whose reads of the parent
row-level security would filter is refused (see [Maintenance steps](#maintenance-steps)): its check for rows
outside the monolith could not see a hidden one, and the reverse would drop it with the parent.

The table comes back with the **privileges and row security the managed table had at the reverse**, not
the ones it had at the conversion. After a `transmute` the parent is the table, so a `GRANT` or `REVOKE`,
an `ENABLE` or `FORCE ROW LEVEL SECURITY` (or their opposites) and a `CREATE` or `DROP POLICY` issued since
all landed on the parent, and none of them reaches a partition. `untransmute` resets the monolith's own
conversion-time copy (every role's privileges revoked, the owner's included, every policy dropped) and puts
the parent's in its place: its table and column grants, each under its grantor as `transmute` carries them
(or, with no grant ever made, the owner's default privileges), both row-security flags, and its policies. So
a privilege the owner revoked from itself on the managed table stays revoked. The same holds for its **owner** and its table and column
**comments**: `ALTER TABLE ... OWNER TO` and `COMMENT ON` the managed table do not reach its partitions
either, so the restored table takes the parent's owner (the role that owned the managed table keeps it)
and the parent's comments, a comment removed since the conversion staying removed. And for its
**publication membership**: `ALTER PUBLICATION ... ADD`, `DROP` or `SET TABLE` naming the managed table
changes the parent's membership, not the monolith's, so the restored table joins every publication the
parent was in, with the parent's row filter and column list, and leaves every one it was not in. A
membership that already matches is left alone, so a reverse with no membership changed since the
conversion issues no `ALTER PUBLICATION` at all. A publication `FOR ALL TABLES` or `FOR TABLES IN SCHEMA`
names no table and covers the restored table as it covered the parent. And for its **replica identity**:
`ALTER TABLE ... REPLICA IDENTITY` on the managed table lands on the parent only, so the restored table takes
the parent's (`DEFAULT`, `FULL`, `NOTHING`, or `USING INDEX` on its own index that was attached under the
parent's identity index) rather than the one the monolith kept from the conversion.

The **indexes and index-backed constraints made on the managed table since the conversion** come back under
the names the managed table gave them. `CREATE INDEX` or `ADD CONSTRAINT ... UNIQUE` on a partitioned table
clones onto each partition under an auto-name of the partition's (`t_p<label>_v_idx`), and the reverse
renames the monolith's copy to the parent's name, so `ON CONFLICT ON CONSTRAINT <name>` and `DROP INDEX
<name>` keep working. That includes a primary key made since the conversion (a keyless table's, or one
replacing the key), whose copy on the monolith carries the clone's auto-name `t_p<label>_pkey`. A secondary
index the conversion carried keeps the name the table always gave it, not its `<name>_pgpm` partitioned
copy's, and the primary key of a table converted before its parent kept the key's name keeps the name it
had.

A table **moved to another schema** with `ALTER TABLE <parent> SET SCHEMA` comes back in that schema, where
the application has been finding it since the move. The monolith stayed where it was, so the reverse names
it by its recorded oid, renames it back and moves it, with its indexes, row type and the sequences it owns,
into the parent's schema (after re-adding any preserved incoming FKs against it by its identity, whatever
name and schema their recorded definitions give it).

It also takes off the monolith whatever **maintenance** put there after the conversion, so the table handed
back is the operator's again with none of pgpm's machinery on it. The retention **write block**
(`pgpm_write_block`) comes off: a monolith retention had reached but not dropped, because archiving was
deferred or because recorded coverage kept the block after the frontier regressed, would otherwise come
back unmanaged and rejecting every write, with no `pgpm` state left to lift it. Coverage recorded for it
stays in `pgpm.archive_ledger`, as it does after a `retire`. And a **regrain still in flight** on the
monolith is abandoned exactly as [`regrain_cancel`](#regrain_cancel) would abandon it (capture trigger and
`TRUNCATE` guard off, fine copies dropped, delta cleared, one `regrain_cancel` log row): before its swap the
monolith still holds every row, so nothing is lost but the copy work.

A **preserved incoming FK** (`p_incoming_fks => 'preserve'`) comes back against the restored table
`NOT VALID` whenever its referencing table is an ordinary one: it enforces every new write at once, but
`untransmute` does not validate it, because validating scans the whole referencing table and would do so
under the `ACCESS EXCLUSIVE` the reverse holds on the restored table, stalling every reader and writer of it
for the length of that scan. The same goes for a key whose referencing table picked up orphans while the key
was suspended: it comes back `NOT VALID` rather than rolling the reverse back. `pgpm` forgets the table at
the end of the call, so no maintenance tick will validate these keys; `untransmute` raises a `NOTICE` naming
each one, and you validate it yourself afterwards, in its own transaction, where it takes only
`SHARE UPDATE EXCLUSIVE` on the referencing table and `ROW SHARE` on the restored one, blocking neither:

```sql
select format('alter table %s validate constraint %I', conrelid::regclass, conname)
  from pg_constraint
 where confrelid = 'public.events'::regclass and contype = 'f' and not convalidated;
-- run each statement it prints; one that fails names an orphan row to fix first
```

Validate them before converting the table again with `p_incoming_fks => 'preserve'`, too: `transmute`
refuses an incoming key that is `NOT VALID` (see `p_incoming_fks` under [`transmute`](#transmute-time--uuidv7--text_time-grid)).

A partitioned referencing table cannot hold a `NOT VALID` key, so its key is re-added validated in one step,
as `restore_incoming_fks` does.

It is a **one-way door** once any row lives outside the monolith's range -- a forward partition after the
frontier crosses `B`, or the finer children a regrain's swap has put in the monolith's place -- because a
metadata-only reverse would lose those rows. And it is one once the monolith is gone, whatever rows are
left: after retention has retired the original table, or a regrain's swap has replaced it, `untransmute`
refuses (`the original table ... is no longer one of its partitions`) rather than hand back a forward
partition or a fine child under the table's name. A table converted before `monolith_oid` existed is
anchored by the upgrade when exactly one attached partition predates its parent, which only the original
can; one the upgrade cannot anchor is refused too.

The door is checked twice. Once before anything is touched, under no lock a writer would feel, so a
refusal never blocks anyone. And again under the **`ACCESS EXCLUSIVE` lock on the parent** that the
detach and drop need, taken explicitly just before them, so a row that commits into a forward partition
while `untransmute` is waiting for that lock is refused rather than dropped with the parent. The wait is
bounded by the caller's `lock_timeout`, and a refusal rolls the whole call back, leaving the table exactly
as it was. The row triggers and their enabled states, the publication memberships, and where the restored
identity sequence resumes, are read under that same lock, so a trigger created or changed, a publication
joined or left, or an id taken, while `untransmute` waits for it comes through to the restored table. `untransmute` must run in a `READ COMMITTED` transaction (the default): a stricter isolation
level cannot give the under-lock check a snapshot taken after the lock, so it refuses up front rather than
proceed on a stale one.

It refuses, the same two ways, while an object names the managed table by its oid: a view, materialized
view, rule, `BEGIN ATOMIC` function or another table's policy created over the parent since the conversion,
or a function, column or domain typed by the parent's row type. The reverse drops the parent, which would
fail on all but a rule and take a rule on the parent with it silently. The drop takes every other partition
too (the empty forward partitions and any `DEFAULT`), so the same objects over one of those, or typed by one's
row type, are refused as well, all named at once; a partition's own rules and policies go with it and are not.
Drop them, run `untransmute`, then re-create them against the restored table. An object over the
monolith partition itself needs nothing: it follows the original table back.

## Migrating from TimescaleDB (`from_hypertable`)

An **optional add-on** (`pgpm_hypertable/install.sql`) for migrating a TimescaleDB **Apache-edition** hypertable
to a `pgpm`-managed native `RANGE` partition set. Load it on top of the core, only in a database where the
`timescaledb` extension exists (the core's lone runtime dependency stays `pg_cron`). It un-hypertables the
table by a full **online copy** into a plain table under the original name, then hands off to `transmute`, so
it stays version- and catalog-agnostic, which is what the deprecated Apache builds need. Verified on
TimescaleDB 2.9.1 and 2.16.1 (PG15).

The procedures `COMMIT` (per chunk during the copy, and at the swap), so they must be invoked at the top
level (a plain `CALL`, never inside a surrounding transaction or an atomic block).

Scope and caveats:

- A single time/`RANGE` dimension on a `timestamptz`, `timestamp` or `date` column, migrated on that column:
  `p_control` must be the dimension column, because the copy is bounded on the dimension's chunk ranges and
  on any other column it would silently lose rows. **Continuous aggregates**, **space partitioning** (more
  than one dimension), **integer-time** dimensions and a `p_control` other than the dimension are refused up
  front.
- The control column's key is whatever `transmute` reuses: a primary key or unique constraint that includes
  it, else **keyless** (the common hypertable shape, since `create_hypertable` makes the time column
  `NOT NULL` but adds no key). A key that is only a bare `UNIQUE INDEX` is refused up front, as `transmute`
  refuses it: TimescaleDB does not allow `ADD CONSTRAINT ... USING INDEX` on a hypertable, so the message
  gives the `ALTER TABLE ... ADD CONSTRAINT ... UNIQUE (...)` and `DROP INDEX` that make it a constraint.
  Identity columns, generated columns, `CHECK` constraints, defaults, and `NOT NULL` are all preserved (see
  `transmute`), and so is every sequence the hypertable **owns** through a column (a `serial`, or an explicit
  `OWNED BY`): the same sequence, at its own position, owned by the same column of the migrated table. So are
  the table's owner, its table and column grants, row-level security (`ENABLE` and
  `FORCE`) and its policies, its comment, its triggers, its replica identity and its publication
  membership (with each row filter and column list), which the swap puts back on the copy before
  `transmute` carries them onto the parent and every partition. TimescaleDB's own insert-blocker trigger is
  not carried, nor is the change-capture trigger of a tracking copy that was never cut over, which the swap
  recognises by the horizon comment on its delta, so a moved or renamed table does not take it along. A
  membership with a row filter or a column list in a publication with `publish_via_partition_root = false`
  is refused up front, by the preflight and by the cutover under its lock, because `transmute` refuses it
  on a partitioned table. Storage parameters are not carried, as `transmute` does not carry them.
- The migration reads every row as the **caller**, so a caller whose reads row-level security would filter
  is refused before anything is copied or committed, by `from_hypertable_preflight` (so by
  `from_hypertable` and `from_hypertable_copy`), by the drains (`from_hypertable_drain_appends`,
  `from_hypertable_drain_delta` and their steps) and by `from_hypertable_cutover`: on a hypertable
  with `FORCE ROW LEVEL SECURITY`, a non-superuser owner without `BYPASSRLS` would copy only the rows its
  policies admit, and the conservation check, reading the source the same way, would agree. The cutover
  asks twice, up front and again under its lock, so row-level security switched on while it prepares
  refuses the swap with the hypertable whole (`cannot swap in the copy of hypertable ...`). Run the
  migration as a role with `BYPASSRLS` (a superuser has it); the hypertable keeps its `FORCE`.
- The copy is **online** (the source serves traffic throughout), and so is the index rebuild: the
  destination's primary key and secondary indexes are built on the private copy **before** the cutover takes
  its lock. The cutover's `ACCESS EXCLUSIVE` window is therefore **brief and metadata-bound** -- it catches up
  the delta, swaps the table in, and *adopts* the pre-built indexes (`USING INDEX`); it does not rebuild them
  under the lock, so the blocking window does not grow with table size the way an under-lock rebuild would.
  The catch-up backlog is also drained **online, in micro-batches, before the lock** -- the tracked change
  delta (`from_hypertable_drain_delta`, with `p_track_changes`) or the appended-rows tail
  (`from_hypertable_drain_appends`, the default append-only path) -- so the window does not grow with the
  accumulated lag either.
- The copy writes a **full second table**, so the migration transiently needs roughly the source's current
  size in extra disk until cutover drops the old hypertable. `from_hypertable_preflight` raises a `NOTICE`
  with the estimate; `from_hypertable_disk_estimate` returns it for sizing a volume ahead of time.
- A carried-over `drop_chunks` retention policy is auto-translated into `pgpm`'s `retain`, and it covers the
  unregrained monolith too: the monolith is **not exempt**, and drops whole, in one step, once its entire range
  is past the horizon (see [`retain`](#retain)). What `regrain` changes is only the granularity, and `regrain`
  is unavailable on a keyless monolith, so a keyless migration reclaims its migrated history in that one cliff
  unless a key is added and the monolith is regrained first.

### `from_hypertable`

```sql
pgpm.from_hypertable(
  p_hypertable regclass, p_control name, p_interval interval,
  p_obtain int default 30, p_retain interval default null,
  p_drain_batch int default 5000, p_anchor timestamptz default '2000-01-01 00:00:00+00',
  p_paused boolean default true, p_track_changes boolean default false, p_predrain boolean default true,
  p_lock_timeout text default '5s', p_force_frontier boolean default false
)
```

The one-shot driver: runs `from_hypertable_copy` then `from_hypertable_cutover` back to back. Use it when the
migration does not need to interleave application writes between the phases. `p_interval` and the
`p_obtain`/`p_retain`/`p_anchor`/`p_paused` parameters pass straight through to `transmute`; `p_drain_batch` is this module's own
to `transmute` (see there); `p_control` is the time dimension column; `p_track_changes`, `p_predrain` and
`p_lock_timeout` are described under `from_hypertable_copy` and `from_hypertable_cutover` (a bad
`p_lock_timeout` is refused before the copy starts, and so is a `p_interval` whose monolith name would not
fit, a key that is a bare unique index, and a newest row past `transmute`'s frontier bound, see
`from_hypertable_cutover`). `p_force_frontier` is passed through to the cutover and on to `transmute`.
When `p_retain` is left `null`, the source's `drop_chunks` policy interval (if any) is carried in.

```sql
call pgpm.from_hypertable('public.metrics', 'ts', interval '1 day', p_paused => false);
```

### `from_hypertable_copy`

```sql
pgpm.from_hypertable_copy(p_hypertable regclass, p_control name, p_track_changes boolean default false)
```

Phase 1: build the plain destination (`<rel>_pgpm_dest`) and bulk-copy the existing chunks into it online, one
chunk-range per transaction, clustered by the control column. The source keeps serving traffic. Run this, let
the workload continue, then run `from_hypertable_cutover` when ready. The destination takes the source's
columns, defaults and `CHECK` constraints as they stand now; schema changes to the hypertable before the
cutover make it refuse (see `from_hypertable_cutover`), so re-run this after one. The destination carries the
table comment `pgpm from_hypertable copy of <oid>`: it is the record by which `pgpm_core/uninstall.sql` finds a
copy that was never cut over and drops it (while the hypertable it names still exists), and the cutover
replaces it with the hypertable's own comment, or none. The copy, and for a tracking copy its delta and
capture function, are recorded in [`pgpm.scratch`](#pgpmscratch) as they are created, and every later step
(the drains, the cutover, a re-run of this copy, `uninstall.sql`) finds them there, by oid. They are owned
like the hypertable, with no grant beyond the owner's (the delta also grants `INSERT` to every role that can
write the hypertable, since its capture trigger writes as the writer), from the moment they are created, so
no role the migrating role's default privileges name reads the copied rows during the online window; the
cutover gives the migrated table the hypertable's own grants. So the migrating role must be the hypertable's
owner or a member of it (and the owner must hold `CREATE` on the schema), as the swap always required; this
copy refuses otherwise, before anything is created. A table, function or trigger already holding one of the
names this copy mints (`<rel>_pgpm_dest`, and for `p_track_changes` `<rel>_pgpm_delta`,
`<rel>_pgpm_delta_fn()` and the trigger `<rel>_pgpm_delta_trg` on the hypertable) that is not this
hypertable's recorded copy is **refused**, never dropped or replaced: rename or drop it and re-run. A copy
an earlier release made carries no record if it predates the comment (pgpm 0.6.0 and earlier) and is
refused the same way; drop it, and this copy rebuilds it. A re-run replaces this hypertable's previous copy.
Each chunk's bounds are
applied in the dimension's own type (`timestamptz`, `timestamp` without time zone, or `date`), so the copy is exact under any
session `TimeZone` and `DateStyle`; a hypertable on a dimension of any other type is refused here. The same
holds for every watermark and control range the drains and the cutover carry: each is rendered in ISO style
and in the column's own type, never through the session's zone or a zone abbreviation.

- `p_track_changes` -- capture in-flight **updates, deletes and out-of-order appends**, not just in-order
  appends. When `false` (the default), the cutover catches up **append-only**: it takes the rows whose
  control column is at or past the copy watermark (`max(control)` in the destination) and nothing else.
  When the hypertable was empty at the copy there is no watermark, and every row the source holds is taken.
  That is correct only for a workload whose rows arrive in control order and are never changed afterwards.
  It **cannot see updates and deletes** to already-copied rows, and it **cannot see a row that arrives
  during the window with a control value below the watermark**: multi-writer clock skew, batched device
  uploads and backfills all produce such rows, and they are the normal shape of an IoT workload. Neither
  is lost silently: the cutover compares the two sides under its lock and **refuses the swap** on any
  mismatch (see `from_hypertable_cutover`), so the failure mode is a refused cutover naming both counts,
  not a table dropped short. A row landing **exactly at** the watermark is taken on a keyed table (the
  catch-up is inclusive there, with a key anti-join against the destination so the copied row already at
  that value is not duplicated); on a keyless table it is detected by the same check rather than taken.
  That append-only tail is pre-drained online before the lock too
  (`from_hypertable_drain_appends`, run automatically by the cutover).

  **Whenever the table has a primary key or unique constraint, pass `p_track_changes => true`.** The
  append-only path is the unsafe one for a real workload, and tracking costs one row trigger and one small
  delta table for the duration of the window. The default is unchanged for now.

  When `true`, the copy installs an
  `AFTER INSERT/UPDATE/DELETE` row trigger on the source that logs the
  touched key values (plus a monotonic `pgpm_seq` ordering column) to a `<rel>_pgpm_delta` table. That
  backlog is reconciled **online, in micro-batches, before the cutover** (`from_hypertable_drain_delta`, run
  automatically by the cutover), and the cutover applies only the residual under the lock. Reconciliation is
  by the key `transmute` reuses (a primary key or unique constraint), so `p_track_changes => true` is
  **refused on a keyless table** (no key to reconcile by) and on a key with a **nullable (non-control)
  column** (a `NULL` key component can never be reconciled, so the change would be lost). Set it for any
  workload that updates or deletes rows, or can append out of order, during the migration window.

  **The capture trigger does not fire under `session_replication_role = replica`.** The core's own
  triggers are enabled `ALWAYS` for that reason, but TimescaleDB refuses `ENABLE ALWAYS` on a hypertable
  and on each of its chunks, so a write applied by a logical-replication apply worker, or by a loader
  running as `replica` to silence triggers, never reaches the delta. It is not lost silently: the copy
  records on the delta table the transaction horizon of a snapshot taken before any chunk is read, and
  the cutover refuses the swap if any source row written since then is missing from the reconciled
  destination or differs from it there (see `from_hypertable_cutover`). Pause replica-role writers for the
  window, or run them as `origin`, and the migration goes through.

### `from_hypertable_drain_delta` / `from_hypertable_drain_delta_step`

```sql
pgpm.from_hypertable_drain_delta(
  p_hypertable regclass, p_control name, p_batch int default 5000,
  p_threshold bigint default 0, p_max_iter int default 1000000, p_best_effort boolean default false
)
pgpm.from_hypertable_drain_delta_step(p_hypertable regclass, p_control name, p_batch int default 5000)
  returns bigint
```

Reconcile the `p_track_changes` delta **online, while the source stays live**, so the cutover's lock applies
only a tiny residual instead of the whole online-copy backlog. The cutover runs this
automatically (`p_predrain`), but you can also drive it directly during a long two-phase window: after
`from_hypertable_copy`, call it repeatedly while the application keeps writing, then `from_hypertable_cutover`.

The reconcile is idempotent and order-independent per key (delete the key's copied row from the destination,
re-insert its current source row), which is what makes incremental draining safe. Each batch
**delete-RETURNS** its rows from the delta as the authority and reconciles exactly those keys against the live
source, so a change is never deleted-without-applying; the source read is bounded per batch to the touched
control range for chunk exclusion. The driver **commits per batch** (so WAL recycles); `_step` does one
batch (no commit, returns the keys it cleared). No throwaway index is built or dropped for it: the
per-batch delete uses the key index the cutover later adopts.

- `p_batch` -- micro-batch size (delta rows processed per batch, bounded by a `pgpm_seq` watermark).
- `p_threshold` -- stop once the residual is at/below this many delta rows (`0` = drain to empty). Under
  sustained write load, stop a little short and let the under-lock cutover pass finish the rest.
- `p_max_iter` -- convergence budget. If the workload dirties keys faster than the drain clears them, the
  driver raises a loud, actionable error -- unless `p_best_effort`, in which case it returns so the caller
  (the cutover) can take the lock and finish the residual under it.

### `from_hypertable_drain_appends` / `from_hypertable_drain_appends_step`

```sql
pgpm.from_hypertable_drain_appends(
  p_hypertable regclass, p_control name, p_batch int default 5000,
  p_threshold bigint default 0, p_max_iter int default 1000000, p_best_effort boolean default false
)
pgpm.from_hypertable_drain_appends_step(p_hypertable regclass, p_control name, p_batch int, p_watermark text)
  returns text
```

The **append-only** counterpart of `from_hypertable_drain_delta`, for the default
(non-`p_track_changes`) path: copy the rows appended past the copy watermark **online, while the source stays
live**, so the cutover's lock applies only the final tail. The cutover runs it automatically (`p_predrain`)
for the non-tracking path; you can also drive it directly during a long two-phase window.

It is purely additive (append-only means already-copied rows never change), so unlike the delta drain it
needs no delta, no reconcile, no key, and no destination index, and works on a **keyless** hypertable. Each
batch copies the rows in `(watermark, hi]` where `hi` is the control value `p_batch` rows past the watermark
(inclusive of ties at `hi`, so the next batch's strict `>` skips none), as literal bounds for chunk exclusion;
it then advances the watermark to `hi`. The driver carries the watermark across batches (read once up front,
never re-scanning the destination for `max()`) and **commits per batch**; `_step` does one batch (no commit,
returns the advanced watermark). `p_threshold`, `p_max_iter`, and `p_best_effort` behave as in
`from_hypertable_drain_delta`. When nothing was copied (the hypertable was empty at `from_hypertable_copy`)
the watermark is `NULL` and every source row is past it; `_step` reads a `NULL` `p_watermark` the same way,
so its first batch starts at the source's first row. Assumes the append-only contract (no updates or deletes to copied rows, and
appends arriving in control order), exactly as the under-lock catch-up does. A row that arrives behind the
watermark is invisible to both; the cutover's conservation check refuses the swap rather than lose it. Use
`p_track_changes` for update/delete workloads and for any workload that can append out of order.

### `from_hypertable_cutover`

```sql
pgpm.from_hypertable_cutover(
  p_hypertable regclass, p_control name, p_interval interval,
  p_obtain int default 30, p_retain interval default null,
  p_drain_batch int default 5000, p_anchor timestamptz default '2000-01-01 00:00:00+00',
  p_paused boolean default true, p_predrain boolean default true,
  p_lock_timeout text default '5s', p_force_frontier boolean default false
)
```

Phase 2: the cutover. It cuts over only the copy `from_hypertable_copy` recorded for this hypertable in
[`pgpm.scratch`](#pgpmscratch), and takes change tracking from the delta recorded there, never from a relation
that merely carries the name `<rel>_pgpm_dest` or `<rel>_pgpm_delta`: with no copy recorded it refuses
(`found no copy to cut over`), and so do the drains. A copy made by pgpm 0.6.0 or earlier carries no record;
drop it and re-run `from_hypertable_copy`. The swap drops the recorded delta and capture function and
removes the records, the copy being the migrated table by then. When `p_predrain` is `true` (the default), it first **pre-drains the catch-up backlog
online** (best-effort, using `p_drain_batch` as the batch size and residual threshold) -- the change delta
(`from_hypertable_drain_delta`) when tracking is on, else the appended-rows tail
(`from_hypertable_drain_appends`) -- so only a tiny residual is left for the lock. Then it **pre-builds the
destination's primary key and secondary indexes online** (on the private copy, before any lock -- this is the
O(rows) work, deliberately kept out of the blocking window). Each is built from the source index's own
definition under `<index>_pgpm_new`, or `pgpm_new_<index oid>` when that name would exceed 63 bytes (pgpm
never cuts it) or, for a key, is held by something not on this destination (an abandoned tracking copy taken
under the table's old name), so index and table names holding spaces or other quoted characters migrate as they are. A key
index the tracking copy already built on the destination, under either name, is adopted rather than rebuilt. For the append-only path the catch-up watermark
(`max(control)` on the destination) is also read here, before the lock, so an `O(rows)` `max()` seqscan on a
keyless destination is not in the blocking window.
Then it takes the **`ACCESS EXCLUSIVE` window**: catch up the writes that arrived during
the copy (append-only, or a full delta replay when `from_hypertable_copy` ran with `p_track_changes => true`
-- auto-detected via the delta table, so the two phases cannot disagree), **verify that the source and the
destination hold the same number of rows** (below), drop the hypertable, rename the copy
into place, **adopt** the pre-built unique indexes as the original `PRIMARY KEY`/`UNIQUE` constraints
(`ALTER TABLE ... USING INDEX`, metadata-only) and rename the secondary indexes back to their original names,
re-add the identity columns (which `CREATE TABLE LIKE` does not carry) in the kind they had on the source
(`ALWAYS` or `BY DEFAULT`) and with their sequences' options (`INCREMENT BY`, `MINVALUE`/`MAXVALUE`,
`START WITH`, `CACHE`, `CYCLE`), put back what `CREATE TABLE LIKE` left off the copy (the owner, the table
and column grants, row-level security and its policies, the table's comment and its triggers, read off the
source under the lock just before it is dropped; every trigger of yours is carried, whatever its function is
called, and only this module's own change capture is left out, known by its record and never by its
function's name; the copy is born with the migrating role's
`ALTER DEFAULT PRIVILEGES`, so its ACL is reset before the source's grants are replayed and it holds exactly
those), then hand off to `transmute`, which carries them onto the parent the same way. A `GRANT` or `REVOKE` takes no lock on the table, so one committed in the instant between that read
and the drop is not carried; make privilege changes before or after the cutover. Because
the index builds happen before the lock, the blocking window is the catch-up, one `count(*)` over the source,
and metadata: the count is the only step in it that reads the whole table, and it is a read, not a rebuild.
It also preserves each identity
sequence's exact position: the re-added identity is set to the source sequence's next value (its last value
plus its own increment, so on the same lattice) inside the swap, so ids the source had already moved past (gaps from rollbacks, caching, or deleted high rows) are not
re-issued, and `transmute` seeds the migrated sequence from it. The swap is one transaction: it
commits whole or rolls back whole, leaving the source intact on any failure in it. Requires `from_hypertable_copy`
to have run (the destination must exist). Parameters past `p_interval` pass through to `transmute`.

**The wait for the lock is bounded.** `p_lock_timeout` (`'5s'` by default, the same default as
`transmute`'s) bounds every lock wait in the swap transaction, the `ACCESS EXCLUSIVE` on the source above
all. A pending `ACCESS EXCLUSIVE` request blocks every later read and write of the table, so an unbounded
wait behind one long reader (an analytics query, `pg_dump`, an idle-in-transaction session) would take the
production table offline for as long as that reader ran. When the timeout expires the cutover fails with
`canceling statement due to lock timeout` and the swap rolls back whole: the source is still a hypertable,
the copy and any drained batches are intact, and re-running the cutover costs only the index pre-builds.
Retry when the reader has finished, or raise the value if a longer queue is acceptable. The same value is
passed to the handoff's `transmute`. A bad value is refused before the pre-drain does any work.

**The monolith's name is checked before anything changes.** `transmute` names the monolith
`<rel>_p<lo>_to_<hi>`, which on a fine grid can exceed PostgreSQL's 63-byte limit for a name this module
otherwise accepts (on a daily grid, a hypertable name of 38 to 48 bytes). The cutover, and `from_hypertable`
before its copy, ask for that name first and refuse with `pg_partition_magician: cannot migrate hypertable
... with p_interval ... -- refused before anything is changed, ...`, naming the name and its length. Pass a
coarser `p_interval`, whose partition names are shorter, or shorten the table name. The check takes the
longer two-label form, so a table whose rows all fall in one step can be refused on a grid `transmute`
would have accepted for it.

**A bare unique key and a far-future row are refused before the swap.** `transmute` reuses a primary key or
a unique constraint as the key, never a bare `UNIQUE INDEX`, and refuses a table whose newest row is further
ahead of `now()` than one step plus one hour unless `p_force_frontier` (see `transmute`). Both are visible on
the hypertable, so both are asked before it is dropped, with `transmute`'s own rule, and refused with
`pg_partition_magician: cannot migrate hypertable ... -- refused before anything is changed, ...`: the key
by `from_hypertable_preflight` (so by `from_hypertable` and `from_hypertable_copy` before the copy), the
frontier by `from_hypertable` before the copy, and both by the cutover under its lock, so a row or an index
that arrived while it prepared is seen too. A refused cutover rolls back whole, though a pre-drain's batches
stay in the copy. For the key, build the unique constraint and drop the bare index (the message gives both
statements); for the frontier, correct the rows, or pass `p_force_frontier => true` to accept the farther
monolith bound, which is skipped here and passed to `transmute`.

**The handoff runs after the swap has committed, and can still refuse.** `transmute` applies its own
preconditions to the plain table (for example, a secondary index whose name leaves no room for the `_pgpm`
suffix of its partitioned copy). The cutover then errors with the swap in place: the table under its
original name is an ordinary table holding every row, not a hypertable and not yet partitioned. Nothing the
swap did is lost. Its identity already continues from the source sequence's position, and every incoming
foreign key it dropped is recorded in `pgpm.dropped_fk` (and logged `drop_incoming_fk`) against that table.
Fix what `transmute`'s message names and call `pgpm.transmute` on the table yourself. Its cutover moves those records onto the new
parent, so [`restore_incoming_fks`](#restore_incoming_fks) re-adds the keys, on the next maintenance tick or
when called directly.

**The cutover refuses to swap unless the two sides hold the same rows.** Before anything is dropped, and still
under the lock (so both sides are exact), it compares the source with the destination after the catch-up by
row count and by a content fingerprint of every row (a sum of 64-bit hashes of each row's text over the
columns the copy moves), so changes that cancel in a count (a copied row deleted and a late row appended, or
an update of a copied row) are refused too. When the counts differ it raises `pg_partition_magician:
from_hypertable_cutover(...) refusing to swap: the source holds N rows but the destination would hold M ...`,
naming both counts and the difference; when only the rows differ, `... refusing to swap: the source and the
destination would both hold N rows after the ... catch-up, but not the same rows ...`. Either way the whole
cutover rolls back: the source is untouched and still a hypertable, the destination copy is intact, and
nothing was handed to `transmute`. On the append-only path the cause is rows that arrived during
the online window with a control value at or below the copy watermark (out-of-order appends, a backfill, or
an update or delete of a copied row). Those rows are below the watermark, so **re-running the cutover cannot
find them**: re-run `from_hypertable_copy` with `p_track_changes => true` (it drops and rebuilds the
destination), or, on a keyless table, pause writes to the source for the duration of the copy. On the
tracking path a mismatch means a write reached the source without firing the capture trigger
(`session_replication_role = replica`, or the trigger disabled); fix the writer and re-run the copy with
tracking. The source's read runs under the lock and is proportional to the table's size (a row rendering and
a hash per row, on top of the count); the destination's side is taken before the lock and adjusted by exactly
the rows the catch-up changed, so it adds nothing there.

**On the tracking path the cutover also refuses a write the trigger missed that changes no count.** An
`UPDATE` under `session_replication_role = replica` leaves both counts equal, and the swap used to install
the copy's stale row over it. The same scan that counts the source now also reads each row version's
`xmin`: one older than the horizon `from_hypertable_copy` recorded was committed before every chunk was
copied, so the copy holds it as it is, and every other one must sit in the reconciled destination exactly
as it sits in the source (probed through the key index the copy built). If any does not, the cutover
raises `pg_partition_magician: from_hypertable_cutover(...) refusing to swap: N source row(s) changed
during the online window without firing the change-capture trigger ... (first key ...)` and rolls back
whole, with the source untouched. The probes are proportional to the rows written during the window, not
to the table. A delta built by an earlier release carries no horizon, and the cutover then verifies every
source row. On a chunk compressed before the copy, only the rows written to it since are probed, and a
chunk compressed during the window is verified in full.

**The cutover refuses a copy whose shape is no longer the source's.** `from_hypertable_copy` fixed the
destination's columns, defaults, `CHECK` constraints and outgoing foreign keys when it ran, so a schema
change to the hypertable since (a column dropped or added, a default changed, a `CHECK` or a foreign key
added or dropped) would be reverted by the swap. The
cutover compares the two before the pre-drain and again under its lock (the source is unlocked until then, so
DDL can land while it prepares): the set of columns, each column's type, `NOT NULL`, collation and default or
generation expression, the `CHECK` constraints by name and definition, the outgoing foreign keys by name and
definition (a key the copy holds `NOT VALID` differs from the source's validated one), and the column order.
Identity, keys
and indexes are not compared, because the cutover rebuilds them from the source under the lock. On any
difference it raises `pg_partition_magician: from_hypertable_cutover(...) refusing to swap: the copy ...
no longer has the source's shape: ...`, naming every difference (for example `column v has default
'new'::text on the source but default 'old'::text on the copy`), and rolls back whole: the source is
untouched and still a hypertable. Re-run `from_hypertable_copy`, which rebuilds the copy in the source's
current shape, then the cutover.

**Do not rename or replace either side of the swap while the cutover is preparing.** The source's name is
resolved once at the start, and the index pre-builds above are deliberately outside the lock, so that is the
longest stretch in which the name can stop meaning what it meant -- and `LOCK TABLE` freezes whatever a name
means *at lock time*. The cutover therefore locks the source **by oid** and then requires the name to still
resolve back to it, and does the same for the destination against the oid its own existence check found,
locking that too. Either mismatch **aborts** the cutover with an error naming both oids: there is no partial
progress to preserve (the swap is one transaction, and the copy and any drained batches survive), and
adapting to the new name would silently migrate a table the operator did not ask for. Re-run the cutover once
the name is settled. A destination substituted *before* the cutover was called is out of reach of this check,
since nothing in the module records what `from_hypertable_copy` built.

```sql
call pgpm.from_hypertable_copy('public.metrics', 'ts', p_track_changes => true);
-- ... the application keeps writing (inserts, updates, deletes) ...
call pgpm.from_hypertable_cutover('public.metrics', 'ts', interval '1 day', p_paused => false);
```

### `from_hypertable_preflight`

```sql
pgpm.from_hypertable_preflight(p_hypertable regclass, p_control name) returns void
```

The refusal gate, factored out so you can dry-run it inside a transaction. Raises a
`pg_partition_magician:`-prefixed error when the hypertable cannot be migrated by this version, and returns
normally otherwise. **Refuses** when: the `timescaledb` extension is absent; `p_hypertable` is not a
hypertable; a **working name** the migration derives from the table's (`<rel>_pgpm_dest`, `<rel>_pgpm_delta`,
`<rel>_pgpm_delta_fn`, `<rel>_pgpm_delta_trg`) would exceed PostgreSQL's 63-byte identifier limit, which pgpm
never truncates (a hypertable name of at most 48 bytes fits; the message names the longest name and how many
bytes to shorten the table name by, and the cutover and both online drains refuse the same way before any DDL,
since a cut name could name another relation: from 55 bytes the destination and the delta cut to one); it has
one or more **continuous aggregates** (no native-partition equivalent, and dropping them is
data-destructive); it has more than one **dimension** (space partitioning); the `p_control` column does not
exist; `p_control` is **not the time dimension** column (the copy is bounded chunk by chunk on the dimension's
ranges, so on any other column it would silently lose rows; the message names the actual dimension); the
dimension is **integer-time** (`smallint`, `integer` or `bigint`: only `timestamptz`, `timestamp` and `date`
dimensions are supported, because an integer dimension's chunk ranges are not in the column the copy reads,
so it would copy nothing); it has an **exclusion constraint** (`EXCLUDE`: nothing in the migration carries one,
and PostgreSQL before 17 allows none on a partitioned table, so the migrated table would silently accept the
rows it rejects; the message names every one); an **incoming** foreign key is `NOT VALID`, or, on PostgreSQL
18, a foreign key either way is `NOT ENFORCED` (the gate `transmute` applies, the same function; the swap would
drop the key and the handoff re-add and validate it, promoting a key you left unvalidated, or failing it every
tick over the rows you tolerated); an **outgoing** foreign key is `NOT VALID`; or an **incoming**
foreign key references anything other than the key pgpm will reuse. On success it raises a `NOTICE` estimating the
transient extra disk the migration needs (see `from_hypertable_disk_estimate`) and a rough copy-time ETA (see
`from_hypertable_time_estimate`). Both `from_hypertable_copy` and `from_hypertable` call it first, and
`from_hypertable_cutover` repeats the two dimension checks and the exclusion-constraint check in its own
right, since a destination left by an earlier copy is enough to reach the cutover's drop without preflight
having run. It asks the exclusion-constraint check twice, before the pre-drain and again under its lock, so a
constraint added while it prepares is refused too, with the source untouched, and it asks the foreign-key gate
under its lock, so a `NOT VALID` incoming key added after the copy is refused before the swap.

#### Foreign keys

Both directions are carried across the migration. An outgoing key added to or dropped from the hypertable
between `from_hypertable_copy` and the cutover is refused by the cutover's shape check (above): re-run the
copy, which carries the keys the source has then.

An **outgoing** key (the migrated table referencing another table) is replayed verbatim on the private copy
during `from_hypertable_copy` as `NOT VALID`, validated there in its own transaction, and re-added at the new
parent after the handoff. Validating on the copy keeps the `O(rows)` scan off the cutover's lock, and because
the copy becomes the monolith child with an already-validated key, the parent-level add is metadata-only.
Logged `from_hypertable_carry_fk`, once per key, by the copy; the parent-level re-add is a step of the
`transmute` the handoff runs, and writes no log row of its own.

An **incoming** key (another table referencing the migrated one) is captured, dropped and recorded in
`pgpm.dropped_fk` in the cutover's swap transaction, since the source hypertable cannot be dropped while one
points at it, then re-added against the new parent after the handoff. The record is written against the
plain table the swap puts in place (the parent does not exist yet), and `transmute`'s cutover moves every
record naming the table it converts onto the new parent, so
[`restore_incoming_fks`](#restore_incoming_fks) and [`validate_incoming_fks`](#validate_incoming_fks) do the
re-add and the validation with their usual reporting. Referential integrity is therefore **off on the
referencing table** from the cutover's drop until that re-add, a window bounded by the swap plus one
`transmute` and surfaced by `status().fks_suspended`. It cannot be closed by re-adding inside the cutover,
because `transmute` refuses a table that still carries an incoming key. Each drop is logged
`drop_incoming_fk` by the swap, against the plain table it put in place: after a completed conversion that
relation is the monolith child, so look for the row there, beside the parent's `restore_incoming_fk`.

The re-add and the validation wait for their locks under `p_lock_timeout`, like every other lock wait in
the cutover. A key whose referencing table's lock is not had in time is logged `fail_restore_incoming_fk`
or `fail_validate_incoming_fk`, its `method` naming the key and the lock timeout, and stays recorded; the
cutover itself completes, and `maintain` finishes the key on a later tick (on a paused table, call
`restore_incoming_fks` or `validate_incoming_fks` yourself).

`from_hypertable_preflight` refuses an incoming key that references anything other than the key pgpm will
reuse, before any copying happens.

### `from_hypertable_disk_estimate`

```sql
pgpm.from_hypertable_disk_estimate(p_hypertable regclass) returns bigint
```

The approximate extra disk the online migration needs: the source hypertable's current on-disk size (heap,
indexes, and toast summed across all chunks) in bytes. The copy writes a full second table, so free roughly
this much until cutover drops the old hypertable and the space is reclaimed. `preflight` reports it as a
`NOTICE`; call this directly (with `pg_size_pretty`) to size a volume before starting.

### `from_hypertable_time_estimate`

```sql
pgpm.from_hypertable_time_estimate(p_hypertable regclass, p_copy_mibps numeric default null) returns interval
```

A **rough** estimate of the online-copy duration, the dominant cost of migrating a hypertable. (Converting a
plain table with `transmute` is metadata-only and takes seconds regardless of size; a hypertable's rows must
be physically copied out, which is O(rows).) It divides `from_hypertable_disk_estimate` by an assumed
effective copy throughput. `p_copy_mibps` overrides that throughput (MiB/s of logical data); when `null` it is
chosen by comparing the estimated size to `effective_cache_size` (cache-resident vs disk-bound). The default
rates (~40 MiB/s cache-resident, ~16 MiB/s disk-bound) are order-of-magnitude figures measured on a 2XL on
gp3 and scale with RAM/IOPS/throughput. It covers **only the copy**; the (online) index build and the brief
cutover are additional. `preflight` reports it as a `NOTICE`.

### Performance: how long, and how to speed it up

The migration time is dominated by two O(rows) but **online** (non-blocking) phases, the chunk-by-chunk copy and
the index pre-build, plus a brief metadata cutover. To go faster (with the limits):

- **More RAM** is the single biggest lever when the working set is near RAM size: a cache-resident copy runs
  several times faster than a disk-bound one (measured ~2.5x). Many times past RAM you are firmly I/O-bound
  and RAM stops helping.
- **More disk IOPS / throughput** (gp3 to io2, higher MiB/s): the copy reads the source chunks and writes the
  destination (~2x the bytes over the disk), so disk throughput caps the disk-bound rate, bounded by the
  instance's sustained-throughput ceiling.
- **Raise `max_wal_size`** for the migration. The copy and index build are write-heavy, and on a stock
  `max_wal_size` they outrun it and force checkpoints that throttle progress (at-scale runs showed dozens of
  forced checkpoints and long checkpoint write times). A larger `max_wal_size` (and `checkpoint_timeout`)
  removes that stall.
- **`maintenance_work_mem`** and **`max_parallel_maintenance_workers`** speed the index pre-build.

Hard floors: every byte is read and written once (the copy); the migration transiently needs roughly 2x the
source size in disk until cutover drops the old hypertable; and the cutover's metadata window cannot go below
the delta catch-up.

## Maintenance steps

`maintain` orchestrates these; you can also call them by hand.

**Row-level security.** Every step reads user rows as the **caller**, and `transmute` leaves the original
table (the monolith) its own `ENABLE` / `FORCE ROW LEVEL SECURITY` and policies, and carries them onto the
parent. So for a caller whose reads row-level security would filter (`row_security_active()` is true: a
non-superuser owner without `BYPASSRLS` on a table with `FORCE ROW LEVEL SECURITY`, or a caller that is not
the owner), each read is refused, with the relation it reads named, before anything is written: the write
frontier read through the parent on an `id`, `uuidv7` or `text_time` grid (`obtain`, `extend_to`,
`progress`, and on an `id` grid `retain`, `retire` and `set_retain`), `regrain`'s copy of its source
partition, `untransmute`'s check for rows outside the monolith, the archive step's reads of the parent and
of the partition (before any `archive_fn` runs), `retire`'s read of the tables that reference a retiring
partition and, on every grid, of the parent its crossing `DELETE` reads (a filtered caller would delete only
the referenced rows it can see, and the detach would then be refused by the rest), `incoming_fk_orphans`,
and the sampling checks. Inside `maintain` and `maintain_obtain` each such
refusal is that step's deferral (`skip_obtain`, `skip_write_block`, `skip_archive`, `skip_retain`,
`skip_regrain`, with pgpm's message in `method`), and on an `id` grid `status()` reports `retain_backlog`
as null for that table. Run maintenance as a role with `BYPASSRLS` (a superuser has it); an owner on a table that only
`ENABLE`s row-level security is not filtered.

### `obtain`

```sql
pgpm.obtain(p_parent regclass) returns int
```

Creates empty partitions ahead of the frontier so live writes always land in a real partition, keeping
`config.obtain` of them ready, and returns how many it created. Pure catalog work: the partitions are
created empty, so nothing is scanned and nothing is moved. It skips any candidate range that overlaps an
existing attached partition, for example the monolith, which covers the current interval, and leaves
unbuilt a cell whose name something it does not own already holds, a relation or a type (see
[Partition naming](#partition-naming)), building the cells around it. An attached `pgpm.part` row whose
partition no longer exists (a forward cell dropped by hand with `DROP TABLE`) does not count as built: the
row is forgotten, logged `forget_dropped_partition`, and the cell is built again, empty. `extend_to` does
the same for every cell of its walk.

It stops early, returning what it built, when the next grid boundary cannot be expressed: a `uuidv7` grid
ends at the last instant a 48-bit millisecond prefix can carry, `10889-08-02 05:31:50.65504+00`; a
`text_time` grid ends wherever the declared `p_tt_width` digits at `p_tt_radix` run out (classic cuid's
8 base36 digits reach year 2059); an `id` grid ends at the last boundary the control column's own type can
hold, so on an `int` column with a step of 10000 the last partition is `[2147470000, 2147480000)`, and
ids from 2147480000 to 2147483647 have no partition to go to. Reaching a ceiling is not a failure: no
`skip_obtain` is logged, and every tick keeps building what the grid can still express.

It also stops early when the next partition would take the call past half the server's shared lock table,
`max_locks_per_transaction x (max_connections + max_prepared_transactions)`. One call is one transaction,
and every partition it creates holds its locks (the table, its indexes, its TOAST table) until that
transaction ends; the call measures what its first two partitions cost and builds only as many as fit, a few
hundred on stock settings for a table with a primary key and a TOASTable column. The rest of the lookahead
is left to the next call, which carries on from where this one stopped, so a lookahead larger than that is
reached over several ticks rather than failing on every one. The frontier read's locks on the partitions
that already exist are not counted against this budget. Nothing is logged for the stop either: it is not a
failure, and the cells it built are logged as usual.

This is the only thing standing between the workload and a write with nowhere to go, since a row outside
the grid is refused rather than parked. `config.obtain x partition_step` is therefore both the slack if
maintenance stalls and a ceiling on how far ahead an application may write.

### `extend_to`

```sql
pgpm.extend_to(p_parent regclass, p_value text, p_max int default 10000) returns int
```

Builds every missing partition on the existing grid, from the current forward edge up to and including
the one that would hold `p_value`, and returns how many it created. Manual and explicit, like `obtain`:
`maintain` never calls it. It exists because `obtain`'s lookahead (`config.obtain x partition_step`) is a
hard ceiling now that there is no `DEFAULT`, and an `id` grid's frontier is data-driven and can jump past
it -- a sequence restart, a non-dense Snowflake/ULID generator, a bulk import, a backfill -- with no way to
recover, since the write that would advance the frontier past the ceiling is the write that fails.

`p_value` is in the control column's own representation: a bare id for `id`, a `uuid` literal (as text)
for `uuidv7`, the encoded text id for `text_time`, anything `timestamptz` accepts for `time`. Pass
exactly what you would insert.

It never moves the frontier or touches data, only creates empty partitions, and is idempotent: partitions
that already exist (or overlap an attached one, like the monolith) are left alone. `p_max` bounds how many
NEW partitions one call may create, checked with a dry count before any DDL runs, so a wildly-off
`p_value` is refused loudly and immediately -- creating nothing -- rather than silently stopping `p_max`
partitions short of the value actually asked for. None of the three arguments takes a null: a null
`p_max` is not "no cap", and a null `p_value` names no cell, so either (or a null `p_parent`) is refused
before anything is read, the message naming it. The count includes the forward edge's own cell when
nothing attached covers it (on a fine `time` grid with a short lookahead, the cell `now()` has moved
into since the last `obtain`), because the call builds that cell too. Like `obtain`, it stops (here, raises) if the next grid
boundary cannot be expressed (the `uuidv7`/`text_time` ceilings described above).

It is a function, so every partition one call creates is created in one transaction and holds its locks
(the table, its indexes, its TOAST table) until that transaction ends, in the lock table every session
shares. So the call is also bounded by that table: once it has created two partitions it measures what one
costs and refuses, creating nothing, if its partitions would hold more than half of
`max_locks_per_transaction x (max_connections + max_prepared_transactions)`. The message gives the
measured cost and about how many partitions one call can create; extend in steps of at most that many,
each call in its own transaction, or raise `max_locks_per_transaction`. On stock settings (64 x 100) that
is a few hundred partitions a call for a table with a primary key, fewer for a table with more indexes.

### `retain`

```sql
pgpm.retain(p_parent regclass) returns int
```

Drops every partition whose whole range is older than the retention horizon (`config.retain`), returning
the count dropped. A coarse partition that merely *straddles* the horizon is **not** dropped, since it
still holds within-horizon data, so its aged span is not reclaimed for as long as it straddles.

A coarse child is **not exempt from retention, only all-or-nothing about it**: once its whole range is
past the horizon it drops like any other partition, in one step, even while a `regrain` is splitting it
(see [`retire`](#retire) for what becomes of that regrain). What `regrain` changes is the
*granularity* of that reclamation, not whether it happens -- split into fine children, each drops on its
own schedule, so storage falls gradually rather than in one cliff (and `regrain` reclaims below-horizon
sub-ranges directly rather than materializing partitions only to drop them). `null` retention drops
nothing.

`config.retain_batch` caps how many eligible partitions one call will **attempt** (write-block ensure,
archive-coverage check, drop), oldest first; the rest of the backlog waits for later calls -- on the
scheduled path, later `maintain` ticks, each its own transaction. `null` (the default) is unbounded. The
cap bounds attempts, not successes: an unexpected drop failure at the head of the backlog defers
everything behind it until it clears (the wedge shows as a flat `status().retain_backlog` with climbing
`retain_drop_failures`). A child whose chunked archiving simply hasn't caught up yet is *not* a wedge --
`retain_drop_failures` stays at zero for that; see [`retire`](#retire).

`retain()` is a loop over [`retire`](#retire): it picks the eligible set and `retire` carries the
per-partition protocol. Every eligible partition is write-blocked before it is dropped, and the block
holds for a session running as `session_replication_role = replica` too (see [`retire`](#retire)).

Each partition's `retire` runs in its own subtransaction. Where `retire` would raise for one partition (a
lock timeout installing its write block, say, while a `VACUUM` or `ANALYZE` of that partition holds `SHARE
UPDATE EXCLUSIVE` on it), `retain` logs `skip_retain` over that partition's `lo` and `hi` with the message in
`method`, counts it against `retain_batch` as an attempt, and goes on: the partitions dropped before and after
it in the same call stay dropped, and the next call takes the deferred one again. A `skip_retain` row with no
range is the whole step deferred (inside `maintain`, a raise outside the loop, such as the frontier read).
A direct call of `retire` still raises.

### `retire`

```sql
pgpm.retire(p_parent regclass, p_child name) returns boolean
```

The sanctioned single-partition drop: `retain()`'s per-partition body, public and claim-guarded, for an
external assistant (e.g. an archive-then-drop scanner) -- or several cooperating ones -- to drive
retirement directly. It claims the `pgpm.part` row, ensures the child is write-blocked
(`pgpm._install_write_block`, idempotent), checks `pgpm._archive_fully_covered`, and only then `DROP`s, deletes the catalog row, and logs `retain_drop`. Returns `true`
iff this call dropped the partition.

The write block is a trigger on the child, enabled `ALWAYS`, so it fires regardless of
`session_replication_role`: a logical-replication apply worker, or a loader running as `replica` to
silence triggers, is refused exactly as an ordinary session is. A block an older pgpm installed in the
origin-only state is brought up to `ALWAYS` by the first `maintain` tick after `install.sql` is re-run.
Only a block enabled `ALWAYS` counts as a write block: one in any other state (origin-only, or disabled
by hand) is treated as no block at all, so the coverage recorded under it is discarded as described
below, and the archive step does not archive the partition until the block is `ALWAYS`.

`retire` never widens what retention may drop -- a caller only picks **which** eligible partition and
**when**. It refuses (raises) an unmanaged table, a table with no retention policy (`config.retain` is
null), a partition whose range is not entirely at/below the retention horizon, and an in-flight
(unattached) regrain copy-child.

It returns `false`, without side effects and without logging anything, in three normal, retryable
situations: the `pgpm.part` row is absent (already retired by another actor), it's claimed by a
concurrent transaction (each partition has exactly one owner at a time), or the partition is
write-blocked but not yet `pgpm._archive_fully_covered` -- chunked archiving simply hasn't caught up yet.
Only a genuinely unexpected failure in the `DROP` itself is logged (`fail_retain_drop`) and returns
`false`.

A partition that is no longer attached to the parent but carries no `retiring_at` was detached by
something other than pgpm (an operator's own `DETACH PARTITION`, to keep the table or to archive it by
hand), and `retire` leaves it alone, whether or not anything references the parent: it returns `false`,
logs `fail_retain_drop` for the partition's range with `method` saying why, and neither write-blocks nor
drops the table. Its `pgpm.part` row stays, so every later `retain` refuses and logs it again and
`status().retain_drop_failures` counts it. To end that, attach the table back to the parent or delete its
`pgpm.part` row. A partition pgpm's own retirement detached carries `retiring_at` and is dropped as usual
(see below).

Coverage `retire` finds on a partition with **no** write block in force on it (a trigger removed or
disabled by hand, lifted by a pgpm older than the rule [`maintain`](#maintain) applies, or left
origin-only by a pgpm older than the `ALWAYS` rule) is discarded before `retire` puts the block
back, exactly as a `maintain` tick would discard it, and logged as `archive_coverage_reset` with the
number of chunks that went. The call then returns `false` with the partition untouched, because the
coverage it would have trusted was recorded while nothing stopped a write landing in the partition, and a
row written then was never handed to the archive strategy. Archiving starts over from the partition's
`lo` under the restored block, and a later `retire` drops it once that coverage is complete. `maintain`
is not a precondition: a direct caller gets the same answer whether or not a tick ran first.

If the partition it drops is the coarse **source of an in-flight regrain**, `retire` takes that regrain's
state with it, in the same transaction as the `DROP`: the not-yet-attached fine copies inside the
partition's range (their tables and their `pgpm.part` rows), the captured changes in the delta when the
partition carries the capture trigger, and `config.regrain_cursor`. It logs one `regrain_cancel` row for
the partition's range ahead of the `retain_drop`, with `rows` counting the copies discarded and `method`
saying that `retire` did it. This is the one-step drop the [`retain`](#retain) contract promises a
wholly-aged coarse child, applied while a regrain happens to be splitting it: every fine child that
regrain could still produce would be retire-eligible the moment it attached, so the regrain has nothing
left to win, and the copies hold nothing the archive does not (the drop is gated on full coverage as
always). A regrain in flight on a **different** child of the same parent is untouched, and a `retire`
that returns `false` reclaims nothing. Without this the copies, the cursor and the delta outlived their
source with no tick able to reclaim them: auto-regrain reports `none` once no coarse child remains, and
the capture sweep only tears down what the cursor does not cover. The regrain's state is read under the
regrain lock every regrain driver takes, so `retire` waits for a step in flight on the same table instead
of reading around it (and leaving behind what that step commits): in a maintenance tick the wait is bounded
by the tick's `lock_timeout`, and one that runs out is logged `fail_retain_drop` and retried next tick.

#### Retiring a partition an incoming FK references

If any foreign key references the managed parent, the partition cannot be dropped in one step, whether or
not any row actually references the aged range: `retire` detaches it first, and the detach runs in the
standing `pgpm_detach` cron job rather than in `retire` itself. `retire` **dispatches** it, by rewriting
that job's command, and returns `false`; a later call finds the partition detached and completes the
`DROP`. Retiring a referenced partition therefore takes at least two calls and requires
[`pgpm.schedule`](#schedule) to have been run.

The sequence, per partition:

1. If a live row references a doomed one, `DELETE` exactly those keys from the parent, so PostgreSQL
   applies the referential action the operator declared. `CASCADE`, `SET NULL` and `SET DEFAULT` proceed,
   and a `CASCADE` reaches whatever further tables it would reach on any other delete; `NO ACTION` and
   `RESTRICT` refuse, and the refusal is logged `fail_retain_crossing` with the
   constraint's own error, leaving the partition intact. A successful crossing is logged `retain_crossing`.
   The keys are found by comparing each referencing column against the partition's bounds under the control
   column's collation, not the referencing column's own, so a referencing column declared without `COLLATE`
   (the database default, `en_US` say) still finds every key of a mixed-case `text_time` cell.
2. Set `pgpm.part.retiring_at` and `pgpm.part.retiring_oid`, and point `pgpm_detach` at this partition's
   concurrent detach, in one transaction, logged `retain_detach`. With no such job, `fail_retain_detach`
   is logged instead.
3. On a later call, with the partition detached, return the cron job to idle, `DROP` the partition, delete
   the catalog row and log `retain_drop`. If the incoming FK has been dropped in the meantime, before the
   detach ran, the later call finishes the retirement with the one-step `DROP` of the still-attached
   partition instead; it returns the job to idle first too, provided the job still holds this
   partition's detach (another retirement's dispatch is left alone).

`fail_retain_crossing`, `fail_retain_detach` and `fail_retain_identity` all count in
`status().retain_drop_failures`; in-flight detaches show in `status().retain_detaching`. A partition that
is detached but carries no `retiring_at` was detached by something other than pgpm, and `retire` refuses to
drop it, on this path as on the one-step one (see above).

A retirement belongs to the retention policy that started it. If retention stops reaching the partition
before the `DROP` (`set_retain` loosened it, or an `id` table's frontier moved back because its newest
rows were deleted), the retirement is taken back, by `set_retain` itself or by the next tick's `retain()`:

- still attached: the `pgpm_detach` job is returned to idle (only if it still holds this partition's
  command), logged `retain_recall`. `retiring_at` is cleared by a later tick that finds no detach of the
  partition still running, so a detach pg_cron had already started is still recognised as pgpm's own when
  it lands.
- already detached by that detach: the job is returned to idle and the partition is re-attached on its own
  bounds, logged `retain_reattach`, and the `CHECK` constraint the concurrent detach left on it is
  dropped again. A re-attach that fails is logged `fail_retain_reattach`, counts in
  `status().retain_drop_failures`, leaves the table and its rows whole, and is retried on the next tick.

##### What `retire` checks a partition's identity against

The detach reaches pg_cron as text naming the partition, and pg_cron re-resolves that name in a session of
its own, a tick or more later, with no lock held on the partition in between. So if something else takes
the name `schema.child` in that gap, and attaches the new relation to the same parent, the dispatched
detach lands on it. pgpm cannot prevent that. What it does instead is record the partition's OID in
`pgpm.part.retiring_oid` at dispatch, and check it at the top of every later `retire` call, before any
side effect: the name must still resolve, and resolve to that OID. When it does not, `retire` logs
`fail_retain_identity`, returns the standing job to idle, and does nothing else -- no re-dispatch, and in
particular no `DROP`. The detach can still land on a substitute; the destructive half cannot.

`retiring_oid` is set only for a partition being retired through a detach. The ordinary one-step path,
whose bare `DROP TABLE schema.child` has nothing else between it and the write block, is covered by
`pgpm.part.child_oid`, recorded when the partition entered the catalog and so populated for every
partition. `retire` checks both, independently, and a disagreement with **either** refuses; the `method`
column names whichever anchor disagreed, so a stale dispatch and a stale catalog row are distinguishable.

The name is resolved in the partition's **own** schema, the schema of the relation `child_oid` records,
not in the parent's. `ALTER TABLE <parent> SET SCHEMA` moves only the parent: the partitions it already
has stay where they were, and the ones pgpm creates afterwards go in the parent's new schema. The
write-block step, the archive step, `retire` and the recall of a retirement retention no longer reaches
all resolve a partition this way, so a table moved to another schema keeps being write-blocked, archived
and retired, and a loosening still takes back a retirement under way. Only the schema comes from the recorded
relation, never the relation itself, so a different relation holding the name in that schema is still
refused as above. A row with a null `child_oid` takes the schema of the attached partition of that parent
carrying the name, and a row whose relation is gone takes the parent's.

That refusal is permanent, not retryable: no later tick makes the name mean the right object again. On the
detach path it shows up as `retain_detaching` stuck non-zero with `retain_drop_failures` climbing; on the
one-step path as `retain_backlog` flat with the same count climbing. Recovery is an operator decision --
put the intended relation back under that name, or delete the `pgpm.part` row if it is gone for good. A
null anchor is not consulted at all: `retiring_oid` is null for every partition on the one-step path and
for a retirement already in flight when the column was added, and `child_oid` is null for a row whose name
no longer resolved when the backfill ran. Both read as unanchored and behave as they did before.

### `_detach_reap`

```sql
pgpm._detach_reap() returns int
```

Finishes any concurrent detach whose session died part-way, and returns how many it finished.
`maintain_all` calls it before the per-parent loop, alongside `_transmute_reap`, because it is the most
urgent thing in a tick: a backend killed during a concurrent detach's *wait* phase leaves the partition
half-detached, with its rows **already invisible through the parent**, so rows appear to vanish from the
table while the partition is neither detached nor dropped. `ALTER TABLE ...
DETACH PARTITION ... FINALIZE` completes it, logged `detach_reap`.

It finalizes only an **abandoned** detach, never a live one. A concurrent detach spends its whole wait
phase looking exactly like an abandoned one in the catalog (the partition flagged pending detach, its rows
already invisible), for as long as the longest transaction holding a lock on the parent, and `maintain_all`
runs on the same cadence as the `pgpm_detach` job, so it routinely meets one in that state. A pending
partition is left alone while any other session is still running its detach: one holding or waiting for a
lock on the partition itself, one parked waiting for a transaction that has the parent locked, or one whose
current statement is a `DETACH PARTITION ... CONCURRENTLY` naming the partition. The first two are read
from `pg_locks`, which every role can see, so a detach run by hand under another role is covered as well.
Nothing is logged for a skipped partition: a detach in progress is the expected state, not a deferral, and
`status().retain_detaching` already counts pgpm's own. The residual failure is deferring a reap by one
tick, never finalizing a detach that is still running.

It drops nothing: `retire` completes pgpm's own retirements on the normal path, and an operator's hand-run
detach that was interrupted is finished and then left alone.

The wait for the partition's lock is bounded at 5 s, `transmute`'s default. `FINALIZE` takes `ACCESS
EXCLUSIVE` on the partition, so behind one long reader of it (a report, a `pg_dump`) an unbounded request
would hold up the whole sweep, and every later access to the partition with it. A timeout leaves that
partition pending, logs `fail_detach_reap` with the lock timeout as its `method`, reaps the others, and the
next tick tries again. The caller's own `lock_timeout` is back when the function returns.

### `regrain`

```sql
pgpm.regrain(p_parent regclass, p_child name, p_target_step text default null) returns int
```

Splits one **frozen** coarse child `p_child` into finer children of width `p_target_step` (default
`config.partition_step`), returning the number of fine children created. It **copies** rows into standalone
children in budget-sized microbatches, then swaps them in for the coarse child and drops that source whole,
rows and all. It never deletes from the source, which is what keeps a read of the parent from ever being
short mid-regrain; the fine children are insert-only, so the product has no bloat. The whole call runs in
one transaction, so it is **atomic and gap-free**. Retention-aware: a sub-range entirely below the horizon
is reclaimed, never materialized. Refuses (as an exception) when the child is not frozen, the target step
does not subdivide it, the target step is zero or negative or has a shape the grid cannot place (the
rules [`set_regrain`](#set_regrain) lists), or another regrain is already in flight on the same parent.
`regrain_step` refuses such a step the same way, before it reads or changes anything.

Only one regrain runs per parent at a time: a second one is refused with an error naming the one in
flight. Let it finish, or stop it with [`regrain_cancel`](#regrain_cancel), then re-run.

**A step at a target the run in flight on that child was not cut on is refused too**, whichever
driver sends it: a hand `regrain_step` or `regrain` at another target on the child an auto-regrain is
splitting, and the `maintain` tick that meets a run started by hand at a step other than `regrain_to` (logged
as `skip_regrain` with the refusal's message). The run's copies belong to the step it was started at, as
[`set_regrain`](#set_regrain) says, and nothing records that step, so it is read off the run: every copy
already made must be exactly a sub-range of the requested step's grid and the cursor one of its boundaries.
The message names the copy (or the cursor) that is off the grid. Drive the run at its own target, or abandon
it with [`regrain_cancel`](#regrain_cancel) and re-run at the new one. The run's own step spelled another way
(`'50'` and `'050'`) is the same grid and is accepted.

**Regrain calls on one parent take turns.** `regrain_step` (and so `regrain`, `regrain_history` and
`maintain`'s auto-regrain), [`regrain_cancel`](#regrain_cancel), [`set_regrain`](#set_regrain) and
[`set_partition_tz`](#set_partition_tz) each take one per-parent lock before they read anything, held until
their transaction ends. A second call on the same parent waits for the first to commit and then acts on
what it left: a hand-driven `regrain_step` beside a `maintain` tick copies the next batch rather than the
same one, and a setter judges a run another session has just prepared. A `maintain` tick waits under its
own `lock_timeout`, so while a long `regrain` holds the lock each tick logs `skip_regrain` and retries.

**Writes wait for the whole call.** Before its first step, `regrain` takes a `SHARE` lock on the parent
(the parent only, not its partitions) and holds it until the call commits. Reads, and foreign-key checks
against the table, carry on as normal. Every `INSERT`, `UPDATE` or `DELETE` through the parent waits
instead, whichever partition it targets, and runs once the call has committed (a write into the regrained
range then lands in the fine children). The
lock is what keeps such a write from deadlocking with the swap: one transaction holds the change-capture
trigger's lock on the source for the whole copy, and a write routed to the source would otherwise hold
its lock on the parent while queuing there, the lock the swap's `DETACH` needs. A long transaction that
already holds a write lock on the table delays the start of `regrain` until it ends. To regrain a table
under live writes, use auto-regrain ([`set_regrain`](#set_regrain)), which commits every tick and takes
no such lock.

A child whose range is exactly one grid step wide carries the plain `_p<lo>` name, which is also what its
own first fine sub-range would be called. Regrain renames such a child to its explicit-range form
(`_p<lo>_to_<hi>`) before splitting it, logged as `regrain_rename`, so the sub-range names are free. The
rename is metadata-only, the child is dropped at the swap anyway, and `pgpm.part` and
`pgpm.archive_ledger` are updated with it (a partly archived source keeps its coverage under the new
name), so the only visible effect is the transitional name. Anything driving a regrain across ticks by hand should
re-read the child name from `pgpm.part` rather than assuming it; `regrain`, `regrain_history` and
auto-regrain all do.

```sql
-- split the monolith into the configured fine granularity, once the frontier has passed it
select pgpm.regrain_history('public.events');
```

### `regrain_step`

```sql
pgpm.regrain_step(p_parent regclass, p_child name, p_target_step text default null, p_batch int default null)
  returns text
```

One resumable microbatch of `regrain`: it **copies** (never deletes) a within-horizon sub-range's next
budget-sized batch into its fine child, and performs the atomic swap once the cursor
(`config.regrain_cursor`) reaches the coarse `hi`. A null `p_target_step` takes the partition step, and a null
`p_batch` takes `config.regrain_batch`.

A **below-horizon** sub-range is handled one of two ways, depending on whether the table archives. With
`config.archive_fn` unset it is skipped, logged as `regrain_aged`, and discarded with the source at the
swap, since `retain` would drop those rows unconditionally the moment they became partitions. With
`archive_fn` set it is **materialized like any other sub-range**, because `retire` will not drop a
partition until archiving has fully covered it, so discarding it would destroy exactly the rows that gate
is protecting. Once materialized, the ordinary pipeline applies: `maintain` write-blocks it,
archives it, and `retire` drops it once covered. The cost is copying rows that are about to be dropped,
which is paid only on tables that archive. A source that was itself **partly archived** when the regrain
ran (its write block on, some chunks in `pgpm.archive_ledger`) has those chunks retired by the swap along
with its `pgpm.part` row, logged as `archive_coverage_reset` with the source's name: the ledger is keyed
`(parent_table, lo)`, so left in place they would collide with the first fine child's own first chunk,
and they describe a relation that no longer exists. The fine children hold every row and archive from
their own `lo` under their own blocks; the objects the source's chunks already wrote stay in the archive,
unreferenced by the ledger. A source whose **whole** range is below the horizon is being
archived and retired in parallel with its regrain, and the two race: if archiving covers it before the
swap, `retire` drops it whole and cancels the regrain, reclaiming its copies (see [`retire`](#retire));
if the swap lands first, the fine children are archived and retired one by one. The
source stays whole and **attached** until that swap, so a read of the parent is never short.

The skip is decided once, as the cursor passes the sub-range, and the swap **re-checks it** against the
retention policy in force at that moment. If a skipped sub-range is no longer entirely below the horizon
(`set_retain` loosened retention, to a longer value or `null`, after the skip), the swap **refuses** with an
error naming the range, because dropping the source would destroy rows the table is now configured to
keep. The refusal locks and changes nothing: the source stays attached, the cursor stays at `hi`, and the
run resumes from there. Set `retain` back and the next tick swaps, or [`regrain_cancel`](#regrain_cancel)
and re-run under the new policy. Through `maintain` the refusal appears as a `skip_regrain` row carrying
the message. A sub-range that already has a fine child is never skipped, even once it ages: its copy is
finished instead, so an attached partition always holds its whole range.

A fine child is only ever copied into, reconciled into or attached when this regrain created it. If a
relation it did not create already bears the name a sub-range's fine child would take (a partition of
another table that once had this table's name, say, since renaming a managed table leaves its partitions'
names as they were), or the name of a copy (in progress or finished) now resolves to a different relation
than the one the regrain created, `regrain_step` refuses with an error naming that relation before a row is
copied, before a captured change is applied, and at the swap before anything is locked or detached.
Nothing has been written to it and nothing is lost: the source stays attached and the captured changes stay
in the delta. Give the copy its name back (rename or drop whatever holds it) and the next tick carries on,
or [`regrain_cancel`](#regrain_cancel) the run. It refuses the same way, before creating anything, when
`pgpm.part` already records the name a new fine child would take for a different range. Through `maintain`
each refusal appears as a `skip_regrain` row carrying the message.

Returns `prepared` (the first tick, which installs change capture and copies nothing), `reconciled:N`,
`copied:N`, `reconciling:N` (the swap is waiting for the captured backlog to clear), `swapped:K` (regrain
complete, K children attached), or a soft no-progress status: `active` (not frozen yet) or `nosubdiv`
(the step does not subdivide). This is the unit `maintain` paces across ticks; because it copies, the
cross-tick path opens **no** read gap. Its incoming-FK touch is the swap's `DETACH`, which transiently
drops and re-adds any incoming FK within that single transaction. Outgoing FKs are carried onto each fine
child while it is still empty, so the swap never validates one under its lock.

Committed DML against the source while a regrain is in flight is honoured. A trigger on the source records
changed keys into a per-parent delta table, and a reconcile pass treats the **source** as the authority for
each captured key, so a row inserted, deleted or updated mid-regrain is not lost, resurrected or reverted
by the swap. The trigger is enabled `ALWAYS`, so DML applied with `session_replication_role = replica` (a
logical-replication subscriber's apply worker, a loader silencing triggers) is captured like any other.
Capture counts only while that holds. A tick that resumes the run and finds the trigger in any other state
(disabled by `ALTER TABLE <partition> DISABLE TRIGGER USER` for a bulk load, or by the same statement on the
parent, which reaches every partition; origin-only after the matching `ENABLE TRIGGER USER`; or origin-only
because the run was prepared by 0.6.0 and was in flight across the upgrade) cannot tell which changes it
missed, so it **restarts** the run: the copies are discarded, capture is re-minted enabled `ALWAYS`, the
cursor goes back to the source's `lo` and `regrain_restart` is logged with `method` naming the state it
found. The swap asks again once its `DETACH` holds the source, and a trigger found in any other state there
fails the tick (a `skip_regrain` row under `maintain`) with the swap rolled back whole, the source still
attached, for the next tick to restart. Only the trigger's current state is visible, so one disabled and
then put back by hand with `ENABLE ALWAYS TRIGGER pgpm_regrain_capture` reads as live although it missed
what was written meanwhile. To silence your own triggers for a bulk load while a regrain is in flight,
name them in `DISABLE TRIGGER` rather than using `USER` or `ALL`, and the run is not restarted at all.
The reconcile is bounded by the same budget as the copy and takes the tick when there is work,
so a burst of DML paces itself rather than landing inside the swap. A pass consumes from the delta exactly
the captured rows it applied, so a change that commits while a pass is running is neither lost nor
consumed early: it stays in the delta for the next pass. If writes outpace it the regrain stalls
at `reconciling:N` rather than swapping: the source stays attached, reads are unaffected, and no unbounded
work is done under the swap's lock.

The delta table and its trigger function live in the parent's schema as `<table>_pgpm_regrain_delta` and
`<table>_pgpm_regrain_capture()`, or, where that name would exceed 63 bytes (a table name over 44 or 42
bytes), as `pgpm_regrain_delta_<oid>` and `pgpm_regrain_capture_<oid>()`, `<oid>` being the parent table's:
pgpm never cuts one to 63 bytes, which for a 63-byte table name would be the table itself. They are named
from the parent when the prepare tick mints them and found
by **oid** from then on (`config.regrain_delta_oid`, `config.regrain_capture_fn_oid`), so renaming the parent
mid-regrain changes nothing: the trigger keeps writing the delta it was given, and the reconcile, the swap
gate and the swap read that same relation, in the schema it is in. The source is likewise the relation
`pgpm.part.child_oid` recorded, in its own schema, so a parent moved by `ALTER TABLE ... SET SCHEMA` before
its regrain begins, or at any point while it runs, regrains as if it had stayed; the
delta is minted in the parent's schema as of the prepare tick. The copies are made beside the source, in its
schema, and each is found again in the schema of the relation its `child_oid` records, so copies made before
the move are filled, checked and attached where they are, and a relation that takes a copy's name in the
parent's new schema is left alone. The copy finds each sub-range's fine child by its bounds in
`pgpm.part`, never by a name rendered from the parent's current name, so the sub-range whose copy was in
progress at the rename resumes into the child it had started (which keeps its pre-rename name), and only
the sub-ranges begun after it are named from the new one. Every prepare tick drops and re-mints the delta from the key as
it is then, so a key column renamed between two regrains is picked up rather than tripping every write into
the source; a relation already holding the name it would mint under, other than the one this parent recorded,
is refused rather than adopted. The trigger runs with the **writer's** privileges (pgpm has no
`SECURITY DEFINER`), so the delta is owned like the parent and every role holding `INSERT`, `UPDATE` or
`DELETE` on the parent, or on the regraining partition itself (which PostgreSQL lets a role write directly
with no grant on the parent), table- or column-level, is granted `INSERT` on it, and so are the **owners** of
the parent and of that partition, whose rights no ACL lists: after `ALTER TABLE <parent> OWNER TO`,
which does not reach the partitions, the old owner still owns the source and writes it directly. Re-synced on
every tick: a role granted, or an owner changed, mid-regrain can write from the next tick on, and nothing
beyond those grants is needed. Beyond those grants and its owner's, the delta holds nothing, from the tick
that creates it: the maintaining role's default privileges are reset, so a role they name cannot read the
captured keys of a table it holds no grant on.

The delta, the capture function and the copies not yet attached **follow the table's owner**. Each tick
gives them the table's owner as it is then, so a table handed to a new owner mid-regrain (`ALTER TABLE ...
OWNER TO` on the table and its partitions) has them handed over by the next tick run as a superuser, or by
a role that is a member of both the old owner and the new. A tick run by a role that can do neither (the
new owner itself, a non-superuser) refuses once, up front, and logs a `skip_regrain` row that leads with the
step to take: see [Handing a table to a new owner](#handing-a-table-to-a-new-owner-hand_over_scratch). The
delta and the function are found by the oids `pgpm.config` recorded; with none recorded (a table that has
never regrained) there is none, so `regrain_cancel`, `untransmute` and `uninstall.sql` leave alone a table or
function of yours named `<rel>_pgpm_regrain_delta` or `<rel>_pgpm_regrain_capture()`. Re-running `install.sql`
(the upgrade) records the pair for a table with none recorded only on proof that pgpm minted it: the capture
function under its name, a trigger function whose body inserts into exactly that delta, and the delta carrying
its `pgpm_seq` identity column. So a table of yours under the delta's name is left unrecorded by an upgrade
too, and the next prepare refuses it, naming it, as on a fresh install.

The swap has the same contract. Whatever is captured between that gate and the moment the `DETACH` takes
its lock is reconciled under the lock until nothing is left, and the source is dropped only once no
captured change in its range remains; if one does, the swap raises rather than drop it, the whole tick rolls
back, the source stays attached with capture still installed, and the next tick reconciles the backlog and
swaps. That residual can be large: a writer that already holds a row in the source keeps the `DETACH`
waiting for as long as its transaction stays open, and everything it commits in that time lands after the
gate. Under `maintain` the `DETACH` gives up after 200 ms (a `skip_regrain` row, retried next tick), which
keeps the residual small; a hand-driven `regrain_step` waits without a timeout, so a large purge committing
during that wait is reconciled under the lock in full.

`TRUNCATE` is the exception, and it is **refused** rather than honoured. It fires no row trigger, so the
rows it removes cannot be captured, and a `TRUNCATE` of the parent never reaches the copies (they are not
partitions until the swap), so the swap would put every truncated row back. While a regrain is in flight, a
`TRUNCATE` of the parent or of the coarse child fails with `pg_partition_magician: cannot TRUNCATE ... a
regrain is in flight on it` before anything is truncated, including from a session with
`session_replication_role = replica`. Cancel the regrain with `regrain_cancel` first, or truncate after the
swap. The refusal holds for a regrain already in flight when you upgrade from a release that did not have
it: re-running `install.sql` puts it on every source still regraining, and each `regrain_step` tick that
resumes a regrain puts it back if it is missing.

`ALTER TABLE` on the parent while a regrain is in flight **restarts** the run rather than wedging it or
attaching stale copies. The copies are standalone tables made `LIKE` the parent when each was created, so a
column added, dropped, retyped or renamed afterwards, a `NOT NULL` set or dropped, a `CHECK` constraint
added or dropped, or an outgoing foreign key added, dropped or redefined, reaches the source but not them,
while the copy, the reconcile and the swap's `ATTACH` all need the parent's current columns and
constraints. Every tick that resumes a run compares each copy's columns (name, type, collation, `NOT
NULL`, generated), `CHECK` constraints (name and expression) and outgoing foreign keys (definition; a
`NOT VALID` key on the parent is not carried, so not compared) with the parent's first. A copy made
before a key was added would otherwise reach the swap without it, and `ATTACH` would validate the key by
scanning the copy under the swap's lock; restarted, every copy is made again carrying the key, validated
while it is empty. It also compares the source with what the run recorded when it began copying
(`config.regrain_source_mark`): an `ALTER` that changes the source's values without changing any column's
name or type, such as `ALTER COLUMN ... TYPE` to the same type with a `USING` expression (which rewrites
every row) or a column dropped and added back under its old name, fires no row trigger, so capture never
sees it, and only that comparison tells the copies made before it hold the old values. When anything
differs the tick discards the copies, puts the cursor back at the source's `lo` and logs `regrain_restart`,
with `rows` counting the copies discarded and `method` naming what differs; the next ticks copy the range
again from the source. Capture stays on throughout, so DML committed across the restart is honoured as
above. The copies are copied again rather than altered because only the source holds the values its rows
took for a new column: a volatile default (`nextval`, `clock_timestamp()`) gave each row its own, and
`now()` the instant of the `ALTER`, which re-evaluating the default in a copy would not reproduce. A
restart costs the copying done so far, so schedule such migrations between regrains of a large partition
when you can. A rewrite that changes no value (`VACUUM FULL`, `CLUSTER`, `SET TABLESPACE` on the source)
cannot be told from one that does, so it restarts the run too. Defaults, statistics targets, storage and
indexes are not compared: the copy inserts explicit values, and `ATTACH` builds an index the parent gained.
A run that has copies but no recorded mark restarts the same way, since nothing says what its copies were
made from. That is a regrain already in flight when you upgrade from a release that did not record the
mark: re-running `install.sql` restarts every such run that has copies, logging `regrain_restart` with
`method` naming the upgrade, and records the mark of a run that has none yet; a tick that meets such a run
anyway restarts it rather than adopting the source as it is then.

Change capture follows the key the same way. The delta's columns and the trigger function are minted from
the reused key's names and types, so a key column renamed or retyped (an `int` key widened to `bigint`)
mid-regrain no longer fits them. The next tick that resumes the run sees that, restarts it as above, and
re-mints capture from the key as it is now, keeping the `TRUNCATE` refusal; the restart re-copies the range
from the source, so nothing captured under the old key is lost with the old delta. Until that tick, a write
into the partition being regrained that the old trigger cannot record is **refused**: a renamed key column
makes it fail with `record "old" has no field` or `record "new" has no field` (`42703`), and a widened one
fails a key the old type cannot hold with `integer out of range` (`22003`). Nothing is written by a refused
statement, and pgpm has no hook into `ALTER TABLE` that would re-mint capture any sooner, so run the next
regrain tick right after such an `ALTER` to close that window at once: `call pgpm.maintain('<table>')` for an
auto-regrain (while the table is not paused), or the next `regrain_step` of a regrain you drive.

The reconcile finds each captured key's fine child by its recorded **range** in `pgpm.part`, not by name,
so a first sub-range that was clamped to the coarse child's own `lo` (a weekly target on a monthly monolith,
whose `lo` is not on the weekly grid) is reconciled into the child that actually exists. A captured key
whose sub-range has **no** fine child is discarded, and logged `regrain_reconcile_aged`, only when that
sub-range lies below the retention horizon, which is the one case in which no child was ever made. In any
other case the tick fails rather than discarding the change, and the key stays in the delta; under
`maintain` that surfaces as a `skip_regrain` row carrying the error.

The first tick installs the capture and copies nothing, so budget one tick more than the microbatch count.

### `regrain_cancel`

```sql
pgpm.regrain_cancel(p_parent regclass) returns int
```

Stops an in-flight regrain and reclaims what it has built, returning the number of in-flight fine children
dropped. It removes change capture (and with it the `TRUNCATE` refusal), clears the delta, drops every
not-yet-attached copy, and resets
`config.regrain_cursor`. A copy is dropped, and the capture trigger and `TRUNCATE` refusal are taken off a
child, by the identity recorded when the regrain created it (or when the child entered the catalog), not by
its name, so a renamed copy or source is still the one reclaimed and a relation that has since taken its old
name is left alone. The parent is untouched: the source child still holds every row, so this costs the
copying work already done and nothing else. On a table handed to a new owner whose regrain objects are still
the old owner's, a session that can neither hand them over nor act as their owner is refused before anything
is changed, SQLSTATE `42501`, with the step to take (see
[Handing a table to a new owner](#handing-a-table-to-a-new-owner-hand_over_scratch)).

The copies are **dropped, not kept**. Keeping them would let a later regrain resume from copies made before
the cancel, which were therefore never reconciled.

Turning auto-regrain off with [`set_regrain`](#set_regrain)`(parent, null)` while the run it started is in
flight abandons that run through this same path, so the two cannot differ: the same teardown, one
`regrain_cancel` log row. `maintain` also sweeps a capture trigger left on a child whose range the cursor no
longer covers, logging `regrain_capture_orphan`, but that is a backstop for a cursor cleared by some other
route, not a way to abandon a run. It judges only under the regrain lock every regrain driver takes, so it
never reads a cursor older than a prepare that committed around it: while a `regrain_step`, `regrain()` or
`regrain_cancel` holds that lock, the tick leaves capture alone and logs `skip_regrain_capture`. And it drops no copies and clears no delta. The copies it leaves are never
resumed from: they were made while capture was off, so the next `regrain_step` on that child discards them
at its prepare tick, whatever the cursor says, logs `regrain_restart` with `rows` counting the copies
discarded, and copies the range again from the source. To stop a run deliberately and get the disk back, or
to clear one left half-done with auto-regrain already off (`config.regrain_cursor` set, `regrain_to` null),
call this.

`retire` makes the same cancellation, scoped to the one source it is dropping, when retention drops the
coarse child a regrain is splitting (see [`retire`](#retire)). That is logged `regrain_cancel` too, with
`method` naming `retire`.

### `regrain_history`

```sql
pgpm.regrain_history(p_parent regclass, p_target_step text default null) returns int
```

Convenience: `regrain` the oldest coarse child (the monolith -- the smallest-`lo` attached partition) to
`p_target_step`. The hierarchical monolith to coarse to fine path is just repeated `regrain` calls with
chosen steps.

### `maintain`

```sql
call pgpm.maintain(p_parent regclass, inout p_status text default null)
```

The per-table tick for everything except `obtain`, which has its own procedure,
[`maintain_obtain`](#maintain_obtain), and its own cron job (see [Scheduling](#scheduling)):
enforce write-blocks on every attached child against the retention boundary, one chunked-archiving
step, `retain`, restore any preserved FK once the table is quiescent, and -- when auto-regrain is on
(`config.regrain_to`) -- one `regrain_step` on the oldest frozen coarse child. A no-op while paused.
Every step runs under a short `lock_timeout` and is isolated from the others, so it never blocks or
deadlocks the live workload, and one step failing does not abandon the rest of the tick; a step that
loses a lock race is deferred and retried next tick.

The write-block step checks each child's name against `pgpm.part.child_oid` before installing anything,
and refuses on a mismatch, logging `fail_write_block_identity` rather than putting a pgpm trigger on a
relation it has not identified. Removal is deliberately *not* anchored: an older pgpm could have left
that trigger on a substituted relation, rejecting every write to it, and removing by name is what lets an
upgraded pgpm lift it off again.

A procedure, and each step commits before the next begins, so no step's locks outlive it. Those commits
mean `maintain` and `maintain_all`, like `transmute`, must be called at the **top level**, never inside
a surrounding transaction; `pg_cron` runs its command as a top-level statement, so the scheduled path
satisfies this for free.

`p_status` reports a one-line summary, for example
`archived=1 dropped=0 restored_fk=0 regrain=copied:5000`. Call
it as `call pgpm.maintain('public.events')` and the summary comes back as a result row; from
PL/pgSQL, pass a variable to receive it.

Write-blocking: a child whose whole range sits at/below the retention horizon
(`_retain_boundary`, the same one `retain` itself uses) gets a `BEFORE INSERT OR UPDATE OR DELETE`
trigger the moment it becomes eligible, independent of whether or how it is archived -- a backdated
write into an eligible-but-not-yet-dropped range (including one a chunked archiver already covered)
is rejected rather than silently diverging the archive from what is live. Loosening `config.retain`
removes the trigger from a partition that becomes ineligible again, **unless `pgpm.archive_ledger`
already records coverage for it**. Coverage is only true of a partition nothing has written to since
it was recorded, so a covered partition keeps its trigger when retention stops reaching it, whether
through a loosened `retain` or, on an `id` table, a frontier that moved back because the newest rows
were deleted. It keeps being archived to completion under the block, and is dropped only if retention
reaches it again. The first tick that keeps a block it would otherwise have lifted logs
`skip_write_block_lift` for that partition, once. To make the partition writable again, delete its
`pgpm.archive_ledger` rows: the next tick lifts the block, and if the partition is ever blocked again
archiving starts over from its `lo`. Coverage a tick finds on a partition that has **no** trigger in
force (one removed or disabled by hand, lifted by a pgpm older than this rule, or left origin-only by a
pgpm older than the `ALWAYS` rule, which a `session_replication_role = replica` writer passes) is
discarded for the same reason, before the same tick repairs the trigger, and logged as
`archive_coverage_reset` with the number of chunks that went. The repair itself is logged too: a tick that
finds the trigger disabled, `ENABLE REPLICA` or origin-only puts it back `ENABLE ALWAYS` and logs
`write_block_reenable`, naming the partition and the state it found. That test is made of the relation
`pgpm.part.child_oid` records, never of whatever currently holds the name: when another relation has
taken a partition's name, the tick refuses on identity (`fail_write_block_identity`, above) and leaves
the real partition's coverage alone. Write-blocked is one of `retire()`'s drop preconditions (see
[`retire`](#retire)).

Chunked archiving: `archived=N` counts how many chunks this tick recorded via
`pgpm._archive_step` -- see [Archive strategy contract](#archive-strategy-contract) for the
mechanism. It only ever considers a child the write-block step above has already protected, so it
always runs after write-blocking within the same tick. Archive coverage is `retire()`'s other drop
precondition.

### `maintain_all`

```sql
call pgpm.maintain_all()
```

A procedure that calls `maintain` for every managed table. This is what the `pgpm` scheduled job runs.

The sweep is one top-level statement, so the maintaining session's `statement_timeout` runs across
every table in it, not per table: the internal `COMMIT`s do not restart it. A sweep the timeout cuts
short stops where it is (a cancellation is not a step failure, so no step defers it), and the tables
after that point wait for the next tick. So that no table waits forever behind a slow one, the sweep
visits the table whose turn is oldest first (`config.sweep_turn_at`, set when a table's `maintain`
returns). A table cut short keeps its old turn and leads the next sweep; the first table of a sweep has
its turn recorded as it starts, so even a table whose own tick overruns the timeout cannot lead, and be
cancelled in, every sweep. Each sweep therefore moves its first table to the back, and every table that
fits the timeout on its own completes at least once every N sweeps for N managed tables. With nothing cut
short the order is the same every tick. Size `archive_byte_budget` so that one table's `maintain` fits
the timeout; the whole sweep need not. A turn is recorded only if the table's `pgpm.config` row is free:
while another transaction holds it (an open transaction around a setter such as `set_obtain`, a
synchronous `regrain()`), the sweep skips that one write rather than waiting on the row or stopping, and
the table, whose own `maintain` still ran, leads the next sweep instead.

### `maintain_obtain`

```sql
call pgpm.maintain_obtain(p_parent regclass, inout p_status text default null)
```

The per-table `obtain` tick, separate from `maintain`: takes `ACCESS EXCLUSIVE` on the
parent under a short `lock_timeout` when it creates a partition, so a lock race is deferred and retried
next tick rather than blocking the live workload; a deferral starts a 30-second
`config.obtain_retry_after` back-off so sustained contention does not retry every tick. The back-off is
honored only while at least `ceil(obtain / 2)` complete grid steps of attached coverage remain beyond the
frontier's own grid cell (coverage, not partitions: grid inside a monolith widened by `p_bound_headroom`
counts): with no `DEFAULT` to catch a write past the grid, a back-off that outlasted the lookahead would
turn a lost lock race into refused writes, so below that threshold obtain runs anyway and the status
notes `obtain_backoff_bypassed`. A no-op while paused, checked independently: it does not assume
`maintain` ran first, or at all, in the same tick. Around `pgpm.obtain()` it is the same operational
wrapper (lock timeout, back-off, exception handling, logging, transaction boundary) that `maintain`
provides for its own steps. The back-off's own writes never stop `maintain_obtain_all`: while another
transaction holds the table's `pgpm.config` row, clearing an expired back-off or arming a new one is
skipped, so the next tick either finds the expired back-off again or retries `obtain` straight away.

A procedure that commits, so like `maintain` it must be called at the **top level**, never inside a
surrounding transaction; the scheduled path satisfies this for free.

`p_status` reports a one-line summary, for example `obtained=2`. Call it as
`call pgpm.maintain_obtain('public.events')` and the summary comes back as a result row; from
PL/pgSQL, pass a variable to receive it.

### `maintain_obtain_all`

```sql
call pgpm.maintain_obtain_all()
```

A procedure that calls `maintain_obtain` for every managed table, in the same table order as
`maintain_all`: the table whose turn is oldest first (`config.sweep_turn_at`). This is what the
`pgpm_obtain` scheduled job runs. Its sweep is one top-level statement too, so the session's
`statement_timeout` runs across every table in it, and it takes turns exactly as `maintain_all` does: the
sweep's first table has its turn recorded as it starts, every table has it recorded when its
`maintain_obtain` returns, and a table the timeout cut short keeps its old turn and leads the next sweep,
so a table whose own `obtain` overruns the timeout cannot deny `obtain` to every table behind it. Both
sweeps record turns in the same column. A sweep that is not cut short records them in the order it
visited the tables, which leaves the order as it was, so only a sweep that was cut short changes it, and
a table either sweep cut short leads the next sweep of both. A turn is skipped, never waited for, while
another transaction holds the table's `pgpm.config` row. Unlike `maintain_all`, it does not
run the crash-recovery reaping (`_transmute_reap`/`_detach_reap`) -- `obtain` does not depend on either
having run, and the `pgpm` job still performs them on its own cadence regardless of whether this job
also runs.

## Archive strategy contract

`config.archive_fn` is one archive strategy per managed table. `null` (the default) means strategy
`none` -- no archiving, a partition is
immediately drop-ready. Set it with `pgpm.set_archive_fn`:

```sql
select pgpm.set_archive_fn('public.events', 'myschema.my_archiver(regclass,name,text,text)'::regprocedure);
```

Casting the second argument to `regprocedure` validates that the function exists with exactly these
argument types right away, not later when a maintenance tick tries to call it, and `pgpm.set_archive_fn`
then checks what it returns. A function whose return type is not `pgpm.archive_result` (any other type,
or `setof pgpm.archive_result`), or a reference that names no function, is refused with an error that
names the function, what it returns and the contract, and `config.archive_fn` is left as it was. The cast
alone checks only the argument list; without the second check a `returns text` strategy would be
installed, and a tick would map its one column onto `covered_hi`. A bare `null` (or calling
`pgpm.set_archive_fn` with no second argument) turns archiving back off.

The calling contract: `archive_fn(p_parent regclass, p_child name, p_lo text, p_hi text) returns
pgpm.archive_result`, where `pgpm.archive_result` is `(covered_hi text, rows_archived bigint, s3_key
text, etag text)`. `archive_fn` is expected to be **resumable**: called once per maintenance tick
against the same child, making bounded incremental progress and reporting how much of `[p_lo, p_hi)`
is now durably archived (`covered_hi`, which may be short of `p_hi`) and how many rows this one call
archived (`rows_archived`, `null` when nothing was actually archived) -- not to archive the whole
range in a single call. `s3_key`/`etag` are optional: a transport strategy that has an object-store
identifier to report (`pgpm.archive_to_s3_ndjson`/`pgpm.archive_to_s3_parquet`) sets
them; a strategy with nothing object-store-shaped to name (`pgpm._archive_noop`, the `none`
strategy) leaves them `null`. This is the contract the byte-budget chunked archiver and the real S3
upload functions implement.

The core holds a strategy to that promise. Before a ledger row is written from a call's result,
`covered_hi` must be a native grid value strictly above the `p_lo` the call was handed and no greater
than its `p_hi`. A return that breaks this (null, at or below `p_lo`, past `p_hi`, or not a native
value at all) is not recorded: the step logs one `fail_archive_contract` row naming the strategy, the
chunk, the value returned and the rule it broke, skips that partition for the tick, and counts the
refusal in `status().retain_drop_failures`; see
[the archive step's contract check](#the-archive-steps-contract-check). A strategy that cannot make
progress on a call (the object store is unreachable, say) should **raise** rather than return:
`maintain()` records that as a `skip_archive` deferral and hands it the same chunk next tick, which
is the retry path. Returning `p_lo` as `covered_hi` is not. The deferral is per partition: the
`skip_archive` row carries that partition's `lo` and `hi` and the raised message in `method`, and the
other partitions of the same `archive_batch` record what the strategy archived for them, as if the raise
had not happened.

`pgpm._run_archive_strategy(p_parent, p_child, p_lo, p_hi)` is the dispatch stub: it looks up
`config.archive_fn` and calls it, or, for a `null` (`none`) strategy, returns `(p_hi, null)` directly
-- the whole requested range is trivially "already covered" since there was never anything to
protect against a drop. `pgpm._archive_noop` is a trivial built-in strategy (always reports the
whole requested range archived immediately, having actually counted the rows in it) that exists only
to exercise real dispatch in tests.

`retire()`'s drop precondition consults `pgpm._archive_fully_covered` (see
[`retire`](#retire)), which in turn is driven by `_run_archive_strategy` via `pgpm._archive_step`
below.

### Byte-budget chunked archiving

`pgpm.maintain()`'s per-tick archiving step (`archived=N` in its summary) is the
built-in way to drive the contract above without hand-writing a resumable `archive_fn`. It is a
byte-budget chunker: never archive a whole large partition as one giant operation, chunk it instead.

- `config.archive_byte_budget` (default 8 MiB) and `config.archive_probe_sample` (default 1000)
  estimate how many rows fit the budget via a sampled average row width.
- **Raising `archive_byte_budget` raises how long the tick's `archive_fn` call runs for, and
  `pgpm.maintain()` applies no timeout of its own to that call.** With `pgpm.archive_to_s3_parquet`
  and `archive.config.compress` on, that time is dominated by `pgpm_archive`'s own from-scratch
  GZIP writer, pure PL/pgSQL and CPU-bound: real compression time runs from ~50ms/MB on
  compressible data up to ~2.6s/MB on near-incompressible data (see
  [`pgpm_archive/README.md`](../pgpm_archive/README.md#ndjson-or-parquet)), scaling roughly linearly
  with the budget. An 8 MiB budget is already several seconds of CPU on the low end of that range;
  doubling it can double the tick's duration and cross whatever `statement_timeout` the connection
  running `maintain()` has, surfacing as the tick failing outright rather than as a slow tick.
  Size `archive_byte_budget` with that per-MB cost and the maintaining session's
  `statement_timeout` in mind, not just S3 part-size or file-count preferences -- if a tick is
  timing out, lowering `archive_byte_budget` (or turning `compress` off, or switching to
  `pgpm.archive_to_s3_ndjson`) is the fix, not raising any lock or statement timeout.
- `pgpm.archive_ledger` (`parent_table`, `lo`, `hi`, `child_name`, `s3_key`, `etag`, `rows_archived`,
  `archived_at`) records one row per chunk. `s3_key`/`etag` come straight from the `archive_fn` call's own
  `pgpm.archive_result` -- populated for a real transport strategy, still `null` for a
  strategy with nothing object-store-shaped to name (`pgpm._archive_noop`, the `none` strategy).
- `pgpm._next_archive_chunk(p_parent, p_child)` picks the next chunk **within one child's own
  `[lo, hi)`** -- resuming from wherever that child's ledger coverage left off, extended to the next
  distinct control value so a run of ties never splits across two chunks. The tie is judged on the
  native grid: a `text_time` or `uuidv7` column decodes at its encoding's unit (a second for ObjectId
  and KSUID ids, a millisecond for uuidv7, ULID and cuid), so rows minted within one unit travel in
  one chunk, and that chunk exceeds `archive_byte_budget` by however much the unit holds. A bulk
  import that lands a chunk's worth of rows in one second is archived as one oversized chunk, then
  the picker resumes at its usual size. It only ever looks at a child that is already write-blocked,
  and the block is not lifted while the ledger covers the child (see [`maintain`](#maintain)), so
  what it archives cannot change underneath it.
- `pgpm._archive_fully_covered(p_parent, p_child)` is true once the ledger's recorded ranges for
  that child reach its own `hi` (or the strategy is `none`) -- `retire()`'s archive-coverage drop
  precondition (see [`retire`](#retire)).
- `pgpm._archive_step(p_parent)`, called once per `maintain()` tick, is the orchestrator: among
  attached children that **already have the write-block trigger installed and enabled `ALWAYS`**
  (checked directly, not re-derived from the boundary formula) and are not yet fully covered, it picks up to
  `config.archive_batch` of them, **oldest first**, and for each picks the next chunk, runs
  `_run_archive_strategy`, checks the returned `covered_hi` against that chunk (see
  [the archive step's contract check](#the-archive-steps-contract-check)), and records the result in
  `pgpm.archive_ledger`. A child without the trigger yet is never touched, however far past the byte
  budget's reach it sits. Before picking candidates it discards coverage recorded under a `child_name`
  that is no longer a tracked partition of the parent when that coverage overlaps a range a tracked
  partition holds (a partition renamed without carrying the ledger, or a source an older `regrain`
  dropped without retiring its chunks): the ledger is keyed `(parent_table, lo)`, so such rows would collide with the live
  partition's own first chunk, and nothing guarded them across the change, so they cannot stand in for
  it. Logged once per name as `archive_coverage_reset`; the live partition archives from its own `lo`.
  Rows under an untracked name that overlap no tracked partition are left where they are: `retire()`
  leaves every dropped partition's chunks in the ledger as the record of where its rows went.
- `config.archive_batch` (default **1**; `null` = unbounded) caps how many *different* partitions
  one `_archive_step` call touches -- the same shape as `retain_batch` (nullable `int`, `null`
  means unlimited, caps attempts not successes), but a different default, and for a reason worth
  spelling out: `retain_batch`'s unlimited default is safe because its unit of work, `DROP TABLE`,
  is cheap and roughly constant-cost regardless of how many run per tick. Archiving's unit of work
  is not -- each partition costs a real table read, an encode pass, and, with a real S3 strategy and
  `archive.config.compress` on, a CPU-bound compression pass (see the note on `archive_byte_budget`
  above). Fanning out over every eligible partition in one tick makes a single `maintain()` call's
  duration scale with the size of the *backlog*, not just with `archive_byte_budget`'s own
  per-partition cost -- invisible in steady state (one partition becomes eligible per rollover
  interval), but very visible the moment a bulk regrain or backfill leaves many partitions
  simultaneously eligible at once, at which point the aggregate cost can cross `statement_timeout`
  regardless of how conservatively the per-partition budget is tuned. Defaulting to `1` makes
  archiving strictly sequential: one partition fully archived, and so retirable, before the next is
  even touched. Raise it, or set it `null`, if a large backlog catching up faster matters more than
  that bound.
- **`archive_batch` and `archive_byte_budget` are fungible for speed and risk, but not for file
  shape.** Per-tick duration is roughly `archive_batch x archive_byte_budget x (cost per byte)`
  (compression scales close to linearly with chunk size), and so is how many ticks it takes to
  clear a backlog: `_archive_step`'s query is a sliding window over the oldest not-yet-covered
  partitions, so total chunk-advancements needed is fixed and each tick contributes `archive_batch`
  of them. Both quantities depend on the same product, so `archive_batch=1` with a bigger budget
  and `archive_batch=N` with a smaller one, chosen so the product matches, land on roughly the same
  per-tick duration and the same backlog-convergence speed. They are NOT interchangeable for the
  *shape* of what gets uploaded: `pgpm._next_archive_chunk` reads only `archive_byte_budget` (never
  `archive_batch`) to decide how many rows make up one chunk, and one chunk is one uploaded file --
  `archive_batch` cannot make files bigger or smaller, or change how many chunks it takes to cover
  one partition, only how many *different* partitions' independent chunk sequences advance in the
  same tick. Pick `archive_byte_budget` first, for the file size (and per-chunk risk) you actually
  want; use `archive_batch` to buy back backlog-convergence speed at that fixed shape, rather than
  raising `archive_byte_budget` alone and reintroducing the per-partition timeout risk to get the
  same speed `archive_batch` would have bought for free on that axis.

#### The archive step's identity check

Every step of archiving works from the partition's **name** out of `pgpm.part`: the chunk is sized from
whatever relation that name resolves to, and `archive_fn` is handed the bare name. So if `child_name` stops
naming the partition it was recorded for -- someone renamed the partition aside, something else took the
name -- the chunk would be sized from whatever now holds it, and the `pgpm.archive_ledger` row that
follows would claim coverage of a range those rows never came from. That ledger is `retire()`'s drop
precondition, so a bad chunk would not merely put a wrong object in the bucket: it would open the gate
that authorises a `DROP`.

So before reading anything about a candidate, `_archive_step` resolves its name and compares the
result to `pgpm.part.child_oid`, recorded when the partition entered the catalog. On a mismatch --
including a name that resolves to nothing at all -- it logs `fail_archive_identity` with both OIDs in
`method` and skips that partition, continuing with the rest of the batch. Nothing is read, so no
ledger row is written, so `_archive_fully_covered` stays false and the drop precondition stays shut.
The write-block step makes the same check before a partition ever becomes an archive candidate (see
[`maintain`](#maintain)); this one is what still catches a trigger an older pgpm left on a
substituted relation.

Like `fail_retain_identity`, the refusal is permanent rather than retryable: no later tick makes the
name mean the right relation again. It counts in `status().retain_drop_failures`, and shows up as
`retain_backlog` flat while that count climbs. Recovery is an operator decision -- put the intended
relation back under that name, or delete the stale `pgpm.part` row (`delete from pgpm.part where
parent_table = ... and child_name = ...`), after which the archive step moves on to the next partition.
[`forget_missing`](#forget_missing) is not the tool here: it clears only a parent whose relation no longer
exists, and this check only ever runs for a live one. At `archive_batch`'s default of `1` a wedged
partition also holds up that parent's other partitions, which is deliberate: pgpm's catalog is
demonstrably wrong about which relation is which, and retention should not march on past that. A null `child_oid` (a
partition recorded before the column existed, whose name no longer resolved at upgrade time) is
unanchored and skips the check entirely.

#### The archive step's contract check

`archive_fn`'s return is a claim about the chunk it was handed, and the `pgpm.archive_ledger` row
written from it is what opens `retire()`'s drop gate. Recorded verbatim, a strategy that answered
chunk `[0, 15)` with `covered_hi = 15000` marked the whole partition covered on the spot, and the next
`retain()` dropped it with nothing archived. So before writing the row, `_archive_step` checks the
returned `covered_hi` against the `[p_lo, p_hi)` it passed: it must be a native grid value with
`p_lo < covered_hi <= p_hi`.

Each bound closes a different hole. Past `p_hi` is the drop with nothing archived. At or below `p_lo`
is "no progress", which recorded as a `(lo, lo)` ledger row wedged the ledger for good: the next tick
resumed from `max(hi) = lo`, handed the strategy the same chunk, and collided on the ledger's primary
key, every tick from then on. A null `covered_hi` is refused for the same reason (a null `hi` is not a
watermark). And a value that is not a native value at all is refused here rather than left in the
text `hi` column, where every later coverage check would have raised, and `maintain()` would have
reported that as a `skip_archive` deferral, tick after tick, for what is a permanent strategy bug.

On a breach nothing is recorded. The step logs `fail_archive_contract`, with the strategy, the chunk,
the value it returned and the rule it broke in `method`, skips that partition for the tick, and
continues with the rest of the batch. Coverage stays exactly where it was, so the drop precondition
stays shut. It counts in `status().retain_drop_failures`, and at `archive_batch`'s default of `1` it
also holds up that parent's other partitions, which is right: the strategy is demonstrably wrong
about what it archived.

Unlike the identity refusals, this one is retryable by construction. Nothing advanced, so the next
tick hands the strategy the very same chunk; correct the strategy (or point `pgpm.set_archive_fn` at
a corrected one) and archiving resumes from where the ledger honestly stands. Until then the row
repeats once per tick. A strategy that genuinely cannot make progress on a call should raise rather
than return `p_lo`: a raise is logged as `skip_archive` and retried with the same chunk, and says
what it is.

#### Sizing `archive_byte_budget`: there is no single optimal size

Four considerations pull in different directions, and no formula resolves all of them at once --
picking a value is a tradeoff, not a lookup.

1. **A floor, from the Parquet writer's compression window.** Its compression only benefits from
   content that repeats within roughly 32 KB *of a single column's own data stream*; repetition
   further apart than that compresses as if it were unique. A chunk should be big enough to
   comfortably clear this floor for whatever repetition actually exists in the data, or cheap
   compression is left on the table. For ordinary tabular data this floor is low (a few hundred KB
   to low single-digit MB) and rarely the binding constraint on its own.
2. **A ceiling, from `statement_timeout`.** As the note above on `archive_byte_budget` describes,
   `_archive_step`'s per-tick call has no timeout of its own. With compression enabled, real
   measurement across several row counts on a synthetic table showed per-chunk time growing
   somewhat faster than the byte budget itself -- not dramatically, but enough that doubling the
   budget should be expected to more than double a chunk's processing time, not exactly double it.
   Treat the roughly-linear estimate above as an optimistic floor, not a guarantee, and measure a
   real chunk at the actual table's scale before sizing a budget close to `statement_timeout`.
3. **A query-pattern consideration: a query engine can skip whole files, never part of one.** The
   files the writer produces carry nothing Athena, DuckDB, or similar engines can use to skip
   *within* a file (see [`pgpm_archive/README.md`](../pgpm_archive/README.md#limits)); the only
   pruning available is by file, through naming or partitioning. Broad-scan workloads (queries that
   touch most or all of the archived history) are indifferent to this and benefit from fewer,
   bigger files (less per-file open/list overhead). Selective, range-scoped workloads (e.g. "just
   last month") are hurt by oversized files: a query touching a fraction of a file still pays to
   scan the whole thing. These two workload shapes want opposite answers -- there is no way to pick
   one without knowing which describes the actual query pattern.
4. **A minimum-count consideration, from S3/Athena's own per-file overhead.** Too many small files
   costs real list/open/task overhead in the query engine, independent of everything above -- this
   is the one consideration that is a fairly universal "not too small," rather than
   workload-dependent.

**Tie the budget to a meaningful boundary, not an arbitrary byte count.** The most useful sizing
method is not a number, it's a way of picking one:

- Size `archive_byte_budget` against a boundary that is already meaningful to the retention/query
  granularity in use -- e.g. "one managed partition archives in as few chunks as
  `statement_timeout` safely allows, ideally one" -- rather than picking a byte target divorced
  from how the data is organized. This gives files that line up with the one pruning mechanism
  these query engines actually have (file-level, via naming), for free.
- Measure the actual per-row cost and compressibility rather than assuming them. Pull an
  already-archived file's size against its `rows_archived` (`pgpm.archive_ledger`) for a real
  compression ratio, and time a real chunk (via `pgpm.archive_ledger.archived_at` deltas, or a
  manual timed call) rather than extrapolating from a generic benchmark -- both vary widely with
  actual data shape.
- If a single partition's data is too large to safely fit in one chunk even at a conservative
  budget, accept multiple files per partition rather than forcing one -- `archive_batch`'s
  sequential-by-default pacing already means only that one partition's cost is at stake per tick,
  not the whole backlog's.
- Prefer raising `archive_batch` over `archive_byte_budget` to recover throughput when both are
  options: `archive_batch`'s effect on total tick time is linear (it multiplies independent,
  separately-sized chunk operations), while `archive_byte_budget`'s effect on a single chunk's own
  cost is somewhat worse than linear whenever compression is enabled (consideration 2 above). The
  same throughput gain carries less risk when bought via `archive_batch` than via
  `archive_byte_budget`.

**The ~1 GiB Postgres `bytea` ceiling documented in
[`pgpm_archive/README.md`](../pgpm_archive/README.md#limits) is not the ceiling that binds in
practice.** The whole encoded file is held in memory before upload, capping it at roughly 1 GiB, but
reaching that in one synchronous call is measured to take on the order of many minutes at minimum
with compression on -- `statement_timeout` is reached first, by orders of magnitude, under any
realistic timeout setting. The 1 GiB figure is real but should not factor into how
`archive_byte_budget` actually gets sized; `statement_timeout` does.

### Real S3 archive strategies

`pgpm_archive` (the optional module, `pgpm_archive/install.sql`) ships two `archive_fn`-conforming
strategies: `pgpm.archive_to_s3_ndjson` and `pgpm.archive_to_s3_parquet` (both in the
`pgpm` schema, not `archive` -- they are `pgpm_core` contract implementations that happen to live in
this optional module). Set either via `pgpm.set_archive_fn`:

```sql
select pgpm.set_archive_fn('public.events', 'pgpm.archive_to_s3_ndjson(regclass,name,text,text)'::regprocedure);
```

Both delegate to `archive._encode_upload_ndjson_single` / `archive._encode_upload_parquet` for the
actual transport -- the same encode/upload steps `archive.to_s3`/`archive.to_s3_parquet` (the
synchronous functions, called directly rather than through `archive_fn`) are built on, so the
encoded bytes and S3 semantics are identical; only the calling contract differs. All four refuse a
caller whose reads row-level security would filter (the transports read the chunk through the parent, the
synchronous functions read the partition), before anything is read or sent. Each strategy also refuses an
empty or inverted range (`p_hi` not above `p_lo`, compared as the grid's native type: numbers for an `id`
grid, instants otherwise) before anything is read or sent: the chunk's key is derived from `p_lo` alone, so
such a call would read no row and write an empty object over the one the chunk at `p_lo` was archived to,
which after `retire()` is the only copy of its rows (`pg_partition_magician: archive_to_s3_ndjson refuses the
range [lo, hi) of <table> -- it is empty or inverted, ...`). `pgpm._next_archive_chunk` never asks for one;
the refusal is for a direct call. Connection settings
(bucket, region, endpoint, prefix, vault key names, compression) still come from `archive.config`,
the same one config surface the synchronous functions use -- setting `archive_fn` this way needs no
second, independently configured surface. An `archive_fn` cannot issue `COMMIT`: it is a plain function
and PL/pgSQL forbids transaction control inside one regardless of call context. It does not need to
either, since `pgpm._next_archive_chunk` bounds every call to `config.archive_byte_budget` before
`archive_fn` ever runs, with one exception: a run of rows tied at a single native value (one second
of ObjectId or KSUID ids, one millisecond of uuidv7, ULID or cuid ids) is never split, so a chunk
that carries such a run is as large as the run.

Each chunk is uploaded to `<prefix><schema>.<table>_<stem>.ndjson` (`.ndjson.gz` when compressed) or
`<prefix><schema>.<table>_<stem>.parquet`, and the key does not depend on the session that runs the
tick. The parent is always schema-qualified (each part quoted only when PostgreSQL would quote it), so
two tables with one name in two schemas can share a bucket prefix without overwriting each other's
objects. The stem is the chunk's `lo`: an `id` kind's numeric text whole (sign and decimal point
included), and for every time kind the digits of `lo` rendered in UTC (`2024-01-01 00:00:00+00` becomes
`2024010100000000`), whatever the session's `TimeZone`, keeping the decimal point of a fractional second
(`2024-01-01 00:00:00.1+00` becomes `20240101000000.100`) and ending `BC` for a BC instant
(`2024-01-01 00:00:00+00 BC` becomes `2024010100000000BC`), so a BC chunk and an AD chunk of one calendar
day, or a fraction of a second and a five-digit year, never share a key. Objects uploaded before this key
shape stay where they are: each `pgpm.archive_ledger` row records the key its object was written to, and
nothing derives a key from a chunk's bounds after the upload. A table whose ticks ran with its schema on the `search_path`
(a `public` table under pg_cron, typically) had its earlier chunks keyed `<prefix><table>_<stem>`, so its
bucket holds both shapes once upgraded; a time-kind chunk archived from a non-UTC session had its stem
rendered in that session's zone, and a BC chunk's stem had no era.

A key is never reused by a different relation. The first relation to archive under a
`<prefix><schema>.<table>` claims that name in `archive.object_key_owner` and keeps the shape above;
any other relation that later archives under the same name and prefix (a table created after the first
was dropped and cleared with `pgpm.forget_missing()`, or one that took a renamed table's name) has its
oid in the key, `<prefix><schema>.<table>.<oid>_<stem>.ndjson` (or `.parquet`), so it cannot write over an
object the first one left, which after `forget_missing()` is the only copy of the rows `retire()` dropped.
Nothing deletes a claim, `forget_missing()` and `DROP` included. Install claims every name
`pgpm.archive_ledger` already records a key under, the earliest-archived relation first, so a table that
archived before this release keeps its keys and its objects are protected the same way. The claims live in
the database: two databases writing one bucket under one prefix are not told apart, so give each its own
prefix.

The synchronous functions write one object per call, named after the partition with its parent's
schema: `archive.to_s3` to `<prefix><schema>.<child>.ndjson` (`.ndjson.gz` when compressed) and
`archive.to_s3_parquet` to `<prefix><schema>.<child>.parquet`, quoted the same way, so two parents with
one name in two schemas sharing a prefix export their same-named partitions to two objects. They used to
write `<prefix><child>.<ext>`, and an object written under that shape stays where it is. Their keys are
claimed the same way as the chunks': the first parent to export a partition under a
`<prefix><schema>.<child>` claims that name in `archive.object_key_owner` and keeps the shape above, and
any other parent that later exports a partition of the same name (its table took the name of one dropped
after `archive.to_s3`, the documented export-then-drop workflow) has its oid in the key,
`<prefix><schema>.<child>.<oid>.ndjson` (`.ndjson.gz`, `.parquet`), so it cannot write over the dropped
table's export. Every key, on every path, comes from one function that takes the claim before the upload.
An export written before this release left no record of whose it was, so its name is claimed by whichever
parent exports under it next.

A name claim alone cannot tell the two kinds of key apart: the export of a relation named
`<table>_<stem>` (the synchronous functions accept any relation in the parent's schema, tracked or not)
is `<prefix><schema>.<table>_<stem>.ndjson`, which is also the key of `<table>`'s chunk at that stem. So
every key is also claimed whole, in `archive.object_key_claim`, by its parent and its kind (`chunk` or
`export`), and a call whose key is already another writer's takes the oid shape instead: the export to
`<prefix><schema>.<child>.<oid>.ndjson`, the chunk to `<prefix><schema>.<table>.<oid>_<stem>.ndjson`
(recorded in `pgpm.archive_ledger` as usual), and the first writer's object is left as it was. The same
parent writing the same kind of object to the same key again (a retried chunk, a re-run export) finds the
key its own. A call whose oid shape is taken as well is refused, and nothing is written. Install claims
every key `pgpm.archive_ledger` records as its table's chunk, so a chunk archived before this release is
protected the same way; an export from before it is not, having left no record.

## Scheduling

### `schedule`

```sql
pgpm.schedule(p_every text default '* * * * *', p_obtain_every text default '* * * * *') returns bigint
```

Creates (or replaces) the `pg_cron` job named `pgpm` that runs `call pgpm.maintain_all()` on the
`p_every` cron schedule in the current database, returning the job id. One job covers every managed
table and is idle while they are paused. Raises if `pg_cron` is not installed.

It also creates a second job, `pgpm_obtain`, that runs `call pgpm.maintain_obtain_all()` on its own,
independent `p_obtain_every` cron schedule. obtain has its own job because it is the one step where
falling behind has a hard consequence: with no `DEFAULT` partition, a write past the forward grid is
rejected outright, not queued, and a slow archive/retain/regrain for one table would otherwise delay
obtain for every table after it in the same tick. `pgpm.maintain()` itself does not obtain at all.

**Upgrade hazard.** `schedule()` is operator-invoked, never automatic. If you already called
`pgpm.schedule()` before upgrading to a version with this split, re-run it once -- the new `pgpm_obtain`
job is not created for you, and without it obtain will not run at all until you do, silently, until the
forward grid runs out and writes start failing. `maintain_all()` also logs a `warn_obtain_unscheduled`
row to `pgpm.log` once per sweep as a backstop for anyone who misses this.

It also creates a third job, `pgpm_detach`, on the `p_every` schedule and **idle** (`select 1`). That one
is machinery for the referenced-partition path: `retire` rewrites its command in place when a partition
an incoming foreign key references needs detaching, and returns it to idle once the drop lands. Leave it
alone: an idle `select 1` is its normal state, and retiring a referenced partition does not work
without it.

### `unschedule`

```sql
pgpm.unschedule() returns int
```

Removes the `pgpm`, `pgpm_obtain` and `pgpm_detach` cron jobs (returns the number removed, so `3` for a
fully scheduled install; `0` if `pg_cron` is absent or nothing was scheduled).

## Control

### `forget_missing`

```sql
pgpm.forget_missing() returns table (parent_oid oid, partitions_forgotten int, orphan_tables text[])
```

Clears pgpm's bookkeeping for every managed table whose relation no longer exists, returning one row per
table it forgot. [`untransmute`](#untransmute) is the sanctioned way to stop managing a table and deletes
these rows itself; a plain `DROP TABLE` does not, because `config.parent_table` is a `regclass` and carries
no dependency. The row then survives pointing at a dead oid, nothing else ever cleans it up, and every
maintenance tick logs `skip_obtain` / `skip_write_block` / `skip_retain` against it forever. A second, quieter
reason not to leave it: PostgreSQL reuses oids, so a stale row is a standing chance of pgpm one day
believing it manages an unrelated table that lands on that oid.

**It takes no argument on purpose.** The relation is gone, so there is no name to pass, and an oid
parameter would be a foot-gun. With no argument the function can only ever match rows whose relation is
*already* absent, so by construction it cannot touch a live managed table -- safe to expose, safe to re-run
(a no-op when nothing is missing).

**It drops nothing.** A *detached* partition survives its parent's `DROP` still holding its rows, and
"detached, not yet dropped" is exactly the state a referenced partition's retirement sits in between the
cron detach and the completing drop. Any such table is reported by name in `orphan_tables` and
left in place -- destroying data as a side effect of a cleanup command would be the worst possible reading
of "forget". Deal with those by hand. `pgpm.log` is also left intact, as the append-only audit trail it is;
the clearance itself is logged `forget_missing`, naming any orphans in `method`.

**It returns `pgpm_detach` to idle when it forgets the retirement that armed it.** A referenced
partition's retirement arms the standing job with `ALTER TABLE <parent> DETACH PARTITION <child>
CONCURRENTLY`, by name. Left armed past the retirement it belonged to, that command would detach the
same-named partition of a table later re-created under the same name and grid, since partition names follow
from the table's name and grid alone. So when the job holds a detach of a partition the forgotten table was
retiring, `forget_missing` puts it back to `select 1`, unless a live retirement owns that exact command (a
re-created namesake already retiring its own partition of that name keeps it).

`orphan_tables` is **schema-qualified**, and deliberately so: `pgpm.part` records no namespace and the
dropped parent's oid can no longer supply one, so the match is on the child's name alone and could in
principle name a same-named table in an unrelated schema. Read the schema before acting on the list.

Find candidates with `status().parent_missing`; see the runbook's
[a managed table was dropped without untransmute](runbook.md#a-managed-table-was-dropped-without-untransmute).

### `resume` / `pause`

```sql
pgpm.resume(p_parent regclass) returns void
pgpm.pause(p_parent regclass)  returns void
```

Flip `config.paused`. `transmute` registers a table paused; `resume` lets scheduled maintenance begin
obtaining, archiving, retaining (and regraining, if enabled). `pause` stops it.

### `set_regrain`

```sql
pgpm.set_regrain(p_parent regclass, p_target_step text default null) returns void
```

Turn auto-regrain on or off. A non-null `p_target_step` (an interval as text for time/uuidv7/text_time, a `bigint`
step as text for id) lets each `maintain` tick feather the oldest frozen coarse child one microbatch
toward that granularity; `null` turns it off (regrain stays operator-driven). A tick reads the target
again when it reaches its regrain step, under the lock `set_regrain` takes, so turning auto-regrain off
while a tick is in an earlier step (archiving, say) stops that tick from starting a regrain. Enabling it is always safe:
`regrain_step` enforces its own preconditions, so an un-meetable tick simply retries, and `maintain` selects
only a frozen coarse child the target subdivides, so a child the target cannot split (a 30-day cell that
starts in February, on a monthly grid) is left alone rather than retried forever; it stays counted in
`status().coarse_partitions`. A `p_target_step` coarser than `partition_step` (compared at
`partition_anchor`) is refused.

Four kinds of target are refused at call time rather than left to wedge every tick: a `p_target_step` of
zero or below (`'0'`, `'-100'`, `'0 days'`, `'-1 month'`: none moves the grid forward, so every tick would
fail or churn), one whose shape the grid cannot place, by the rules `transmute` applies to a
`partition_step` (a month count mixed with a duration such as `'1 month 1 day'` or `'1 month -40 days'`, a
step that is not a whole number of days on a `date` column, a fractional step such as `'2.5'` on an
`int2`/`int4`/`int8` column, and on those columns a whole step written with a fraction such as `'10.0'`,
whose fraction the grid would write into every bound, so the message says to write it as `'10'`; a
step finer than a `numeric(p,s)` column's scale, such as `'0.5'` on `numeric(12,0)` or `'0.05'` on
`numeric(12,1)`, whose fine bounds `ATTACH` would round until two of them meet; a domain is judged by its
base type and typmod; a fractional step on an unconstrained `numeric` column is allowed), one coarser than
`partition_step` (auto-regrain would reselect the same unsplittable child forever), and one whose fine
names `<rel>_p<label>` would exceed PostgreSQL's 63-byte identifier limit.
A finer step has a wider label, so a table whose monthly names fit can still be refused a daily target; the
message names the offending name and says how many bytes to shorten the table name by (see [Partition naming](#partition-naming)).
The names asked about are the ones auto-regrain would render for every child it would split, at both ends
of each, not only the anchor's: on a `numeric` key a cell's label grows with a fractional target's digits,
so the cell after the anchor can need a longer name than the anchor itself.

Turning it **off while the run it started is in flight** abandons that run, exactly as
[`regrain_cancel`](#regrain_cancel) would: the capture trigger and the `TRUNCATE` refusal come off, the
not-yet-attached copies are dropped (the transient disk comes back at once), the delta is cleared, the cursor
is reset, and one `regrain_cancel` row is logged. The source child still holds every row, so only the copy
work is lost. To keep that work, leave auto-regrain on until [`progress`](#progress) shows the swap, then
turn it off. A call that finds auto-regrain already off changes nothing, so it never touches an
operator-driven regrain.

**Changing the target while a run is in flight is refused** (`config.regrain_cursor` set, a
not-yet-attached copy, or change capture on a child). The run's copies and cursor belong to the step it was
started at, which nothing else records, and the rest of the run would be computed on the new step's grid,
collide with them and fail on every tick. Let the run finish (watch [`progress`](#progress)), or abandon it
with [`regrain_cancel`](#regrain_cancel) and set the new target then. Re-stating the target already set is
not a change and is accepted. With auto-regrain off and an operator-driven run in flight, any target is
refused, since that run's step is not recorded.

### `set_obtain`

```sql
pgpm.set_obtain(p_parent regclass, p_obtain int) returns void
```

Change `config.obtain`, the number of partitions `obtain` keeps built ahead of the write frontier.
Refuses a negative `p_obtain`, which would otherwise silently and permanently disable lookahead with
nothing raised. `0` is allowed (no lookahead beyond the partition the frontier is already in). A value
larger than one transaction can build is accepted: each [`obtain`](#obtain) call builds what fits in half
the shared lock table and the next tick builds on from there, so raising the lookahead by thousands of
partitions takes several ticks to fill.

### `set_retain`

```sql
pgpm.set_retain(p_parent regclass, p_retain text default null) returns void
```

Change `config.retain`, the retention horizon `retain()` drops partitions past (`null` = keep forever).
`p_retain` is validated against `control_kind` the same way `transmute` does: `numeric` for `id`, an
interval for `time`/`uuidv7`/`text_time`, and, like `transmute`, it must not be negative, in any of an
interval's fields (a mixed-sign value is refused as `transmute` refuses it). An `id` retain of `NaN` is
refused with the negative values: PostgreSQL orders `NaN` above every number, so its horizon is past every
partition. A negative
value is refused outright, whatever the current value: it puts the horizon past the partition taking
writes, and the guard below compares boundaries, so on its own it cannot see a value that grid-floors to
the current boundary. `'0'` is allowed and keeps only the partition taking writes.

`retain` is the destructive knob -- it decides what gets `DROP`ped -- so `set_retain` **refuses**,
rather than warns, whenever the new value would make the very next `retain()` tick drop a partition
the *old* value still kept. The check runs before anything is written. Loosening (a larger
interval/count, or `null`) can never trip it: a wider horizon only ever keeps a superset of what a
narrower one kept. A tighter value that happens to grid-floor to the same boundary as before (nothing
newly eligible) is also allowed -- the refusal is about what would actually drop, not the raw number.

Loosening does not reopen a partition that chunked archiving has already begun to cover: its write
block stays, it is archived to completion, and the tick that keeps the block logs
`skip_write_block_lift` once. See write-blocking under [`maintain`](#maintain) for why, and for how to
make such a partition writable again.

Loosening also takes back a referenced partition's retirement that the new value no longer reaches. If
`retire` has already pointed the `pgpm_detach` job at that partition's concurrent detach, `set_retain`
returns the job to idle in the same call, before pg_cron can run it, and logs `retain_recall`; the
partition never leaves the parent. If a detach pg_cron had already started lands anyway, the next tick
re-attaches the partition (see [`retire`](#retire)).

Loosening while a regrain is in flight (`config.regrain_cursor` set) raises a **warning**, not a refusal.
Sub-ranges that regrain has already skipped as aged under the old value are re-checked against the new
one at the swap (see [`regrain_step`](#regrain_step)), which refuses while any of them is no longer below
the horizon. The change itself is safe; the swap waits until `retain` is set back or the run is
cancelled with [`regrain_cancel`](#regrain_cancel).

### Handing a table to a new owner (`hand_over_scratch`)

```sql
pgpm.hand_over_scratch(p_parent regclass) returns int
```

`ALTER TABLE <table> OWNER TO <new owner>` reaches neither the table's partitions nor the scratch relations
pgpm keeps beside it while a regrain or a `from_hypertable` migration is in flight (a regrain's delta,
capture function and not-yet-attached copies; a migration's copy, delta and capture function). Hand a table
over by re-owning the table and every partition, then run `hand_over_scratch(<table>)`, which gives every
scratch relation pgpm has recorded for the table to the table's owner as it is now and returns how many it
handed over. Run it as a superuser, or as a role that is a member of both the old owner and the new;
otherwise it refuses, as a tick does. A maintenance tick run by such a role does this on its own, so under
pg_cron as a superuser there is nothing to do. A tick run by a role that can do neither (the new owner, as a
non-superuser) refuses with a `skip_regrain` row whose message begins `run select
pgpm.hand_over_scratch(...)`, and the regrain resumes on the first tick after the step is taken. So does every
other path that drops, empties or truncates those objects, before it changes anything: the tick that prepares
the table's next regrain (it drops what the last one left), `regrain_cancel`, a retirement that reclaims the
source of a regrain in flight, and `untransmute`. The refusal is SQLSTATE `42501` (`insufficient_privilege`).
A retirement with nothing of a regrain to reclaim is not refused. A null table is refused.

### `set_partition_tz`

```sql
pgpm.set_partition_tz(p_parent regclass, p_tz text) returns void
```

Change `config.partition_tz`, the zone the grid is computed in and partition names are rendered in.
`transmute` records the transmuting session's `TimeZone` there and every later boundary is computed in
it whatever zone the maintaining session runs in, so this is normally never called. It exists for the
upgrade case: an install that predates the column has it backfilled to `UTC`, and a table whose grid was
built from a non-UTC session has to be told which zone that was.

`p_tz` must be a name in `pg_timezone_names` (any casing; the canonical spelling is stored). An `id` grid
is refused: it has no calendar and never reads the zone. A `timestamp` or `date` control column is
refused too: it carries no zone, its grid is its own wall clock (recorded as `UTC`), and the zone also
decides how its bound literals are rendered and read, so a change would shift every new partition
against the existing ones. A change is **refused** when the newest
partition's upper bound is not a grid boundary in the new zone, because `obtain` would then skip every
candidate that half-overlaps the current tail and create the first one past it, leaving a permanent
hole. It is refused too when any other attached bound that is a grid boundary in the recorded zone is not
one in the new zone, and the message names the oldest such bound and its partition: two zones can agree
at the top and disagree further down (UTC and `Europe/London` share every month edge from November to
March and none from April to October), and a regrain in the new zone would clamp a sub-range to that
bound, give it the name of the neighbouring cell, and refuse every swap. A bound that is not a grid
boundary in the recorded zone, such as a day child left by a finer regrain, is not judged. A
day-denominated step is the same lattice in every zone and its partitions are named by UTC date,
so its zone can always change and nothing about the grid moves; a month or year step can only be moved to
the zone the grid was in fact built in. A change is also refused while a regrain is in flight: its copies
and cursor are not attached bounds, so the checks above cannot see them, and the rest of the run would be
computed in the new zone, overlap them and fail every swap. Let the run finish, or abandon it with
[`regrain_cancel`](#regrain_cancel), then change the zone. The call also takes turns with
[`obtain`](#obtain) and [`extend_to`](#extend_to) on the same parent: it waits for one in flight to commit
and then judges the grid that call built, and one that starts while a change is uncommitted waits for it
and then builds in the new zone, so neither can leave the grid off the zone it is recorded in. A
`maintain_obtain` tick waits under its own `lock_timeout` and logs `skip_obtain` if the change outlasts it.
Naming the zone already recorded is not a change and is accepted. Each accepted call writes a `set_partition_tz` row to `pgpm.log`
with `old -> new` in `method`.

## Observability

### `status`

```sql
pgpm.status() returns table (
  parent regclass, control_kind text, partition_step text, obtain int, retain text,
  paused boolean, n_partitions bigint, coarse_partitions bigint, inflight_partitions bigint,
  newest_bound text, fks_suspended bigint, fks_unvalidated bigint,
  history_unregrained boolean, retain_drop_failures bigint, retain_backlog bigint,
  retain_detaching bigint, parent_missing boolean, regrain_to text
)
```

One row per managed table. Beyond the static config it surfaces:

- `n_partitions` / `coarse_partitions` -- attached partitions, and how many of those are still coarse
  (wider than one step). Only partitions that still exist count: a row whose partition was dropped by hand
  is not counted, nor is its `hi` the `newest_bound`, until `obtain` rebuilds the cell.
  `coarse_partitions > 0` (and `history_unregrained = true`) is the regraining backlog: pruning and fine
  retention are suspended over that span until it is regrained.
- `inflight_partitions` -- regrain copy-children created but not yet attached. Because regrain copies
  rather than moves, the source stays attached throughout, so a read of the parent is never short and
  these are purely informational.
- `newest_bound` -- the top of the forward grid. This is the write-ahead ceiling: an insert past it is
  refused, since there is no `DEFAULT` to catch it.
- `fks_suspended` / `fks_unvalidated` -- preserve-managed incoming FKs currently dropped (RI off) versus
  re-added `NOT VALID` but blocked from full validation by pre-existing orphans. A standing non-zero
  `fks_suspended` is a `transmute` cutover's preserve drop that
  [`restore_incoming_fks`](#restore_incoming_fks) has not re-added yet: `maintain` re-adds it on the next
  tick, but a paused table (the default after `transmute`) is not maintained, so there it stands until you
  call `restore_incoming_fks` or [`resume`](#resume--pause) the table. A regrain swap drops and re-adds its
  keys inside one transaction, so no other session ever sees it counted here.
- `retain_drop_failures` -- unexpected `DROP` failures since the last successful drop (not a
  child whose chunked archiving simply hasn't caught up yet -- see `retire`). Non-zero means a partition
  is genuinely stuck. Counts `fail_retain_drop`, `fail_retain_crossing` (a live row references an aged
  one and the FK's own `ON DELETE` refused the delete), `fail_retain_detach` (nowhere to dispatch a
  concurrent detach to), `fail_retain_identity` (the partition's name no longer resolves to the
  relation whose detach was dispatched), `fail_archive_identity` (the same mismatch found one step
  earlier, by the archive step, so coverage never completes and the drop gate never opens) and
  `fail_write_block_identity` (the same mismatch one step earlier again, so the partition never
  becomes an archive candidate at all) and `fail_archive_contract` (the archive step refused a
  strategy's returned `covered_hi` that broke the contract, so coverage does not advance), since all
  seven wedge retention the same way. It also counts `fail_retain_reattach`: a partition whose
  retirement retention no longer reaches, taken out of the parent by its detach and not yet put back,
  so its rows are missing from every read of the parent until it is.
- `parent_missing` -- the managed relation itself is **gone**: dropped without
  [`untransmute`](#untransmute), leaving the `pgpm.config` row pointing at an oid that no longer
  resolves. Everything else in the row still reports (it comes from pgpm's own catalog), but the
  partitions went with the table, so `n_partitions` and `coarse_partitions` read 0 and `newest_bound` null,
  and `retain_backlog` is null, because the retention horizon is derived from `max(control)` read from the
  relation and there is no honest answer without it. Clear the state with
  [`forget_missing`](#forget_missing).
- `retain_detaching` -- partitions whose concurrent detach has been dispatched and not yet completed
  Non-zero for a tick or two is normal; persistently non-zero alongside climbing
  `retain_drop_failures` means the dispatch has nowhere to go -- run `pgpm.schedule()`.
- `retain_backlog` -- partitions whose whole range is past the retention horizon but which are not yet
  dropped. Non-zero is normal while `retain_batch` paces a backlog across ticks, or while a write-blocked
  child's chunked archiving is still catching up -- either way it should fall tick over tick. A flat
  `retain_backlog` with climbing `retain_drop_failures` is retention genuinely wedged.
- `regrain_to` -- the auto-regrain target step (`config.regrain_to`), null when auto-regrain is off.
  Whether the history is being split at all is the first thing to check when `coarse_partitions` looks
  stalled, and it is here so that check needs no second query.

### `progress`

```sql
pgpm.progress(p_parent regclass default null) returns table (
  parent regclass, control_kind text, parent_missing boolean,
  frontier text, write_child name, write_ceiling text, freeze_margin text, freeze_in interval,
  coarse_frozen bigint,
  regrain_to text, regrain_child name, regrain_cursor text, regrain_pct_range numeric,
  regrain_rows_copied bigint, regrain_rows_total_est bigint, regrain_delta_pending bigint,
  regrain_started_at timestamptz, regrain_elapsed interval, regrain_eta interval
)
```

The drill-down `status` is not: one table's position in the transmute, freeze, regrain sequence. One row
per managed table, or just `p_parent`'s (an unmanaged table is refused by name rather than answered with
no rows). It answers two questions that otherwise need `pgpm.part`, `pgpm.config`, `pgpm.log` and the
grid arithmetic by hand.

**When will the monolith freeze?** A coarse child can only be regrained once the frontier has moved past
its upper bound, and that bound is what the anchor, the step and any `p_bound_headroom` actually
produced, not what you meant them to.

- `frontier` -- the write frontier in native terms: `now()` for `time`, `max(control)` for `id`,
  `greatest(max(control), now())` for `uuidv7` and `text_time`.
- `write_child` / `write_ceiling` -- the attached partition the frontier sits in, and its upper bound.
  While `write_child` is the monolith, it has not frozen. Null if the grid has fallen behind the frontier.
- `freeze_margin` -- `write_ceiling - frontier`: an interval for the time-grid kinds, a count for `id`.
- `freeze_in` -- the same margin as an `interval`, **only for `time`, `uuidv7` and `text_time`**, whose
  frontier is a clock and so makes this plain arithmetic. For `id` it is **null**: the frontier is
  `max(control)`, pgpm keeps no history of it, and a rate to divide by would be a guess. Read
  `freeze_margin` instead.
- `coarse_frozen` -- coarse partitions whose whole range is already behind the frontier: frozen, and
  eligible for regrain; with `regrain_to` set, only those the target subdivides, which is exactly what
  `maintain` will select. `coarse_frozen > 0` beside a null `regrain_to` is a history that is not going to
  split by itself. `coarse_frozen = 0` beside `coarse_partitions > 0` and a set `regrain_to` is coarse
  history that is either not frozen yet (see `freeze_in`) or that the target cannot split.

**How far along is the regrain, and when does it finish?** Populated while a regrain is in flight
(`config.regrain_cursor` set, and one child carrying change capture); null otherwise.

- `regrain_child` / `regrain_cursor` -- the coarse child being split, and the native lower bound of the
  sub-range currently being copied. The cursor only ever advances, one sub-range at a time.
- `regrain_pct_range` -- `(cursor - lo) / (hi - lo)`: the exact fraction of the child's **range** behind
  the cursor. This is not a row fraction. The cursor moves only when a whole sub-range completes, so it
  sits still while rows pile up in a large one, and a below-horizon sub-range is advanced over without
  being copied, so it can jump ahead of the rows. Read it alongside `regrain_rows_copied`.
- `regrain_rows_copied` -- rows copied by this run, exact, summed from its `regrain_copy` log rows.
- `regrain_rows_total_est` -- `reltuples` of the source child. An estimate, counting every row in the
  source including those in aged sub-ranges that will never be copied; null until the child has been
  analyzed. There is deliberately no fused "N of M rows" figure, because one cannot be produced honestly
  without a full scan.
- `regrain_delta_pending` -- captured changes not yet reconciled. A regrain that returns `reconciling:N`
  tick after tick is waiting on this to fall below `regrain_batch`. Populated whether or not a regrain is
  in flight (0 when idle).
- `regrain_started_at` / `regrain_elapsed` -- when this run's `regrain_prepare` was logged, and how long
  ago that was.
- `regrain_eta` -- `elapsed * (1 - pct_range) / pct_range`: extrapolated from the range fraction observed
  so far, so it inherits that fraction's caveats. **Null until `regrain_pct_range > 0`**, which is the
  whole of the first sub-range: there is nothing to extrapolate from yet, and pgpm does not invent a
  figure.

```sql
select write_child, freeze_in, coarse_frozen, regrain_to from pgpm.progress('public.events');
select regrain_pct_range, regrain_rows_copied, regrain_eta from pgpm.progress('public.events');
```

A parent dropped without [`untransmute`](#untransmute) is reported with `parent_missing = true` and every
frontier-derived column null, the same way `status` does, rather than taking the whole row set down.

### `check_uuidv7`

```sql
pgpm.check_uuidv7(p_table regclass, p_control name, p_sample int default 1000)
  returns table (sampled bigint, plausible bigint, fraction numeric, oldest timestamptz, newest timestamptz,
                 newest_decoded timestamptz, newest_in_future boolean)
```

Samples a `uuid` column and reports the fraction whose decoded 48-bit timestamp prefix is a plausible
recent time. Genuine UUIDv7/ULID scores `~1.0`; random UUIDv4 scores `~0`. A heuristic, not a proof; this
is the check `transmute` runs to gate the uuidv7 kind.

`sampled`, `plausible`, `fraction`, `oldest` and `newest` describe the **sample**. `newest_decoded` does
not: it is the column's actual maximum (its greatest non-null value, however many NULLs the column holds),
found the way `transmute` finds its frontier and decoded, and `newest_in_future` is whether that maximum
sits more than one hour past `now()`. Both are null only when the column holds no non-null value. Look
at these before converting: a single future-dated row (a client with a wrong clock) leaves `fraction` at
`0.99+` and can still pin the monolith's permanent `hi` years out, which is why `transmute` refuses one that
leads the clock by more than one partition step plus one hour (see
[`p_force_frontier`](#transmute-time--uuidv7--text_time-grid)).
Rows to delete or correct are the ones sorting above `pgpm._ts_to_uuid(now() + <step> + interval '1 hour')`.

`check_uuidv7`, `check_text_time` and `check_time_monotonic` refuse a caller whose reads of `p_table`
row-level security would filter, rather than describe the visible rows as the column's (see
[Maintenance steps](#maintenance-steps)).

### `check_text_time`

```sql
pgpm.check_text_time(p_table regclass, p_control name, p_prefix text, p_width int, p_radix int,
                      p_unit text, p_sample int default 1000,
                      p_alphabet text default null, p_discard_bits int default 0,
                      p_epoch timestamptz default '1970-01-01 00:00:00+00')
  returns table (sampled bigint, plausible bigint, fraction numeric,
                 newest_decoded timestamptz, newest_in_future boolean)
```

The `text_time` analogue of `check_uuidv7`: samples a `text`/`varchar` column against a *declared* shape
(the same `p_tt_prefix`/`p_tt_width`/`p_tt_radix`/`p_tt_unit` `transmute` takes) and reports the fraction
that both match the shape and decode to a plausible recent time. A value that does not even match the
shape counts as implausible directly, rather than raising -- one malformed row must not abort the sample.
A heuristic, not a proof; this is the check `transmute` runs to gate the text_time kind.

`newest_decoded` and `newest_in_future` are [`check_uuidv7`](#check_uuidv7)'s: the column's actual maximum
(not the sample's, and NULLs skipped), decoded, and whether it sits more than one hour past `now()`. A
maximum that does not match the declared shape reports `null` rather than raising. Rows to delete or
correct before a refused `transmute` are the ones sorting above
`pgpm._ts_to_text_time(now() + <step> + interval '1 hour', <prefix>, <width>, <radix>, <unit>, ...)`.

Refuses, with the same message `transmute` gives, when the control column's collation does not order the
declared alphabet the way base-`p_radix` place value does (a mixed-case alphabet such as KSUID's base62
on an `en_US` column, or any alphabet with digits under an ICU collation with numeric ordering, which
compares a run of digits by its value). That is not a heuristic and no fraction is reported: RANGE bounds on a `text`
column compare under the column's collation, so any such column would route rows to the wrong
partition. The message names the collation (the effective database locale when the column is on the
default), the first misordered digit pair, the two strings the collation put out of order, and the
remedy, `alter table ... alter column ... type text collate "C"`.

### `check_time_monotonic`

```sql
pgpm.check_time_monotonic(p_table regclass, p_id name, p_time name, p_sample int default 1000)
  returns table (sampled bigint, monotonic bigint, fraction numeric)
```

Samples rows and reports the fraction of adjacent pairs (ordered by the id) whose time is non-decreasing.
`~1.0` means an id column and a timestamp column co-increase; backfills and out-of-order arrival drive it
down. Use it before retaining an id-partitioned table by a time horizon.

### Observability with pg_flight_recorder (`observe`)

Part of `pgpm_core`: functions that correlate `pgpm.log` against
[`pg_flight_recorder`](https://github.com/dventimisupabase/pg_flight_recorder) (PGFR) telemetry. `pgpm.log`
records exactly when pgpm ran each operation, but pgpm keeps no history of what the rest of the database was
doing; PGFR samples that history continuously but does not know which spikes were pgpm's. These functions
bridge the two over a `pgpm.log` time window. It is **read-only and one-directional** (pgpm never writes into
PGFR, and PGFR needs no changes), and PGFR is **never a dependency**: the PGFR-backed functions raise a
`pgpm`-prefixed error when PGFR is absent.

```sql
pgpm.observe_window(p_parent regclass, p_since interval default '7 days') returns table (
  parent_table regclass, window_start timestamptz, window_end timestamptz, duration interval,
  log_rows bigint, rows_copied bigint, regrains bigint, retains bigint
)
```

The span pgpm was active on a table within `p_since`, plus a summary of what it did. **Pure `pgpm.log`** with
no PGFR dependency, so it works (and is useful) standalone.

```sql
pgpm.impact_report(p_parent regclass, p_since interval default '7 days') returns text
```

"What did the conversion do to the workload?" Derives the window with `observe_window`, then asks
`pgfr_analyze` what the database experienced during it: forced checkpoints, WAL generated, temp spilled, top
wait events, and top queries by execution-time delta. Sections degrade independently (a window with fewer
than two PGFR snapshots, or a `pg_stat_statements` that is absent or was reset, is reported, not fatal).
Requires PGFR.

## Incoming foreign keys

These manage the `preserve` lifecycle: an incoming FK dropped at `transmute` is re-added against the new
parent on a later tick, split into a re-add (`NOT VALID`, enforcing new writes) and a later validation so a
pre-existing orphan can never permanently brick restoration. `maintain` calls `restore` automatically; the
others are operator tools.

### `restore_incoming_fks`

```sql
pgpm.restore_incoming_fks(p_parent regclass, p_ids bigint[] default null) returns int
```

Re-adds each dropped preserve-managed FK against the new parent, returning the number re-added. Self-gates
on quiescence: a no-op while an in-flight, not-yet-attached regrain child remains (a standalone table
named like a fine child, recognised exactly as `transmute`'s orphan guard recognises one).

`p_ids` restricts the re-add to specific `pgpm.dropped_fk.id` values instead of every not-yet-restored row
for the parent. Operators calling this directly should leave it at the default (`null`, restore
everything); it exists for regrain's own swap, which restores exactly the keys it suspended and leaves
any other unrestored FK for the next tick.

It re-adds each FK `NOT VALID` and **stops there**. `NOT VALID` already enforces every *new* write, so
referential integrity is live the moment this returns; only pre-existing rows are unverified, which
`status().fks_unvalidated` reports. `maintain` finishes the validation on a later tick.

That split is deliberate. The re-add briefly blocks writes to **both** the referencing table and the
managed parent; validating in the same statement would hold that block across a full scan of the
referencing table, so writes to your managed table would stall for a time set by a table pgpm does not
own. Split, the blocking part is instant and the scan runs later under a lock that blocks no writes.

### `validate_incoming_fks`

```sql
pgpm.validate_incoming_fks(p_parent regclass, p_respect_backoff boolean default false) returns int
```

Finishes validating any preserve-managed FK that was re-added `NOT VALID` but is not yet validated.
Returns the number newly validated; each is isolated, so one still-blocked FK does not stop the others.
In its own transaction the `VALIDATE` holds only `SHARE UPDATE EXCLUSIVE` on the referencing table and
`ROW SHARE` on the parent, neither of which blocks writes.

`maintain` calls this every tick with `p_respect_backoff => true`, which is what completes the validation
without operator action. A *failed* validation re-scans the referencing table to discover it still cannot
succeed, so a failure parks that FK for five minutes (`dropped_fk.validate_retry_after`) rather than
burning that scan every tick. Called by hand it ignores the back-off, since the point of running it
yourself is that you have just cleared the orphans and want the answer now.

### `incoming_fk_orphans`

```sql
pgpm.incoming_fk_orphans(p_parent regclass)
  returns table (referencing_table regclass, constraint_name name, orphan_rows bigint)
```

For each re-added-but-unvalidated FK, the count of orphan rows blocking validation, under the key's own match
type: for `MATCH SIMPLE` (the default), referencing rows with no FK column null that match no parent key; for
`MATCH FULL`, those plus every row with some but not all of its FK columns null, which `VALIDATE` refuses
whatever the parent holds. Handles composite FKs. Use it to find what to clear before `validate_incoming_fks`.

### `suspend_incoming_fks`

```sql
pgpm.suspend_incoming_fks(p_parent regclass, p_force boolean default false) returns int
```

The inverse of restore: re-drops every live preserve-managed FK on the parent, returning how many. Its one
caller is regrain's swap, which passes `p_force => true` and restores the same keys inside the same
transaction, so no other session ever observes referential integrity off; a live `ON DELETE CASCADE` or
`SET NULL` would otherwise silently delete or null referencing rows as their referent left the parent.
Without `p_force` it does nothing, and a null `p_force` is refused (it used to read as `true`). There is no
reason for an operator to call it.

## Catalog

All `pgpm` state lives in these tables. Treat them as read-mostly; use the functions above to mutate them.

### `pgpm.config`

One row per managed table (`parent_table` is the primary key). Columns:

| Column | Type | Meaning |
|---|---|---|
| `parent_table` | `regclass` | the managed partitioned parent |
| `control_column` | `name` | the partition-key column, by the name it had at transmute. pgpm resolves the column through the parent's partition key (its attribute number) on every read, so after `ALTER TABLE ... RENAME COLUMN` of it every step uses the new name; this value is not rewritten |
| `control_kind` | `text` | `time`, `id`, `uuidv7`, or `text_time` |
| `partition_step` | `text` | grid width (`1 month` for time/uuidv7/text_time; a bigint for id) |
| `partition_anchor` | `text` | grid origin, a native value in the same form as `pgpm.part`'s bounds |
| `partition_tz` | `text` | the zone calendar boundaries are computed in and month/year names rendered in: the transmuting session's `TimeZone` (`UTC` for id, and for a `timestamp`/`date` column, whose grid is its own wall clock); change it only with [`set_partition_tz`](#set_partition_tz) |
| `obtain` | `int` | partitions kept ahead of the frontier |
| `retain` | `text` | retention horizon (interval for time/uuidv7/text_time, bigint count for id; null = keep) |
| `retain_batch` | `int` | max partitions one `retain()` call attempts, oldest first (null = unbounded) |
| `regrain_batch` | `int` | rows per regrain COPY microbatch |
| `paused` | `boolean` | maintenance is idle while true |
| `created_at` | `timestamptz` | when transmuted |
| `obtain_retry_after` | `timestamptz` | back-off marker after an obtain lock-race deferral |
| `regrain_max_blocks` | `int` | optional block budget per microbatch (caps wide rows; null = row cap only) |
| `regrain_to` | `text` | auto-regrain target step (null = off; see `set_regrain`) |
| `regrain_cursor` | `text` | how far the in-progress regrain has copied (null = not regraining); [`progress`](#progress) reads it as a fraction of the range |
| `regrain_delta_oid` / `regrain_capture_fn_oid` | `oid` / `oid` | the change-capture delta table and trigger function the last prepare tick minted for this parent, by identity; every reader of the delta resolves them from here, so a rename of the parent mid-regrain is harmless (null until the first regrain; backfilled by an upgrade, only for a pair pgpm provably minted) |
| `regrain_source_mark` | `jsonb` | what the in-flight regrain copies from: the source partition's relfilenode and each column's attnum, recorded by the prepare tick and compared by every later tick, so an `ALTER TABLE` that rewrote the source or replaced a column restarts the run (meaningful only while `regrain_cursor` is set; null before the first regrain, and a null one over copies restarts the run too; an upgrade restarts a run in flight with copies and records the mark of one without) |
| `archive_fn` | `regprocedure` | the pluggable archive strategy (null = `none`); see [Archive strategy contract](#archive-strategy-contract) |
| `archive_byte_budget` / `archive_probe_sample` | `bigint` / `int` | byte-budget chunking knobs for the built-in chunked archiver (see [Byte-budget chunked archiving](#byte-budget-chunked-archiving)) |
| `archive_batch` | `int` | max partitions one `_archive_step` call touches, oldest first (default 1; null = unbounded -- see [Byte-budget chunked archiving](#byte-budget-chunked-archiving)) |
| `sweep_turn_at` | `timestamptz` | when this table last had its turn in a `maintain_all` or `maintain_obtain_all` sweep, each of which visits the oldest turn first (null = never, and goes first); see [`maintain_all`](#maintain_all) |
| `monolith_oid` | `oid` | the original table, now the monolith partition, by identity: recorded by `transmute`, and what [`untransmute`](#untransmute) resolves the monolith through (it refuses when that relation is no longer an attached partition, or when this is null: backfilled by an upgrade when exactly one attached partition predates the parent) |
| `text_time_prefix` / `text_time_width` / `text_time_radix` / `text_time_unit` | `text` / `int` / `int` / `text` | the declared shape for a `text_time` control column (null for every other kind); see `p_tt_prefix` etc. above |
| `text_time_alphabet` / `text_time_discard_bits` / `text_time_epoch` | `text` / `int` / `timestamptz` | non-default digit set, bits to discard, and epoch for a `text_time` column (null/0/Unix epoch for cuid/ULID-shaped ones; see `p_tt_alphabet` etc. above) |

### `pgpm.part`

The registry of managed partitions. `lo`/`hi` are native-grid values as text: for the time kinds
(`time`, `uuidv7`, `text_time`) ISO 8601 with the offset (`2026-10-01 00:00:00+00`), rendered that way
whatever `DateStyle` the writing session had, so a bound reads back as the same instant from any
session; for `id`, the number.

| Column | Type | Meaning |
|---|---|---|
| `parent_table` | `regclass` | the parent |
| `child_name` | `name` | the partition's table name |
| `lo` / `hi` | `text` | native `[lo, hi)` bounds (a partition is coarse when `hi > grid_next(lo)`) |
| `created_at` | `timestamptz` | when created |
| `attached` | `boolean` | false while a regrain is still filling it standalone; true once attached |
| `retiring_at` | `timestamptz` | set when `retire` dispatches a concurrent detach for this partition, so recovery can tell whose detach a pending one was; null for every partition on the ordinary one-step drop path |
| `retiring_oid` | `oid` | which relation that dispatch meant. The detach travels to pg_cron as text naming the partition, and is re-resolved there; this is what lets `retire` refuse to act when the name has stopped resolving to it (see [identity](#what-retire-checks-a-partitions-identity-against)). Null alongside a null `retiring_at`, and for a retirement already in flight when the column was added |
| `child_oid` | `oid` | which relation this row is about, recorded where the partition enters this table (`obtain`, regrain's standalone child, `transmute`'s monolith) rather than at retirement. The write-block step checks `child_name` against it before issuing any DDL, the archive step checks it before reading the child (see [the archive step's identity check](#the-archive-steps-identity-check)), and `retire` checks it before any side effect -- which is what anchors the ordinary one-step `DROP` that `retiring_oid` leaves uncovered (see [identity](#what-retire-checks-a-partitions-identity-against)). A rename does not change an OID, so regrain's own transitional rename leaves it correct. Null reads as unanchored; an upgrade backfills it for every row whose name still resolves |

Primary key `(parent_table, child_name)`. The non-overlap invariant holds over `attached = true` rows
only; an in-flight child may transiently sit inside a still-attached coarse child.

### `pgpm.scratch`

The record of the scratch relations `from_hypertable_copy` makes beside a hypertable, written in the
transaction that creates each one. The drains, the cutover, a re-run of the copy and `uninstall.sql` find
them here, by oid, never by name. (The core's own are recorded where they always were:
`pgpm.config.regrain_delta_oid` and `regrain_capture_fn_oid`, and `pgpm.part.child_oid`.)

| Column | Type | Meaning |
|---|---|---|
| `parent_oid` | `oid` | the hypertable, by oid (a hypertable dropped by hand leaves its rows naming nothing) |
| `kind` | `text` | `hypertable_dest` (the copy), `hypertable_delta` (a tracking copy's delta), or `hypertable_delta_fn` (its trigger function) |
| `obj` | `oid` | the relation (`pg_class`) or, for `hypertable_delta_fn`, the function (`pg_proc`) |

Primary key `(parent_oid, kind)`. The swap removes a hypertable's rows. An upgrade records a copy made by an
earlier release from the comment that release put on it.

### `pgpm.log`

An append-only audit trail. `lo`/`hi` are native bounds in the same form as `pgpm.part`'s, `method` a
free-text detail, `rows` a count.

**Non-success events are prefixed, never suffixed.** A step that was deferred logs `skip_<mechanism>`
and one that failed logs `fail_<mechanism>`, so no non-success action is ever a prefix-extension of the
success it corresponds to. So `action like 'skip_%'` gives every deferral across all mechanisms without
having to enumerate them, and no failure can hide inside a prefix match on a success the way a suffixed
`retain_skip` would hide inside `retain%`. Prefer exact values regardless: `action = 'obtain'`, not
`action like 'obtain%'`, which would also match whatever is added later.

`action` vocabulary:

| Action | When |
|---|---|
| `transmute` / `untransmute` | conversion and its reversal |
| `transmute_resume` | a conversion resumed mid-flight from its recorded bound (crash/restart between phases), rather than starting over |
| `transmute_abort` | a half-finished conversion undone by an explicit `transmute_abort()` call; `method` records that the bound was dropped |
| `transmute_reap` | the same cleanup as `transmute_abort`, but automatic: `maintain_all`'s sweep found an abandoned in-flight conversion (the session that claimed it is gone) and undid it itself |
| `obtain` | a forward partition created (`method` = `plain`) |
| `retain_drop` | a partition dropped by retention (via `retain()` or `retire()`) |
| `retain_detach` / `retain_crossing` / `detach_reap` | a concurrent detach dispatched for a referenced partition / rows deleted to honour a crossing FK's declared `ON DELETE` / an abandoned concurrent detach finalized |
| `retain_recall` / `retain_reattach` | retention stopped reaching a partition whose retirement was under way: its dispatched detach was recalled and the `pgpm_detach` job returned to idle / the detach had already landed, and the partition was re-attached on its own bounds (see [`retire`](#retire)) |
| `regrain_copy` / `regrain_aged` / `regrain_attach` / `regrain` | a regrain microbatch copied rows into a fine child / skipped a below-horizon sub-range that has no fine child yet (only when `archive_fn` is unset; discarded with the source, never copied, once the swap has re-checked that it is still below the horizon) / attached a fine child (`method` = `check_skip`) / completed (`method` = `copy_swap_drop`) |
| `regrain_prepare` / `regrain_capture_orphan` / `regrain_reconcile` / `regrain_reconcile_aged` / `regrain_rename` / `regrain_restart` / `regrain_cancel` | the cross-tick regrain's own steps: change capture installed / a leftover capture table cleared / the source-is-authority reconcile before the swap (and its below-horizon counterpart) / the source renamed onto the target grid / a stale run restarted (copies that predate capture, or copies a parent altered mid-regrain made stale: their columns or `CHECK` constraints no longer match, the source was rewritten or had a column replaced, or change capture no longer fits the key, or copies no recorded source mark vouches for, as a run in flight across an upgrade has, or change capture's trigger found disabled, origin-only or replica-only rather than enabled `ALWAYS`) / a run cancelled by `regrain_cancel()`, or by `retire` dropping the run's source whole (`method` names `retire`, `rows` counts the copies discarded) |
| `drop_incoming_fk` / `suspend_incoming_fk` / `restore_incoming_fk` / `validate_incoming_fk` | preserve-FK lifecycle events |
| `from_hypertable_carry_fk` | (`pgpm_hypertable` only) an outgoing FK re-added onto the migrated destination during `from_hypertable_copy` |
| `forget_missing` | `forget_missing()` cleared a parent's registration because its relation no longer exists; `rows` carries how many partition rows were cleared with it |
| `forget_dropped_partition` | `obtain` or `extend_to` found an attached `pgpm.part` row over a cell it was about to judge whose partition no longer exists (dropped by hand, outside pgpm), forgot the row and built the cell again, empty (logged `obtain` next, or `fail_obtain_name` if something else holds its name). `method` names the dropped partition and its OID. Logged once per dropped partition |
| `forget_incoming_fk` | a `pgpm.dropped_fk` record was forgotten because the catalog no longer backs it: its referencing table was dropped, or a key recorded as re-added is no longer on that table (see [`pgpm.dropped_fk`](#pgpmdropped_fk)). `method` names the key and which of the two it was |
| `adopt_incoming_fk` | a `pgpm.dropped_fk` record still marked dropped was marked re-added because its key is live again, re-added by hand on its referencing table under its name and against this table (see [`pgpm.dropped_fk`](#pgpmdropped_fk)). `method` names the key, and says `NOT VALID` when the live key is not validated yet |
| `archive_coverage_reset` | `pgpm.archive_ledger` rows were discarded because the coverage they record cannot be vouched for; `rows` carries how many chunks and `method` says why. Three causes: the partition they were recorded for has no write block in force on it (absent, disabled, or origin-only: coverage nothing has been guarding, see [`maintain`](#maintain) and [`retire`](#retire)); they were recorded under a `child_name` that is no longer a tracked partition of the parent, over a range a tracked partition now holds (a partition renamed without carrying the ledger, see [the archive step](#byte-budget-chunked-archiving)); or a `regrain` swap dropped a partly archived source, whose chunks go with it (see [`regrain`](#regrain)). In every case the partition holding the range archives again from its own `lo` |
| `warn_replica_identity_nothing` | a partition was minted (by `obtain`, `extend_to` or a regrain's swap) for a parent whose `REPLICA IDENTITY USING INDEX` index was dropped, a state PostgreSQL treats as `NOTHING`, so the partition took `NOTHING` (see the replica identity paragraph under `transmute`). Logged at most once per transaction for the parent; `method` names the first such partition. Each one keeps `NOTHING` after the parent is given an identity again, so give it the identity by hand |
| `warn_obtain_unscheduled` | logged at most once per `maintain_all` sweep, with a null `parent_table`, when the `pgpm` cron job exists but `pgpm_obtain` doesn't -- obtain is silently not running |
| `skip_obtain` / `skip_retain` / `skip_regrain` / `skip_regrain_capture` / `skip_archive` / `skip_write_block` / `skip_restore_fk` / `skip_validate_fk` | a step deferred (lock race or transient error; `method` carries the reason) |
| `skip_transmute_reap` | `maintain_all`'s sweep found an abandoned conversion but could not take the table's lock within 5 s (a long transaction holds it), so it left the bound and the claim in place for the next tick rather than queue every read and write of the table behind it; `method` carries the lock timeout |
| `write_block_reenable` | a partition's retention write block was found disabled, `ENABLE REPLICA` or origin-only and was put back `ENABLE ALWAYS` (see [`maintain`](#maintain)); `method` names the partition and the state it found. Logged once per re-enable |
| `skip_write_block_lift` | a partition retention no longer reaches kept its write block, because `pgpm.archive_ledger` already covers it and that coverage is only true while nothing can write to it. Logged once per partition, on the first tick that would otherwise have lifted the block; `method` says how to make the partition writable again (see [`maintain`](#maintain)) |
| `fail_restore_incoming_fk` / `fail_validate_incoming_fk` | a preserve-FK re-add failed / a validation was blocked by an orphan, or either did not get its table's lock in time |
| `fail_retain_drop` / `fail_retain_detach` / `fail_retain_crossing` / `fail_detach_reap` | an unexpected `DROP` failure, or a partition detached by something other than pgpm, which `retire` leaves alone / no `pgpm_detach` job to dispatch the detach to (run `pgpm.schedule()`) / a `NO ACTION`/`RESTRICT` FK blocked the crossing delete / finalizing an abandoned detach failed (including its 5 s lock wait running out behind a reader of the partition, retried next tick). In every case the partition is left whole and `method` carries the error |
| `fail_retain_reattach` | a partition retention no longer reaches, which its dispatched detach had already taken out of the parent, could not be re-attached (a lock timeout, or something else now holds its range). The table and its rows are left whole, `method` carries the error, and the next tick tries again. Counts in `status().retain_drop_failures` |
| `fail_retain_identity` / `fail_archive_identity` / `fail_write_block_identity` | a partition's name no longer resolves to the relation pgpm recorded for it, so `retire` refused to detach or drop it (see [identity](#what-retire-checks-a-partitions-identity-against)) / the archive step refused to read it (see [the archive step's identity check](#the-archive-steps-identity-check)) / the write-block step refused to put its trigger on it. `method` names the OIDs and, for the first, which anchor disagreed. None clears itself on a later tick |
| `fail_obtain_name` | `obtain` or `extend_to` left the cell `[lo, hi)` unbuilt because its name is held by a relation that is not one of the table's partitions or by a type (an enum, domain or range type, since a table's row type takes its name), or its explicit-range stand-in is taken or over 63 bytes (see [Partition naming](#partition-naming)); every write into the range is refused until the name is freed. `method` names what holds it. Repeats once per tick until the cell is built |
| `fail_archive_contract` | the archive step refused what the archive strategy returned: `covered_hi` was null, not above the chunk's `lo`, past its `hi`, or not a native value, so no ledger row was written and coverage did not advance (see [the archive step's contract check](#the-archive-steps-contract-check)). `method` names the strategy, the chunk, the value returned and the rule it broke. Repeats once per tick until the strategy is corrected, and clears itself once it is |

### `pgpm.dropped_fk`

Preserve-managed incoming FKs and their lifecycle.

| Column | Type | Meaning |
|---|---|---|
| `id` | `bigint` | identity |
| `parent_table` | `regclass` | the referenced parent |
| `referencing_table` | `regclass` | the table holding the FK. Follows the table through pgpm's own renames: a self-referential key names the new parent, and a later `transmute` (or `untransmute`) of the referencing table moves the anchor onto its new parent (or restored table), never onto a monolith partition |
| `constraint_name` | `name` | the FK name |
| `definition` | `text` | the captured FK definition, naming the referenced table schema-qualified as it was named at the capture. It is a record, not the statement replayed: every re-add points it at the table the record names by OID, under its name and schema as they are then (`parent_table` for `restore_incoming_fks` and regrain's swap, the restored table for `untransmute`), so a table moved with `SET SCHEMA` or renamed since gets its key back, and a table that took its old name does not |
| `restored_at` | `timestamptz` | null = dropped (RI off); set = re-added |
| `validated_at` | `timestamptz` | set = fully validated; null with `restored_at` set = re-added `NOT VALID` (orphans pending) |
| `dropped_at` | `timestamptz` | when the FK was captured and dropped |

A record names its referencing table by OID, and nothing ties the two together after the capture, so
`pgpm` reconciles the records with the catalog before it acts on them. `untransmute`, regrain's swap
(through `suspend_incoming_fks`), `restore_incoming_fks` and `validate_incoming_fks` each first forget a
record whose referencing table no longer exists, and a record marked re-added whose key is no longer on its
referencing table, logging each as `forget_incoming_fk`, and then go on with the rest. So dropping a
referencing table, or one of these keys, is ordinary DDL: the managed table can still be reversed and
regrained, and the key you dropped is not put back. A key recorded as dropped (`restored_at` null) is absent
by design until it is restored, and is kept.

The same four paths adopt a key recorded as dropped that you have put back yourself (the remedy
uninstall's refusal offers): a foreign key on the record's referencing table, under its name, against the
managed table. The record is marked re-added (and validated if the live key is), logged
`adopt_incoming_fk`, so `restore_incoming_fks` does not try to add it a second time and `untransmute` drops
and re-adds it like any restored key. A key that only shares the name, against another table, is not
adopted: the re-add keeps failing on it as `fail_restore_incoming_fk`, because the name is taken. The
uninstall script asks the same question before it exempts a record from its refusal, so such a key does not
let the record go with the schema.

### `pgpm.transmute_inflight`

One row per conversion currently between transactions. Written when `transmute` adds the monolith's bound
and deleted when the cutover commits, so a row that outlives its session is exactly the evidence
`maintain_all`'s sweep and [`transmute_abort`](#transmute_abort) act on. A row here means the table still
carries a `pgpm_monolith_bound` `CHECK` and is refusing writes outside `[lo, hi)`.

| Column | Type | Meaning |
|---|---|---|
| `parent_table` | `regclass` | the table being converted (primary key) |
| `nsp` / `rel` | `name` | its schema and name as of the conversion's start, so the bound can still be dropped by name after the rename |
| `control_kind` | `text` | `time`, `id`, `uuidv7` or `text_time` |
| `lo` / `hi` | `text` | the native bounds the `CHECK` is enforcing; a retry reuses these rather than recomputing |
| `partition_tz` | `text` | the zone `lo` and `hi` were computed in; a retry adopts it along with them, whatever zone its own session runs in (null on a row written before the column existed, which a retry reads as "keep this session's zone") |
| `control_attnum` | `smallint` | the attribute number of the control column `lo` and `hi` were computed on, which the `CHECK` constrains; a retry on another column is refused, one on the same column under a new name resumes (null on a row written before the column existed, which a retry does not check) |
| `started_at` | `timestamptz` | when the conversion added the bound |

### `pgpm.archive_ledger`

One row per archived chunk. See [Byte-budget chunked archiving](#byte-budget-chunked-archiving).

| Column | Type | Meaning |
|---|---|---|
| `parent_table` | `regclass` | the managed partitioned parent (primary key with `lo`) |
| `lo` | `text` | native-grid start of this chunk |
| `hi` | `text` | native-grid end of this chunk |
| `child_name` | `name` | the child this chunk belongs to |
| `s3_key` | `text` | set by a real transport strategy; null for a strategy with nothing object-store-shaped to name |
| `etag` | `text` | set by a real transport strategy; null for a strategy with nothing object-store-shaped to name |
| `rows_archived` | `bigint` | rows this chunk archived; null if the strategy reported no progress |
| `archived_at` | `timestamptz` | when this chunk was recorded |

## Partition naming

A fine (one-step) partition is named `<rel>_p<lo>`; a coarse or monolith partition (wider than one step)
is `<rel>_p<lo>_to_<hi>`, both bounds formatted at the step's granularity:

- time/uuidv7/text_time: `events_p2026_03` (a fine month), `events_p2026_03_to_2026_07` (the monolith)
- id: `events_p0000000000000010000`, `events_p0000000000000000000_to_0000000000000060000`

Each label is fine enough for its step, so no two cells of a grid share a name: a year, month, day or
hour step is labelled at that grain, a step of a minute or more to the minute (`events_p2026_03_01_0930`),
a step under a minute to the second (`events_p2026_03_01_093030`) and a step under a second to the
microsecond (`events_p2026_03_01_093030_500000`). An id label is zero-padded to 19 digits and never cut:
a value of 20 digits or more (a `numeric` key at or past 10^19) keeps every digit
(`events_p10000000000000000000`), and a non-integral value, which only a regrain toward a fractional step
on a `numeric` column produces, carries its fraction (`events_p0000000000000000001_5` for 1.5). A time
label in a year before the common era carries `_bc` (`events_p0001_06_01_bc`), so year N BC and year N AD
never share one.

Month and year labels are rendered in `config.partition_tz`, the zone those calendar cells are defined
in. Day and shorter labels are rendered in UTC: those steps are a fixed number of seconds from the anchor
whatever the zone, and in a zone with daylight saving the day lattice drifts an hour against local
midnight twice a year, so two adjacent day cells could otherwise start on the same wall date (as two
adjacent hour cells share a wall hour every autumn) and share a name. UTC never repeats a date or an
hour.

A regrain toward a fixed step clamps a child's first cell to the child's own lower bound when that bound
is off the target's lattice: a monthly grid in `America/New_York` regrained to `'1 day'` starts February at
05:00Z while the day cells start at 00:00Z, so February's first cell is `[02-01 05:00Z, 02-02 00:00Z)`. A
label at the step's grain is the floor of the instant, which that cell shares with the cell beside it (here
January's last, `[02-01 00:00Z, 05:00Z)`, `events_p2024_02_01`), so a clamped cell is labelled at the
coarsest grain, no coarser than the step's, at which both its bounds read exactly: `events_p2024_02_01_05`,
`events_p2024_01_31_1830` for a month edge in `Asia/Kolkata`, down to the microsecond. A clamped cell
whose bounds already read exactly at the step's grain (a weekly regrain of a UTC monthly grid) keeps the
plain name, and every cell on the lattice keeps its name. The finer label makes the name up to 14 bytes
longer; one that would exceed 63 bytes is refused like any other (see below): `set_regrain` refuses the
target at call time when a partition auto-regrain would split needs it, `regrain` raises, and auto-regrain
(for a table renamed after `set_regrain` accepted its target) logs `skip_regrain` on each tick until the
table is renamed to a shorter name.

A regrain toward a calendar step (`'1 year'`, `'3 months'`) follows the same rule, with the year and the
month read in `partition_tz` as the two coarsest grains. A year lattice starts in the month the anchor reads
in `partition_tz`, which is December anywhere west of UTC with the default anchor: a monthly
`America/New_York` monolith starting 2023-03-01, regrained to `'1 year'`, clamps its first cell to
`[2023-03-01, 2023-12-01)`, labelled `events_p2023_03`, while the lattice cell after it,
`[2023-12-01, 2024-12-01)`, keeps `events_p2023`. A clamp whose bounds read exactly as whole years (on a
`'2 years'` step) or whole months (a quarter) keeps the plain name.

A day or week partition created before that rule keeps the name it was given, the wall date of its start
in `partition_tz`. East of UTC, with the grid anchored at local midnight, that is exactly the UTC date
of the cell after it, so on such a grid the next cell's plain name is already taken. When `obtain` or
`extend_to` finds a missing cell's plain name held by one of the same parent's partitions over a
different range, it builds the cell under its explicit-range name (`events_p2026_10_02_to_2026_10_03`,
one step wide) and leaves the older partition untouched. A name held by anything else still stops the
cell from being built (a relation, or a type such as an enum or domain, since a table's row type takes
its name), and so does an explicit-range name that would exceed 63 bytes (it is 14 bytes longer
than a day cell's plain name, so a table name of 38 to 51 bytes meets this): that one cell is left unbuilt,
never under a cut name, and the cells after it are built. Renaming the table to a name that fits frees it.
Each time `obtain` or `extend_to` leaves a cell unbuilt this way it logs `fail_obtain_name` for the cell's
range, naming what holds the name, so the hole shows in `pgpm.log` before a write into it is refused.

The name is a human-facing label; `pgpm.part` holds the authoritative bounds. The `_to_` form is also
what keeps `transmute`'s orphan check from mistaking a monolith for a leftover of an interrupted regrain.

**Names are never truncated.** PostgreSQL cuts an identifier to 63 bytes, and a cut label would make two
cells share a name, which `obtain`, `extend_to` and `regrain_step` read as "already exists" and skip: the
forward grid would silently stop growing. So `transmute` refuses a table whose derived names (the
monolith's, the fine cells', the `<rel>_pgpm_new` staging name) would not fit, naming the offending name
and the bytes to shorten the table name by, refuses a secondary index whose `<index>_pgpm` copy would not
fit (an index name of at most 58 bytes does; the key's name needs no room, because the monolith's copy of
the key takes `pgpm_key_<index oid>`, which always fits), and `set_regrain` refuses a target step whose wider labels
would not fit. The budget, in bytes: a fine name is `len(<rel>) + 2 + label`, the monolith's is
`len(<rel>) + 6 + 2 * label`, the staging name is `len(<rel>) + 9`, where the label is 4 (year), 7 (month),
10 (day), 13 (hour), 15 (minute), 17 (second), 24 (microsecond) or 19 (id, longer past 19 digits or with a
fraction). A monthly grid therefore takes a table name of up to 43 bytes when the data spans more than one
month (a coarse monolith) and 54 when it does not; an id grid, whose labels are 19 digits, takes 19 and 42.

## Internal adapter layer

Functions named `pgpm._*` are private and may change without notice. The kind-specific logic lives in a
small adapter (`_grid_floor`, `_grid_next`, `_encode`, `_decode`, `_frontier_native`, `_part_name`/`_id_label`,
`_native_gt`, `_native_type`), which is where a new partition kind would plug in; the rest (`_transmute`,
`_create_partition`, `_uuid_to_ts`/`_ts_to_uuid`, `_time_literal`/`_col_to_native`/`_canonical_tz`,
`_install_write_block`/`_remove_write_block`/`_enforce_write_blocks`/`_is_write_blocked`,
`_run_archive_strategy`/`_archive_noop`,
`_next_archive_chunk`/`_archive_fully_covered`/`_archive_step`) implements the engine. Do not call
them directly.
