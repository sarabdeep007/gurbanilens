"""Phase 1 evaluation: run every sample through the full pipeline.

Writes evaluation/phase1_<model>_report.md + .csv with per-sample results.
Transcripts are cached under evaluation/.cache/<model>/ so we can iterate on
matcher/normalisation logic without re-running Whisper.

Near-miss inference: when a sub-threshold sample's top match shabad_id appears
in another sample's top match (especially a confident one from the same singer
group), we flag it as a "near miss correct" — likely the right Shabad area,
just below confidence.
"""

from __future__ import annotations

import argparse
import json
import sys
import time
from collections import defaultdict
from dataclasses import asdict, dataclass
from pathlib import Path

from gurbanilens.asr import Segment, WhisperASR
from gurbanilens.corpus import Corpus
from gurbanilens.matcher import Match, Matcher

ROOT = Path(__file__).resolve().parent.parent
SAMPLES_DIR = ROOT / "samples"
EVAL_DIR = ROOT / "evaluation"
CACHE_DIR = EVAL_DIR / ".cache"
THRESHOLD = 75.0
SHORT_SEGMENT_MAX = 8
WINDOW = 6
STEP = 3
DEFAULT_PER_SAMPLE_TIMEOUT = 1800.0  # 30 min; med took up to 300s, 5× gives 1500s, buffer to 1800


@dataclass
class WindowResult:
    start: float
    end: float
    latin: str
    native: str | None
    match: Match | None


def _fmt_time(t: float) -> str:
    return f"{int(t // 60):02d}:{int(t % 60):02d}"


def _filename_group(name: str) -> str:
    """e.g. 'harjinder singh 4.mp3' → 'harjinder singh'."""
    stem = Path(name).stem
    parts = stem.rsplit(" ", 1)
    if len(parts) == 2 and parts[1].isdigit():
        return parts[0]
    return stem


# -- caching ----------------------------------------------------------------

def _cache_path(model: str, audio: Path) -> Path:
    return CACHE_DIR / model / f"{audio.stem}.json"


def _segments_to_json(segments: list[Segment]) -> list[dict]:
    return [asdict(s) for s in segments]


def _segments_from_json(data: list[dict]) -> list[Segment]:
    return [Segment(**s) for s in data]


def transcribe_cached(
    asr: WhisperASR | None,
    path: Path,
    model: str,
    per_sample_timeout: float,
) -> tuple[list[Segment], float, bool]:
    """Return (segments, elapsed_seconds, timed_out)."""
    cache_path = _cache_path(model, path)
    cache_path.parent.mkdir(parents=True, exist_ok=True)
    if cache_path.exists() and cache_path.stat().st_mtime >= path.stat().st_mtime:
        with cache_path.open() as f:
            data = json.load(f)
        return _segments_from_json(data["segments"]), float(data["elapsed"]), bool(data["timed_out"])

    if asr is None:
        raise RuntimeError(f"Cache miss for {path.name} but no ASR engine provided")

    segments: list[Segment] = []
    timed_out = False
    start = time.time()
    for seg in asr.transcribe_stream(path):
        if (time.time() - start) > per_sample_timeout:
            timed_out = True
            print(f"           ⚠ TIMEOUT after {per_sample_timeout:.0f}s; captured {len(segments)} segments",
                  flush=True)
            break
        segments.append(seg)
    elapsed = time.time() - start

    with cache_path.open("w") as f:
        json.dump(
            {
                "segments": _segments_to_json(segments),
                "elapsed": elapsed,
                "timed_out": timed_out,
            },
            f,
            ensure_ascii=False,
        )
    return segments, elapsed, timed_out


# -- windowing / matching ---------------------------------------------------

def _windows_from_segment(seg: Segment, matcher: Matcher) -> list[WindowResult]:
    tokens = seg.text_latin.split()
    if len(tokens) <= SHORT_SEGMENT_MAX:
        results = matcher.match(seg.text_latin, top_n=1)
        return [WindowResult(
            seg.start, seg.end, seg.text_latin, seg.text_native,
            results[0] if results else None,
        )]
    out: list[WindowResult] = []
    duration_per_token = (seg.end - seg.start) / max(len(tokens), 1)
    for i in range(0, len(tokens) - STEP + 1, STEP):
        sub = tokens[i : i + WINDOW]
        if len(sub) < STEP:
            break
        sub_latin = " ".join(sub)
        sub_start = seg.start + i * duration_per_token
        sub_end = seg.start + (i + len(sub)) * duration_per_token
        results = matcher.match(sub_latin, top_n=1)
        out.append(WindowResult(
            sub_start, sub_end, sub_latin, None,
            results[0] if results else None,
        ))
    return out


# -- per-sample summary -----------------------------------------------------

@dataclass
class SampleSummary:
    filename: str
    group: str
    elapsed_sec: float
    timed_out: bool
    windows: list[WindowResult]
    best: WindowResult | None
    windows_confident: int
    first_confident_time: float | None
    distinct_confident_angs: list[int]
    near_miss_correct: bool | None  # filled in post-hoc


def _summarise(filename: str, windows: list[WindowResult], elapsed: float, timed_out: bool) -> SampleSummary:
    confident = [w for w in windows if w.match and w.match.score >= THRESHOLD]
    best = max(
        (w for w in windows if w.match),
        key=lambda w: w.match.score,
        default=None,
    )
    return SampleSummary(
        filename=filename,
        group=_filename_group(filename),
        elapsed_sec=elapsed,
        timed_out=timed_out,
        windows=windows,
        best=best,
        windows_confident=len(confident),
        first_confident_time=confident[0].start if confident else None,
        distinct_confident_angs=sorted({w.match.line.ang for w in confident}),
        near_miss_correct=None,
    )


def _infer_near_misses(summaries: list[SampleSummary]) -> None:
    """Mark near_miss_correct on every sub-threshold sample."""
    # Map shabad_id → list of (filename, group, score)
    shabad_index: dict[str, list[tuple[str, str, float]]] = defaultdict(list)
    for s in summaries:
        if s.best and s.best.match:
            shabad_index[s.best.match.line.shabad_id].append(
                (s.filename, s.group, s.best.match.score)
            )

    for s in summaries:
        if not s.best or not s.best.match:
            continue
        score = s.best.match.score
        if score >= THRESHOLD:
            continue  # already confident, not a near-miss
        shabad = s.best.match.line.shabad_id
        siblings = [(fn, g, sc) for fn, g, sc in shabad_index[shabad] if fn != s.filename]
        # True if any other sample on this same shabad scored confidently
        # OR if 2+ samples in the same singer-group landed on this shabad
        any_confident_sibling = any(sc >= THRESHOLD for _, _, sc in siblings)
        same_group_siblings = sum(1 for _, g, _ in siblings if g == s.group)
        if any_confident_sibling or same_group_siblings >= 1:
            s.near_miss_correct = True


# -- report writing ---------------------------------------------------------

def _nm_label(s: SampleSummary) -> str:
    if not s.best or not s.best.match:
        return "—"
    if s.best.match.score >= THRESHOLD:
        return "—"  # already confident
    return "✅ same Shabad as confident sibling" if s.near_miss_correct else "❓ unverified"


def _notes_for(s: SampleSummary) -> str:
    if not s.windows:
        return "no transcription produced"
    if s.timed_out:
        return f"TIMED OUT — partial result from {len(s.windows)} windows"
    if s.windows_confident == 0:
        return "no confident matches"
    if s.windows_confident == len(s.windows):
        return "every window confident"
    if len(s.distinct_confident_angs) == 1:
        return f"all confident windows on Ang {s.distinct_confident_angs[0]} (Rahao repeat / one Shabad)"
    if len(s.distinct_confident_angs) > 3:
        return f"confident matches scattered across {len(s.distinct_confident_angs)} Angs — possibly lost the thread"
    return f"confident on {len(s.distinct_confident_angs)} distinct Angs"


def _write_report(model: str, summaries: list[SampleSummary]) -> Path:
    md: list[str] = []
    md.append(f"# Phase 1 Evaluation Report — Whisper `{model}`\n\n")
    md.append(f"_Auto-generated. Threshold: {THRESHOLD}. "
              f"Window: {WINDOW} tokens / {STEP} step. VAD off._\n\n")

    md.append("## Summary\n\n")
    md.append("| # | File | Dur | Best match | Shabad | Conf | First conf. | Conf./total | Near-miss | Notes |\n")
    md.append("|---|---|---|---|---|---|---|---|---|---|\n")
    for i, s in enumerate(summaries, 1):
        end = max((w.end for w in s.windows), default=0.0)
        dur = _fmt_time(end)
        if s.best and s.best.match:
            best = f"Ang {s.best.match.line.ang}:P{s.best.match.line.pangti} [{s.best.match.line.line_type or '-'}]"
            shabad = f"`{s.best.match.line.shabad_id}`"
            conf = f"{s.best.match.score:.1f}"
        else:
            best, shabad, conf = "—", "—", "—"
        first = _fmt_time(s.first_confident_time) if s.first_confident_time is not None else "—"
        nm = _nm_label(s)
        notes = _notes_for(s)
        md.append(
            f"| {i} | `{s.filename}` | {dur} | {best} | {shabad} | {conf} | {first} | "
            f"{s.windows_confident} / {len(s.windows)} | {nm} | {notes} |\n"
        )

    md.append(
        "\n_Near-miss column inferred automatically when a sub-threshold sample's "
        "top match shabad_id matches a confident sibling's. Manual ground-truth pass still "
        "welcome._\n\n"
    )

    md.append("\n## Per-sample detail\n\n")
    for i, s in enumerate(summaries, 1):
        md.append(f"### {i}. `{s.filename}`\n\n")
        md.append(f"Processed in {s.elapsed_sec:.1f}s")
        if s.timed_out:
            md.append(" (TIMED OUT)")
        md.append(f". {s.windows_confident}/{len(s.windows)} windows confident "
                  f"(≥{THRESHOLD}). Notes: {_notes_for(s)}.\n\n")

        if not s.windows:
            md.append("_No transcription produced._\n\n")
            continue

        md.append("| Time | Conf | Match | Shabad | Latin (heard) | Corpus line |\n")
        md.append("|---|---|---|---|---|---|\n")
        for w in s.windows:
            t = f"{_fmt_time(w.start)} → {_fmt_time(w.end)}"
            if w.match:
                conf = f"**{w.match.score:.1f}**" if w.match.score >= THRESHOLD else f"{w.match.score:.1f}"
                ang = f"Ang {w.match.line.ang}:P{w.match.line.pangti}"
                shabad = f"`{w.match.line.shabad_id}`"
                line = (w.match.line.transliteration_en or "")[:80]
            else:
                conf, ang, shabad, line = "—", "—", "—", "—"
            latin = w.latin[:80]
            md.append(f"| {t} | {conf} | {ang} | {shabad} | `{latin}` | {line} |\n")
        md.append("\n")

    out = EVAL_DIR / f"phase1_{model}_report.md"
    out.write_text("".join(md))
    return out


def _write_csv(model: str, summaries: list[SampleSummary]) -> Path:
    rows = ["filename,group,ground_truth,best_ang,best_pangti,best_shabad_id,"
            "best_conf,best_time,windows_confident,windows_total,near_miss_correct,timed_out,elapsed_sec,notes\n"]
    for s in summaries:
        if s.best and s.best.match:
            ang = str(s.best.match.line.ang)
            pangti = str(s.best.match.line.pangti or "")
            shabad = s.best.match.line.shabad_id
            conf = f"{s.best.match.score:.1f}"
            time_str = _fmt_time(s.best.start)
        else:
            ang = pangti = shabad = conf = time_str = ""
        nm = "true" if s.near_miss_correct else ("false" if s.best and s.best.match and s.best.match.score < THRESHOLD else "")
        notes = _notes_for(s).replace(",", ";")
        rows.append(
            f"\"{s.filename}\",\"{s.group}\",,{ang},{pangti},{shabad},{conf},{time_str},"
            f"{s.windows_confident},{len(s.windows)},{nm},{str(s.timed_out).lower()},"
            f"{s.elapsed_sec:.1f},\"{notes}\"\n"
        )
    out = EVAL_DIR / f"phase1_{model}_summary.csv"
    out.write_text("".join(rows))
    return out


# -- main -------------------------------------------------------------------

def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--model", default="medium", help="faster-whisper model size")
    ap.add_argument("--timeout-per-sample", type=float, default=DEFAULT_PER_SAMPLE_TIMEOUT,
                    help="kill a sample's transcription if it exceeds this many seconds")
    ap.add_argument("--use-cache-only", action="store_true",
                    help="don't load Whisper; only use cached transcripts")
    args = ap.parse_args()

    EVAL_DIR.mkdir(exist_ok=True)
    samples = sorted(SAMPLES_DIR.glob("*.mp3"))
    if not samples:
        raise SystemExit(f"No .mp3 samples found in {SAMPLES_DIR}")

    print(f"Loading corpus + matcher...")
    corpus = Corpus()
    matcher = Matcher(corpus)
    print(f"  indexed {len(matcher):,} lines")

    asr: WhisperASR | None = None
    if not args.use_cache_only:
        print(f"Loading Whisper ({args.model})...")
        asr = WhisperASR(model_size=args.model, vad_filter=False)
        print(f"  ready\n")

    summaries: list[SampleSummary] = []
    for i, path in enumerate(samples, 1):
        print(f"[{i:>2d}/{len(samples)}] {path.name} ...", flush=True)
        try:
            segments, elapsed, timed_out = transcribe_cached(
                asr, path, args.model, args.timeout_per_sample
            )
        except Exception as e:
            print(f"           ✗ {e}")
            continue
        windows: list[WindowResult] = []
        for seg in segments:
            windows.extend(_windows_from_segment(seg, matcher))
        s = _summarise(path.name, windows, elapsed, timed_out)
        summaries.append(s)
        if s.best and s.best.match:
            best_str = f"Ang {s.best.match.line.ang}:P{s.best.match.line.pangti} ({s.best.match.score:.1f})"
        else:
            best_str = "—"
        print(f"           done in {elapsed:6.1f}s   best: {best_str}   "
              f"conf: {s.windows_confident}/{len(s.windows)}"
              f"{' (TIMED OUT)' if timed_out else ''}")

    _infer_near_misses(summaries)
    report = _write_report(args.model, summaries)
    csv = _write_csv(args.model, summaries)
    print(f"\nReport: {report}")
    print(f"CSV:    {csv}")


if __name__ == "__main__":
    main()
