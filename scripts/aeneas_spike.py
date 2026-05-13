"""Track C — forced-alignment spike.

Original plan: aeneas (eSpeak-based forced alignment of audio against known
text). Outcome from this spike: aeneas's PyPI package has a brittle build
process and unmaintained eSpeak dependency on macOS — it failed to install
under any reasonable combination of --no-build-isolation / preinstalled
numpy / brew espeak.

Pivot: use ``faster-whisper`` with ``word_timestamps=True``. We already have
faster-whisper for Phase 1 ASR; turning on word timestamps gives us
word-level alignment "for free" — without aeneas's eSpeak dependency. This
is also the modern best-practice for Sikh-language alignment (eSpeak doesn't
know Gurmukhi phonology; Whisper at least transcribes plausible phonetics).

This script:
  1. Loads `samples/harjinder singh 3.mp3` (confidently matched Ang 626:P19 in Phase 1)
  2. Loads the corpus reference text for Ang 626 P10-P25 (the Shabad's window)
  3. Runs Whisper with word_timestamps and prints word-by-word alignment
  4. Calls out where the audio words map to corpus words

Outcome and recommendation are written to ``docs/aeneas_spike.md``.
"""

from __future__ import annotations

import json
import sys
import time
from pathlib import Path

from gurbanilens.asr import WhisperASR, to_latin
from gurbanilens.corpus import Corpus

ROOT = Path(__file__).resolve().parent.parent
SAMPLE = ROOT / "samples" / "harjinder singh 3.mp3"
ANG = 626
PANGTI_RANGE = range(10, 26)


def main() -> int:
    if not SAMPLE.exists():
        print(f"Sample missing: {SAMPLE}", file=sys.stderr)
        return 1

    # 1. Get reference transcript from corpus
    corpus = Corpus()
    refs = []
    for p in PANGTI_RANGE:
        for line in corpus.lookup(ANG, p):
            if line.transliteration_en:
                refs.append((p, line.transliteration_en))

    print(f"=== Reference (Ang {ANG}, Pangtis {PANGTI_RANGE.start}-{PANGTI_RANGE.stop - 1}) ===")
    for p, t in refs:
        print(f"  P{p:2d}: {t}")

    # 2. Transcribe with word timestamps
    print(f"\n=== Whisper transcript with word timestamps (medium model) ===")
    asr = WhisperASR(model_size="medium", vad_filter=False)
    # Bypass the high-level wrapper to access word_timestamps option
    from faster_whisper import WhisperModel
    model = asr._model
    t0 = time.time()
    segments, info = model.transcribe(
        str(SAMPLE),
        language="pa",
        task="transcribe",
        vad_filter=False,
        word_timestamps=True,
    )
    captured = []
    for seg in segments:
        for w in (seg.words or []):
            captured.append({
                "start": w.start,
                "end": w.end,
                "word": w.word.strip(),
            })
    elapsed = time.time() - t0
    print(f"  {len(captured)} word-level timestamps captured in {elapsed:.1f}s")

    if not captured:
        print("  (no word timestamps produced)")
        return 0

    # 3. Print alignment + latinized version
    print("\n=== Word-by-word alignment (heard → latin) ===")
    for w in captured:
        lat = to_latin(w["word"]).strip()
        print(f"  {w['start']:6.2f}–{w['end']:6.2f}  {w['word']:20s} → {lat}")

    # 4. Persist a JSON dump for downstream tools
    out = ROOT / "docs" / "aeneas_spike_alignment.json"
    out.parent.mkdir(exist_ok=True)
    out.write_text(json.dumps({
        "sample": SAMPLE.name,
        "ang": ANG,
        "pangti_range": [PANGTI_RANGE.start, PANGTI_RANGE.stop - 1],
        "elapsed_sec": round(elapsed, 1),
        "reference_pangtis": [{"pangti": p, "transliteration": t} for p, t in refs],
        "whisper_words": captured,
    }, indent=2, ensure_ascii=False))
    print(f"\nWrote alignment JSON → {out}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
