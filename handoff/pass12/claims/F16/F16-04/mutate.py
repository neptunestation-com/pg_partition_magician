# The mutant: archive._encode_upload_parquet (behind pgpm.archive_to_s3_parquet) PUTs only the file's first four
# bytes, the magic PAR1, while it still ledgers the rows it encoded.
import sys
src = open(sys.argv[1]).read()
fn = src.index("create or replace function archive._encode_upload_parquet(")
old = "'application/vnd.apache.parquet', v_payload, v_key_id, v_secret);"
at = src.index(old, fn)
assert at < src.index("$$;", fn), "the PUT is not inside archive._encode_upload_parquet"
new = "'application/vnd.apache.parquet', substring(v_payload from 1 for 4), v_key_id, v_secret);"
sys.stdout.write(src[:at] + new + src[at + len(old):])
