#!/usr/bin/env python3
"""Convert an Urban Dictionary data dump into Apple Dictionary Development Kit XML.

Input: one or more CSV, JSON (array of objects) or JSONL files. Column names are
matched against common aliases used by public Urban Dictionary dumps (e.g. the
Kaggle "urbandict-word-defs.csv": word_id, word, up_votes, down_votes, author,
definition), so most dumps work without configuration.

Output: a single XML file ready for the DDK's build_dict.sh.

Only the Python standard library is used.
"""

from __future__ import annotations

import argparse
import csv
import html
import json
import re
import sys
import unicodedata
from collections import Counter, defaultdict
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, Iterator

# Canonical field -> accepted column names (compared case-insensitively).
FIELD_ALIASES: dict[str, tuple[str, ...]] = {
    "word": ("word", "term", "title", "headword"),
    "definition": ("definition", "meaning", "def", "definitions"),
    "example": ("example", "examples", "usage"),
    "up": ("up_votes", "thumbs_up", "upvotes", "up", "likes"),
    "down": ("down_votes", "thumbs_down", "downvotes", "down", "dislikes"),
    "author": ("author", "user", "username", "contributor"),
    "date": ("written_on", "date", "created_at", "timestamp"),
    "defid": ("defid", "word_id", "id", "definition_id"),
}

# Characters that are illegal in XML 1.0.
_INVALID_XML = re.compile("[\x00-\x08\x0b\x0c\x0e-\x1f￾￿]")
# Urban Dictionary marks cross-references as [term].
_BRACKET_LINK = re.compile(r"\[([^\[\]\n]{1,100})\]")
_WS = re.compile(r"[ \t]+")


@dataclass
class Definition:
    word: str
    definition: str
    example: str
    up: int
    down: int
    author: str
    date: str
    defid: str

    @property
    def score(self) -> int:
        return self.up - self.down

    @property
    def ratio(self) -> float:
        total = self.up + self.down
        return self.up / total if total else 0.0


# --------------------------------------------------------------------------- #
# Reading
# --------------------------------------------------------------------------- #

def _resolve_columns(keys: Iterable[str]) -> dict[str, str]:
    lowered = {k.strip().lower(): k for k in keys if k is not None}
    mapping: dict[str, str] = {}
    for field, aliases in FIELD_ALIASES.items():
        for alias in aliases:
            if alias in lowered:
                mapping[field] = lowered[alias]
                break
    missing = {"word", "definition"} - mapping.keys()
    if missing:
        raise ValueError(
            f"input is missing required column(s) {sorted(missing)}; "
            f"found columns: {sorted(lowered)}"
        )
    return mapping


def _to_int(value: object) -> int:
    if value is None or value == "":
        return 0
    try:
        return int(float(str(value).replace(",", "").strip()))
    except ValueError:
        return -1  # sentinel: malformed row


def _iter_raw(path: Path) -> Iterator[dict]:
    suffix = path.suffix.lower()
    if suffix in (".jsonl", ".ndjson"):
        with path.open(encoding="utf-8", errors="replace") as fh:
            for line in fh:
                line = line.strip()
                if line:
                    try:
                        obj = json.loads(line)
                    except json.JSONDecodeError:
                        continue
                    if isinstance(obj, dict):
                        yield obj
    elif suffix == ".json":
        with path.open(encoding="utf-8", errors="replace") as fh:
            data = json.load(fh)
        if isinstance(data, dict):  # e.g. API response {"list": [...]}
            data = data.get("list", [])
        for obj in data:
            if isinstance(obj, dict):
                yield obj
    else:  # treat everything else as CSV/TSV
        csv.field_size_limit(sys.maxsize)
        with path.open(encoding="utf-8", errors="replace", newline="") as fh:
            sample = fh.read(65536)
            fh.seek(0)
            try:
                dialect = csv.Sniffer().sniff(sample, delimiters=",\t;|")
            except csv.Error:
                dialect = csv.excel
            yield from csv.DictReader(fh, dialect=dialect)


def read_definitions(paths: Iterable[Path], stats: Counter) -> Iterator[Definition]:
    for path in paths:
        mapping: dict[str, str] | None = None
        for raw in _iter_raw(path):
            if mapping is None:
                mapping = _resolve_columns(raw.keys())
            stats["rows"] += 1

            def get(field: str) -> str:
                col = mapping.get(field)
                val = raw.get(col) if col else None
                return "" if val is None else str(val)

            word = clean_text(get("word")).strip()
            definition = clean_text(get("definition")).strip()
            up, down = _to_int(get("up")), _to_int(get("down"))
            if not word or not definition or up < 0 or down < 0:
                stats["malformed"] += 1
                continue
            yield Definition(
                word=_WS.sub(" ", word),
                definition=definition,
                example=clean_text(get("example")).strip(),
                up=up,
                down=down,
                author=clean_text(get("author")).strip(),
                date=get("date").strip(),
                defid=get("defid").strip(),
            )


# --------------------------------------------------------------------------- #
# Filtering
# --------------------------------------------------------------------------- #

def clean_text(text: str) -> str:
    text = unicodedata.normalize("NFC", text)
    text = text.replace("\r\n", "\n").replace("\r", "\n")
    return _INVALID_XML.sub("", text)


def normalize_key(word: str) -> str:
    return _WS.sub(" ", word.casefold().strip())


def select_entries(
    defs: Iterable[Definition],
    *,
    min_up: int,
    min_ratio: float,
    max_defs: int,
    max_words: int | None,
    max_word_len: int,
    stats: Counter,
) -> dict[str, list[Definition]]:
    """Return {normalized word: [best definitions, highest score first]}."""
    grouped: dict[str, list[Definition]] = defaultdict(list)
    for d in defs:
        if len(d.word) > max_word_len:
            stats["rejected_long_word"] += 1
            continue
        if d.up < min_up or d.ratio < min_ratio:
            stats["rejected_votes"] += 1
            continue
        grouped[normalize_key(d.word)].append(d)
        stats["kept_candidates"] += 1

    selected: dict[str, list[Definition]] = {}
    for key, items in grouped.items():
        # Dumps sometimes contain the same definition twice; dedupe by text.
        seen: set[str] = set()
        unique = []
        for d in sorted(items, key=lambda d: (d.score, d.up), reverse=True):
            fp = normalize_key(d.definition)[:500]
            if fp not in seen:
                seen.add(fp)
                unique.append(d)
        selected[key] = unique[:max_defs]

    if max_words is not None and len(selected) > max_words:
        ranked = sorted(selected, key=lambda k: selected[k][0].score, reverse=True)
        selected = {k: selected[k] for k in ranked[:max_words]}
    return selected


# --------------------------------------------------------------------------- #
# Writing
# --------------------------------------------------------------------------- #

def _attr(text: str) -> str:
    return html.escape(text, quote=True)


def entry_id(key: str, used: set[str]) -> str:
    slug = re.sub(r"[^a-z0-9]+", "_", key.encode("ascii", "ignore").decode().lower())
    slug = slug.strip("_")[:60] or "entry"
    base = f"ud_{slug}"
    candidate, n = base, 1
    while candidate in used:
        n += 1
        candidate = f"{base}_{n}"
    used.add(candidate)
    return candidate


def render_body(text: str, link_targets: dict[str, str]) -> str:
    """Escape text, turn [term] into links when the term exists, keep line breaks."""
    out: list[str] = []
    pos = 0
    for m in _BRACKET_LINK.finditer(text):
        out.append(html.escape(text[pos:m.start()], quote=False))
        term = m.group(1)
        target = link_targets.get(normalize_key(term))
        label = html.escape(term, quote=False)
        if target:
            out.append(f'<a href="x-dictionary:r:{_attr(target)}">{label}</a>')
        else:
            out.append(label)
        pos = m.end()
    out.append(html.escape(text[pos:], quote=False))
    paragraphs = [p.strip() for p in re.split(r"\n\s*\n", "".join(out)) if p.strip()]
    return "".join(f"<p>{p.replace(chr(10), '<br/>')}</p>" for p in paragraphs)


def display_word(defs: list[Definition]) -> str:
    """Most common spelling among the kept definitions; ties go to the top one."""
    counts = Counter(d.word for d in defs)
    best = max(counts.values())
    return next(d.word for d in defs if counts[d.word] == best)


FRONT_MATTER_ID = "front_back_matter"


def write_xml(selected: dict[str, list[Definition]], out, *, show_author: bool) -> int:
    used: set[str] = {FRONT_MATTER_ID}
    ids = {key: entry_id(key, used) for key in sorted(selected)}

    out.write('<?xml version="1.0" encoding="UTF-8"?>\n')
    out.write(
        '<d:dictionary xmlns="http://www.w3.org/1999/xhtml" '
        'xmlns:d="http://www.apple.com/DTDs/DictionaryService-1.0.rng">\n'
    )
    for key in sorted(selected):
        defs = selected[key]
        title = display_word(defs)
        out.write(f'<d:entry id="{ids[key]}" d:title="{_attr(title)}">\n')
        for spelling in sorted({title, *(d.word for d in defs)}):
            out.write(f'  <d:index d:value="{_attr(spelling)}"/>\n')
        out.write(f'  <h1 class="headword">{html.escape(title, quote=False)}</h1>\n')
        out.write('  <ol class="defs">\n')
        for d in defs:
            out.write('    <li class="def">\n')
            out.write(f'      <div class="meaning">{render_body(d.definition, ids)}</div>\n')
            if d.example:
                out.write(f'      <div class="example">{render_body(d.example, ids)}</div>\n')
            meta = [f'<span class="votes">▲ {d.up:,} · ▼ {d.down:,}</span>']
            if show_author and d.author:
                meta.append(f'<span class="author">by {html.escape(d.author, quote=False)}</span>')
            if d.date:
                meta.append(f'<span class="date">{html.escape(d.date[:10], quote=False)}</span>')
            out.write(f'      <div class="meta">{" ".join(meta)}</div>\n')
            out.write("    </li>\n")
        out.write("  </ol>\n</d:entry>\n")

    out.write(
        f'<d:entry id="{FRONT_MATTER_ID}" d:title="About Urban Dictionary">\n'
        '  <h1>Urban Dictionary (personal build)</h1>\n'
        '  <p>Definitions are user-submitted content from urbandictionary.com and '
        'remain the property of Urban Dictionary and their authors. Built for '
        'personal, non-commercial use. Content is unmoderated and frequently '
        'offensive.</p>\n'
        '</d:entry>\n'
    )
    out.write("</d:dictionary>\n")
    return len(selected)


# --------------------------------------------------------------------------- #
# CLI
# --------------------------------------------------------------------------- #

def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    p.add_argument("inputs", nargs="+", type=Path, help="CSV / JSON / JSONL dump file(s)")
    p.add_argument("-o", "--output", type=Path, required=True, help="output XML path")
    p.add_argument("--min-up", type=int, default=50, help="minimum upvotes (default 50)")
    p.add_argument("--min-ratio", type=float, default=0.6,
                   help="minimum up/(up+down) ratio (default 0.6)")
    p.add_argument("--max-defs", type=int, default=3,
                   help="definitions kept per word (default 3)")
    p.add_argument("--max-words", type=int, default=None,
                   help="cap on total headwords, best-scoring first (default: no cap)")
    p.add_argument("--max-word-len", type=int, default=60,
                   help="drop headwords longer than this (default 60)")
    p.add_argument("--no-author", action="store_true", help="omit author names")
    return p.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    for path in args.inputs:
        if not path.is_file():
            print(f"error: {path} not found", file=sys.stderr)
            return 2

    stats: Counter = Counter()
    selected = select_entries(
        read_definitions(args.inputs, stats),
        min_up=args.min_up,
        min_ratio=args.min_ratio,
        max_defs=args.max_defs,
        max_words=args.max_words,
        max_word_len=args.max_word_len,
        stats=stats,
    )
    if not selected:
        print("error: no entries passed the filters; loosen --min-up/--min-ratio",
              file=sys.stderr)
        return 1

    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("w", encoding="utf-8") as out:
        n = write_xml(selected, out, show_author=not args.no_author)

    print(
        f"rows read: {stats['rows']:,}  malformed: {stats['malformed']:,}  "
        f"below vote threshold: {stats['rejected_votes']:,}  "
        f"over-long words: {stats['rejected_long_word']:,}\n"
        f"headwords written: {n:,}  ->  {args.output}",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
