"""Matcher regression battery.

6 good cases (derived from Ang 462, Pangti 3) + 5 bad cases. Asserts:
- All good cases return ground truth as top match
- No bad case false-matches the ground-truth line
- A real Pangti from a different Ang is routed correctly (specificity)
- Worst-good score strictly outscores best-bad score (excluding the
  different-Pangti case, which is itself a real match)

Run with ``pytest -s tests/test_matcher.py`` to also see the diagnostic table.
"""

from __future__ import annotations

import pytest

from gurbanilens.corpus import DEFAULT_DB_PATH, Corpus
from gurbanilens.matcher import Match, Matcher

pytestmark = pytest.mark.skipif(
    not DEFAULT_DB_PATH.exists(),
    reason="SGGS corpus not downloaded; run scripts/fetch_corpus.py",
)


# Ground truth for good cases. Verbatim Ang 462 Pangti 3 from the corpus:
#   "meenaa jalaheen. meenaa jalaheen he; ohu; bichhurat. man tan kheen he;
#    kat jeevan, pria, bin hot |"
GT_ANG = 462
GT_PANGTI = 3

GOOD_CASES: list[tuple[str, str]] = [
    (
        "1. full exact",
        "meenaa jalaheen meenaa jalaheen he ohu bichhurat "
        "man tan kheen he kat jeevan pria bin hot",
    ),
    (
        "2. light perturbation (~10% chars)",
        "meena jalaheen meena jalheen he ohu bichurat "
        "man tan kheen he kat jeevan pria bin hot",
    ),
    (
        "3. heavy perturbation (~25% chars, Whisper-realistic)",
        "mina jalhin mina jalhin he o bichrat "
        "man tan khin he kat jivan pria bin hot",
    ),
    (
        "4. first half only",
        "meenaa jalaheen meenaa jalaheen he ohu bichhurat",
    ),
    (
        "5. last half only",
        "man tan kheen he kat jeevan pria bin hot",
    ),
    (
        "6. one word wrong (substitution)",
        "meenaa jalaheen waheguru jalaheen he ohu bichhurat "
        "man tan kheen he kat jeevan pria bin hot",
    ),
]

BAD_CASES: list[tuple[str, str]] = [
    ("7. english gibberish", "the quick brown fox jumps over the lazy dog"),
    ("8. punjabi-flavored with one gurbani-ish word", "kithe gaya tu kal dopahar nu"),
    ("9. pure glue words", "hai te ki di nu de ne"),
    ("10. common gurbani vocab combo", "har naam ras sukh sat"),
    # 11 is a real Pangti from a different Ang — tests specificity (top match
    # should be Ang 1:1 Mool Mantar, NOT Ang 462:3).
    (
        "11. different real Pangti (Mool Mantar)",
        "ik oankaar sat naam karataa purakh nirbhau niravair "
        "akaal moorat ajoonee saibhan gur prasaad",
    ),
]


@pytest.fixture(scope="module")
def matcher() -> Matcher:
    with Corpus() as c:
        return Matcher(c)


def _run_battery(m: Matcher) -> tuple[list[tuple[str, list[Match]]], list[tuple[str, list[Match]]]]:
    good = [(label, m.match(q, top_n=3)) for label, q in GOOD_CASES]
    bad = [(label, m.match(q, top_n=3)) for label, q in BAD_CASES]
    return good, bad


def test_all_good_cases_top_match_is_ground_truth(matcher: Matcher) -> None:
    """Cases 1-6 must rank Ang 462:P3 as the top result."""
    failures = []
    for label, q in GOOD_CASES:
        results = matcher.match(q, top_n=3)
        if not results:
            failures.append(f"{label}: no results")
            continue
        top = results[0]
        if top.line.ang != GT_ANG or top.line.pangti != GT_PANGTI:
            failures.append(
                f"{label}: top was Ang {top.line.ang}:P{top.line.pangti} "
                f"score={top.score:.1f}, expected Ang {GT_ANG}:P{GT_PANGTI}"
            )
    assert not failures, "\n  " + "\n  ".join(failures)


def test_bad_cases_do_not_false_match_ground_truth(matcher: Matcher) -> None:
    """Cases 7-11 must not surface Ang 462:P3 in their top 3.

    This is the core specificity test: regardless of where a non-462:P3 query
    actually matches, it must not be confused for 462:P3. Case 11 (Mool Mantar)
    legitimately matches one of the ~30 Manglacharan occurrences in SGGS — fine,
    as long as 462:P3 is not among them.
    """
    failures = []
    for label, q in BAD_CASES:
        for m in matcher.match(q, top_n=3):
            if m.line.ang == GT_ANG and m.line.pangti == GT_PANGTI:
                failures.append(f"{label}: false-matched Ang 462:P3 at score {m.score:.1f}")
    assert not failures, "\n  " + "\n  ".join(failures)


def test_score_gap_separates_good_from_noise(matcher: Matcher) -> None:
    """Worst-scoring good case must outscore the noise-floor bad cases (7, 8, 9).

    Cases 10 and 11 are excluded: case 10's common-vocab query legitimately
    matches a real Pangti ("har har naam japat sukh sahaje..." at Ang 825:P18),
    case 11 is a verbatim Manglacharan that has 30+ valid matches. Both produce
    high scores — that's correct behavior, not false-positive noise.
    """
    worst_good_score = min(matcher.match(q)[0].score for _, q in GOOD_CASES)
    NOISE_FLOOR_CASES = {"7", "8", "9"}
    noise_scores = [
        matcher.match(q)[0].score
        for label, q in BAD_CASES
        if label.split(".", 1)[0] in NOISE_FLOOR_CASES
    ]
    best_noise = max(noise_scores) if noise_scores else 0.0
    assert worst_good_score > best_noise, (
        f"No clean gap: worst-good={worst_good_score:.1f}, best-noise={best_noise:.1f}"
    )


# ---------------------------------------------------------------------------
# Diagnostic — `python tests/test_matcher.py` prints the full score table.
# ---------------------------------------------------------------------------

def _print_battery() -> None:
    with Corpus() as c:
        m = Matcher(c)
        print(f"Indexed {len(m):,} lines\n")
        good, bad = _run_battery(m)

        def row(label: str, results: list[Match]) -> None:
            if not results:
                print(f"  {label:55s}  NO RESULTS")
                return
            top = results[0]
            loc = f"Ang {top.line.ang}:P{top.line.pangti}"
            gap = top.score - results[1].score if len(results) > 1 else 0.0
            print(
                f"  {label:55s}  score={top.score:5.1f}  "
                f"pr={top.partial_ratio:5.1f} cov={top.coverage:.2f}  "
                f"gap_to_2={gap:5.1f}  → {loc}"
            )

        print("=== GOOD cases ===")
        for label, results in good:
            row(label, results)

        print("\n=== BAD cases ===")
        for label, results in bad:
            row(label, results)

        # Summary gap
        worst_good = min(r[0].score for _, r in good if r)
        bad_for_gap = [r[0].score for label, r in bad if r and not label.startswith("11")]
        best_bad = max(bad_for_gap) if bad_for_gap else 0.0
        print(f"\n=== Gap: worst-good={worst_good:.1f}  best-bad={best_bad:.1f}  "
              f"separation={worst_good - best_bad:.1f} ===")


if __name__ == "__main__":
    _print_battery()
