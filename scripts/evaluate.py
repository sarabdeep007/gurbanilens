"""Phase 1 evaluation: run every sample through the full pipeline,
emit an aggregate report at evaluation/phase1_report.md.

Per-window matches use the same sliding-window heuristic as the CLI:
short Whisper segments matched as-is, longer ones split into ~Pangti-sized
windows with 50% overlap.
"""

from __future__ import annotations

import json
import time
from dataclasses import dataclass
from pathlib import Path

from gurbanilens.asr import Segment, WhisperASR
from gurbanilens.corpus import Corpus
from gurbanilens.matcher import Match, Matcher

ROOT = Path(__file__).resolve().parent.parent
SAMPLES_DIR = ROOT / "samples"
EVAL_DIR = ROOT / "evaluation"
THRESHOLD = 75.0
SHORT_SEGMENT_MAX = 8
WINDOW = 6
STEP = 3


@dataclass
class Window:
    start: float
    end: float
    latin: str
    native: str | None
    match: Match | None


def _fmt_time(t: float) -> str:
    return f"{int(t // 60):02d}:{int(t % 60):02d}"


def _windows_from_segment(seg: Segment, matcher: Matcher) -> list[Window]:
    tokens = seg.text_latin.split()
    if len(tokens) <= SHORT_SEGMENT_MAX:
        results = matcher.match(seg.text_latin, top_n=1)
        return [Window(seg.start, seg.end, seg.text_latin, seg.text_native,
                       results[0] if results else None)]
    out = []
    duration_per_token = (seg.end - seg.start) / max(len(tokens), 1)
    for i in range(0, len(tokens) - STEP + 1, STEP):
        sub = tokens[i : i + WINDOW]
        if len(sub) < STEP:
            break
        sub_latin = " ".join(sub)
        sub_start = seg.start + i * duration_per_token
        sub_end = seg.start + (i + len(sub)) * duration_per_token
        results = matcher.match(sub_latin, top_n=1)
        out.append(Window(sub_start, sub_end, sub_latin, None,
                          results[0] if results else None))
    return out


def _summarise(windows: list[Window]) -> dict:
    confident = [w for w in windows if w.match and w.match.score >= THRESHOLD]
    best = max(
        (w for w in windows if w.match),
        key=lambda w: w.match.score,
        default=None,
    )
    # First confident match timestamp
    first_confident_t = confident[0].start if confident else None

    # Lost-the-thread heuristic: distinct Angs across confident windows
    distinct_angs = sorted({w.match.line.ang for w in confident})

    return {
        "windows_total": len(windows),
        "windows_confident": len(confident),
        "best": best,
        "first_confident_time": first_confident_t,
        "distinct_confident_angs": distinct_angs,
    }


def _notes_for(summary: dict, windows: list[Window]) -> str:
    confident = summary["windows_confident"]
    total = summary["windows_total"]
    angs = summary["distinct_confident_angs"]
    if total == 0:
        return "no transcription produced"
    if confident == 0:
        return "no confident matches"
    if confident == total:
        return "every window confident"
    if len(angs) == 1:
        return f"all confident windows hit single Ang {angs[0]} (likely Rahao repeat or one Shabad)"
    if len(angs) > 3:
        return f"confident matches scattered across {len(angs)} Angs — possibly lost the thread"
    return f"matched {len(angs)} distinct Angs"


def main() -> None:
    EVAL_DIR.mkdir(exist_ok=True)
    samples = sorted(SAMPLES_DIR.glob("*.mp3"))
    if not samples:
        raise SystemExit(f"No .mp3 samples found in {SAMPLES_DIR}")

    print(f"Loading corpus + matcher...")
    corpus = Corpus()
    matcher = Matcher(corpus)
    print(f"  indexed {len(matcher):,} lines")

    print(f"Loading Whisper (medium)...")
    asr = WhisperASR(model_size="medium", vad_filter=False)
    print(f"  ready\n")

    all_results = []
    for i, path in enumerate(samples, 1):
        print(f"[{i:>2d}/{len(samples)}] {path.name} ...", flush=True)
        t0 = time.time()
        windows: list[Window] = []
        for seg in asr.transcribe_stream(path):
            windows.extend(_windows_from_segment(seg, matcher))
        elapsed = time.time() - t0
        summary = _summarise(windows)
        all_results.append({
            "filename": path.name,
            "elapsed_sec": elapsed,
            "windows": windows,
            **summary,
        })
        b = summary["best"]
        best_str = f"Ang {b.match.line.ang}:P{b.match.line.pangti} ({b.match.score:.1f})" if b and b.match else "—"
        print(f"           done in {elapsed:5.1f}s   best: {best_str}   "
              f"confident: {summary['windows_confident']}/{summary['windows_total']}")

    _write_report(all_results)
    _write_csv(all_results)
    print(f"\nReport: {EVAL_DIR / 'phase1_report.md'}")
    print(f"CSV:    {EVAL_DIR / 'phase1_summary.csv'}")


def _write_report(results: list[dict]) -> None:
    md: list[str] = []
    md.append("# Phase 1 Evaluation Report\n\n")
    md.append(f"_Auto-generated. Whisper model: medium. Threshold: {THRESHOLD}. "
              f"Window: {WINDOW} tokens / {STEP} step. VAD off._\n\n")

    md.append("## Summary\n\n")
    md.append("| # | File | Dur | Best match | Conf | First confident | Confident / total | Notes |\n")
    md.append("|---|---|---|---|---|---|---|---|\n")
    for i, r in enumerate(results, 1):
        end = max((w.end for w in r["windows"]), default=0.0)
        dur = _fmt_time(end)
        b = r["best"]
        if b and b.match:
            best = f"Ang {b.match.line.ang}:P{b.match.line.pangti} [{b.match.line.line_type or '-'}]"
            conf = f"{b.match.score:.1f}"
        else:
            best, conf = "—", "—"
        first = _fmt_time(r["first_confident_time"]) if r["first_confident_time"] is not None else "—"
        notes = _notes_for(r, r["windows"])
        md.append(f"| {i} | `{r['filename']}` | {dur} | {best} | {conf} | {first} | "
                  f"{r['windows_confident']} / {r['windows_total']} | {notes} |\n")

    md.append("\n_Ground-truth column intentionally empty — Deep to fill in for verified matches._\n\n")

    md.append("\n## Per-sample detail\n\n")
    for i, r in enumerate(results, 1):
        md.append(f"### {i}. `{r['filename']}`\n\n")
        md.append(f"Processed in {r['elapsed_sec']:.1f}s. ")
        md.append(f"{r['windows_confident']}/{r['windows_total']} windows confident "
                  f"(≥{THRESHOLD}). Notes: {_notes_for(r, r['windows'])}.\n\n")

        if not r["windows"]:
            md.append("_No transcription produced._\n\n")
            continue

        md.append("| Time | Conf | Match | Latin (heard, normalised) | Corpus line |\n")
        md.append("|---|---|---|---|---|\n")
        for w in r["windows"]:
            t = f"{_fmt_time(w.start)} → {_fmt_time(w.end)}"
            if w.match:
                conf = f"**{w.match.score:.1f}**" if w.match.score >= THRESHOLD else f"{w.match.score:.1f}"
                ang = f"Ang {w.match.line.ang}:P{w.match.line.pangti}"
                line = (w.match.line.transliteration_en or "")[:80]
            else:
                conf, ang, line = "—", "—", "—"
            latin = w.latin[:80]
            md.append(f"| {t} | {conf} | {ang} | `{latin}` | {line} |\n")
        md.append("\n")

    (EVAL_DIR / "phase1_report.md").write_text("".join(md))


def _write_csv(results: list[dict]) -> None:
    lines = ["filename,ground_truth,best_ang,best_pangti,best_conf,"
             "best_time,windows_confident,windows_total,notes\n"]
    for r in results:
        b = r["best"]
        if b and b.match:
            ang = str(b.match.line.ang)
            pangti = str(b.match.line.pangti or "")
            conf = f"{b.match.score:.1f}"
            time_str = _fmt_time(b.start)
        else:
            ang = pangti = conf = time_str = ""
        notes = _notes_for(r, r["windows"]).replace(",", ";")
        lines.append(
            f"\"{r['filename']}\",,{ang},{pangti},{conf},{time_str},"
            f"{r['windows_confident']},{r['windows_total']},\"{notes}\"\n"
        )
    (EVAL_DIR / "phase1_summary.csv").write_text("".join(lines))


if __name__ == "__main__":
    main()
