# GurbaniLens Kirtan Dataset

_An open dataset for training Sikh-Kirtan ASR models. Phase 2B output. v1, in active construction._

This directory holds a content-addressed, splits-and-manifest snapshot of the **Kirtan ASR training corpus** that the GurbaniLens project builds and releases as Seva infrastructure. The intent is that any Sikh-AI project — not just GurbaniLens — should be able to clone this directory, pull the audio referenced by `manifest.json`, and fine-tune a Whisper-family model against it.

If you are a researcher, hobbyist, Gurdwara tech volunteer, or another Sikh-AI project: **you are welcome to use this dataset under the licence in §5 below.** Contributions are also welcome — see §6.

---

## 1. What this dataset is (and is not)

**Is:**
- A set of `(audio_span, Gurmukhi_text)` pairs, where each `audio_span` is a slice of a real Kirtan recording and each `Gurmukhi_text` is the matched SGGS Pangti.
- Sourced from real Kirtan performances by named Ragis / jathas, traced back to their `source_url` (typically YouTube, Gurdwara broadcasts, or personal recordings shared with permission).
- Built with conservative quality gates — every training row went through automated alignment + tier-scoring (and, where available, Sevadaar review).
- Open: alignments and metadata are CC-BY-SA-4.0; you can use, modify, and redistribute the *labels* freely, with attribution and share-alike.

**Is not:**
- A general Punjabi-speech dataset. This is specifically Kirtan — sung Gurbani — which has very different acoustic properties from spoken Punjabi.
- A redistribution of copyrighted audio. **Audio files are not included in this directory.** `manifest.json` lists `source_url` for each sample; you re-fetch the audio from the source under whatever terms apply there.
- A complete or finished corpus. v1 is small (target: ~5 hours of high-tier audio) and explicitly biased toward clean-studio recordings. v2 expands to live-Gurdwara, multi-jatha, multi-raag coverage.

---

## 2. Directory layout

```
dataset/
├── README.md           ← this file
├── manifest.json       ← which samples + alignments are in this build, with build_id
├── splits/
│   ├── train.json      ← ~80% of samples — for fine-tuning
│   ├── val.json        ← ~10% of samples — for early-stopping / checkpoint selection
│   └── test.json       ← ~10% of samples — held out, only touched at end of project
├── alignments/         ← per-sample segment JSONs (CC-BY-SA-4.0, our work)
│   └── <sample_id>.json
└── audio/              ← symlinks (or copies with --copy) to samples/
                         (this subdir is gitignored — audio itself is gitignored upstream)
```

**Split assignment is deterministic by sample id.** All segments from the same audio file land in the same split — no segment leakage. The hash is `sha256(sample_id) -> first 4 bytes -> mod 100`; buckets 0–79 = train, 80–89 = val, 90–99 = test. This means adding new samples never reshuffles existing assignments.

---

## 3. Training row schema

Each entry in `splits/*.json` is one training-eligible Pangti span:

```json
{
  "sample_id": "sha256:abc123…",
  "segment_idx": 4,
  "audio": "audio/bhai_harjinder_singh_srinagar_soohee_626_19_studio.mp3",
  "audio_sha256": "ab12cd34…",
  "start_sec": 3.6,
  "end_sec": 8.3,
  "duration_sec": 4.7,
  "sentence": "ਜੀਅ ਜੰਤ ਤੇਰੇ ਧਾਰੇ",
  "text_latin": "jeea jant tere dhaare",
  "ang": 626,
  "pangti_index": 19,
  "shabad_id": "ZT4",
  "match_confidence": 88.2,
  "coverage": 0.85,
  "alignment_quality": "high",
  "jatha": "bhai_harjinder_singh_srinagar_wale",
  "raag": "soohee",
  "recording_quality": "studio",
  "source_url": "https://www.youtube.com/watch?v=…",
  "license_notes": "User-uploaded; redistribution unclear; reference by URL only"
}
```

The `audio` field is a path relative to this `dataset/` directory. HuggingFace's `Audio` feature class reads it directly:

```python
from datasets import load_dataset, Audio

ds = load_dataset("json", data_files={
    "train": "dataset/splits/train.json",
    "val":   "dataset/splits/val.json",
    "test":  "dataset/splits/test.json",
})
ds = ds.cast_column("audio", Audio(sampling_rate=16000))
# Train against ds["train"], early-stop on ds["val"], publish numbers on ds["test"].
```

The `sentence` key follows HuggingFace's Whisper-fine-tune convention (transformers expects target text under `sentence` when using `WhisperTokenizer`). The `text_latin` key is provided for matcher-side regression checks.

---

## 4. Eligibility predicate (what made it into the splits)

A segment was included iff **all** of these held — see `docs/alignment_accuracy.md` §6 for the rationale:

1. `alignment_quality in {"high", "medium"}` — auto-rejected `needs_review` and `n/a`.
2. `kind == "pangti"` — rejected `alaap`, `silence`, `overlap`, `unknown`.
3. `text_gurmukhi` is present — we need the target text to train against.
4. `repeat_group_id is None` — in v1 we exclude all segments belonging to a detected repeat group. This is conservative (some are perfectly fine training data) but it eliminates the silent-poison-the-training-set failure mode described in `docs/DATASET_PHILOSOPHY.md` §1.
5. Parent sample's `recording_quality in {"studio", "clean_live"}` — no archival, no broadcast artefacts, no noisy_live. These tiers will be re-included in v2 with appropriate per-tier loss weighting.

`manifest.json.eligibility_predicate` records the exact predicate that was applied for the current build, so a downstream consumer can reproduce or audit the filtering.

---

## 5. License

**Alignments and metadata** (everything in `splits/`, `alignments/`, `manifest.json`, this README): **Creative Commons Attribution-ShareAlike 4.0 International (CC-BY-SA-4.0)**.

Why CC-BY-SA-4.0:
- **Attribution** so the Sikh AI community knows who built the labels and can cite the project.
- **ShareAlike** so derivative datasets stay open. Closed-source forks of the labels would undermine the Seva intent.
- **Not CC-0** because attribution preserves the chain of provenance — a critical property for a dataset that will be used to train models for Darbar Sahib.

**Audio files** referenced by `source_url` are subject to **their own licenses**, set by the original uploader / broadcaster / performer. The dataset asserts no rights over the audio; we only label it. If you re-distribute audio along with the labels, that's on you to clear.

**Code** (`scripts/build_dataset.py`, `scripts/align_sample.py`, the rest of the GurbaniLens repo): see the project-root `LICENSE` file.

---

## 6. How to contribute

The dataset grows through three contribution paths:

### 6.1 Contribute audio (`samples/`)

Most-needed. We are explicitly trying to broaden:
- Jatha coverage (AKJ, Taksali, Damdami, traditional, modern)
- Raag coverage (the 31 raags of SGGS — many are under-represented in available recordings)
- Recording-quality coverage (clean studio is over-represented relative to live Gurdwara)

To contribute a recording:
1. Get permission from the recording's rights-holder, OR confirm it's openly licensed.
2. Use `scripts/fetch_samples.py local <path> --label <jatha>_<raag>_<ang>_<pangti>_<difficulty>` (or `youtube <url>` for an openly-licensed YouTube source).
3. Add a metadata entry to `samples/registry.json` per the schema in `samples/MANIFEST.md`.
4. PR the registry change. Audio itself stays gitignored — it's referenced by `source_url`.

### 6.2 Contribute alignments

Run `python scripts/align_sample.py audio samples/<filename>` against samples that are in the registry but have `alignment_status: pending`. The script outputs to `samples/alignments/<id>.json`. PR that JSON file + the registry update that flips `alignment_status` to `machine_aligned`.

### 6.3 Contribute Sevadaar review

For samples with `alignment_status: machine_aligned`, the segments tagged `needs_review` are blocking — they hold back potentially-good training data because the machine couldn't confirm them. A reviewer with Gurbani knowledge can listen to a sample, confirm or correct each `needs_review` segment, and flip it to `high` / `medium` / `excluded`. The labeller UI for this is Phase 2B v2 — until it exists, manual JSON edits are accepted with `labeled_by: "human:<initials>"`.

All contributions go through normal GitHub PR review.

---

## 7. Reproducing a build

```sh
# Rebuild from current registry + alignments
python scripts/build_dataset.py build

# Validate on-disk consistency
python scripts/build_dataset.py validate

# Print stats
python scripts/build_dataset.py stats
```

The `manifest.json.build_id` is a content hash over the sample SHA-256s — two machines with the same `samples/registry.json` + `samples/alignments/` will produce the same `build_id`. If yours differs from a release build, your inputs differ; check the registry diff.

---

## 8. Provenance

- **`docs/DATASET_PHILOSOPHY.md`** explains *why* the schema is shaped this way — the Kirtan-repetition finding from the aeneas spike, the tier system, and the v1 quality bar.
- **`samples/MANIFEST.md`** documents the source samples themselves: taxonomy, filename convention, per-sample metadata schema.
- **`docs/alignment_accuracy.md`** documents the v1 aligner's accuracy bar and the per-sample expected behaviour.
- **`docs/finetuning_plan.md`** is the (research-only, no execution) plan for the first fine-tune run that consumes this dataset.

Read them in roughly that order if you want to understand how the dataset was built.

---

## 9. Current state of this build

Run `python scripts/build_dataset.py stats` to see the latest. At time of writing (2026-06-17), the first build is necessarily empty: the alignment pipeline is built but no samples have been aligned yet on this host. The first real build will happen when:

1. Deep imports the 13 Phase 1 samples + the new 50+ he is collecting into `samples/registry.json`.
2. `align_sample.py` is run against each — producing `samples/alignments/*.json`.
3. `build_dataset.py build` is re-run.

The v1 release target is ~5 hours of `high`-tier audio across ≥ 5 jathas, ≥ 5 raags, ≥ 200 distinct Pangtis. The `manifest.json` shows current coverage vs. that bar.
