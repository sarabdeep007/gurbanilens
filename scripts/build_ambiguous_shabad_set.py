#!/usr/bin/env python3
"""Build the ambiguous-shabad set for sung-mode disambiguation.

Brief #9.23 part 4/8. Rationale: when the raagi sings a common phrase
like "gopal gobinde" or "har har naam", the matcher's phrase-level
score can spike for many shabads that happen to contain those exact
2-3 word runs. Under sung-mode, we want to down-weight cross-shabad
hits for shabads that participate in these ambiguous n-gram
clusters — they are, by construction, poor evidence.

Approach:
  1. Read all SGGS lines (source_id=1) with their Latin
     transliteration (language_id=1) and shabad_id.
  2. For each line, tokenize the Latin transliteration into words and
     enumerate 2-grams + 3-grams.
  3. For each n-gram, collect the set of shabadIds that contain it.
  4. Any n-gram whose shabad-set exceeds THRESHOLD (default 8) is
     "ambiguous" — mark every shabad in that set as ambiguous.
  5. Emit JSON: { "ambiguousShabadIds": [...], "generatedAt": "...",
                  "corpusHash": "...", "threshold": N }.

Ships into the iOS bundle via scripts/fetch_ios_deps.sh — the
`SungModeAccumulatorStore` (Part 4 patch) applies a 0.5x tier
multiplier to cross-shabad hits landing on any of these shabadIds.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import logging
import re
import sqlite3
import sys
from collections import Counter, defaultdict
from datetime import datetime, timezone
from pathlib import Path

log = logging.getLogger("build_ambiguous_shabad_set")

DEFAULT_DB = Path("data/sggs/database.sqlite")
DEFAULT_OUT = Path("data/sggs/ambiguous_shabads.json")
# The brief prescribed threshold=8 across 2- and 3-grams. Measured on
# the SGGS corpus that yields 94.7% of shabads (2-grams like
# "har naam" appear in 639 shabads, "har har" in 596 — core Sikh
# vocabulary, not phrase-level ambiguity). Deep's target for the set
# was 200–2000 shabads. Restricting to 3-grams + threshold=25 lands
# at 1632 (29.4%) and captures the actual phrase-level coincidences
# ("har har naam" in 250 shabads, "gur kai sabad" in 149) that
# Deep's brief describes. Keep both options configurable via CLI.
DEFAULT_THRESHOLD = 25
DEFAULT_NGRAM_SIZES = (3,)
SGGS_SOURCE_ID = 1
ENGLISH_LANG_ID = 1
# Skip section headers etc. — only body pangtis + rahao carry sung
# phonetic content that the streaming matcher works against.
INCLUDED_TYPE_IDS = {3, 4}  # 3=Rahao, 4=Pankti

_WORD_RE = re.compile(r"[a-z]+")


def normalise(text: str) -> list[str]:
    """Lower-case, strip punctuation, tokenize to Latin words."""
    return _WORD_RE.findall(text.lower())


def n_grams(tokens: list[str], n: int) -> list[tuple[str, ...]]:
    if len(tokens) < n:
        return []
    return [tuple(tokens[i : i + n]) for i in range(len(tokens) - n + 1)]


def build(db_path: Path, threshold: int, ngram_sizes: tuple[int, ...]) -> dict:
    if not db_path.exists():
        raise SystemExit(f"corpus not found: {db_path}")

    conn = sqlite3.connect(db_path)
    cur = conn.cursor()

    # Row source: SGGS lines (source_id=1) with their Latin
    # transliteration. LEFT JOIN so a missing transliteration surfaces
    # as NULL rather than silently dropping the line.
    cur.execute(
        """
        SELECT l.shabad_id, l.type_id, t.transliteration
        FROM lines l
        JOIN shabads s ON s.id = l.shabad_id
        LEFT JOIN transliterations t
            ON t.line_id = l.id AND t.language_id = ?
        WHERE s.source_id = ?
        """,
        (ENGLISH_LANG_ID, SGGS_SOURCE_ID),
    )

    ngram_to_shabads: dict[tuple[str, ...], set[str]] = defaultdict(set)
    total_lines = 0
    skipped_no_translit = 0
    skipped_wrong_type = 0
    scored_lines = 0

    for shabad_id, type_id, translit in cur.fetchall():
        total_lines += 1
        if type_id not in INCLUDED_TYPE_IDS:
            skipped_wrong_type += 1
            continue
        if not translit:
            skipped_no_translit += 1
            continue
        tokens = normalise(translit)
        for n in ngram_sizes:
            for gram in n_grams(tokens, n):
                ngram_to_shabads[gram].add(shabad_id)
        scored_lines += 1

    # Identify ambiguous n-grams + collect the union of shabads they
    # appear in — that union is the ambiguous shabad set.
    ambiguous_shabads: set[str] = set()
    ambiguous_ngram_count = 0
    top_shared: list[tuple[tuple[str, ...], int]] = []
    for gram, shabads in ngram_to_shabads.items():
        if len(shabads) > threshold:
            ambiguous_shabads.update(shabads)
            ambiguous_ngram_count += 1
            top_shared.append((gram, len(shabads)))

    top_shared.sort(key=lambda x: x[1], reverse=True)

    # Content hash of the corpus file so the JSON can be checked
    # against the SQLite it was derived from at runtime.
    hasher = hashlib.sha256()
    with db_path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            hasher.update(chunk)
    corpus_hash = hasher.hexdigest()

    total_shabads = conn.execute(
        "SELECT COUNT(*) FROM shabads WHERE source_id = ?", (SGGS_SOURCE_ID,)
    ).fetchone()[0]

    conn.close()

    payload = {
        "generatedAt": datetime.now(timezone.utc).isoformat(),
        "corpusHash": corpus_hash,
        "corpusPath": str(db_path),
        "threshold": threshold,
        "ngramSizes": list(ngram_sizes),
        "totalShabads": total_shabads,
        "totalLines": total_lines,
        "scoredLines": scored_lines,
        "skippedNoTranslit": skipped_no_translit,
        "skippedWrongType": skipped_wrong_type,
        "ambiguousShabadCount": len(ambiguous_shabads),
        "ambiguousNgramCount": ambiguous_ngram_count,
        "ambiguousShabadIds": sorted(ambiguous_shabads),
        "topSharedNgrams": [
            {"gram": " ".join(g), "shabadCount": c} for g, c in top_shared[:10]
        ],
    }
    return payload


def main() -> int:
    logging.basicConfig(level=logging.INFO, format="%(message)s")
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--db", type=Path, default=DEFAULT_DB)
    ap.add_argument("--out", type=Path, default=DEFAULT_OUT)
    ap.add_argument("--threshold", type=int, default=DEFAULT_THRESHOLD)
    ap.add_argument(
        "--ngram-sizes",
        type=lambda s: tuple(int(x) for x in s.split(",")),
        default=DEFAULT_NGRAM_SIZES,
        help="comma-separated n-gram sizes (default: 3 — see script header)",
    )
    args = ap.parse_args()

    log.info(
        "building ambiguous-shabad set from %s (threshold=%d, ngram_sizes=%s)",
        args.db, args.threshold, args.ngram_sizes,
    )
    payload = build(args.db, args.threshold, args.ngram_sizes)

    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(payload, indent=2, ensure_ascii=False))

    log.info(
        "corpus: total=%d shabads, %d lines (scored=%d, skipped_no_translit=%d, skipped_type=%d)",
        payload["totalShabads"], payload["totalLines"],
        payload["scoredLines"], payload["skippedNoTranslit"],
        payload["skippedWrongType"],
    )
    log.info(
        "ambiguous: %d shabads across %d n-grams (%.1f%% of SGGS)",
        payload["ambiguousShabadCount"], payload["ambiguousNgramCount"],
        100.0 * payload["ambiguousShabadCount"] / max(payload["totalShabads"], 1),
    )
    log.info("top-10 shared n-grams:")
    for entry in payload["topSharedNgrams"]:
        log.info("  %6d  %s", entry["shabadCount"], entry["gram"])
    log.info("wrote %s (%d bytes)", args.out, args.out.stat().st_size)
    return 0


if __name__ == "__main__":
    sys.exit(main())
