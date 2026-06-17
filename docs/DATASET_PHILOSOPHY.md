# Dataset Philosophy — Phase 2B Kirtan ASR Training Corpus

_Written 2026-06-17. Owner: dataset agent (Claude). Status: foundational — informs all subsequent Phase 2B tooling._

This document records the most important finding from the Phase 1 → Phase 2B handoff, and the dataset-construction principles it forces on us. Read this before writing any alignment script, labeller, or training pipeline.

---

## 1. The Kirtan-repetition finding

Source: `docs/aeneas_spike.md`, run 2026-05-13 on `samples/harjinder singh 3.mp3` (the canonical Phase 1 confidently-matched sample — Ang 626, Pangti 19).

### What was tried
1. **aeneas** (the textbook forced-alignment tool used for audiobooks). Failed to install — abandoned PyPI package, unmaintained since 2017, build-time numpy hooks broken, eSpeak system dep missing. Not a tooling gap we can paper over; aeneas is dead.
2. **faster-whisper `word_timestamps=True`** on the same sample, medium model, no VAD. 23 word-level timestamps captured over 65 s of audio.

### What the timestamps showed

The Ragi was singing **two adjacent Pangtis from Ang 626, in alternation, four or more times** across the 65 s clip:

```
P19a: jeea jant tere dhaare       (Whisper heard: "jee jaant tere taare")
P19b: prabh ddoree haath tumaare  (Whisper heard: "rab doree raap tumaaree")
```

The alignment was *correct at the word level* — Whisper's timestamps are accurate to ~100 ms, the phonetic drift is consistent with Phase 1's `to_latin` normalisation, and the matcher's Phase 1 hit on Ang 626 P19 was right.

**But the temporal structure is not what aeneas, audiobook aligners, or Whisper's own monotonic decoder assume.** All of those tools assume audio words map to transcript words in a single forward sweep. Kirtan does not work that way.

### What broke

If you took this 65 s of audio and naively force-aligned it to Ang 626's text starting at P19, every alignment tool we have would do one of two wrong things:

1. **Stretch one Pangti pair across 65 s** — losing all repetition structure, producing two enormous time-spans that span repeats.
2. **March forward through the corpus** — aligning the first repeat to P19, the second repeat to P20, the third to P21, etc. The training labels would be wrong: the model would learn that "jeea jant tere dhaare" is the audio for P20 and P21 too. This poisons the training set silently.

Both failure modes are silent. Neither tool will tell you the alignment is wrong.

### What worked

The Phase 1 matcher — token-coverage × partial_ratio × length factor — *did* identify the right Pangtis (P19a and P19b), and would have rejected the spurious P20/P21 matches because they share no tokens with what Whisper heard. The matcher's per-window hypothesis is the right baseline; the aligner's job is to consume that hypothesis, not to ignore it.

---

## 2. What this implies for dataset construction

The naive mental model — "we have audio, we have the text, run forced alignment, get a labeled training set" — is wrong for Kirtan. Five concrete consequences:

### 2.1 Kirtan time ≠ corpus time

A single Pangti can occupy 30 seconds of audio (sung slowly with alaap), or 2 seconds (a quick repeat in a fast Rahao). Adjacent Pangtis in the corpus can be 5 minutes apart in audio (Ragi expounds, then returns) or simultaneous (Pangti repeated by the second jatha member). **Pangti index ≠ time index, and the map is many-to-many.**

### 2.2 The Rahao multiplier

The Rahao (the "pause" / chorus line) is structurally designed to be repeated. In a typical Shabad, the Rahao is sung 4–10 times across the rendition, interleaved with the other Pangtis. Any aligner that produces one (Pangti, start, end) row per Rahao occurrence is wrong by a factor of 4–10× — and biases the training set toward over-representation of Rahao text.

### 2.3 Alaap is not Gurbani

Alaap (melodic improvisation on a vowel, no Gurbani text) is interleaved with the Pangtis. It looks like audio, the Ragi is clearly performing, but **there is no transcript for it**. Forced alignment will either (a) inflate the duration of the nearest Pangti to absorb the alaap, or (b) align random Whisper hallucinations to spurious Pangtis. Both poison the training set. Alaap segments must be **labeled and excluded**, not aligned.

### 2.4 Multi-jatha and overlap

Akhand Paath has handoffs between Pathis. Kirtan often has two voices (lead + accompaniment) singing different Pangtis simultaneously or in close call-and-response. A single (start, end, pangti) row cannot represent overlap. Either we accept that overlap segments are unlabelable (mark them and exclude), or we add a `voice` channel to the schema. v1 punts on overlap by marking it.

### 2.5 Backward jumps are first-class

The Ragi can and does return to a previous Pangti — sometimes 30 seconds back, sometimes 5 minutes. A monotonic aligner cannot represent this. The data model must allow the same Pangti to appear in multiple non-adjacent time spans, and the aligner must be able to *detect* that a backward jump happened (the matcher already can, per-window; the aligner just needs to trust it).

---

## 3. Dataset structure (recommended)

Given the above, the unit of labeled data is **a labeled time-span**, not a labeled Pangti. The schema:

```json
{
  "audio_file": "samples/<slug>.mp3",
  "audio_sha256": "<hex>",
  "duration_sec": 1247.3,
  "sample_rate_hz": 16000,
  "metadata": {
    "jatha": "bhai_harjinder_singh_srinagar_wale",
    "raag": "soohee",
    "recording_quality": "studio",
    "source_url": "https://...",
    "notes": "..."
  },
  "segments": [
    {
      "start_sec": 0.0,
      "end_sec": 3.6,
      "kind": "pangti",
      "ang": 626,
      "shabad_id": 3251,
      "pangti_index": 19,
      "pangti_part": "a",
      "text_latin": "jeea jant tere dhaare",
      "text_gurmukhi": "ਜੀਅ ਜੰਤ ਤੇਰੇ ਧਾਰੇ",
      "match_confidence": 88.2,
      "alignment_quality": "high",
      "labeled_by": "machine"
    },
    {
      "start_sec": 3.6,
      "end_sec": 8.34,
      "kind": "pangti",
      "ang": 626,
      "shabad_id": 3251,
      "pangti_index": 19,
      "pangti_part": "b",
      "text_latin": "prabh ddoree haath tumaare",
      "text_gurmukhi": "ਪ੍ਰਭ ਡੋਰੀ ਹਾਥ ਤੁਮਾਰੇ",
      "match_confidence": 84.5,
      "alignment_quality": "high",
      "repeat_group_id": "rg_a1",
      "labeled_by": "machine"
    },
    {
      "start_sec": 8.34,
      "end_sec": 14.40,
      "kind": "pangti",
      "ang": 626,
      "pangti_index": 19,
      "pangti_part": "a",
      "repeat_group_id": "rg_a1",
      "...": "second repeat of P19a"
    },
    {
      "start_sec": 42.1,
      "end_sec": 47.8,
      "kind": "alaap",
      "alignment_quality": "n/a",
      "labeled_by": "machine"
    },
    {
      "start_sec": 89.0,
      "end_sec": 94.5,
      "kind": "overlap",
      "alignment_quality": "n/a",
      "notes": "lead + tabla improv vocal — unlabelable",
      "labeled_by": "machine"
    }
  ]
}
```

### Design notes

- **`kind` is the discriminator.** `pangti` segments are training data. `alaap`, `overlap`, `silence`, `applause`, `announcement`, `unknown` segments are *non-training* — they're labeled so we know to exclude them and so QA can spot when a labeler misclassifies. **Do not throw them away** — knowing where the alaap is is itself useful (for Phase 2A v2's continuous-listener to ignore alaap).
- **`pangti_part`** (`a` / `b` / `c` …) handles the SGGS convention that one Pangti is often two text-lines. Phase 1's matcher already operates at the part level; we follow suit.
- **`repeat_group_id`** ties together repeats of the same Pangti within one rendition. The fine-tuner can use this to downweight repeated samples (so the Rahao doesn't dominate the loss), or upsample under-represented Pangtis. The aligner just has to assign the same group ID to all instances of the same Pangti from the same rendition.
- **`alignment_quality`** is a coarse three-tier label — see §4.
- **`labeled_by`** is `"machine"` until a human reviews; then it becomes `"human:<initials>"`. Mixed (machine span + human-corrected boundary) is `"human:<initials>"`.

### What this is NOT

It is not a HuggingFace `Audio` dataset row yet. The HF-style row (one (audio_slice, transcript) per training example) is **derived** from this schema by the dataset builder (`scripts/build_dataset.py`, Task 4), which slices the audio by `pangti` segments and emits the training rows. We keep the labeled-time-span form as the source of truth because it preserves the structure that fine-tuning will eventually need (curriculum learning, repeat downweighting, alaap-region augmentation).

---

## 4. Quality bar — three tiers

Not every aligned segment is good enough to train on. We use three tiers, recorded per-segment in `alignment_quality`:

### `high` — machine-aligned, safe to train on without review

All of:
- Phase 1 matcher confidence ≥ 80 on the segment
- Strong word overlap (≥ 70% of Whisper words present in corpus Pangti, after `to_latin`)
- Temporal boundaries land near (within ~300 ms of) Whisper word-timestamp boundaries
- Segment is **monotonic** within its local 10 s window (no repeats inside the span itself)
- Duration is plausible (between 1.5 s and 25 s per Pangti — flags very fast or very slow segments for review)

These can be auto-promoted into the training set. Target: ≥ 50% of clean-studio segments hit this tier.

### `medium` — machine-aligned, training-eligible with caveat

Matcher confidence 65–80, OR word-overlap 50–70%, OR boundary uncertainty 300–800 ms. Include in training but mark; useful for curriculum learning (train on `high` first, then mix in `medium` after loss stabilises) and for measuring whether `medium`-tier inclusion helps or hurts validation metrics.

### `needs_review` — must be touched by a human

Any of:
- Matcher confidence < 65
- Repeated Pangti detected (`repeat_group_id` assigned by aligner) — human confirms grouping is correct
- Segment is at a boundary between two adjacent corpus Pangtis (we can't tell from confidence alone which one it really is)
- `kind` is `alaap`, `overlap`, `silence`, `announcement`, `unknown` — even the labels for these need spot-check
- Duration < 1.5 s or > 25 s
- The audio sample crosses an Ang boundary not covered by the requested Pangti range

`needs_review` segments are NOT in training data until a human flips them to `high` or `medium`.

### Repetition is always `needs_review` in v1

This is the most important rule. **Every machine-detected repeat group must go through human review before any of its segments enter the training set.** The Kirtan-repetition finding is exactly the failure mode we're guarding against; we do not trust the machine to resolve repeats correctly yet. The aligner's job is to *flag* repeats correctly (cheap) and *defer* the decision to a human (safe).

This will be relaxed in v2 once we have a few hundred human-confirmed repeat groups to evaluate aligner accuracy against.

---

## 5. Implications for the alignment script (Task 3 preview)

`scripts/align_sample.py` should:

1. Run `faster-whisper` with `word_timestamps=True` and `language=pa` on the audio — same as the spike.
2. Slide the Phase 1 matcher over the Whisper output in overlapping windows, producing per-window Pangti hypotheses (matcher already does this in `cli.py`).
3. **Merge adjacent windows with the same (ang, pangti, pangti_part) hypothesis** into one segment, using Whisper's word timestamps for the segment's `start_sec` and `end_sec`.
4. **Detect repeat groups**: if the same (ang, pangti_part) hypothesis appears in two non-adjacent windows with a gap ≥ 1 s between them, assign both the same `repeat_group_id` and force `alignment_quality = "needs_review"`.
5. **Detect alaap**: stretches where Whisper produces no words for > 2 s, or produces only vowel-like tokens (heuristic: token has no consonants in `to_latin` output), get `kind = "alaap"`.
6. **Detect overlap / unknown**: low matcher confidence (< 50) on a window with high Whisper word-density — emit `kind = "unknown"` and `needs_review`.
7. Apply the §4 tier rules to assign `alignment_quality`.
8. Output the schema in §3.

This is the v1 aligner. It is intentionally conservative — it would rather flag too many segments as `needs_review` than poison the training set. We tune the thresholds based on what fraction of segments come out as `high` on real samples; the goal for the first pass is *correctness of the `high` tier*, not maximising the `high` tier's size.

---

## 6. Implications for the human-in-the-loop labeller (deferred build, post-Task 5)

Per the aeneas spike's recommendation (`docs/aeneas_spike.md` §5), we eventually need a labeller UI for the `needs_review` tier. The dataset schema in §3 is designed so the labeller's job is *editing existing JSON*, not creating from scratch. Specifically the labeller:

- Plays the audio with a moving cursor synced to `segments[].start_sec/end_sec`.
- Shows each segment as a draggable region on a timeline.
- For repeat groups, shows all members highlighted in one colour so the Sevadaar can confirm they're really the same Pangti.
- Lets the Sevadaar split, merge, or re-tag segments (`pangti` → `alaap` for example) and edit Pangti hypotheses against an autocompleter over the SGGS corpus.
- On save, flips `labeled_by` to `"human:<initials>"` and `alignment_quality` to `"high"` (or `"medium"` if the Sevadaar marks uncertain).

This is a Phase 2B v2 build. The v1 dataset uses only machine-aligned `high`-tier segments from clean studio recordings.

---

## 7. Quality > quantity (the v1 bar)

The brief's architectural rule applies directly: **better 5 hours of clean, repetition-free, high-tier-aligned audio than 50 hours of garbage.** The dataset's first usable version is:

- 5 hours of audio
- All from `recording_quality: studio` or `clean_live` samples
- Only `high`-tier `pangti` segments (no `medium`, no `needs_review`, no `alaap`)
- Distributed across at least 5 different jathas (no one Ragi dominates the loss)
- Distributed across at least 5 different raags (so the model doesn't learn a single raag's melody as a feature)
- Total Pangti coverage ≥ 200 distinct Pangtis (not 200 repeats of the same Rahao)

That's the bar at which we attempt the first fine-tune. Anything less and we are tuning to noise.

---

## 8. What this document does NOT cover

Out of scope here, covered in sibling docs:
- Sample taxonomy and filename convention → `samples/MANIFEST.md` (Task 2)
- Alignment script implementation details and accuracy assessment → `docs/alignment_accuracy.md` (Task 3)
- Dataset directory layout and build pipeline → `dataset/README.md` (Task 4)
- Fine-tuning model choice, GPU budget, evaluation protocol → `docs/finetuning_plan.md` (Task 5)

This document is the philosophical foundation those four sit on top of. If any of them contradicts this document, this document is right and the other is the one to fix.
