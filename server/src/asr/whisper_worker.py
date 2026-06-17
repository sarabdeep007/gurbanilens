#!/usr/bin/env python3
"""Single-shot faster-whisper transcription worker.

Invoked as a subprocess by the Node server. Reads an audio file path
from argv, transcribes it once, prints a single JSON object to stdout,
exits. No persistent process, no logging of transcript content (the
process holds the text in memory only).

Privacy contract: this script never opens a network socket, never reads
anything outside its argv-provided audio path, and writes nothing to
disk. It prints exactly one JSON object on stdout and exits.

Whisper config mirrors Phase 1 (and the on-device Swift wrapper):
  temperature=[0.0]      — no temperature fallback ladder
  vad_filter=False       — VAD discards sung Kirtan, verified 2026-05-12
  language=<arg>         — pin to 'pa' for Punjabi voice search
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from faster_whisper import WhisperModel


def transcribe(audio_path: Path, model_size: str, language: str | None) -> dict:
    """Run faster-whisper end-to-end on the file and return a result dict."""
    model = WhisperModel(model_size, device="auto", compute_type="auto")
    segments, info = model.transcribe(
        str(audio_path),
        language=language,
        task="transcribe",
        temperature=[0.0],
        vad_filter=False,
        condition_on_previous_text=False,
    )
    text_parts = []
    for seg in segments:
        chunk = (seg.text or "").strip()
        if chunk:
            text_parts.append(chunk)

    return {
        "transcript": " ".join(text_parts).strip(),
        "language": info.language,
        "language_probability": float(info.language_probability),
        "duration": float(info.duration),
        "model": model_size,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="faster-whisper single-shot worker")
    parser.add_argument("audio_path", type=Path, help="Path to audio file")
    parser.add_argument(
        "--model",
        default="large-v3",
        help="faster-whisper model name (default: large-v3)",
    )
    parser.add_argument(
        "--language",
        default=None,
        help="ISO 639-1 language code; omit for auto-detect (default: auto)",
    )
    args = parser.parse_args()

    if not args.audio_path.exists():
        print(json.dumps({"error": "audio_not_found", "path": str(args.audio_path)}),
              file=sys.stdout)
        return 2

    try:
        result = transcribe(args.audio_path, args.model, args.language)
    except Exception as exc:
        # Surface the error type but never the audio content.
        print(json.dumps({
            "error": "transcribe_failed",
            "kind": type(exc).__name__,
            "message": str(exc),
        }), file=sys.stdout)
        return 1

    print(json.dumps(result), file=sys.stdout)
    return 0


if __name__ == "__main__":
    sys.exit(main())
