# The mutant: archive._encode_upload_ndjson_single (behind pgpm.archive_to_s3_ndjson) writes every line with
# "id":1 in place of the row's own numeric id; the line count, rows_archived and the rows digest are unchanged.
import sys
src = open(sys.argv[1]).read()
old = "string_agg(row_to_json(t.*)::text, e''\\n'' order by t.%I)"
new = "string_agg(regexp_replace(row_to_json(t.*)::text, ''\"id\":[0-9]+'', ''\"id\":1''), e''\\n'' order by t.%I)"
assert src.count(old) == 1, src.count(old)
sys.stdout.write(src.replace(old, new))
