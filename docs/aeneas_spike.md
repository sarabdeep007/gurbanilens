# Forced-Alignment Spike — Track C (Phase 2B prep)

_Run 2026-05-13. Sample: `samples/harjinder singh 3.mp3` (confidently matched **Ang 626 P19** in Phase 1)._

## What was tried, in order

### 1. aeneas (the original plan) — failed to install

`pip install aeneas` (with and without `--no-build-isolation`, with numpy pre-installed) consistently failed:

```
[ERRO] You must install numpy before installing aeneas
```

The aeneas `setup.py` checks for numpy at module import time inside the build-isolated environment, ignoring system numpy installs. Also requires `espeak-ng` at runtime (system-level dep, not on the machine).

aeneas's last PyPI release was 2017; appears unmaintained. Not pursuing further.

### 2. faster-whisper `word_timestamps=True` — works, much simpler

We already have faster-whisper for Phase 1 ASR. Turning on word-level timestamps gives essentially the same forced-alignment data without aeneas's eSpeak dependency. Implementation in `scripts/aeneas_spike.py`.

Run on `harjinder singh 3.mp3` (medium model, no VAD): **23 word-level timestamps captured in 28.9s** of compute for 65s of audio.

## Alignment outcome

Whisper output (Devanagari, latinised via Phase 1's `to_latin`), with timestamps:

```
   0.00–  1.44   jee
   1.44–  2.48   jaant
   2.48–  3.60   tere
   3.60–  8.34   taare      ← Pangti boundary
   8.34– 14.40   jee
  14.40– 15.82   jaant
  15.82– 16.56   tere
  16.56– 21.42   taare      ← Pangti boundary (repeat)
  21.42– 23.36   rab
  23.36– 24.72   doree
  24.72– 32.20   raap
  32.20– 41.40   tumaaree   ← Pangti boundary
  ... pattern continues
```

Comparing to the Phase 1 confidently-matched corpus area (Ang 626):

```
P19: jeea jant. tere dhaare |
P19: prabh ddoree haath tumaare |
```

**The alignment is correct.** The Ragi is singing P19a (`jeea jant tere dhaare`) and P19b (`prabh ddoree haath tumaare`) in alternation, multiple times. Whisper's "jee jaant tere taare" maps to `jeea jant tere dhaare`; "rab doree raap tumaaree" maps to `prabh ddoree haath tumaare`. Vowel/consonant drift consistent with Phase 1 (`dhaare → taare`, `prabh → rab`, `haath → raap`).

## What this revealed about Kirtan vs prose alignment

This is the most important finding from the spike. **Kirtan audio is not a linear traversal of the corpus text.** The Ragi repeated the same two Pangtis (P19a, P19b) at least four times across 65 seconds. A naive forced-alignment tool that assumes "audio words map monotonically to transcript words" would produce wrong results — it would try to align repeats to consecutive Pangtis (P19, P20, P21...) instead of recognising them as repetitions of P19.

Aeneas, audiobook ASR aligners, and Whisper's own word_timestamps all assume monotonic alignment. None of them are correct for Kirtan as-is.

## Recommendation for Phase 2B dataset tooling

Don't build forced alignment as a one-shot algorithm. Build a **human-in-the-loop labeller**:

1. **Whisper word_timestamps gives the baseline** — word-level audio segmentation, fast, no extra deps. Use what we already have.
2. **Phase 1 matcher gives the baseline Pangti hypothesis** — already shown to be correct on this sample. Use this to seed the labeller's "best guess".
3. **A small web app for the human labeller** (Sevadaar with knowledge of Gurbani):
   - Plays the audio with a moving cursor
   - Shows Whisper's word-timestamps below the audio
   - Shows the Phase 1 matcher's best-guess Pangti, plus N nearby Pangtis
   - Sevadaar drags audio-segment markers to corpus Pangtis; can mark a span as "P19a × 4 repeats"
   - Outputs `(audio_url, time_start, time_end, ang, pangti)` rows to a CSV
4. **For Akhand Paath training data** specifically — the same UI handles long sessions with breaks between Pathis.

This is a Phase 2B build, not Phase 2A. The spike confirms the tooling is feasible with our existing dependencies; aeneas is not on the critical path.

## Next steps

- Phase 2B kick-off: spec the human-in-the-loop labeller UI as the first dataset-creation task
- Aeneas: closed, not pursuing
- Whisper word_timestamps utility: keep `scripts/aeneas_spike.py` around as a quick "what does Whisper hear word-by-word on file X" diagnostic tool. May rename to `scripts/word_align.py` to match what it actually does.

## Artifacts

- Per-word alignment JSON: `docs/aeneas_spike_alignment.json` (gitignored, regenerable)
- Spike script: `scripts/aeneas_spike.py`
- Reference sample: `samples/harjinder singh 3.mp3` (gitignored)
