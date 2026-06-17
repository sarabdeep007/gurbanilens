"""Forced alignment for Phase 2B dataset construction — v1.

Produces one JSON file per audio sample, conforming to the segment schema in
``docs/DATASET_PHILOSOPHY.md`` §3. Each segment is a labeled time-span with
``kind`` in {pangti, alaap, overlap, silence, unknown}, a
``repeat_group_id`` linking repeats of the same Pangti, and an
``alignment_quality`` tier in {high, medium, needs_review}.

Pipeline (per DATASET_PHILOSOPHY.md §5):
  1. faster-whisper with ``word_timestamps=True`` + ``language=pa`` →
     stream of {start, end, word}.
  2. Slide the Phase 1 matcher over the word stream in overlapping windows;
     each window yields a top hypothesis ``(ang, pangti, confidence)`` plus
     a coverage metric.
  3. Merge adjacent windows with the same ``(ang, pangti)`` into one segment;
     boundary timestamps come from the underlying word timestamps.
  4. Detect repeat groups: same ``(ang, pangti)`` segment appearing in two
     non-adjacent positions with ≥1 s gap → assign shared ``repeat_group_id``
     and force ``alignment_quality = "needs_review"`` per DATASET_PHILOSOPHY §4.
  5. Detect alaap (gaps > 2 s with no words, OR runs of vowel-only tokens).
  6. Detect ambiguous spans (low matcher confidence + dense words → unknown).
  7. Score tiers and emit JSON.

Usage:

    # Full pipeline against an audio file (requires faster-whisper installed)
    python scripts/align_sample.py audio samples/harjinder_singh_3.mp3 \\
        --ang-start 626 --ang-end 626 --out samples/alignments/

    # Skip Whisper — feed a pre-captured words JSON (regression / unit test)
    python scripts/align_sample.py from-words \\
        docs/aeneas_spike_alignment.json --out samples/alignments/

    # Pure smoke test — stdlib only, no audio, no matcher
    python scripts/align_sample.py self-test

The pure helpers (`merge_segments`, `detect_repeats`, `detect_alaap`,
`score_tier`) are import-free and unit-tested by the `self-test` subcommand,
so we can validate the algorithm on hosts that don't have faster-whisper or
rapidfuzz installed.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
import time
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any, Iterable

ROOT = Path(__file__).resolve().parent.parent
CORE = ROOT / "core"
if str(CORE) not in sys.path:
    sys.path.insert(0, str(CORE))

DEFAULT_OUT_DIR = ROOT / "samples" / "alignments"

# Algorithm parameters (mirror DATASET_PHILOSOPHY.md §4)
WINDOW_TOKENS = 6
WINDOW_STEP = 3
HIGH_CONF = 80.0
MEDIUM_CONF = 65.0
HIGH_COVERAGE = 0.70
MEDIUM_COVERAGE = 0.50
HIGH_BOUNDARY_SEC = 0.3
MEDIUM_BOUNDARY_SEC = 0.8
MIN_PANGTI_DURATION_SEC = 1.5
MAX_PANGTI_DURATION_SEC = 25.0
ALAAP_GAP_SEC = 2.0
REPEAT_GAP_SEC = 1.0
SCHEMA_VERSION = 1


# ─── Data shapes ────────────────────────────────────────────────────────────


@dataclass
class Word:
    """One Whisper word with its timestamp."""
    start: float
    end: float
    word: str  # native script (Gurmukhi or Devanagari)


@dataclass
class WindowHypothesis:
    """The matcher's per-window guess. One per sliding window."""
    word_start_idx: int   # index into the Word list
    word_end_idx: int     # exclusive
    start_sec: float
    end_sec: float
    text_latin: str
    ang: int | None
    pangti: int | None
    shabad_id: str | None
    confidence: float     # combined matcher score, 0-100
    coverage: float       # fraction of long query tokens fuzzy-matched, 0-1


@dataclass
class Segment:
    """One labeled time-span — the unit of dataset output."""
    start_sec: float
    end_sec: float
    kind: str  # pangti | alaap | overlap | silence | unknown
    ang: int | None = None
    pangti_index: int | None = None
    pangti_part: str | None = None  # v1: always None; Sevadaar fills in
    shabad_id: str | None = None
    text_latin: str | None = None
    text_gurmukhi: str | None = None
    match_confidence: float | None = None
    coverage: float | None = None
    boundary_uncertainty_sec: float | None = None
    alignment_quality: str = "needs_review"  # high | medium | needs_review | n/a
    repeat_group_id: str | None = None
    labeled_by: str = "machine"
    notes: str | None = None


# ─── Pure helpers (testable without faster-whisper/rapidfuzz) ────────────────


def _is_vowel_only(token: str) -> bool:
    """Heuristic for alaap tokens: ASCII letters only, no consonants.

    indic-transliteration's IAST output for alaap (sustained vowel) will be a
    string of just 'a', 'aa', 'e', 'ee', 'o', 'oo', etc. with no consonants.
    """
    consonants = set("bcdfghjklmnpqrstvwxyz")
    letters = [c for c in token.lower() if c.isalpha()]
    if not letters:
        return False
    return not any(c in consonants for c in letters)


def merge_windows(windows: list[WindowHypothesis]) -> list[Segment]:
    """Step 3: collapse runs of adjacent same-(ang, pangti) windows into segments.

    Adjacent = consecutive in the window list (sliding step ensures temporal
    adjacency). Confidence/coverage are averaged across the merged span.
    """
    segments: list[Segment] = []
    if not windows:
        return segments

    i = 0
    while i < len(windows):
        head = windows[i]
        j = i + 1
        while (
            j < len(windows)
            and windows[j].ang == head.ang
            and windows[j].pangti == head.pangti
            and head.ang is not None  # don't merge "no match" windows
        ):
            j += 1
        run = windows[i:j]
        confs = [w.confidence for w in run]
        covs = [w.coverage for w in run]
        segments.append(Segment(
            start_sec=run[0].start_sec,
            end_sec=run[-1].end_sec,
            kind="pangti" if head.ang is not None else "unknown",
            ang=head.ang,
            pangti_index=head.pangti,
            shabad_id=head.shabad_id,
            text_latin=" ".join(w.text_latin for w in run).strip() or None,
            match_confidence=sum(confs) / len(confs) if confs else None,
            coverage=sum(covs) / len(covs) if covs else None,
        ))
        i = j
    return segments


def detect_repeats(segments: list[Segment]) -> list[Segment]:
    """Step 4: assign repeat_group_id when same (ang, pangti) recurs with gap ≥1s.

    Mutates the segments in place (also returns them for chaining). Per
    DATASET_PHILOSOPHY.md §4, repeat membership forces needs_review tier — we
    do not promote that to needs_review here (score_tier owns the tier
    decision) but we set the group id so score_tier sees it.
    """
    last_seen: dict[tuple[int, int], list[int]] = {}
    for idx, seg in enumerate(segments):
        if seg.kind != "pangti" or seg.ang is None or seg.pangti_index is None:
            continue
        key = (seg.ang, seg.pangti_index)
        if key in last_seen:
            prev_idx = last_seen[key][-1]
            prev_seg = segments[prev_idx]
            gap = seg.start_sec - prev_seg.end_sec
            if gap >= REPEAT_GAP_SEC:
                # All members of this group get the same id
                group_id = f"rg_{key[0]}_{key[1]}_{last_seen[key][0]}"
                if prev_seg.repeat_group_id is None:
                    prev_seg.repeat_group_id = group_id
                seg.repeat_group_id = group_id
                for earlier_idx in last_seen[key][:-1]:
                    if segments[earlier_idx].repeat_group_id is None:
                        segments[earlier_idx].repeat_group_id = group_id
        last_seen.setdefault(key, []).append(idx)
    return segments


def detect_alaap_and_silence(
    segments: list[Segment], words: list[Word], audio_duration_sec: float
) -> list[Segment]:
    """Step 5: insert alaap/silence segments into gaps between pangti spans.

    Two rules:
    - A gap of > ALAAP_GAP_SEC between adjacent pangti segments (or between
      audio start/end and the first/last segment) becomes a "silence" or
      "alaap" segment. We call it "alaap" if any word landed in that gap and
      every word in the gap is vowel-only; otherwise "silence".
    - A pangti span where every token in text_latin is vowel-only is
      retroactively re-tagged as alaap (matcher was guessing on humming).
    """
    if not segments and audio_duration_sec <= 0:
        return segments

    # Build word index by mid-time for gap classification
    def words_in_gap(start: float, end: float) -> list[Word]:
        return [w for w in words if start <= (w.start + w.end) / 2 < end]

    augmented: list[Segment] = []
    prev_end = 0.0
    for seg in segments + [Segment(start_sec=audio_duration_sec, end_sec=audio_duration_sec, kind="_sentinel")]:
        gap = seg.start_sec - prev_end
        if gap > ALAAP_GAP_SEC:
            gap_words = words_in_gap(prev_end, seg.start_sec)
            if gap_words and all(_is_vowel_only(w.word) for w in gap_words):
                kind = "alaap"
            elif not gap_words:
                kind = "silence"
            else:
                kind = "unknown"
            augmented.append(Segment(
                start_sec=prev_end,
                end_sec=seg.start_sec,
                kind=kind,
                alignment_quality="n/a",
                notes="auto-detected gap",
            ))
        if seg.kind != "_sentinel":
            augmented.append(seg)
        prev_end = seg.end_sec

    # Retag pangti segments whose text is entirely vowel-only as alaap
    for seg in augmented:
        if seg.kind == "pangti" and seg.text_latin:
            tokens = seg.text_latin.split()
            if tokens and all(_is_vowel_only(t) for t in tokens):
                seg.kind = "alaap"
                seg.ang = None
                seg.pangti_index = None
                seg.shabad_id = None
                seg.alignment_quality = "n/a"
                seg.notes = (seg.notes or "") + "; retagged from pangti (vowel-only)"
    return augmented


def score_tier(seg: Segment) -> str:
    """Step 7: assign alignment_quality per DATASET_PHILOSOPHY.md §4."""
    if seg.kind in {"alaap", "silence", "overlap", "unknown", "announcement"}:
        return "needs_review" if seg.kind in {"overlap", "unknown", "announcement"} else "n/a"
    if seg.kind != "pangti":
        return "needs_review"

    duration = seg.end_sec - seg.start_sec
    if duration < MIN_PANGTI_DURATION_SEC or duration > MAX_PANGTI_DURATION_SEC:
        return "needs_review"
    if seg.repeat_group_id is not None:
        # Repetition is always needs_review in v1, regardless of confidence
        return "needs_review"
    if seg.match_confidence is None or seg.coverage is None:
        return "needs_review"

    conf, cov = seg.match_confidence, seg.coverage
    boundary = seg.boundary_uncertainty_sec or 0.0

    if conf >= HIGH_CONF and cov >= HIGH_COVERAGE and boundary <= HIGH_BOUNDARY_SEC:
        return "high"
    if conf >= MEDIUM_CONF and cov >= MEDIUM_COVERAGE and boundary <= MEDIUM_BOUNDARY_SEC:
        return "medium"
    return "needs_review"


def apply_tiers(segments: list[Segment]) -> list[Segment]:
    for seg in segments:
        seg.alignment_quality = score_tier(seg)
    return segments


# ─── ASR + matcher integration (needs faster-whisper + rapidfuzz) ────────────


def transcribe_words(audio_path: Path, model_size: str) -> tuple[list[Word], float]:
    """Run faster-whisper with word_timestamps=True on the audio."""
    from faster_whisper import WhisperModel

    print(f"[asr] loading {model_size}...", file=sys.stderr)
    t0 = time.time()
    model = WhisperModel(model_size, device="auto", compute_type="auto")
    print(f"[asr] ready in {time.time()-t0:.1f}s", file=sys.stderr)

    print(f"[asr] transcribing {audio_path.name} ...", file=sys.stderr)
    t0 = time.time()
    segments, info = model.transcribe(
        str(audio_path),
        language="pa",
        task="transcribe",
        vad_filter=False,
        word_timestamps=True,
        temperature=0.0,
    )
    words: list[Word] = []
    for seg in segments:
        for w in (seg.words or []):
            txt = (w.word or "").strip()
            if not txt:
                continue
            words.append(Word(start=float(w.start), end=float(w.end), word=txt))
    print(f"[asr] {len(words)} word timestamps in {time.time()-t0:.1f}s", file=sys.stderr)
    return words, float(info.duration)


def match_windows(words: list[Word]) -> list[WindowHypothesis]:
    """Slide the Phase 1 matcher over the word stream in overlapping windows."""
    from gurbanilens.asr import to_latin
    from gurbanilens.corpus import Corpus
    from gurbanilens.matcher import Matcher

    print("[match] loading corpus + matcher...", file=sys.stderr)
    t0 = time.time()
    corpus = Corpus()
    matcher = Matcher(corpus)
    print(f"[match] {len(matcher):,} corpus lines in {time.time()-t0:.1f}s", file=sys.stderr)

    if not words:
        return []

    # Pre-compute latin per word; matcher operates in latin space
    latin_words = [(w, to_latin(w.word).strip()) for w in words]
    latin_words = [(w, lat) for (w, lat) in latin_words if lat]

    windows: list[WindowHypothesis] = []
    n = len(latin_words)
    for i in range(0, max(n - WINDOW_STEP + 1, 1), WINDOW_STEP):
        chunk = latin_words[i : i + WINDOW_TOKENS]
        if len(chunk) < WINDOW_STEP:
            break
        query_text = " ".join(lat for (_, lat) in chunk)
        first_word = chunk[0][0]
        last_word = chunk[-1][0]
        results = matcher.match(query_text, top_n=1)
        if results:
            top = results[0]
            windows.append(WindowHypothesis(
                word_start_idx=i,
                word_end_idx=i + len(chunk),
                start_sec=first_word.start,
                end_sec=last_word.end,
                text_latin=query_text,
                ang=top.line.ang,
                pangti=top.line.pangti,
                shabad_id=top.line.shabad_id,
                confidence=float(top.score),
                coverage=float(top.coverage),
            ))
        else:
            windows.append(WindowHypothesis(
                word_start_idx=i,
                word_end_idx=i + len(chunk),
                start_sec=first_word.start,
                end_sec=last_word.end,
                text_latin=query_text,
                ang=None,
                pangti=None,
                shabad_id=None,
                confidence=0.0,
                coverage=0.0,
            ))
    return windows


def lookup_gurmukhi(segments: list[Segment]) -> list[Segment]:
    """Fill text_gurmukhi for pangti segments by looking up the corpus."""
    from gurbanilens.corpus import Corpus

    corpus = Corpus()
    for seg in segments:
        if seg.kind == "pangti" and seg.ang is not None and seg.pangti_index is not None:
            lines = corpus.lookup(seg.ang, seg.pangti_index)
            if lines and lines[0].gurmukhi:
                seg.text_gurmukhi = lines[0].gurmukhi
    return segments


# ─── Top-level pipeline ──────────────────────────────────────────────────────


def align(words: list[Word], audio_duration_sec: float) -> list[Segment]:
    """Pure-ish pipeline: words → segments. Requires matcher (rapidfuzz)."""
    windows = match_windows(words)
    segments = merge_windows(windows)
    segments = detect_repeats(segments)
    segments = detect_alaap_and_silence(segments, words, audio_duration_sec)
    segments = lookup_gurmukhi(segments)
    segments = apply_tiers(segments)
    return segments


def envelope(
    audio_path: Path | None,
    audio_duration_sec: float,
    words: list[Word],
    segments: list[Segment],
    source: str,
    model_size: str | None,
) -> dict[str, Any]:
    """Build the top-level JSON document around the segments list."""
    audio_sha256 = None
    if audio_path is not None and audio_path.exists():
        h = hashlib.sha256()
        with audio_path.open("rb") as f:
            for chunk in iter(lambda: f.read(65536), b""):
                h.update(chunk)
        audio_sha256 = h.hexdigest()
    return {
        "schema_version": SCHEMA_VERSION,
        "audio_file": str(audio_path.relative_to(ROOT)) if audio_path else None,
        "audio_sha256": audio_sha256,
        "duration_sec": audio_duration_sec,
        "produced_by": {
            "tool": "scripts/align_sample.py",
            "version": SCHEMA_VERSION,
            "source": source,  # "whisper" | "from-words-json" | "synthetic"
            "model": model_size,
        },
        "word_count": len(words),
        "segment_count": len(segments),
        "tier_counts": {
            t: sum(1 for s in segments if s.alignment_quality == t)
            for t in ("high", "medium", "needs_review", "n/a")
        },
        "segments": [asdict(s) for s in segments],
    }


def write_alignment(envelope_doc: dict[str, Any], out_dir: Path, slug: str) -> Path:
    out_dir.mkdir(parents=True, exist_ok=True)
    out_path = out_dir / f"{slug}.json"
    out_path.write_text(json.dumps(envelope_doc, indent=2, ensure_ascii=False))
    return out_path


# ─── CLI subcommands ─────────────────────────────────────────────────────────


def cmd_audio(args: argparse.Namespace) -> int:
    audio_path = Path(args.audio).resolve()
    if not audio_path.exists():
        print(f"audio not found: {audio_path}", file=sys.stderr)
        return 1
    words, duration = transcribe_words(audio_path, args.model)
    segments = align(words, duration)
    env = envelope(audio_path, duration, words, segments, source="whisper", model_size=args.model)
    out = write_alignment(env, Path(args.out), audio_path.stem)
    print(f"wrote {out}")
    print(f"  tiers: {env['tier_counts']}")
    return 0


def cmd_from_words(args: argparse.Namespace) -> int:
    """Re-run alignment from a previously captured words JSON.

    Expected shape (matches docs/aeneas_spike_alignment.json):
        {
          "sample": "...",
          "whisper_words": [{"start": float, "end": float, "word": "..."}, ...]
        }
    """
    src = Path(args.words_json)
    if not src.exists():
        print(f"words json not found: {src}", file=sys.stderr)
        return 1
    doc = json.loads(src.read_text())
    words = [
        Word(start=float(w["start"]), end=float(w["end"]), word=str(w["word"]))
        for w in doc.get("whisper_words", [])
    ]
    if not words:
        print("no whisper_words in json", file=sys.stderr)
        return 1
    duration = max(w.end for w in words)
    segments = align(words, duration)
    audio_name = doc.get("sample", src.stem)
    audio_path = ROOT / "samples" / audio_name if audio_name else None
    env = envelope(
        audio_path if (audio_path and audio_path.exists()) else None,
        duration, words, segments,
        source="from-words-json",
        model_size=None,
    )
    out = write_alignment(env, Path(args.out), Path(audio_name).stem)
    print(f"wrote {out}")
    print(f"  tiers: {env['tier_counts']}")
    return 0


def cmd_self_test(_args: argparse.Namespace) -> int:
    """Exercise the pure helpers with synthetic input — no ASR, no matcher.

    Validates: merge_windows, detect_repeats, detect_alaap_and_silence,
    score_tier, _is_vowel_only. Sufficient to catch refactor regressions on
    hosts without faster-whisper/rapidfuzz installed.
    """
    failures: list[str] = []

    # 1. _is_vowel_only
    cases = [
        ("aa", True), ("aaaa", True), ("ee", True), ("oo", True),
        ("naam", False), ("har", False), ("waheguru", False),
    ]
    for tok, expected in cases:
        got = _is_vowel_only(tok)
        if got != expected:
            failures.append(f"_is_vowel_only({tok!r}): expected {expected}, got {got}")

    # 2. merge_windows: two adjacent same-(ang, pangti) → one segment
    windows = [
        WindowHypothesis(0, 3, 0.0, 3.0, "aa bb cc", 626, 19, "ZT4", 88.0, 0.85),
        WindowHypothesis(3, 6, 3.0, 6.0, "dd ee ff", 626, 19, "ZT4", 90.0, 0.80),
        WindowHypothesis(6, 9, 6.0, 9.0, "gg hh ii", 626, 20, "ZT4", 72.0, 0.60),
    ]
    segs = merge_windows(windows)
    if len(segs) != 2:
        failures.append(f"merge_windows: expected 2 segments, got {len(segs)}")
    elif segs[0].end_sec != 6.0 or segs[0].ang != 626 or segs[0].pangti_index != 19:
        failures.append(f"merge_windows: first segment wrong: {segs[0]}")

    # 3. detect_repeats: same (ang, pangti) with gap → repeat_group_id set
    segs2 = [
        Segment(0.0, 3.0, "pangti", ang=626, pangti_index=19, match_confidence=85.0, coverage=0.80),
        Segment(10.0, 13.0, "pangti", ang=626, pangti_index=20, match_confidence=82.0, coverage=0.75),
        Segment(20.0, 23.0, "pangti", ang=626, pangti_index=19, match_confidence=86.0, coverage=0.82),
    ]
    detect_repeats(segs2)
    if segs2[0].repeat_group_id is None or segs2[2].repeat_group_id is None:
        failures.append("detect_repeats: failed to mark P19 repeats")
    elif segs2[0].repeat_group_id != segs2[2].repeat_group_id:
        failures.append("detect_repeats: P19 repeats have different group ids")
    if segs2[1].repeat_group_id is not None:
        failures.append("detect_repeats: P20 should not be in a repeat group")

    # 4. detect_alaap_and_silence: gap with no words → silence
    words = [Word(0.0, 1.0, "naam"), Word(1.0, 2.0, "har"), Word(15.0, 16.0, "saachaa")]
    segs3 = [
        Segment(0.0, 2.0, "pangti", ang=1, pangti_index=1, match_confidence=85.0, coverage=0.80),
        Segment(15.0, 16.0, "pangti", ang=1, pangti_index=2, match_confidence=85.0, coverage=0.80),
    ]
    augmented = detect_alaap_and_silence(segs3, words, 16.0)
    silence_segs = [s for s in augmented if s.kind == "silence"]
    if len(silence_segs) != 1:
        failures.append(f"detect_alaap_and_silence: expected 1 silence segment, got {len(silence_segs)}")

    # 5. detect_alaap_and_silence: gap with vowel-only words → alaap
    words_alaap = [Word(0.0, 1.0, "naam"), Word(5.0, 8.0, "aaaa"), Word(15.0, 16.0, "saachaa")]
    segs4 = [
        Segment(0.0, 1.0, "pangti", ang=1, pangti_index=1, match_confidence=85.0, coverage=0.80),
        Segment(15.0, 16.0, "pangti", ang=1, pangti_index=2, match_confidence=85.0, coverage=0.80),
    ]
    augmented4 = detect_alaap_and_silence(segs4, words_alaap, 16.0)
    alaap_segs = [s for s in augmented4 if s.kind == "alaap"]
    if len(alaap_segs) != 1:
        failures.append(f"detect_alaap_and_silence: expected 1 alaap segment, got {len(alaap_segs)}")

    # 6. detect_alaap_and_silence: pangti segment with vowel-only text → retagged alaap
    segs5 = [
        Segment(0.0, 4.0, "pangti", ang=626, pangti_index=19,
                text_latin="aa aa aaa", match_confidence=78.0, coverage=0.70),
    ]
    augmented5 = detect_alaap_and_silence(segs5, [], 4.0)
    if not (len(augmented5) == 1 and augmented5[0].kind == "alaap"):
        failures.append(f"detect_alaap_and_silence: vowel-only pangti not retagged: {augmented5}")

    # 7. score_tier: high / medium / needs_review boundaries
    s_high = Segment(0, 5, "pangti", ang=1, pangti_index=1,
                     match_confidence=85.0, coverage=0.75, boundary_uncertainty_sec=0.1)
    s_med = Segment(0, 5, "pangti", ang=1, pangti_index=1,
                    match_confidence=70.0, coverage=0.55, boundary_uncertainty_sec=0.5)
    s_low = Segment(0, 5, "pangti", ang=1, pangti_index=1,
                    match_confidence=50.0, coverage=0.40, boundary_uncertainty_sec=0.5)
    s_short = Segment(0, 1.0, "pangti", ang=1, pangti_index=1,
                      match_confidence=85.0, coverage=0.75, boundary_uncertainty_sec=0.1)
    s_repeat = Segment(0, 5, "pangti", ang=1, pangti_index=1,
                       match_confidence=85.0, coverage=0.75, boundary_uncertainty_sec=0.1,
                       repeat_group_id="rg_1_1_0")
    s_alaap = Segment(0, 5, "alaap")
    s_unknown = Segment(0, 5, "unknown")

    expected = {
        "high": score_tier(s_high),
        "medium": score_tier(s_med),
        "needs_review_lowconf": score_tier(s_low),
        "needs_review_short": score_tier(s_short),
        "needs_review_repeat": score_tier(s_repeat),
        "alaap_na": score_tier(s_alaap),
        "unknown_review": score_tier(s_unknown),
    }
    want = {
        "high": "high",
        "medium": "medium",
        "needs_review_lowconf": "needs_review",
        "needs_review_short": "needs_review",
        "needs_review_repeat": "needs_review",
        "alaap_na": "n/a",
        "unknown_review": "needs_review",
    }
    for k, v in want.items():
        if expected[k] != v:
            failures.append(f"score_tier[{k}]: expected {v}, got {expected[k]}")

    # 8. End-to-end: two P19 spans separated by P20 and a gap → all P19 instances
    #    join one repeat group (per DATASET_PHILOSOPHY §4: any detected repeat
    #    forces every member into needs_review).
    e2e_segs = [
        Segment(0.0, 4.0, "pangti", ang=626, pangti_index=19,
                match_confidence=88.0, coverage=0.85, text_latin="jee jaant tere taare"),
        Segment(5.0, 9.0, "pangti", ang=626, pangti_index=20,
                match_confidence=82.0, coverage=0.78, text_latin="rab doree raap tumaaree"),
        Segment(12.0, 16.0, "pangti", ang=626, pangti_index=19,
                match_confidence=87.0, coverage=0.84, text_latin="jee jaant tere taare"),
    ]
    detect_repeats(e2e_segs)
    if e2e_segs[0].repeat_group_id is None or e2e_segs[2].repeat_group_id is None:
        failures.append("e2e: both P19 instances should be tagged")
    if e2e_segs[0].repeat_group_id != e2e_segs[2].repeat_group_id:
        failures.append("e2e: P19 instances should share repeat_group_id")
    if e2e_segs[1].repeat_group_id is not None:
        failures.append("e2e: P20 (no repeat) should not be in a group")
    # And tier scoring should force needs_review on all P19 instances
    apply_tiers(e2e_segs)
    if e2e_segs[0].alignment_quality != "needs_review":
        failures.append(f"e2e: P19 instance 1 should be needs_review (repeat), got {e2e_segs[0].alignment_quality}")
    if e2e_segs[1].alignment_quality not in {"high", "medium"}:
        failures.append(f"e2e: P20 (no repeat) should be high/medium, got {e2e_segs[1].alignment_quality}")

    if failures:
        print("SELF-TEST FAIL:", file=sys.stderr)
        for f in failures:
            print(f"  - {f}", file=sys.stderr)
        return 1
    print(f"SELF-TEST PASS — {len(cases) + 6} assertions")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    p_audio = sub.add_parser("audio", help="Full pipeline against an audio file (needs faster-whisper)")
    p_audio.add_argument("audio", help="Path to audio file")
    p_audio.add_argument("--model", default="medium", help="faster-whisper model size")
    p_audio.add_argument("--out", default=str(DEFAULT_OUT_DIR), help="Output directory for alignment JSON")
    p_audio.set_defaults(func=cmd_audio)

    p_words = sub.add_parser("from-words", help="Re-run alignment from a captured words JSON (needs rapidfuzz)")
    p_words.add_argument("words_json", help="JSON file with whisper_words array")
    p_words.add_argument("--out", default=str(DEFAULT_OUT_DIR), help="Output directory for alignment JSON")
    p_words.set_defaults(func=cmd_from_words)

    p_test = sub.add_parser("self-test", help="Smoke test pure helpers — no audio, no ASR, no matcher")
    p_test.set_defaults(func=cmd_self_test)

    args = ap.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
