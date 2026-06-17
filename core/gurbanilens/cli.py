"""GurbaniLens CLI.

Currently exposes one command: ``match-file <audio>`` — transcribe an audio
file and match each segment to SGGS Pangtis.
"""

from __future__ import annotations

import sys
import time
from pathlib import Path

import typer

from .asr import ASREngine, Segment, WhisperASR
from .corpus import Corpus
from .matcher import Match, Matcher

app = typer.Typer(add_completion=False, help="GurbaniLens — Kirtan-to-Pangti matcher.")


@app.callback()
def _main() -> None:
    """GurbaniLens — Kirtan-to-Pangti matcher."""
    # Empty callback forces typer into multi-subcommand mode so `match-file`
    # remains a required subcommand even when it's the only one.


def _fmt_time(t: float) -> str:
    m, s = divmod(int(t), 60)
    return f"{m:02d}:{s:02d}"


def _emit_match(
    start: float,
    end: float,
    native: str,
    latin: str,
    results: list[Match],
    threshold: float,
    indent: str = "",
) -> None:
    when = f"[{_fmt_time(start)} → {_fmt_time(end)}]"
    if not results:
        print(f"{indent}{when}  (no transcript)")
        return
    top = results[0]
    confident = top.score >= threshold
    tag = "MATCH " if confident else "no    "
    loc = f"Ang {top.line.ang}:P{top.line.pangti}"
    print(f"{indent}{when}  {tag} (conf {top.score:5.1f})  {loc}  [{top.line.line_type}]")
    if native:
        print(f"{indent}           heard: {native}")
    print(f"{indent}           latin: {latin}")
    print(f"{indent}           line : {top.line.transliteration_en}")
    if not confident and len(results) > 1:
        runners = ", ".join(
            f"Ang {m.line.ang}:P{m.line.pangti} ({m.score:.0f})"
            for m in results[1:3]
        )
        print(f"{indent}           also : {runners}")
    print()


def _process_segment(
    seg: Segment,
    matcher: Matcher,
    threshold: float,
    window_tokens: int = 6,
    window_step: int = 3,
    short_segment_max: int = 8,
) -> None:
    """Match a Whisper segment, sub-windowing if it spans multiple Pangtis.

    Whisper sometimes packs 2-3 Pangtis into a single segment (no audible
    pause between lines). A long query against single-Pangti corpus rows
    can't score well — partial_ratio aligns but token coverage falls. We
    slide a ~Pangti-sized window across the latin text and emit each
    sub-window's match, with linearly-interpolated timestamps.
    """
    tokens = seg.text_latin.split()
    if len(tokens) <= short_segment_max:
        results = matcher.match(seg.text_latin, top_n=3)
        _emit_match(seg.start, seg.end, seg.text_native, seg.text_latin, results, threshold)
        return

    print(f"[{_fmt_time(seg.start)} → {_fmt_time(seg.end)}]  long segment "
          f"({len(tokens)} tokens) — windowing")
    print(f"           heard: {seg.text_native}")
    duration_per_token = (seg.end - seg.start) / max(len(tokens), 1)
    for i in range(0, len(tokens) - window_step + 1, window_step):
        sub_tokens = tokens[i : i + window_tokens]
        if len(sub_tokens) < window_step:
            break
        sub_text = " ".join(sub_tokens)
        sub_start = seg.start + i * duration_per_token
        sub_end = seg.start + (i + len(sub_tokens)) * duration_per_token
        results = matcher.match(sub_text, top_n=3)
        _emit_match(sub_start, sub_end, "", sub_text, results, threshold, indent="  ")


@app.command("match-file")
def match_file(
    audio_path: Path = typer.Argument(..., exists=True, dir_okay=False, readable=True),
    model: str = typer.Option("medium", "--model", "-m", help="faster-whisper model size"),
    threshold: float = typer.Option(75.0, "--threshold", "-t", help="confidence cutoff for MATCH tag"),
    engine: str = typer.Option("whisper", "--engine", help="ASR engine: whisper (default)"),
    vad: bool = typer.Option(False, "--vad/--no-vad", help="Silero VAD pre-filter; OFF by default — VAD eats sung Kirtan. Enable only for noisy ambient mics with lots of silence"),
) -> None:
    """Transcribe AUDIO_PATH and match each segment to SGGS Pangtis."""
    print(f"Loading corpus...", file=sys.stderr)
    t0 = time.time()
    corpus = Corpus()
    matcher = Matcher(corpus)
    print(f"  indexed {len(matcher):,} lines in {time.time()-t0:.1f}s", file=sys.stderr)

    print(f"Loading ASR engine ({engine}, model={model})...", file=sys.stderr)
    t0 = time.time()
    asr: ASREngine
    if engine == "whisper":
        asr = WhisperASR(model_size=model, vad_filter=vad)
    else:
        raise typer.BadParameter(f"unknown engine: {engine}")
    print(f"  ready in {time.time()-t0:.1f}s", file=sys.stderr)

    print(f"\nTranscribing {audio_path.name} ...\n", file=sys.stderr)
    for seg in asr.transcribe_stream(audio_path):
        _process_segment(seg, matcher, threshold)


if __name__ == "__main__":
    app()
