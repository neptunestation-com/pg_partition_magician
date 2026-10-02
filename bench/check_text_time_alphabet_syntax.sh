#!/usr/bin/env bash
# Run tests/232_check_text_time_alphabet_syntax_test.sql against an ARBITRARY copy of
# pgpm_core/install.sql, so bench/discriminate.sh can point it at a mutant. The harness is
# bench/grid_timezone.sh's, selected by its GRID_TZ_TEST_FILE override: same fresh database, same
# install-must-succeed check, same "the assertions were reached at all" count, so read that file's header
# for why a wrapper around a plain pgTAP file exists at all.
#
# What THIS file guards (issue #837): check_text_time decides "has the declared shape" with
# pgpm._text_time_shaped, for the sample and for the column's maximum alike, so an alphabet is read as
# data. It used to splice the alphabet raw into the regex '[^' || alphabet || ']': '-' between two
# characters made a range, so under '+-0123456789' a value with ',' in its timestamp field counted as
# shaped, raised in _text_time_to_ts and aborted the sample and transmute's sampling step; a backslash
# left the bracket unclosed and raised on every column. tests/232 pins the counts, the maximum and both
# conversions, with a default-alphabet control (the same malformed row was always counted implausible
# there) and witnesses that the malformed row really is malformed and that the raw regex really misreads
# it. This wrapper proves the file would notice.
#
# The mutation it is required to fail against (bench/mutations/mutate.py):
#   check_text_time_alphabet_regex  -- both shape tests are the raw bracket-expression regex again
#
# Usage: check_text_time_alphabet_syntax.sh <container> <db> [install.sql]
set -uo pipefail
GRID_TZ_TEST_FILE="${CHECK_TEXT_TIME_ALPHABET_SYNTAX_TEST_FILE:-/repo/tests/232_check_text_time_alphabet_syntax_test.sql}" \
GRID_TZ_LABEL="check_text_time reads the alphabet as data" \
exec bash "$(dirname "$0")/grid_timezone.sh" "$@"
