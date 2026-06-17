# Whisper Fine-Tuning Plan — Phase 2B v1

_Written 2026-06-17. Owner: dataset agent. Status: **research-only — do not execute**. Decision to run is Deep's, gated on the criteria in §9._

This document is the plan for the first serious Whisper fine-tune run that consumes the Phase 2B dataset (`dataset/`). It exists so that when the dataset is ready, Deep doesn't have to figure out the training mechanics under time pressure — every choice below has been thought through, with the *reasoning* recorded so future-Deep can revisit any decision.

No code is executed by this plan. No GPU hours are spent. No model is downloaded. The first call this plan makes is `python scripts/build_dataset.py stats` to check if the inputs are ready — see §9.

---

## 1. Base model choice — `large-v3`

We fine-tune from **`openai/whisper-large-v3`** (1.55 B params).

### Why large-v3, not medium or large-v2

Phase 1's headline number was 31% confident matches on `medium` vs 46% on `large-v3` — a 15-point absolute improvement from model size alone, on the same audio, same matcher, same threshold. More importantly, large-v3's failure modes were qualitatively different: medium would silently transcribe English (`"nan"`, `"at six"`) or Kannada glyphs (`babiha 3.mp3`'s ಥತಟ output), while large-v3 produced plausible Devanagari more consistently. Fine-tuning a model whose mistakes are already in the right script is a much shorter distance to "useful" than fine-tuning one whose mistakes are out-of-distribution garbage.

We don't pick a smaller model for cost reasons — it's a false economy. Fine-tuning `medium` would converge faster and cost less per epoch, but Phase 1 showed `medium`'s ceiling on Kirtan is ~30% confident matches. Pushing that ceiling up takes more data, not more training. We pay the larger-model cost once at training time; inference cost is downstream-deployment's problem.

We don't pick `large-v2` because v3 added Indic language coverage explicitly — including better Punjabi training data. The aeneas spike's clean word-timestamps on `harjinder_singh_3.mp3` confirm Whisper's Punjabi acoustic model is competent; the failure is in the *language* model (mapping acoustic phonemes to the right corpus words). That's exactly what fine-tuning a small head on top of the encoder can fix.

### Alternatives considered and rejected

- **IndicWhisper** (AI4Bharat). Reasonable starting point given its Indic focus, but its training set is general-domain Indic *speech*, not Gurbani-specific sung Kirtan. We'd be paying the cost of switching base models for a marginal improvement that fine-tuning `large-v3` should match.
- **Distil-Whisper** (large-v3 distilled to 750M). Faster inference, similar accuracy on prose English. No published Indic distillation, and distillation typically loses tail-of-distribution accuracy — exactly where Kirtan lives.
- **NeMo / Conformer-CTC**. Different architecture family. Re-tooling the entire matching pipeline around CTC output (no language model, no language detection, different tokenization) is too much scope for v1.

### Updates after model releases

If Whisper-v4 or Whisper-large-v3-turbo lands with proven Indic-fine-tunability before we execute, re-evaluate. The plan below mostly transfers — only the base model identifier and the LoRA rank may need to change.

---

## 2. Fine-tuning approach — **PEFT / LoRA**, not full fine-tune

We do **LoRA (Low-Rank Adaptation) on the decoder cross-attention layers** rather than full-parameter fine-tuning.

### Why LoRA

- **Cost:** full fine-tuning of `large-v3` requires ≥ 80 GB VRAM (one A100-80GB or two A100-40GB with sharding). LoRA at rank 32 trains on a single A100-40GB or even a 3090/4090 (24 GB) with gradient accumulation. That's 4–10× cheaper per epoch.
- **Dataset-size match:** PEFT/LoRA papers consistently show that LoRA matches full fine-tune within 1–2% WER when the training set is < 100 hours. v1's target is 5 hours of high-tier audio; we are deep in LoRA's sweet spot.
- **Reversibility:** LoRA adapters are a separate ~50 MB file. We can publish multiple adapters (raag-specific, jatha-specific, formal vs informal) without re-shipping the base model. This is also how the eventual on-device-only deployment will work — bundle base whisper.cpp + a small LoRA adapter.
- **Iteration speed:** swapping adapters takes seconds; reverting a bad fine-tune takes one CLI flag. Compared to full fine-tuning, where a bad run silently corrupts your checkpoint, LoRA gives us safety.

### LoRA configuration (starting points)

| Hyperparameter | Value | Rationale |
|---|---|---|
| Target modules | `["q_proj", "k_proj", "v_proj", "out_proj"]` on decoder cross-attention layers | Standard Whisper-LoRA recipe (HF Transformers `WhisperForConditionalGeneration` exposes these names). Cross-attention is where acoustic features meet the language model — the right place to adjust for "this sound means this Gurbani word." |
| Rank `r` | 32 | Middle of the published Whisper-LoRA range (8–64). Higher rank = more parameters trained = more capacity but more overfit risk on a small dataset. 32 is conservative; can revisit. |
| Alpha | 64 | `2r` per the LoRA paper. |
| Dropout | 0.05 | Standard. |
| Trainable params | ~9M (≈ 0.6% of full model) | What LoRA buys us — 99.4% of the model is frozen. |

### Why decoder cross-attention specifically, not encoder

The encoder converts audio to acoustic embeddings — that work is *correct* for Gurbani (Whisper hears the right sounds, per the aeneas spike's clean word-timestamps). It's the decoder that fails — mapping acoustic embeddings to the right Gurmukhi/Devanagari tokens. Fine-tuning the encoder would be wasted effort and could even degrade general-language performance.

### Future variant to consider

If v1 results plateau and we want to push further, an *additional* LoRA on the encoder's last 2 self-attention layers may help — there's a subtle adaptation needed for the melodic-prosody-rich input that Kirtan has and prose speech doesn't. v2 question.

---

## 3. Training framework — HuggingFace Transformers

We use `transformers >= 4.40` + `peft >= 0.10` + `accelerate` + `datasets`. This is the path of least resistance:

- HF Transformers has a first-class `WhisperForConditionalGeneration` model and `WhisperFeatureExtractor` / `WhisperTokenizer` that read 16 kHz mono audio (which is what our dataset is).
- HF `datasets` reads our `splits/train.json` directly via `load_dataset("json", data_files=...)` and the `Audio` feature class handles audio loading + resampling.
- HF `peft` ships LoRA wrappers for Whisper. The integration is two lines (`get_peft_model(base, lora_config)`).
- HF `accelerate` handles multi-GPU / mixed-precision / gradient-accumulation without us writing distributed-training boilerplate.

We deliberately avoid:
- **NVIDIA NeMo** — same model is available with more flexibility, but much steeper learning curve and unfamiliar to most downstream contributors.
- **Custom PyTorch training loop** — re-implementing the standard recipe is a waste of time when HF's `Trainer` does it correctly. Reserve custom code for the things HF can't do (a custom Kirtan-aware sampler? — see §5).

### Versions to pin

To keep the run reproducible, the eventual training command should pin:
```
transformers==4.42.x
peft==0.11.x
accelerate==0.30.x
datasets==2.20.x
torch==2.3.x
```

Pin to the actual exact versions at run time; this list is the *family* to target.

---

## 4. Training infrastructure — GPU and cloud

### Recommended setup

- **GPU: one A100-40GB** (or equivalent: H100, A6000, RTX 6000 Ada). LoRA on `large-v3` fits comfortably in 40 GB with batch size 8 and gradient accumulation.
- **Cloud provider options** (rough $/hr as of writing — verify at run time):
  - Vast.ai / RunPod community cloud: $1–1.50/hr A100-40GB
  - Lambda Labs: $1.10/hr A100-40GB on-demand
  - AWS p4d.24xlarge (8× A100): overkill, ~$32/hr, only if we go multi-GPU
  - GCP a2-highgpu-1g: ~$3/hr A100 on-demand
- **CPU + RAM:** 8 vCPU, 32 GB RAM minimum. The audio preprocessing pipeline is CPU-bound during data loading; under-provisioning CPU starves the GPU.
- **Disk:** 200 GB SSD. Base model (~6 GB) + dataset audio (~10 GB for 5h at 16 kHz mono mp3, ~50 GB if WAV) + intermediate checkpoints (~10 GB) + working room.

### Fallback for early experimentation

For a sanity-check run before committing real money: a single **RTX 3090 (24 GB)** is enough for LoRA on `large-v3` with batch size 2 and gradient accumulation of 8 (effective batch 16). This is what an Anyscale / RunPod consumer-tier instance gives you for ~$0.40/hr. Use for debugging the training script, not for the real run.

### What does NOT work

- **Apple Silicon (M2/M3 Max with MPS).** `transformers` Whisper-LoRA training on MPS has been buggy as recently as transformers 4.40 (silent NaNs, weight-update issues with mixed precision). Don't burn a day debugging it — rent the A100.
- **Google Colab free tier.** T4 GPU has 16 GB VRAM; OOMs on `large-v3` LoRA even with batch size 1. Colab Pro (V100) works but you'll be repeatedly disconnected. Use only for tutorial-level experiments.

---

## 5. Data pipeline

### Read path

```python
from datasets import load_dataset, Audio
from transformers import WhisperFeatureExtractor, WhisperTokenizer, WhisperProcessor

ds = load_dataset("json", data_files={
    "train": "dataset/splits/train.json",
    "val":   "dataset/splits/val.json",
}).cast_column("audio", Audio(sampling_rate=16000))

processor = WhisperProcessor.from_pretrained("openai/whisper-large-v3", language="pa", task="transcribe")

def prepare(batch):
    audio = batch["audio"]
    batch["input_features"] = processor.feature_extractor(
        audio["array"], sampling_rate=audio["sampling_rate"]
    ).input_features[0]
    batch["labels"] = processor.tokenizer(batch["sentence"]).input_ids
    return batch

ds = ds.map(prepare, remove_columns=ds["train"].column_names)
```

That's the standard HF Whisper fine-tune recipe; our `splits/*.json` rows are shaped to match it exactly (the `sentence` field is the HF convention).

### Sampling strategy — important

**Naive random sampling will over-represent jathas/raags that have more recordings.** For v1's small dataset, this means the most-recorded jatha (likely Bhai Harjinder Singh) will dominate the loss, and the model will learn to ASR *that voice* rather than *Kirtan*.

We mitigate with **stratified sampling by `(jatha, raag)`** — a custom sampler that yields batches with balanced representation. In HF terms:

```python
from torch.utils.data import WeightedRandomSampler
from collections import Counter

key = lambda row: (row["jatha"], row["raag"])
counts = Counter(key(row) for row in ds["train"])
weights = [1.0 / counts[key(row)] for row in ds["train"]]
sampler = WeightedRandomSampler(weights, num_samples=len(weights), replacement=True)
```

Pass `sampler` to the `Trainer`'s `data_collator` via the standard mechanism.

### Curriculum — high then medium

Train on `alignment_quality == "high"` only for the first epoch (a "warmup" against trusted data). Mix in `medium` from epoch 2 onwards if val loss improved on epoch 1. If val loss got worse, keep `high` only and hold `medium` for a held-out study.

This is implemented by adding a `--epoch-eligibility-tier {high,high+medium}` flag to the training script and changing it between epochs. Not exotic — just disciplined.

---

## 6. Hyperparameters (starting points)

| Hyperparameter | Recommended | Rationale |
|---|---|---|
| Effective batch size | 16 | LoRA tolerates small batches well; 16 hits a good loss-curve smoothness sweet spot for Whisper |
| Per-device batch | 2 (RTX 3090) or 8 (A100-40GB) | VRAM-limited; use gradient accumulation to reach effective 16 |
| Gradient accumulation | 8 or 2 | (depends on per-device) |
| Learning rate | 1e-5 | Standard Whisper-LoRA LR. Lower than full fine-tune (1e-4) because we're updating less |
| LR scheduler | linear warmup → cosine decay | Industry default; works for short runs |
| Warmup steps | 50 | Small dataset → few total steps; 50 warmup is ~5% which is right |
| Epochs | 5 | First-run heuristic. With ~5h training audio and effective batch 16, that's roughly 1000–2000 steps per epoch — enough for convergence but not enough to memorize |
| Max grad norm | 1.0 | Standard clip |
| FP16 / BF16 | BF16 | A100 prefers BF16 (better numerical range); RTX 3090 use FP16 |
| Eval steps | every 100 steps | Frequent eval for early-stopping |
| Save strategy | best on val WER, keep 2 | Don't keep every checkpoint; disk fills |
| Weight decay | 0.01 | Standard |

These are starting points. Expect to tune LR (try 5e-6 and 2e-5 in addition to 1e-5) and epochs (extend if val loss is still improving at epoch 5).

### Reproducibility

Set seed=42 in `TrainingArguments`. Pin all package versions per §3. Record the `manifest.json.build_id` of the dataset that was trained against — that's the dataset's content-hash and lets us reproduce the run.

---

## 7. Evaluation methodology

### Primary: reuse `scripts/evaluate.py` against the Phase 1 13-sample battery

`scripts/evaluate.py` already exists, already produces per-sample reports, and was the measurement instrument used for Phase 1's headline numbers (`evaluation/phase1_medium_report.md`, `phase1_large-v3_report.md`). Reusing it gives us an apples-to-apples comparison against Phase 1.

For the fine-tuned model:
1. Wire the fine-tuned model into `WhisperASR` (the engine class in `core/gurbanilens/asr.py`) via the existing `model_size` parameter — pass the local checkpoint path instead of an OpenAI model name. The faster-whisper-format conversion can be done with `transformers-to-ctranslate2` after the LoRA adapter is merged back into the base.
2. Run `python scripts/evaluate.py --model <path-to-fine-tuned>` against the 13-sample battery.
3. Compare the resulting `evaluation/phase2b_finetuned_*.md` against `phase1_large-v3_report.md` on these axes:
   - **Confident-match rate** (≥75): expect ≥ 60% (vs Phase 1's 46% on large-v3). If less, fine-tune isn't helping enough.
   - **Cluster stability** on harjinder samples 1/3/5: all three should land on the same Shabad (Phase 1 medium did, large-v3 broke 2 of 3). Regression here is a red flag.
   - **Negative-test rejection** on `waheguru 1.mp3`: must remain at < 75. Non-negotiable safety property.
   - **Near-miss inference**: samples that were `medium`-tier near-miss in Phase 1 should mostly promote to confident.

### Secondary: held-out test split

The v1 dataset has its own `dataset/splits/test.json` (deterministic 10% holdout, no overlap with train/val). Compute standard WER + CER on the test split's audio:

```python
from evaluate import load
wer = load("wer")
cer = load("cer")
predictions = [transcribe(row["audio"]) for row in test_split]
references = [row["sentence"] for row in test_split]
print({"wer": wer.compute(predictions=predictions, references=references),
       "cer": cer.compute(predictions=predictions, references=references)})
```

WER is the academic standard; CER is more meaningful for Gurmukhi (where character-level accuracy matters more than word-level because there's no word-boundary consensus). Both should be reported.

### Tertiary: confidence calibration

For each test-split row, run the **fine-tuned ASR → Phase 1 matcher → record matcher's top-1 confidence**. Plot a histogram of confidences. We want a clearly bimodal distribution: high-confidence band ≥ 80 for matches that ARE the labelled Pangti, low-confidence band ≤ 50 for matches that are NOT. A unimodal distribution centred near 75 is the worst outcome — it means the matcher can't distinguish right from wrong.

### What NOT to measure

- **Loss on val** — useful for early-stopping checkpoint selection, not for cross-model comparison. Loss numbers depend on tokenizer and aren't comparable to Phase 1.
- **Single-sample anecdotes** ("listen to this output, it's amazing/terrible"). Quantify it via the 13-sample battery.

---

## 8. Budget

### Sanity-check run (first execution)

Goal: train for ~30 minutes on a 1-hour subset of the v1 data to confirm the training script works end-to-end and the eval pipeline produces a sensible report. Not aiming for accuracy — just plumbing.

- GPU: RTX 3090 community cloud, $0.40/hr × 1 hr = **~$0.50**
- Worth doing twice (once on Linux, once on the target deployment OS) = **~$1**

### First serious run

Goal: train one epoch on the full v1 dataset, eval, decide whether to extend.

- GPU: A100-40GB on RunPod / Vast.ai community, $1.20/hr
- Training: ~3 hours per epoch (5 h training audio, batch 16, ~1500 steps) × 5 epochs = 15 hours
- Eval (Phase 1 13-sample battery): ~1 hour
- Buffer for restarts / failed runs: 1.5×
- **Estimate: 25 GPU-hours × $1.20 = ~$30**

Significantly under the brief's $200–500 estimate. The brief was budgeting for full fine-tuning; LoRA brings it down a lot.

### Production-scale run (post-v1, with 20+ hours of training audio)

When the dataset reaches ~20 h (v1.5 or v2), full fine-tune may make sense (LoRA's edge over full FT narrows above ~10h training data). At that point:

- A100-80GB rental at ~$2/hr × ~50 GPU-hours = **~$100**
- Or two-A100-40GB DDP at ~$2.40/hr × ~25 hours = **~$60**

Brief's $200–500 estimate becomes relevant if we go further: multi-epoch sweeps over hyperparameters, multiple base-model comparisons (large-v3 vs IndicWhisper), etc. For v1 we don't need that.

---

## 9. Decision gate — when to actually run

Do not start the first serious run until **all** of these are true:

1. `python scripts/build_dataset.py stats` shows:
   - ≥ 5.0 hours `high`-tier audio in `dataset/manifest.json.coverage.duration_hours`
   - ≥ 5 distinct jathas
   - ≥ 5 distinct raags
   - ≥ 200 distinct Pangtis covered
   (These are the DATASET_PHILOSOPHY §7 v1 targets.)

2. `python scripts/build_dataset.py validate` passes — on-disk consistency check.

3. At least **3** randomly-sampled `high`-tier segments have been spot-checked by a Sevadaar (the eventual labeller UI does this systematically, but at this stage a manual listen by Deep is enough). The point is to catch any systematic bug in `align_sample.py` before we train against it — a corrupt 5-hour training set wastes the entire budget.

4. The sanity-check run (§8) has been done successfully, producing an `evaluation/phase2b_sanity_*.md` report that loads in the same format as Phase 1's reports.

5. `scripts/evaluate.py` has been confirmed to work against an OpenAI `large-v3` baseline checkpoint on the host that will run the fine-tune (so we have a known-good baseline to compare against).

If any of these aren't true, fix them first. The point of the gate is to make sure we don't spend money on a run that produces uninterpretable results.

### What success looks like for the first run

Targets for the v1 fine-tuned model on the Phase 1 13-sample battery:

- Confident-match rate ≥ 60% (vs 46% large-v3 baseline) — a meaningful improvement
- All three harjinder samples cluster correctly (vs 1 of 3 for large-v3) — the cluster-stability regression that large-v3 introduced gets fixed by Kirtan-specific tuning
- `waheguru 1.mp3` confidence remains < 75 — safety property preserved
- WER on `dataset/splits/test.json` ≤ 25% — speculative; we have no baseline for sung Kirtan WER. This is the first measurement we get.

If we hit ≥ 60% / cluster-correct / safety-preserved, **the projector use case (Phase 2C) becomes credible** for the first time. That's the strategic win.

---

## 10. Failure modes and mitigations

| Failure mode | Likelihood | Mitigation |
|---|---|---|
| Overfit on small dataset — fine-tuned model is amazing on training jathas, terrible on held-out | High | Stratified sampling by `(jatha, raag)` (§5); held-out test split; report WER on **other** jathas separately |
| Catastrophic forgetting — gains Kirtan but loses general Punjabi (so spoken Paath regresses) | Medium | Include `japji sahib 1.mp3` (spoken Paath) in the Phase 1 13-sample eval; specifically check it doesn't regress from large-v3's 96.6 confidence |
| Hallucination on silence / alaap | Medium | Train with `kind=alaap` segments as targets pointing to empty string ("") — explicitly teach the model that alaap → no text. Requires extending the data pipeline; deferred to v1.5 |
| Tokenization mismatch — fine-tuned model produces Devanagari when corpus expects Gurmukhi, or vice versa | Medium | Force consistent target script in `sentence` field (use Gurmukhi everywhere — `dataset/splits/*.json.sentence` is already Gurmukhi); validate by checking that any model output is Gurmukhi at eval time, fail loudly if not |
| Repeat-group bias slips in despite v1 filter — model learns Rahao text is the answer to everything | Low (v1 filter excludes repeats) | Add a sanity check: post-training, transcribe `harjinder singh 3.mp3` (the Rahao-heavy canonical) and check that the output isn't pure Rahao text |
| GPU OOM mid-run | Low | Use gradient checkpointing; reduce per-device batch; the cost is wall-clock not money |
| Sevadaar review turns out to systematically disagree with `high`-tier auto-labels | Low | If true, the dataset is bad before training; need a labeller-vs-aligner reconciliation pass — this is a v1.5 issue if it happens. Caught at the §9 spot-check gate |

---

## 11. After the first run — decision tree

| Outcome | Next step |
|---|---|
| Hit all §9 success criteria | Publish LoRA adapter as `gurbanilens/whisper-large-v3-kirtan-v1` on HuggingFace Hub (Seva, open weights). Wire into iOS / Android apps for v2 builds. Phase 2C (projector) becomes viable. |
| Hit confident-match target but cluster-stability regressed | Investigate per-Shabad sampling — was one Shabad over-represented? Re-run with stricter sampling. ~$30. |
| Confident-match rate improved by < 10 points over large-v3 baseline | Dataset is too small or too narrow. Don't iterate on training; iterate on dataset (more samples, broader jathas/raags). The runs after the second one are cheap, but iterating against a bad dataset is not. |
| Negative-test broke (`waheguru 1.mp3` now confidently matches) | **Critical safety regression. Do not deploy.** Audit the dataset for silent contamination — likely a Simran segment got mislabelled as a Pangti. Pull the LoRA. |
| WER on test split is wildly off (≥ 60%) | Likely a tokenization or audio-format bug in the pipeline. Debug the sanity-check run first; do not re-run on full dataset. |

---

## 12. What this plan does NOT cover

- **Phase 2C (projector) deployment** — model inference on Gurdwara-side hardware. Out of scope; that's a separate work item once a fine-tuned model exists.
- **iOS/Android model swap** — the fine-tuned LoRA gets converted to whisper.cpp format for on-device inference. Out of scope; the iOS agent's `WhisperASR` already has a `model_path` parameter that this plugs into trivially.
- **Continuous live listening fine-tune** — the Phase 2A v2 mode (auto-follow during a Kirtan rendition) needs a *streaming-aware* fine-tune. Not v1.
- **Multi-modal fine-tune** (audio + Pangti context as input) — research direction for v3+.
- **Cost of human-reviewer time** for the Sevadaar labelling UI. Volunteer Seva time is not modelled in the budget.
