# Phase 2B v1 — First Real Kirtan Alignment Findings

**Date:** 2026-06-20
**Sample:** `samples/harjinder singh 3.mp3` (64.0 sec)
**Output:** `samples/alignments/harjinder singh 3.json`
**Tool:** `scripts/align_sample.py` (Whisper medium + Phase 1 matcher)

---

## Why this doc exists

First real run of the Phase 2B alignment toolchain on actual Kirtan audio. The artifact validates the Kirtan-repetition finding from `docs/DATASET_PHILOSOPHY.md` AND surfaces three concrete bugs in the v1 alignment script that must be fixed before dataset accumulation begins.

When the time comes to label 20-50 real samples, fix the bugs documented here FIRST, then re-run alignment on this sample as the verification gate. Don't accept the toolchain as production-ready until this sample's output matches the expected behavior described below.

---

## What worked

**Whisper + Phase 1 matcher correctly identified Ang 626, Pangti 19 three times across the audio.**

The Ragi sings "Jeea Jant Tere Dhaare" (ਜੀਅ ਜੰਤ ਤੇਰੇ ਧਾਰੇ — "all souls and beings are Yours") three non-contiguous times in 64 seconds. The alignment output produced three segments all pointing at `ang=626, pangti_index=19`:

- Segment 1: 0–15.82s — confidence 87.8, tier `high`
- Segment 3: 15.82–41.4s — confidence 54.4, tier `needs_review`
- Segment 5: 41.4–64.0s — confidence 82.6, tier `high`

This is exactly what `DATASET_PHILOSOPHY.md` §3 predicts: a single Pangti spans multiple non-contiguous time spans in real Kirtan. Phase 1's per-window hypothesis correctly resolves each chunk to the same Pangti.

The Phase 1 finding is vindicated against real data.

---

## Bug 1 — `repeat_group_id` never assigned

**Spec (`DATASET_PHILOSOPHY.md` §4):**
> Same `(ang, pangti)` segment appearing in two non-adjacent positions with ≥1s gap → assign shared `repeat_group_id` and force `alignment_quality = "needs_review"`.

**Actual output:**
Segments 1, 3, 5 all have `repeat_group_id: null` despite being the same `(ang=626, pangti_index=19)` repeated three times with multi-second gaps between them.

**Implication:**
Downstream tools that need to group repeats (for human review batching, for forced-alignment correction, for skipping duplicate training samples) cannot do so. The repeat group information is lost.

**Fix required:**
In `scripts/align_sample.py`, after segments are computed, run a pass that groups segments by `(ang, pangti_index)` where multiple segments share that key and are separated by gaps ≥1s. Assign a unique `repeat_group_id` (UUID or sequential int) to each group.

---

## Bug 2 — `alignment_quality` not uniformly demoted for repeats

**Spec (`DATASET_PHILOSOPHY.md` §4):**
> Every machine-detected repeat is forced to `needs_review` in v1 — humans verify repeats.

**Actual output:**
Of the three repeat segments (1, 3, 5), only segment 3 was marked `needs_review`. Segments 1 and 5 remained `high`.

**Implication:**
A reviewer scanning for "what needs human verification?" would miss segments 1 and 5, even though they're machine-detected repeats and the spec requires all of them be flagged.

**Fix required:**
After `repeat_group_id` assignment (Bug 1 fix), demote ALL segments belonging to any repeat group to `alignment_quality = "needs_review"`, not just the middle/subsequent ones.

---

## Bug 3 — False-positive `pangti` segments from Whisper hallucinations

**Actual output:**
Segments 2 and 4 are classified as `kind=pangti` but point at unrelated Angs (1385 and 1016) with low confidence (73.3 and 64.5) and use Whisper transcripts of sustained-vowel/alaap passages.

The audio contains only Ang 626 content. Segments 2 and 4 are Whisper hallucinations during alaap, fitting the matcher's best-effort guess.

**Implication:**
These would enter the training set as wrong labels. The matcher coverage of 1.0 on segment 4 is misleading — Whisper produced confident-looking words for what is actually melodic improvisation with no transcript.

**Fix required:**
The `detect_alaap` function in `scripts/align_sample.py` should:
- Set a minimum matcher confidence threshold (e.g., `confidence < 70` AND `coverage < 0.8` → `kind=unknown` or `kind=alaap`, not `kind=pangti`)
- Treat sustained vowel runs (Whisper output like "aaaa" or single-vowel tokens repeated) as alaap regardless of word count
- When two segments overlap in time AND one has much higher confidence, suppress the lower-confidence one

Alternative: keep low-confidence segments but tier them `needs_review` not `medium`. v1 default should be skeptical.

---

## Expected output after fixes

For `samples/harjinder singh 3.mp3`, after the three bugs are fixed:

- **Segments 1, 3, 5** all have shared `repeat_group_id` (e.g., `"rg_0"`)
- **Segments 1, 3, 5** all have `alignment_quality: "needs_review"`
- **Segments 2 and 4** are reclassified as `kind: "alaap"` or `kind: "unknown"`, NOT `kind: "pangti"`
- `tier_counts` becomes something like `{"high": 0, "medium": 0, "needs_review": 3, "n/a": 2}` (5 segments, all flagged for human review since this is the first sample in a noisy real-world scenario)

This sample (`samples/harjinder singh 3.mp3`) becomes the canonical regression test: after any future change to `align_sample.py`, re-running against this audio MUST produce the above shape.

---

## Where to fix

Single file: `scripts/align_sample.py`

Specific functions per `DATASET_PHILOSOPHY.md` §5:
- `detect_repeats(segments)` — assign `repeat_group_id` and demote tier
- `detect_alaap(segments, words)` — apply minimum confidence threshold
- `score_tier(segment, repeat_group_assigned)` — respect the "needs_review forced" rule

The `self-test` subcommand already passes 13 assertions, so the pure-helper unit tests are a good place to add regression cases for these bugs.

---

## Status

**Toolchain status:** working scaffolding, NOT production-ready.
**Dataset construction status:** blocked on these three fixes.
**Recommended next step:** dispatch dataset agent with this doc as input when v1 voice-search ships and dataset work begins.

Critical: do NOT start labeling real samples or building dataset splits until these fixes are verified against this canonical sample.
