"""Fuzzy Pangti matcher.

Phase 1 design — naive rapidfuzz with one refinement:

- Stage 1 (recall): take top-K candidates by fuzz.partial_ratio. This is forgiving
  enough to find partial Pangtis (a 5-10s Whisper segment may capture only part of
  a sung line).
- Stage 2 (precision): re-rank by `partial_ratio × token_coverage`, where
  token_coverage is the fraction of "long" query tokens (>= 4 chars) that have a
  fuzzy match in the candidate's tokens.

Why this matters: plain partial_ratio spikes to 75+ when a single common token
matches (e.g. "kal" in "kithe gaya tu kal..."). Token coverage crushes those
false positives by demanding that *most* of the substantial query tokens
actually appear (fuzzy-equivalent) in the corpus line.

Token-level fuzzy match uses fuzz.ratio at a >= 60 threshold (forgiving enough
for vowel variations like "mina"~"meenaa", "khin"~"kheen"). The "long token"
cutoff is 3 chars, so informative content words ("har", "naam", "man", "tan")
are included while pure glue words ("hai", "te", "ki", "to", "ne") are excluded.

Deliberately deferred:
- Sequential-progression bias (boost lines near recent matches by order_id)
- First-letter prefiltering for speed
- Vishraam-aware scoring (lines.vishraam_first_letters)
- Line-type weighting (e.g. boost Rahao when it repeats)
"""

from __future__ import annotations

import re
from dataclasses import dataclass

from rapidfuzz import fuzz, process

from .corpus import Corpus, Line

_PUNCT = re.compile(r"[.,;|:!?\-\"'(){}\[\]0-9]+")
_WHITESPACE = re.compile(r"\s+")

LONG_TOKEN_MIN = 3
TOKEN_MATCH_THRESHOLD = 55.0
CANDIDATE_POOL = 50


def normalize(text: str) -> str:
    """Canonical form for matching. Applied identically to corpus and query."""
    text = text.lower()
    text = _PUNCT.sub(" ", text)
    text = _WHITESPACE.sub(" ", text)
    return text.strip()


def _long_tokens(normalized: str) -> list[str]:
    return [t for t in normalized.split() if len(t) >= LONG_TOKEN_MIN]


def _token_coverage(query_long_tokens: list[str], candidate_tokens: list[str]) -> float:
    """Fraction of query long-tokens that have a fuzzy-equivalent in candidate."""
    if not query_long_tokens:
        return 0.0
    if not candidate_tokens:
        return 0.0
    matched = 0
    for qt in query_long_tokens:
        best = max((fuzz.ratio(qt, ct) for ct in candidate_tokens), default=0.0)
        if best >= TOKEN_MATCH_THRESHOLD:
            matched += 1
    return matched / len(query_long_tokens)


@dataclass(frozen=True, slots=True)
class Match:
    line: Line
    score: float          # combined: partial_ratio * coverage, 0-100
    partial_ratio: float  # raw partial_ratio, 0-100
    coverage: float       # fraction of long query tokens fuzzy-matched, 0-1


class Matcher:
    """In-memory fuzzy matcher over SGGS English transliterations."""

    def __init__(self, corpus: Corpus) -> None:
        self._lines: list[Line] = []
        self._norm_texts: list[str] = []
        self._tokens: list[list[str]] = []
        for line in corpus.all_lines():
            if not line.transliteration_en:
                continue
            normalized = normalize(line.transliteration_en)
            if not normalized:
                continue
            self._lines.append(line)
            self._norm_texts.append(normalized)
            self._tokens.append(normalized.split())

    def __len__(self) -> int:
        return len(self._lines)

    def match(self, query: str, top_n: int = 5) -> list[Match]:
        """Return top-N candidates by combined score, descending."""
        normalized = normalize(query)
        if not normalized:
            return []
        q_long = _long_tokens(normalized)

        candidates = process.extract(
            normalized,
            self._norm_texts,
            scorer=fuzz.partial_ratio,
            limit=CANDIDATE_POOL,
        )

        rescored: list[tuple[float, float, float, int]] = []
        for (_, partial_score, idx) in candidates:
            cov = _token_coverage(q_long, self._tokens[idx])
            final = partial_score * cov
            rescored.append((final, partial_score, cov, idx))
        rescored.sort(reverse=True)

        return [
            Match(
                line=self._lines[idx],
                score=final,
                partial_ratio=pr,
                coverage=cov,
            )
            for (final, pr, cov, idx) in rescored[:top_n]
        ]
