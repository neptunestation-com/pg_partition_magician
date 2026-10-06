"""Split operator markdown into sentences that a doc guard can hold to a measured fact.

Shared by the bench/doc_*.sh guards that check a sentence of the docs against pgpm's own behaviour
(bench/doc_archive_identity_recovery.sh, bench/doc_fks_suspended_meaning.sh,
bench/doc_monolith_retention.sh, bench/doc_transmute_no_default.sh). Each guard measures a fact in the harness first, then asks this module
for every sentence of the living docs and decides which of them state that fact.

What a sentence is, here. Fenced code is skipped whole (its blank lines do not split anything). Prose is
cut into BLOCKS at blank lines, at headings, at the start of every list item and at every table row, so a
list item's sentences never borrow context from the item beside it. A block is flattened to one line and
cut into sentences at `.`, `!` or `?` followed by whitespace. Every sentence carries its block, the
heading of the section it sits in, the full text of that section, and the line its block starts on.

`plain()` drops markdown emphasis (`**`, `*`) so a bold word reads as the word.
"""
import os
import re

FENCE = re.compile(r"^\s*(```|~~~)")
HEADING = re.compile(r"^\s{0,3}#{1,6}\s+(.*)$")
ITEM = re.compile(r"^\s*(?:[-*+]|\d+[.)])\s+")
TABLE = re.compile(r"^\s*\|")
SPLIT = re.compile(r"(?<=[.!?])\s+")


def plain(s):
    return re.sub(r"\*+", "", s)


class Sentence:
    __slots__ = ("doc", "line", "heading", "section", "block", "text")

    def __init__(self, doc, line, heading, section, block, text):
        self.doc, self.line, self.heading = doc, line, heading
        self.section, self.block, self.text = section, block, text


def _blocks(text):
    """Yield (start_line, heading, section_index, block_text) for every prose block."""
    heading, sec, cur, start, fenced = "", 0, [], 0, False
    for n, raw in enumerate(text.split("\n"), 1):
        if FENCE.match(raw):
            if cur:
                yield start, heading, sec, " ".join(cur)
                cur = []
            fenced = not fenced
            continue
        if fenced:
            continue
        h = HEADING.match(raw)
        if h or raw.strip() == "" or ITEM.match(raw) or TABLE.match(raw):
            if cur:
                yield start, heading, sec, " ".join(cur)
                cur = []
            if h:
                heading, sec = h.group(1).strip(), sec + 1
                continue
            if raw.strip() == "":
                continue
        if not cur:
            start = n
        cur.append(raw.strip())
        if TABLE.match(raw):
            yield start, heading, sec, " ".join(cur)
            cur = []
    if cur:
        yield start, heading, sec, " ".join(cur)


def sentences(text, doc="<text>"):
    blocks = list(_blocks(text))
    sections = {}
    for _, _, sec, block in blocks:
        sections.setdefault(sec, []).append(block)
    out = []
    for line, heading, sec, block in blocks:
        flat = re.sub(r"\s+", " ", block).strip()
        section = " ".join(sections[sec])
        for s in SPLIT.split(flat):
            if s.strip():
                out.append(Sentence(doc, line, heading, section, flat, s.strip()))
    return out


def living_docs(root):
    """The operator-facing markdown a doc guard scans when it is given no single file."""
    docs = [os.path.join(root, "ONBOARDING.md"), os.path.join(root, "README.md"),
            os.path.join(root, "pgpm_archive", "README.md")]
    docs += sorted(os.path.join(root, "docs", f) for f in os.listdir(os.path.join(root, "docs"))
                   if f.endswith(".md"))
    return [d for d in docs if os.path.isfile(d)]


def rel(root, path):
    return os.path.relpath(path, root) if path.startswith(root + os.sep) else path
