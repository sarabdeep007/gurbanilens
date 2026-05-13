"""Smoke tests for Corpus loader. Requires data/sggs/database.sqlite present."""

from __future__ import annotations

import pytest

from gurbanilens.corpus import DEFAULT_DB_PATH, Corpus

pytestmark = pytest.mark.skipif(
    not DEFAULT_DB_PATH.exists(),
    reason="SGGS corpus not downloaded; run scripts/fetch_corpus.py",
)


def test_total_line_count_is_sane() -> None:
    """SGGS has ~60K rows in Shabad OS v4 (Pankti + Rahao + Sirlekh + Manglacharan)."""
    with Corpus() as corpus:
        n = len(corpus)
    assert 50_000 < n < 70_000, f"Unexpected SGGS line count: {n}"


def test_mool_mantar_at_ang_1_has_english_transliteration() -> None:
    """Ang 1 Pangti 1 is the Mool Mantar. Our matching surface is English
    transliteration; assert its opening contains 'ik oankaar'."""
    with Corpus() as corpus:
        rows = corpus.lookup(ang=1, pangti=1)
    assert rows, "No line at Ang 1, Pangti 1"
    translit = rows[0].transliteration_en
    assert translit is not None, "Mool Mantar should have English transliteration"
    assert "ik oankaar" in translit.lower(), (
        f"Expected Mool Mantar opening 'ik oankaar' in transliteration, got: {translit!r}"
    )


def test_iteration_is_ordered_by_ang() -> None:
    """all_lines() should produce lines in non-decreasing Ang order, starting at 1."""
    with Corpus() as corpus:
        angs: list[int] = []
        for i, line in enumerate(corpus.all_lines()):
            if i >= 500:
                break
            angs.append(line.ang)
    assert angs[0] == 1, f"First line should be on Ang 1, got {angs[0]}"
    assert angs == sorted(angs), "Lines should iterate in non-decreasing Ang order"


def test_all_line_types_present() -> None:
    """The first ~2000 lines should cover the main line types: Pankti, Rahao, Sirlekh."""
    with Corpus() as corpus:
        types_seen: set[str] = set()
        for i, line in enumerate(corpus.all_lines()):
            if i >= 2000:
                break
            if line.line_type:
                types_seen.add(line.line_type)
    assert {"Pankti", "Rahao", "Sirlekh"}.issubset(types_seen), (
        f"Expected to see Pankti, Rahao, Sirlekh in first 2000 lines; got {types_seen}"
    )
