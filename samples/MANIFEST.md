# Samples Manifest

_Last updated 2026-06-17. Owner: dataset agent. Authoritative companion: `samples/registry.json`._

The `samples/` directory holds the raw audio inputs to Phase 2B. Audio files are **gitignored** (see `.gitignore` lines 18–25) — only this manifest, `registry.json`, and `.gitkeep` are committed. Audio is shared out-of-band (cloud bucket / direct transfer).

This document is the human-readable index. `registry.json` is the machine-readable source of truth. If they disagree, `registry.json` wins and this doc should be updated.

---

## 1. Why audio is gitignored

- Most samples are sourced from YouTube, broadcaster archives, or Gurdwara recordings whose licenses are unclear or non-redistributable.
- Even where the recording is freely shareable, the file sizes (multi-MB to multi-GB for Akhand Paath) would bloat the repo.
- The alignments we produce (Task 3 output, in `samples/alignments/` and later `dataset/alignments/`) are **our original work** and are committed under CC-BY-SA-4.0. The audio they reference is sourced via `source_url` in the registry.

This separation is deliberate: alignments are open dataset infrastructure, audio is referenced by URL. Anyone reproducing the dataset re-fetches audio from `source_url` using `scripts/fetch_samples.py`.

---

## 2. Current samples (inherited from Phase 1)

13 samples were used in the Phase 1 evaluation (`evaluation/phase1_medium_report.md`). All present on Deep's Phase 1 machine, all gitignored. Listed here for posterity; their `registry.json` entries will be backfilled as Deep re-imports them via `fetch_samples.py local …`.

| # | Filename (Phase 1) | Dur | Phase 1 best match (medium) | Conf | Phase 1 best match (large-v3) | Conf | Notes |
|---|---|---|---|---|---|---|---|
| 1 | `babiha 1.mp3` | 0:10 | Ang 488:P12 | 40.0 | (see large-v3 report) | — | very short clip |
| 2 | `babiha 2.mp3` | 0:38 | Ang 1138:P1 | **81.1** | — | — | clean studio, both windows confident |
| 3 | `babiha 3.mp3` | 0:29 | Ang 694:P1 | 0.0 | — | — | Whisper produced Kannada glyphs (script confusion) |
| 4 | `babiha 4.mp3` | 0:28 | Ang 250:P12 | 17.2 | — | — | |
| 5 | `harjinder singh 1.mp3` | 0:34 | Ang 372:P2 | **78.6** | — | — | studio, Rahao |
| 6 | `harjinder singh 2.mp3` | 0:37 | Ang 372:P2 | 74.5 | — | — | near-miss to same Shabad as #5 |
| 7 | `harjinder singh 3.mp3` | 1:03 | Ang 626:P19 | **87.8** | — | — | **canonical aeneas-spike sample** (P19a/b × 4+ repeats) |
| 8 | `harjinder singh 4.mp3` | 0:59 | Ang 626:P18 | 65.2 | — | — | near-miss to same Shabad as #7/#9 |
| 9 | `harjinder singh 5.mp3` | 1:28 | Ang 626:P18 | **91.1** | — | — | studio, highest confidence in Phase 1 |
| 10 | `japji sahib 1.mp3` | 0:04 | Ang 2:P7 | 71.8 | Ang 2:P7 | **96.6** | spoken Paath — Phase 1 proof that recitation is cleaner ASR input than Kirtan |
| 11 | `satnam singh 1.mp3` | 0:57 | Ang 1293:P15 | 0.0 | — | — | |
| 12 | `satnam singh 2.mp3` | 1:06 | Ang 457:P18 | 51.7 | — | — | |
| 13 | `waheguru 1.mp3` | 0:24 | Ang 962:P6 | 67.9 | — | — | **Simran (negative test) — must never confidently match** |

The four samples we know to be confidently matched on `medium` are #2, #5, #7, #9 — these are the candidates for the first end-to-end alignment runs in Task 3. `harjinder singh 3.mp3` is the canonical test case per Phase 1 + the aeneas spike.

**Caveat on durations:** Phase 1 sample audio is not on this dataset-agent machine. Durations above are from the Phase 1 evaluation report, not re-probed with `ffprobe`. When Deep re-imports them, the `register` command will re-probe and write authoritative values to `registry.json`.

---

## 3. Sample categories Deep is collecting

Per the brief, Deep is gathering 50+ new samples in parallel. The target distribution:

| Category | Target count | Purpose |
|---|---|---|
| `studio_clean` | 15 | High-confidence machine alignment, primary source of `high`-tier training segments |
| `live_gurdwara` | 15 | Realistic mic conditions, mid-quality alignment, validates v2 robustness |
| `varied_raags` | 10 | At least 10 distinct raags so the fine-tuned model doesn't overfit to one raag's melodic structure |
| `varied_jathas` | 5 | At least 5 jatha traditions — AKJ, Taksali, Damdami Taksal, modern professional, traditional Ragi |
| `challenging` | 5 | Edge cases for v2 robustness: Nagar Kirtan (street, very noisy), kid Kirtan (young voices), rabab/dilruba (instrumental-dominant), archival (low-fi historic recording), processed broadcast (TV/satellite compression artefacts) |

These are **dimensions, not exclusive buckets** — one recording can satisfy multiple categories (a studio recording in a rare raag by an AKJ jatha counts for `studio_clean` + `varied_raags` + `varied_jathas`). The registry's per-sample tags capture which dimensions each recording contributes to.

### v1 dataset coverage targets (recap from DATASET_PHILOSOPHY.md §7)

- ≥ 5 hours of `high`-tier `pangti` segments
- ≥ 5 distinct jathas represented
- ≥ 5 distinct raags represented
- ≥ 200 distinct Pangtis covered (not 200 repeats of one Rahao)

Sample collection should be driven by these coverage targets, not by raw count.

---

## 4. Filename convention

```
<jatha-slug>_<raag-slug>_<ang>_<pangti>_<difficulty>.<ext>
```

Examples:

```
bhai_harjinder_singh_srinagar_soohee_626_19_studio.mp3
akj_jatha_ny_aasaa_372_2_live.mp3
unknown_raag_unknown_unknown_unknown_nagar_kirtan.mp3
```

### Slot definitions

| Slot | Required | Format | Notes |
|---|---|---|---|
| `jatha-slug` | yes | snake_case ASCII | jatha or lead Ragi. Use `unknown_jatha` if uncertain. Full name with title (`bhai_`, `bibi_`, `gyani_`) for individual Ragis; descriptive slug (`akj_jatha_<city>`, `taksali_jatha`) for jatha-name recordings |
| `raag-slug` | yes | snake_case ASCII | Standard raag transliteration. Use `unknown_raag` if uncertain. The registry maintains the canonical raag taxonomy under `registry.raags` (see §6) |
| `ang` | yes | integer or `unknown` | Starting Ang in SGGS (1–1430). For multi-Shabad recordings, use the first Ang |
| `pangti` | yes | integer or `unknown` | Starting Pangti index within the Ang. Use `unknown` if the recording spans the whole Shabad with no clear starting Pangti |
| `difficulty` | yes | one of `studio`, `live`, `noisy`, `nagar_kirtan`, `kid`, `instrumental`, `archival`, `broadcast`, `paath_recitation`, `simran` | Coarse category — drives quality-tier expectations. `paath_recitation` and `simran` distinguish non-Kirtan audio |
| `ext` | yes | `mp3`, `wav`, `m4a`, `flac` | Prefer `mp3` at 16 kHz mono (what `fetch_samples.py` produces) |

### Backwards compatibility

Phase 1's filenames (`harjinder singh 3.mp3`, `babiha 1.mp3`) **do not match the convention**. They are grandfathered — the registry maps their legacy names to canonical metadata via the `legacy_name` field rather than forcing a rename. New samples must follow the convention.

The convention is enforced by `scripts/fetch_samples.py local` when given a `--label` that the registry can parse; non-conforming labels write a warning to stderr but proceed (we don't want to block import of an obvious-but-unconventional name).

---

## 5. Per-sample metadata schema

Each entry in `registry.json` is one object with this shape. All `null`-able fields can be filled in incrementally as a Sevadaar reviews the sample.

```json
{
  "id": "stable-uuid-v4-or-content-hash",
  "filename": "bhai_harjinder_singh_srinagar_soohee_626_19_studio.mp3",
  "legacy_name": "harjinder singh 3.mp3",
  "audio_sha256": "ab12cd34…",
  "duration_sec": 63.4,
  "file_size_bytes": 1015234,
  "sample_rate_hz": 16000,
  "channels": 1,
  "codec": "mp3",

  "jatha": "bhai_harjinder_singh_srinagar_wale",
  "jatha_tradition": "modern",
  "raag": "soohee",
  "ang_start": 626,
  "ang_end": 626,
  "pangtis_covered": [19],
  "shabad_id": "ZT4",

  "recording_quality": "studio",
  "difficulty": "studio",
  "categories": ["studio_clean"],
  "voice_count": 1,
  "has_alaap": true,
  "has_overlap": false,
  "has_announcement": false,

  "source_url": "https://www.youtube.com/watch?v=...",
  "source_type": "youtube",
  "source_attribution": "Bhai Harjinder Singh ji Srinagar Wale, official channel",
  "license_notes": "User-uploaded; redistribution unclear; reference by URL only",

  "phase1_eval": {
    "best_match_medium": {"ang": 626, "pangti": 19, "confidence": 87.8},
    "best_match_large_v3": null,
    "matched_shabad_id": "ZT4"
  },

  "alignment_status": "pending",
  "alignment_file": null,

  "added_by": "deep",
  "added_at": "2026-06-17",
  "notes": "Canonical aeneas-spike sample — P19a/P19b alternation × 4+"
}
```

### Field rules and enums

| Field | Type | Enum / format | Notes |
|---|---|---|---|
| `id` | string | UUIDv4 or `sha256:<hex>` | Stable across re-imports. Use content hash when possible |
| `filename` | string | follows convention §4 | Authoritative path within `samples/` |
| `legacy_name` | string \| null | freeform | Original filename if grandfathered from Phase 1 |
| `audio_sha256` | string | `[0-9a-f]{64}` | SHA-256 of the audio bytes — proof of identity |
| `duration_sec` | number | seconds, float | From `ffprobe` |
| `sample_rate_hz` | int | typically `16000` | |
| `jatha_tradition` | enum | `akj`, `taksali`, `damdami`, `modern`, `traditional`, `unknown` | One per recording, simplification — multi-tradition collaborations get `mixed` |
| `raag` | string | from `registry.raags` taxonomy | Canonical slug. Add new raags to the taxonomy before referencing |
| `ang_start` / `ang_end` | int | 1–1430, or `null` if non-SGGS (Simran, Aarti, etc.) | |
| `pangtis_covered` | int[] \| null | Pangti indices known to appear | Sevadaar fills in after listening. Drives Task 3 alignment-search bounds |
| `shabad_id` | string \| null | Shabad OS database ID | Single Shabad recordings only |
| `recording_quality` | enum | `studio`, `clean_live`, `live_mic`, `noisy_live`, `archival`, `broadcast` | Drives default `alignment_quality` ceiling — `archival`/`broadcast` segments cap at `medium` even if matcher confidence is high |
| `difficulty` | enum | same enum as §4 filename slot | |
| `categories` | string[] | from §3 category list | Used to compute coverage against v1 targets |
| `voice_count` | int | 1, 2, 3+ | 2+ voices likely means overlap segments — flag for Sevadaar review |
| `has_alaap` / `has_overlap` / `has_announcement` | bool | | Hints to the aligner; can be set after first alignment pass |
| `source_url` | string \| null | URL | Where the audio was sourced |
| `source_type` | enum | `youtube`, `gurdwara_direct`, `broadcaster`, `personal_recording`, `archived_dataset` | |
| `source_attribution` | string | freeform | Whose recording, what channel — credit |
| `license_notes` | string | freeform | License situation. Conservative: assume non-redistributable unless explicit |
| `phase1_eval` | object \| null | structured | Phase 1 match results when known. Useful for regression-checking against fine-tuned models |
| `alignment_status` | enum | `pending`, `in_progress`, `machine_aligned`, `human_reviewed`, `excluded` | Workflow state |
| `alignment_file` | string \| null | path | Relative to repo root, e.g. `samples/alignments/<id>.json` |
| `added_by` | string | `deep`, `claude`, contributor handle | |
| `added_at` | string | `YYYY-MM-DD` | |
| `notes` | string | freeform | |

### Excluded samples

If `alignment_status == "excluded"`, the sample stays in the registry but never makes it into the dataset. Use this for samples that turn out to be unusable (bad audio, unrecognised content, license-blocking). Always include a `notes` reason.

---

## 6. Raag taxonomy

`registry.json` includes a top-level `raags` object mapping canonical slugs to display info. Initial seed covers the 31 raags of SGGS plus a few common variants and the `unknown_raag` fallback. Add to this list when a new raag is encountered; do not invent ad-hoc slugs in sample entries.

The taxonomy lives in the registry (not a separate file) so it stays in lockstep with the samples that reference it.

---

## 7. Workflow for adding a new sample

1. **Acquire audio** — `python scripts/fetch_samples.py youtube <url> --label <jatha>_<raag>_<ang>_<pangti>_<difficulty>` or `local <path> --label …`.
2. **Probe** — `ffprobe` runs automatically inside the fetch script; resulting `duration_sec`, `sample_rate_hz`, `codec` flow into registry.
3. **Compute SHA-256** — script writes `audio_sha256` and the stable `id`.
4. **Manually fill** the human-judgement fields: `jatha_tradition`, `raag`, `ang_start/end`, `pangtis_covered` (best-effort), `recording_quality`, `voice_count`, `source_*`, `license_notes`, `notes`.
5. **Append entry** to `registry.json` (`samples` array).
6. **Run alignment** (Task 3) — `python scripts/align_sample.py <filename> <ang_start> <ang_end>` → writes `samples/alignments/<id>.json`, updates registry `alignment_status` and `alignment_file`.
7. **Sevadaar review** (when v2 labeller ships) — flips `alignment_status` from `machine_aligned` to `human_reviewed`.

Step 5 is currently manual — the brief defers a `fetch_samples.py register` subcommand to a later task. Until then, edit `registry.json` directly. Validate the file with `python -m json.tool < samples/registry.json` after edits.

---

## 8. Open questions

- **Mid-recording Shabad transitions.** A 30-minute Kirtan recording often covers 2–3 Shabads. Current schema allows `ang_start != ang_end` but doesn't break the recording into per-Shabad segments at the metadata level. We may want a `shabads` array of `{ang_start, ang_end, shabad_id, time_start_sec?, time_end_sec?}` once we have a recording that needs it. Defer until first such sample exists.
- **Audio storage.** Long-term, we want a public bucket where alignments can resolve `source_url` against a content-addressed cache. Out of scope for v1 — the registry just records the URL.
- **License-clean re-recording.** For samples whose license is unclear but which prove valuable in training, the right long-term answer is to commission new recordings under explicit Creative Commons. Out of scope for v1 — flag the candidates in `notes` for follow-up.
