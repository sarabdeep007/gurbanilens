# Port-parity contract

Python (`core/gurbanilens/matcher.py`) is the canonical reference. Every other-language port (Swift, Kotlin) must satisfy the assertions in `test_vectors.json`.

## What this guarantees

- All ports return the same **top match** (Ang + Pangti) for every test case
- All ports return scores within **±5 points** of Python's canonical score (tolerance for floating-point and minor algorithm differences between fuzzy-string libraries)
- All ports correctly **refuse to match the ground truth** on bad-case queries (no false-positive leakage)

## What this does not guarantee

- Exact identical scores. We accept ±5 point drift.
- Identical top-N ordering beyond position 1. Implementations may rank ties differently.

## Adding a new test case

1. Add the case in `core/tests/test_matcher.py` first (regression battery must pass)
2. Re-run `core/tests/portparity/regenerate.py` to refresh `test_vectors.json`
3. Re-run every port's runner; commit the JSON update alongside any port assertion changes

## Adding a new port (e.g. Kotlin)

The port must:

1. Load `test_vectors.json`
2. Build its corpus (full SGGS) and matcher (with the thresholds from the JSON's `thresholds` block)
3. For each `test_cases[i]`:
   - Run the matcher on `query`
   - For "good" category cases: assert top match's (ang, pangti) equals `python_canonical.top_ang/top_pangti`, and final score >= `assertions.good.score_at_least`
   - For "bad" category cases: assert ground truth (ang, pangti) does not appear in top-3, and final score <= `assertions.bad.score_at_most`
4. Run on every PR touching matcher code

## Algorithm spec

See `test_vectors.json#/algorithm_spec` for the exact algorithm. Any port that differs from this spec is a bug.
