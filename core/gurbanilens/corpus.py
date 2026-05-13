"""SGGS corpus loader.

Wraps the Shabad OS SQLite (v4 schema) and exposes the subset of data Phase 1
needs: SGGS lines with Ang, Pangti, line type, raw Gurmukhi (Anmol Lipi font
encoding), and English transliteration.

Phase 1 design notes:
- `gurmukhi` is stored in Anmol Lipi font encoding (ASCII designed to render as
  Gurmukhi via the Anmol Lipi typeface). Proper Unicode conversion is deferred —
  to be done via anvaad-js or equivalent established library, not hand-rolled.
- `transliteration_en` (from the `transliterations` table) is hand-curated Latin
  romanization. This is the primary matching surface for Phase 1 — both the
  corpus and ASR output get normalized to Latin space before fuzzy matching.
- `pronunciation` on `lines` is empty for SGGS in this DB, so we ignore it.

The matcher pulls all_lines() once to build an in-memory index. The CLI uses
lookup() to fetch a specific line for display.
"""

from __future__ import annotations

import sqlite3
from dataclasses import dataclass
from pathlib import Path
from typing import Iterator

DEFAULT_DB_PATH = Path(__file__).resolve().parent.parent.parent / "data" / "sggs" / "database.sqlite"
SGGS_NAME_PREFIX = "Sri Guru Granth Sahib"
TRANSLITERATION_LANGUAGE = "English"


@dataclass(frozen=True, slots=True)
class Line:
    """A single line of SGGS — Pankti, Rahao, Sirlekh, or Manglacharan."""

    id: str
    shabad_id: str
    ang: int
    pangti: int | None
    line_type: str | None
    gurmukhi: str
    transliteration_en: str | None
    first_letters: str | None
    order_id: int

    def __str__(self) -> str:
        loc = f"Ang {self.ang}"
        if self.pangti is not None:
            loc += f", Pangti {self.pangti}"
        if self.line_type:
            loc += f" [{self.line_type}]"
        body = self.transliteration_en or self.gurmukhi
        return f"{loc}\n  {body}"


_LINE_COLS = """
    l.id, l.shabad_id, l.source_page, l.source_line, l.gurmukhi,
    l.first_letters, l.order_id,
    lt.name_english AS line_type,
    t.transliteration AS transliteration_en
"""


class Corpus:
    """Read-only SGGS corpus backed by Shabad OS SQLite."""

    def __init__(self, db_path: Path | str = DEFAULT_DB_PATH) -> None:
        self.db_path = Path(db_path)
        if not self.db_path.exists():
            raise FileNotFoundError(
                f"Corpus DB not found at {self.db_path}. "
                f"Run: python scripts/fetch_corpus.py"
            )
        self._conn = sqlite3.connect(f"file:{self.db_path}?mode=ro", uri=True)
        self._conn.row_factory = sqlite3.Row
        self._sggs_source_id = self._resolve_id(
            "sources", "name_english LIKE ? || '%'", SGGS_NAME_PREFIX, "SGGS"
        )
        self._english_language_id = self._resolve_id(
            "languages", "name_english = ?", TRANSLITERATION_LANGUAGE, "English language"
        )

    def _resolve_id(self, table: str, where: str, value: str, label: str) -> int:
        row = self._conn.execute(
            f"SELECT id FROM {table} WHERE {where}",
            (value,),
        ).fetchone()
        if row is None:
            raise RuntimeError(
                f"Could not resolve {label} id from {table} (where {where}, value {value!r}). "
                f"DB may be wrong schema version."
            )
        return int(row["id"])

    def _row_to_line(self, row: sqlite3.Row) -> Line:
        return Line(
            id=row["id"],
            shabad_id=row["shabad_id"],
            ang=row["source_page"],
            pangti=row["source_line"],
            line_type=row["line_type"],
            gurmukhi=row["gurmukhi"],
            transliteration_en=row["transliteration_en"],
            first_letters=row["first_letters"],
            order_id=row["order_id"],
        )

    def __len__(self) -> int:
        return self._conn.execute(
            """
            SELECT COUNT(*) AS n
            FROM lines l
            JOIN shabads s ON l.shabad_id = s.id
            WHERE s.source_id = ?
            """,
            (self._sggs_source_id,),
        ).fetchone()["n"]

    def all_lines(self) -> Iterator[Line]:
        """Yield every SGGS line in canonical order."""
        cur = self._conn.execute(
            f"""
            SELECT {_LINE_COLS}
            FROM lines l
            JOIN shabads s ON l.shabad_id = s.id
            LEFT JOIN line_types lt ON l.type_id = lt.id
            LEFT JOIN transliterations t
                ON t.line_id = l.id AND t.language_id = ?
            WHERE s.source_id = ?
            ORDER BY l.order_id
            """,
            (self._english_language_id, self._sggs_source_id),
        )
        for row in cur:
            yield self._row_to_line(row)

    def lookup(self, ang: int, pangti: int) -> list[Line]:
        """Return all SGGS lines at (ang, pangti). Usually one, occasionally more."""
        cur = self._conn.execute(
            f"""
            SELECT {_LINE_COLS}
            FROM lines l
            JOIN shabads s ON l.shabad_id = s.id
            LEFT JOIN line_types lt ON l.type_id = lt.id
            LEFT JOIN transliterations t
                ON t.line_id = l.id AND t.language_id = ?
            WHERE s.source_id = ? AND l.source_page = ? AND l.source_line = ?
            ORDER BY l.order_id
            """,
            (self._english_language_id, self._sggs_source_id, ang, pangti),
        )
        return [self._row_to_line(row) for row in cur]

    def shabad_lines(self, shabad_id: str) -> list[Line]:
        """All lines belonging to a single Shabad, in order."""
        cur = self._conn.execute(
            f"""
            SELECT {_LINE_COLS}
            FROM lines l
            LEFT JOIN line_types lt ON l.type_id = lt.id
            LEFT JOIN transliterations t
                ON t.line_id = l.id AND t.language_id = ?
            WHERE l.shabad_id = ?
            ORDER BY l.order_id
            """,
            (self._english_language_id, shabad_id),
        )
        return [self._row_to_line(row) for row in cur]

    def close(self) -> None:
        self._conn.close()

    def __enter__(self) -> "Corpus":
        return self

    def __exit__(self, *exc: object) -> None:
        self.close()
