"""Python's own port-parity runner.

Loads test_vectors.json and asserts the Python matcher satisfies every
assertion. This is the reference impl for what Swift/Kotlin runners must do.

A Python failure here means the canonical Python matcher has drifted from
the recorded test_vectors.json; either fix the matcher or regenerate
(`python core/tests/portparity/regenerate.py`).
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from gurbanilens.corpus import DEFAULT_DB_PATH, Corpus
from gurbanilens.matcher import Matcher

VECTORS_PATH = Path(__file__).resolve().parent / "test_vectors.json"

pytestmark = pytest.mark.skipif(
    not DEFAULT_DB_PATH.exists() or not VECTORS_PATH.exists(),
    reason="Requires corpus + test_vectors.json",
)


@pytest.fixture(scope="module")
def vectors() -> dict:
    return json.loads(VECTORS_PATH.read_text())


@pytest.fixture(scope="module")
def matcher() -> Matcher:
    with Corpus() as c:
        return Matcher(c)


def test_good_cases_match_ground_truth(vectors: dict, matcher: Matcher) -> None:
    failures = []
    gt = vectors["ground_truth"]
    for case in vectors["test_cases"]:
        if case["category"] != "good":
            continue
        results = matcher.match(case["query"], top_n=3)
        assert results, f"{case['label']}: no results"
        top = results[0]
        if top.line.ang != gt["ang"] or top.line.pangti != gt["pangti"]:
            failures.append(
                f"{case['label']}: top was Ang {top.line.ang}:P{top.line.pangti}, "
                f"expected Ang {gt['ang']}:P{gt['pangti']}"
            )
        min_score = case["assertions"]["good"]["score_at_least"]
        if top.score < min_score:
            failures.append(
                f"{case['label']}: score {top.score:.1f} < expected_at_least {min_score:.1f}"
            )
    assert not failures, "\n  " + "\n  ".join(failures)


def test_bad_cases_no_false_positive(vectors: dict, matcher: Matcher) -> None:
    failures = []
    gt = vectors["ground_truth"]
    for case in vectors["test_cases"]:
        if case["category"] != "bad":
            continue
        results = matcher.match(case["query"], top_n=3)
        for r in results:
            if r.line.ang == gt["ang"] and r.line.pangti == gt["pangti"]:
                failures.append(
                    f"{case['label']}: ground truth in top-3 at score {r.score:.1f}"
                )
        if results:
            top = results[0]
            max_score = case["assertions"]["bad"]["score_at_most"]
            if top.score > max_score:
                failures.append(
                    f"{case['label']}: top score {top.score:.1f} > expected_at_most {max_score:.1f}"
                )
    assert not failures, "\n  " + "\n  ".join(failures)
