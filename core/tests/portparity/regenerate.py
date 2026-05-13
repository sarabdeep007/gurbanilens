"""Regenerate test_vectors.json from the canonical Python matcher.

Run after editing core/tests/test_matcher.py (the regression battery) or after
matcher behavior changes that intentionally shift scores.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

# Make test_matcher's constants importable
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from gurbanilens.corpus import Corpus
from gurbanilens.matcher import (
    CANDIDATE_POOL,
    LONG_TOKEN_MIN,
    MIN_LONG_TOKENS_FOR_FULL_CONFIDENCE,
    Matcher,
    TOKEN_MATCH_THRESHOLD,
)
from test_matcher import BAD_CASES, GOOD_CASES, GT_ANG, GT_PANGTI

MATCH_THRESHOLD = 75.0


def main() -> None:
    corpus = Corpus()
    m = Matcher(corpus)

    test_cases = []
    for label, query in GOOD_CASES + BAD_CASES:
        results = m.match(query, top_n=3)
        top = results[0] if results else None
        is_good = (label, query) in GOOD_CASES
        test_cases.append({
            "id": label.split(".", 1)[0].strip(),
            "label": label,
            "query": query,
            "category": "good" if is_good else "bad",
            "python_canonical": {
                "top_ang": top.line.ang if top else None,
                "top_pangti": top.line.pangti if top else None,
                "top_shabad_id": top.line.shabad_id if top else None,
                "top_score": round(top.score, 2) if top else None,
                "top_partial_ratio": round(top.partial_ratio, 2) if top else None,
                "top_coverage": round(top.coverage, 3) if top else None,
                "top_3": [
                    {"ang": r.line.ang, "pangti": r.line.pangti, "score": round(r.score, 2)}
                    for r in results
                ],
            },
            "assertions": {
                "good": {
                    "top_ang_pangti_matches_ground_truth": True,
                    "score_at_least": max(0.0, round(top.score, 2) - 5.0) if top else 0.0,
                } if is_good else None,
                "bad": {
                    "ground_truth_ang_pangti_must_not_appear_in_top_3": [GT_ANG, GT_PANGTI],
                    "score_at_most": min(100.0, round(top.score, 2) + 5.0) if top else 100.0,
                } if not is_good else None,
            }
        })

    vectors = {
        "version": 1,
        "purpose": (
            "Canonical port-parity battery. Python (core/) is source of truth. "
            "Swift and Kotlin ports must satisfy every assertion. Tolerance: "
            "±5 points on score (floating-point + algorithm-detail variance)."
        ),
        "ground_truth": {"ang": GT_ANG, "pangti": GT_PANGTI},
        "thresholds": {
            "TOKEN_MATCH_THRESHOLD": TOKEN_MATCH_THRESHOLD,
            "LONG_TOKEN_MIN": LONG_TOKEN_MIN,
            "MIN_LONG_TOKENS_FOR_FULL_CONFIDENCE": MIN_LONG_TOKENS_FOR_FULL_CONFIDENCE,
            "CANDIDATE_POOL": CANDIDATE_POOL,
            "MATCH_THRESHOLD": MATCH_THRESHOLD,
        },
        "algorithm_spec": {
            "normalize": (
                "lowercase; strip ASCII punctuation [.,;|:!?\\-\"'(){}\\[\\]0-9]; "
                "collapse whitespace"
            ),
            "long_token": "token after normalize whose length >= LONG_TOKEN_MIN",
            "stage1_recall": (
                "fuzz.partial_ratio(query, corpus_line) — Indel-based partial "
                "substring matching; take top CANDIDATE_POOL"
            ),
            "stage2_token_coverage": (
                "for each query long_token, find max fuzz.ratio (Indel-based, "
                "normalized 0-100) over candidate's tokens; count as covered "
                "if >= TOKEN_MATCH_THRESHOLD"
            ),
            "length_factor": "min(1.0, n_long_query_tokens / MIN_LONG_TOKENS_FOR_FULL_CONFIDENCE)",
            "final_coverage": "(covered_count / n_long_query_tokens) * length_factor",
            "final_score": "partial_ratio * final_coverage",
            "rank": "sort by final_score desc",
        },
        "test_cases": test_cases,
    }

    out = Path(__file__).resolve().parent / "test_vectors.json"
    out.write_text(json.dumps(vectors, indent=2, ensure_ascii=False))
    print(f"Wrote {out} ({len(test_cases)} cases)")


if __name__ == "__main__":
    main()
