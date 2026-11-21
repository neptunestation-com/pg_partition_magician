-- The objects the invariant oracle's ArchiveNoClobber reads, for tests/formal/load_store.py (formal methods Phase 3 W4).
-- One line per retired chunk with a key, of every parent archived to the archive track's own MinIO bucket, plus one
-- line with no key per such parent, so a parent with nothing retired is still listed (judged over no chunk, not
-- skipped). Parents archived anywhere else (a test's unreachable endpoint, another bucket) are left out: their
-- objects cannot be read, so ArchiveNoClobber says it did not judge them. Nothing when a file uninstalled either module.
--   <parent oid> <TAB> <endpoint> <TAB> <bucket> <TAB> <key>
select to_regclass('archive.config') is not null and to_regclass('pgpm.archive_ledger') is not null as have_archive \gset
\if :have_archive
select c.parent_table::oid, c.endpoint, c.bucket, coalesce(l.s3_key, '')
  from archive.config c
  left join pgpm.archive_ledger l on l.parent_table = c.parent_table and l.s3_key is not null and l.retired_at is not null
 where c.endpoint = 'http://minio:9000' and c.bucket = 'archive-test-bucket'
union
select c.parent_table::oid, c.endpoint, c.bucket, ''
  from archive.config c
 where c.endpoint = 'http://minio:9000' and c.bucket = 'archive-test-bucket';
\endif
