"""Speech recognition + transliteration.

Defines an ``ASREngine`` Protocol so the rest of the pipeline doesn't care
which model produces transcripts. ``WhisperASR`` is the Phase 1 implementation
using ``faster-whisper``; later experiments (IndicWhisper, AI4Bharat models, a
fine-tuned Whisper on Kirtan) plug in by satisfying the same interface.

Whisper transcribes Punjabi audio to Unicode Gurmukhi. We then convert each
segment to plain ASCII Latin via indic-transliteration (IAST scheme) and NFD
diacritic stripping, producing text in the same canonical space as the
corpus's ``transliteration_en`` column.
"""

from __future__ import annotations

import unicodedata
from dataclasses import dataclass
from pathlib import Path
from typing import Iterator, Protocol

from indic_transliteration import sanscript


@dataclass(frozen=True, slots=True)
class Segment:
    """A timestamped chunk of recognised speech."""

    start: float
    end: float
    text_native: str  # transcript as the engine produced it (Gurmukhi for Whisper-pa)
    text_latin: str   # ASCII Latin form, ready for the matcher


def _detect_source_scheme(text: str) -> str | None:
    """Pick the indic-transliteration source scheme by dominant Indic script.

    Empirically Whisper-pa often transcribes Punjabi audio to *Devanagari*, not
    Gurmukhi — its Punjabi training data leans that way. We detect per-segment
    so the same pipeline handles either script (or a mix).
    """
    gurmukhi = devanagari = 0
    for ch in text:
        cp = ord(ch)
        if 0x0A00 <= cp <= 0x0A7F:
            gurmukhi += 1
        elif 0x0900 <= cp <= 0x097F:
            devanagari += 1
    if gurmukhi == 0 and devanagari == 0:
        return None
    return sanscript.GURMUKHI if gurmukhi >= devanagari else sanscript.DEVANAGARI


# Long-vowel IAST chars → doubled letters (BaniDB transliteration convention).
# Applied BEFORE NFD-strip so the length information survives.
_LONG_VOWEL_DOUBLES = {
    "ā": "aa", "Ā": "Aa",
    "ī": "ee", "Ī": "Ee",  # BaniDB uses "ee" (not "ii") for long ī
    "ū": "oo", "Ū": "Oo",  # BaniDB uses "oo" (not "uu") for long ū
}


def _strip_final_schwa(text: str) -> str:
    """Drop word-final short 'a' — Indic phonology drops schwa, BaniDB follows.

    indic-transliteration's IAST output preserves every schwa ("nānaka",
    "nidhāna"), while BaniDB's curated transliteration drops them ("naanak",
    "nidhaan"). We mirror BaniDB so both sides compare in the same space.

    Rules: token must be >3 chars and end in single 'a' (not 'aa', 'ia',
    'ya' which encode different phonemes).
    """
    keep_endings = ("aa", "ia", "ya")
    out = []
    for tok in text.split():
        if len(tok) > 3 and tok.endswith("a") and not tok.endswith(keep_endings):
            out.append(tok[:-1])
        else:
            out.append(tok)
    return " ".join(out)


def to_latin(text: str) -> str:
    """Convert any Indic-script text (Gurmukhi or Devanagari) to plain ASCII Latin.

    Pipeline:
        1. Detect source script (Gurmukhi vs Devanagari vs already-Latin)
        2. Transliterate to IAST (with diacritics)
        3. Pre-strip pass: double long vowels to match BaniDB's transliteration
           style (ā→aa, ī→ee, ū→oo) so length info survives the NFD strip
        4. NFD-decompose + strip remaining combining marks (nasals, etc.)
    """
    source = _detect_source_scheme(text)
    if source is None:
        iast = text
    else:
        iast = sanscript.transliterate(text, source, sanscript.IAST)
    for src, dst in _LONG_VOWEL_DOUBLES.items():
        iast = iast.replace(src, dst)
    decomposed = unicodedata.normalize("NFD", iast)
    ascii_text = "".join(ch for ch in decomposed if unicodedata.category(ch) != "Mn")
    return _strip_final_schwa(ascii_text)


class ASREngine(Protocol):
    """Anything that streams ``Segment``s from an audio file."""

    def transcribe_stream(self, audio_path: Path) -> Iterator[Segment]:
        ...


class WhisperASR:
    """faster-whisper wrapper. Streams (start, end, text) segments.

    Args:
        model_size: faster-whisper model name. ``medium`` is the default fast
            iteration target; pass ``large-v3`` for max accuracy.
        device: ``auto`` picks CUDA if available, else CPU.
        compute_type: ``auto`` picks a sensible default (float16 on GPU, int8
            on CPU). Override for benchmarking.
        vad_filter: Silero VAD pre-filter — drops silent regions before
            decoding. Recommended for Kirtan with natural pauses.
    """

    def __init__(
        self,
        model_size: str = "medium",
        device: str = "auto",
        compute_type: str = "auto",
        vad_filter: bool = True,
    ) -> None:
        from faster_whisper import WhisperModel  # lazy: heavy import + model download

        self.model_size = model_size
        self._vad_filter = vad_filter
        self._model = WhisperModel(model_size, device=device, compute_type=compute_type)

    def transcribe_stream(self, audio_path: Path) -> Iterator[Segment]:
        segments, _info = self._model.transcribe(
            str(audio_path),
            language="pa",
            task="transcribe",
            vad_filter=self._vad_filter,
        )
        for s in segments:
            text_native = (s.text or "").strip()
            if not text_native:
                continue
            yield Segment(
                start=float(s.start),
                end=float(s.end),
                text_native=text_native,
                text_latin=to_latin(text_native),
            )
