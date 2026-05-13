"""Helper for systematic Kirtan / Paath sample gathering — Track B prep for Phase 2B.

Usage patterns Deep can leverage:

  # 1. From YouTube (audio-only download, 16kHz mono mp3)
  $ python scripts/fetch_samples.py youtube <url> --label "bhai_harjinder_ang462"

  # 2. From a local file (normalised, copied into samples/)
  $ python scripts/fetch_samples.py local /path/to/audio.wav --label "satnam_singh_ang872"

  # 3. List samples we have, with duration + size
  $ python scripts/fetch_samples.py list

  # 4. Validate samples for ASR sanity (transcript a 5s slice, log result)
  $ python scripts/fetch_samples.py probe <filename>

This script is intentionally lightweight — Deep does the curation/labelling,
the script just makes the mechanics quick. Long-form sample-gathering UI is
a Phase 2B deliverable; this is the shovel.
"""

from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SAMPLES_DIR = ROOT / "samples"
LABELS_FILE = SAMPLES_DIR / "labels.json"


def _slugify(label: str) -> str:
    """Filesystem-safe slug from a label."""
    return "".join(c if c.isalnum() or c in "-_" else "_" for c in label.lower())


def cmd_youtube(args: argparse.Namespace) -> int:
    """Download audio-only from a YouTube URL via yt-dlp.

    Requires `yt-dlp` and `ffmpeg` on PATH. We deliberately don't bundle these
    — they're standard tooling Deep should have / install separately.
    """
    if shutil.which("yt-dlp") is None:
        print("yt-dlp not found on PATH. Install: pipx install yt-dlp", file=sys.stderr)
        return 1
    if shutil.which("ffmpeg") is None:
        print("ffmpeg not found on PATH. Install: brew install ffmpeg", file=sys.stderr)
        return 1

    SAMPLES_DIR.mkdir(exist_ok=True)
    slug = _slugify(args.label)
    out_template = SAMPLES_DIR / f"{slug}.%(ext)s"
    cmd = [
        "yt-dlp",
        "--extract-audio",
        "--audio-format", "mp3",
        "--audio-quality", "5",  # mid-range — sufficient for ASR, smaller files
        "--postprocessor-args", "ffmpeg:-ar 16000 -ac 1",
        "-o", str(out_template),
        args.url,
    ]
    print(f"$ {' '.join(cmd)}")
    result = subprocess.run(cmd)
    return result.returncode


def cmd_local(args: argparse.Namespace) -> int:
    """Copy and resample a local audio file into samples/ as 16 kHz mono mp3."""
    if shutil.which("ffmpeg") is None:
        print("ffmpeg not found on PATH. Install: brew install ffmpeg", file=sys.stderr)
        return 1
    src = Path(args.path)
    if not src.exists():
        print(f"Source not found: {src}", file=sys.stderr)
        return 1
    SAMPLES_DIR.mkdir(exist_ok=True)
    slug = _slugify(args.label)
    out = SAMPLES_DIR / f"{slug}.mp3"
    cmd = ["ffmpeg", "-y", "-i", str(src), "-ar", "16000", "-ac", "1", "-q:a", "5", str(out)]
    print(f"$ {' '.join(cmd)}")
    result = subprocess.run(cmd, capture_output=True)
    if result.returncode != 0:
        print(result.stderr.decode(errors="replace"), file=sys.stderr)
        return result.returncode
    print(f"Wrote {out}")
    return 0


def cmd_list(args: argparse.Namespace) -> int:
    """List samples we already have, with sizes."""
    if not SAMPLES_DIR.exists():
        print(f"No samples dir at {SAMPLES_DIR}", file=sys.stderr)
        return 1
    samples = sorted(SAMPLES_DIR.glob("*.mp3"))
    if not samples:
        print(f"(no .mp3 samples in {SAMPLES_DIR})")
        return 0
    total = 0
    for p in samples:
        sz = p.stat().st_size
        total += sz
        print(f"  {p.name:<40s}  {sz / 1024:>8.0f} KB")
    print(f"\n{len(samples)} samples, {total / 1024 / 1024:.1f} MB total")
    return 0


def cmd_probe(args: argparse.Namespace) -> int:
    """Quick ASR sanity probe on a sample — runs evaluate.py against just this file."""
    target = SAMPLES_DIR / args.filename
    if not target.exists():
        print(f"Sample not found: {target}", file=sys.stderr)
        return 1
    # Re-use evaluate.py's cache-only path by running on the single file
    cmd = [
        sys.executable, "scripts/evaluate.py",
        "--model", args.model,
    ]
    print("probe = run full eval (uses cache where available)")
    print(f"$ {' '.join(cmd)}")
    return subprocess.run(cmd).returncode


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    p_yt = sub.add_parser("youtube", help="Download audio from YouTube")
    p_yt.add_argument("url")
    p_yt.add_argument("--label", required=True, help="filename slug")
    p_yt.set_defaults(func=cmd_youtube)

    p_local = sub.add_parser("local", help="Import a local audio file")
    p_local.add_argument("path")
    p_local.add_argument("--label", required=True)
    p_local.set_defaults(func=cmd_local)

    p_list = sub.add_parser("list", help="List samples")
    p_list.set_defaults(func=cmd_list)

    p_probe = sub.add_parser("probe", help="Probe a sample with ASR")
    p_probe.add_argument("filename")
    p_probe.add_argument("--model", default="medium")
    p_probe.set_defaults(func=cmd_probe)

    args = ap.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
