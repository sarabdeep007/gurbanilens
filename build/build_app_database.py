"""Build the bundle-ready app SQLite from build/intermediate_unicode.sqlite.

Trims the Shabad OS database to the ~100 MB curated subset Deep approved
(see docs/PHASE_2A_ARCHITECTURE.md §4):

KEEPS:
- lines.{gurmukhi, gurmukhi_unicode, first_letters, vishraam_first_letters,
  type_id, order_id, source_page, source_line, shabad_id, id}
- shabads, sources, sections, subsections, writers, banis, bani_lines, line_types
- transliterations WHERE language = English
- translations WHERE translation_source IN (Bhai Manmohan Singh English,
                                            Prof. Sahib Singh Punjabi)

DROPS (server-downloadable on demand later):
- transliterations in Hindi, Urdu, Devanagari, etc.
- translations from Sant Singh Khalsa, SikhNet Spanish, Fareedkot, etc.
- lines.pronunciation, lines.pronunciation_information
- translation_sources we don't ship from

Inputs:  build/intermediate_unicode.sqlite
Outputs: build/app_database.sqlite
"""

from __future__ import annotations

import argparse
import shutil
import sqlite3
import sys
from pathlib import Path

BUILD_DIR = Path(__file__).resolve().parent
INPUT = BUILD_DIR / "intermediate_unicode.sqlite"
OUTPUT = BUILD_DIR / "app_database.sqlite"

# Curated translation sources we ship by default. Match against
# translation_sources.name_english.
DEFAULT_ENGLISH_TRANSLATION = "Bhai Manmohan Singh"
DEFAULT_PUNJABI_TEEKA = "Prof. Sahib Singh"
KEEP_TRANSLITERATION_LANGUAGES = {"English"}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--input", type=Path, default=INPUT)
    ap.add_argument("--output", type=Path, default=OUTPUT)
    args = ap.parse_args()

    if not args.input.exists():
        print(f"Input not found: {args.input}", file=sys.stderr)
        print("Run: cd build && npm install && npm run convert", file=sys.stderr)
        return 1

    print(f"Copying {args.input}\n     -> {args.output}")
    shutil.copy2(args.input, args.output)

    conn = sqlite3.connect(args.output)
    conn.row_factory = sqlite3.Row

    initial_size = args.output.stat().st_size
    print(f"\nInitial size: {initial_size / 1024 / 1024:.1f} MB")

    # 1. Find the translation_sources we want to keep
    keep_ts = []
    for r in conn.execute(
        """
        SELECT ts.id, ts.name_english, lang.name_english AS lang
        FROM translation_sources ts
        JOIN languages lang ON ts.language_id = lang.id
        """
    ):
        if r["name_english"] == DEFAULT_ENGLISH_TRANSLATION and r["lang"] == "English":
            keep_ts.append(r["id"])
            print(f"  keep translation_source #{r['id']}: {r['name_english']} ({r['lang']})")
        elif r["name_english"] == DEFAULT_PUNJABI_TEEKA and r["lang"] == "Punjabi":
            keep_ts.append(r["id"])
            print(f"  keep translation_source #{r['id']}: {r['name_english']} ({r['lang']})")

    if len(keep_ts) < 2:
        print(f"WARNING: only {len(keep_ts)} of 2 expected translation_sources matched. "
              f"Check exact names_english in the DB.", file=sys.stderr)

    # 2. Find transliteration language ids to keep
    keep_lang_ids = []
    for r in conn.execute("SELECT id, name_english FROM languages"):
        if r["name_english"] in KEEP_TRANSLITERATION_LANGUAGES:
            keep_lang_ids.append(r["id"])
            print(f"  keep transliteration language #{r['id']}: {r['name_english']}")

    # 3. Delete unwanted translations
    if keep_ts:
        placeholders = ",".join("?" * len(keep_ts))
        cur = conn.execute(
            f"DELETE FROM translations WHERE translation_source_id NOT IN ({placeholders})",
            keep_ts,
        )
        print(f"\nDeleted {cur.rowcount:,} translations")
    cur = conn.execute(
        f"DELETE FROM translation_sources WHERE id NOT IN ({','.join('?' * len(keep_ts))})",
        keep_ts,
    )
    print(f"Deleted {cur.rowcount:,} translation_sources")

    # 4. Delete unwanted transliterations
    if keep_lang_ids:
        placeholders = ",".join("?" * len(keep_lang_ids))
        cur = conn.execute(
            f"DELETE FROM transliterations WHERE language_id NOT IN ({placeholders})",
            keep_lang_ids,
        )
        print(f"Deleted {cur.rowcount:,} transliterations")

    # 5. Null out the pronunciation_information column (saves several MB)
    cur = conn.execute("UPDATE lines SET pronunciation_information = NULL")
    print(f"Cleared pronunciation_information from {cur.rowcount:,} lines")
    cur = conn.execute("UPDATE lines SET pronunciation = NULL")
    print(f"Cleared pronunciation (empty in source anyway) from {cur.rowcount:,} lines")

    # 6. VACUUM to reclaim space
    conn.commit()
    print("\nVACUUMing...")
    conn.execute("VACUUM")
    conn.close()

    final_size = args.output.stat().st_size
    print(f"\nFinal size:   {final_size / 1024 / 1024:.1f} MB "
          f"({(initial_size - final_size) / 1024 / 1024:+.1f} MB)")
    print(f"App database ready at: {args.output}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
