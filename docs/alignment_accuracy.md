# Alignment Accuracy — v1 Assessment

_Written 2026-06-17. Source: `scripts/align_sample.py` + `docs/DATASET_PHILOSOPHY.md`. Status: v1 baseline — expected to be revised after the first end-to-end run on real audio._

This document records what the v1 aligner does, what it has been validated on, and what its accuracy bar is expected to be when run on real Phase 1 samples. It complements `docs/DATASET_PHILOSOPHY.md` (which explains *why* the algorithm is shaped this way) and `samples/MANIFEST.md` (which lists the candidate samples).

---

## 1. Host limitations at the time of writing

The dataset agent built and ran v1 from a Linux host that does **not** have:

- Any audio in `samples/` (Phase 1's 13 `.mp3`s are gitignored and live on Deep's Phase 1 machine — see `samples/MANIFEST.md` §2).
- `pip`, `python3-venv`, or any way to install Python packages in this session — so `faster-whisper`, `rapidfuzz`, and `indic-transliteration` (the runtime deps) are not importable here.

These two together mean the **end-to-end pipeline (`audio` subcommand) has not been run on this host**. The brief explicitly anticipates this case and directs us to (a) skip the canonical-audio test and (b) prove the code path with a dry-mode self-test instead, which is what we did.

When Deep runs this script on the Phase 1 machine (where the audio + deps are both present), the audio canonical test below is the first thing to execute.

---

## 2. What was validated on this host

`python3 scripts/align_sample.py self-test` — passes with 13 assertions, stdlib only. Coverage:

| Helper | What the test proves |
|---|---|
| `_is_vowel_only` | Distinguishes alaap-style tokens (`aa`, `ee`, `oo`) from real Gurmukhi tokens (`naam`, `har`, `waheguru`) |
| `merge_windows` | Two adjacent windows with the same `(ang, pangti)` collapse into one segment; a different `(ang, pangti)` starts a new segment |
| `detect_repeats` | Two non-adjacent same-`(ang, pangti)` segments (gap ≥ 1 s) share a `repeat_group_id`; an unrelated Pangti in between does not |
| `detect_alaap_and_silence` | A gap with no words → `silence`; a gap with vowel-only words → `alaap`; a `pangti` segment whose text is entirely vowel-only gets retagged as `alaap` |
| `score_tier` | High/medium/needs_review cutoffs land at the values specified in DATASET_PHILOSOPHY.md §4; repeat-group membership forces `needs_review`; short (<1.5 s) Pangti segments force `needs_review`; alaap maps to `n/a`; unknown maps to `needs_review` |
| End-to-end on synthetic Pangti spans | A two-instance P19 repeat with a P20 in between produces one shared `repeat_group_id` for both P19 instances, no group on P20, and `needs_review` tier on all P19 members + `high`/`medium` tier on P20 |

These cover the entire post-Whisper / post-matcher algorithm. The two remaining things only the canonical-audio run can validate are:

1. Whether Whisper actually produces accurate word-timestamps on Kirtan audio (the aeneas spike's 23-words-over-65s on `harjinder singh 3.mp3` says yes — see `docs/aeneas_spike.md`).
2. Whether the matcher's per-window confidence is well-calibrated against the §4 cutoffs (Phase 1's per-sample confidence numbers in `evaluation/phase1_medium_report.md` suggest yes for the four confidently-matched samples).

---

## 3. Canonical-audio test (deferred until Deep runs on Phase 1 machine)

The brief specifies `samples/harjinder singh 3.mp3` (Phase 1 confidently matched to Ang 626 P19 at confidence 87.8) as the canonical test. Expected behaviour:

```
$ python scripts/align_sample.py audio samples/harjinder_singh_3.mp3 \
      --model medium --out samples/alignments/
```

| Expectation | Source / why |
|---|---|
| Whisper produces ~20–25 word timestamps over the 65 s of audio | Aeneas spike captured 23 in 28.9 s of compute |
| Matcher proposes `(626, 19)` on most windows in alternation with `(626, 20)` | Phase 1 medium-model match: Ang 626 P19 at 87.8; aeneas spike showed P19a/P19b (text-halves of P19 + the following Pangti) alternating |
| `merge_windows` collapses consecutive same-key windows into segments | Per algorithm step 3 |
| `detect_repeats` flags at least two non-adjacent P19 segments → assigns a `repeat_group_id` to all P19 instances | Aeneas spike: P19a sung ≥ 4 times; gap between repeats was multiple seconds |
| `score_tier` puts every P19 instance into `needs_review` despite individual confidences ≥ 80 | DATASET_PHILOSOPHY §4: repeat-group membership forces `needs_review` in v1 |
| Tier distribution looks like `{high: 0, medium: 0-2, needs_review: ≥4, n/a: 0-1}` | Repetition-heavy sample; no `high`-tier segments are expected from this audio because the repetition prevents auto-promotion |

**Interpretation:** producing zero `high`-tier segments from `harjinder singh 3.mp3` is the **correct** v1 behaviour, not a failure. The whole point of the philosophy doc is that repetition is the dangerous case and v1 defers it to humans. The high-tier output will come from `babiha 2.mp3` (Phase 1 confidence 81.1, both windows confident, no Rahao repetition visible in the report) and similar studio recordings.

A useful sanity check post-run: open the produced JSON and verify that every P19 segment has the same `repeat_group_id` and `alignment_quality == "needs_review"`. If the aligner produces P19→P20→P21 monotonic-march output instead, the Kirtan-repetition finding is biting us and we need to look at why the windowing isn't recognising the loop.

---

## 4. Expected tier distribution across the Phase 1 13-sample battery

Based on Phase 1's per-sample confidence numbers, the v1 aligner is expected to produce roughly:

| Sample | Phase 1 conf | Expected tier mix | Rationale |
|---|---|---|---|
| `babiha 2.mp3` | 81.1 | mostly `high` (no detected repeats) | Both windows confident, single Shabad, no obvious repetition in the 38 s clip |
| `harjinder singh 1.mp3` | 78.6 | `medium` + `needs_review` (Rahao repeat) | One Shabad / Rahao repeat structure noted in the report |
| `harjinder singh 3.mp3` | 87.8 | all `needs_review` | Repetition-heavy (canonical aeneas-spike sample) |
| `harjinder singh 5.mp3` | 91.1 | `medium` + `needs_review` (Rahao repeat) | Same Shabad family as #1/#3; report notes "Rahao repeat" |
| `japji sahib 1.mp3` | 71.8 (medium) / 96.6 (large-v3) | `medium` on medium model, `high` on large-v3 | Spoken Paath — easiest ASR input we have |
| `babiha 1`, `babiha 3`, `babiha 4`, `satnam singh 1/2`, `harjinder singh 2/4`, `waheguru 1` | < 75 | all `needs_review` (matcher under threshold) | Phase 1 had no confident matches |

**Throughput expectation for the v1 dataset:**

- The four confident Phase 1 samples (`babiha 2`, `harjinder singh 1/3/5`) cover roughly 3 minutes of audio combined.
- After repeat-flagging, only `babiha 2` is expected to yield any auto-promoted `high`-tier Pangtis — call it ~30 s.
- That is **far below** the v1 training-set bar (5 hours of high-tier audio per DATASET_PHILOSOPHY §7). So the Phase 1 samples alone do not constitute a dataset; the new 50+ samples Deep is collecting are what will close the gap. The Phase 1 samples are useful as the *first end-to-end validation run* and as the *negative-test set* (`waheguru 1.mp3` must continue to produce zero `pangti` segments under any tier — that's the Simran-rejection safety property from Phase 1).

---

## 5. Known weaknesses of the v1 aligner

These are accepted v1 limitations; fixing them is a v2/v3 backlog item.

### 5.1 `pangti_part` is always `None`

DATASET_PHILOSOPHY §3 specifies `pangti_part: "a" | "b" | "c"` to disambiguate sub-Pangti text-halves (the `|` separator in BaniDB transliterations). The corpus stores both halves in a single row with `|` intact, and the matcher treats them as one row. v1 outputs `pangti_part: null`; Sevadaar disambiguation in the labeller (Phase 2B v2) sets it. This is fine for training data — Whisper learns on whole-Pangti audio fine; sub-Pangti granularity is a downstream-usefulness feature, not a training-quality requirement.

### 5.2 Boundary uncertainty is not yet computed

`score_tier` reads `boundary_uncertainty_sec` from the segment, but v1 doesn't *populate* it (defaults to 0.0). The intended computation: distance between the segment's `start_sec`/`end_sec` and the nearest Whisper word-timestamp boundary. Implementing this requires storing the underlying word list on the segment; it'll move the dial on a few borderline `medium` → `needs_review` transitions but won't change the high-confidence outputs. Track in v2.

### 5.3 Overlap detection is missing

The "low matcher confidence + dense words → unknown/overlap" heuristic (DATASET_PHILOSOPHY §5.6) is not implemented. v1 treats those windows as low-confidence single-Pangti segments and lets `score_tier` push them to `needs_review`. Functionally equivalent for v1 because both paths land in `needs_review`; revisit when there's a labeller UI that distinguishes "needs_review because overlap" vs "needs_review because low confidence" usefully.

### 5.4 Vowel-only heuristic for alaap detection is conservative

`_is_vowel_only` only matches IAST output with zero ASCII consonants. Real alaap often has soft consonant articulations (gentle "ha", glottal stops, etc.) that Whisper transcribes as `ha`, `na`, etc. — those slip through as low-coverage pangti hypotheses and get tier=`needs_review`. The conservative behaviour is correct (don't auto-mark something as alaap when it might be Gurbani); we just don't get free alaap auto-tagging. Sevadaar review fixes it. Revisit if alaap-detection becomes a bottleneck.

### 5.5 No detection of Ang-boundary crossings

If a recording's `ang_start != ang_end` (Sevadaar listed it in `samples/registry.json`), the aligner doesn't currently know about that. The matcher proposes against the entire SGGS corpus regardless — so an Ang-boundary span could in principle match a Pangti from the wrong Ang if the audio is ambiguous. v1 catches this only through the matcher's intrinsic confidence (matches from outside the expected Ang range should generally score lower because the surrounding context doesn't fit). Plumbing the `ang_start/end` constraint through the matcher is a v2 improvement.

---

## 6. Accuracy quality bar — "good enough to include in training set"

A segment is **training-eligible** iff:

1. `alignment_quality in {"high", "medium"}`
2. `kind == "pangti"`
3. `text_gurmukhi is not None` (we need the target text for the Whisper fine-tune)
4. `repeat_group_id is None` (v1 conservatism, see DATASET_PHILOSOPHY §4)
5. The parent sample has `recording_quality in {"studio", "clean_live"}` (so we don't train on artefact-heavy audio)

This is the predicate that `scripts/build_dataset.py` (Task 4) applies when filtering for the HuggingFace splits. The expectation is that the high+medium tier together yields roughly half of the candidate Pangti spans, of which the studio-quality subset is the training set.

A `high`-tier segment is **safe to train on without review**: the matcher was confident, the coverage was strong, the boundaries are tight, no repeats, normal duration. We treat it as ground truth.

A `medium`-tier segment is **training-eligible with curriculum-learning rules**: we train on `high` first, let loss stabilise, then mix in `medium`. If validation degrades when `medium` is added, we move `medium` to a held-out set instead.

A `needs_review` segment is **excluded from training until a Sevadaar inspects it**. This is the bulk of v1 output and is the input to the future labeller UI.

---

## 7. Re-run protocol

When Deep does run this on real audio, the validation steps are:

1. Pick a Phase 1 sample with known confidence — start with `babiha 2.mp3` (Phase 1 conf 81.1, no obvious repetition in the report).
2. Run: `python scripts/align_sample.py audio samples/babiha\ 2.mp3 --model medium`.
3. Open the produced JSON. Verify:
   - `tier_counts.high` ≥ 1 (the expected outcome for a clean, non-repeating, confidently-matched sample).
   - Every `high`-tier segment's `text_gurmukhi` is present and matches the corpus at the claimed `(ang, pangti_index)`.
   - Every `high`-tier segment's duration is in [1.5, 25] s.
4. Re-run on `harjinder singh 3.mp3` (the repetition canonical). Verify:
   - `tier_counts.high == 0`
   - All P19 segments share one `repeat_group_id`
   - Every P19 segment has `alignment_quality == "needs_review"`
5. Re-run on `waheguru 1.mp3` (negative test, Simran). Verify:
   - Either no `pangti` segments at all, OR all `pangti` segments are `needs_review` with `match_confidence < 65`. The non-negotiable safety property from Phase 1.
6. If any of the above violate expectations, do not produce a dataset — debug the aligner first. The cost of building a corrupt dataset is much higher than the cost of a one-day debug delay.

Steps 3–5 collectively form the "v1 aligner is correct enough to use" gate.
