"""Build the Phase 2B Kirtan dataset from the sample registry + alignments.

Consumes:
  - ``samples/registry.json`` — sample metadata (jatha, raag, recording_quality, ...)
  - ``samples/alignments/<id>.json`` — per-sample segment alignments
    produced by ``scripts/align_sample.py``

Produces:
  - ``dataset/manifest.json`` — registry of which samples + alignments are
    included in this build, with the algorithm version and the
    training-eligibility predicate that was applied
  - ``dataset/splits/{train,val,test}.json`` — JSON-Lines-compatible arrays of
    training rows in HuggingFace-datasets-friendly shape
  - ``dataset/audio/<id>.<ext>`` — symlink (or copy with ``--copy``) of the
    source audio so the splits can resolve paths relative to ``dataset/``

Training-eligibility predicate (per ``docs/alignment_accuracy.md`` §6):
  1. ``segment.alignment_quality in {"high", "medium"}``
  2. ``segment.kind == "pangti"``
  3. ``segment.text_gurmukhi`` is not null
  4. ``segment.repeat_group_id`` is null  (v1 conservatism)
  5. Parent sample ``recording_quality in {"studio", "clean_live"}``

Splits are deterministic: assignment is by ``sha256(sample_id) mod 100`` —
0-79 train, 80-89 val, 90-99 test. All segments from the same sample go to
the same split (no sample leakage between splits).

Usage:

    # Build from current registry + alignments
    python scripts/build_dataset.py build

    # Show what would be built without writing
    python scripts/build_dataset.py build --dry-run

    # Validate an existing build (manifest ↔ disk consistency)
    python scripts/build_dataset.py validate

    # Print stats about the current build
    python scripts/build_dataset.py stats
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parent.parent
REGISTRY_PATH = ROOT / "samples" / "registry.json"
ALIGN_SRC_DIR = ROOT / "samples" / "alignments"
DATASET_DIR = ROOT / "dataset"
DATASET_MANIFEST = DATASET_DIR / "manifest.json"
DATASET_SPLITS_DIR = DATASET_DIR / "splits"
DATASET_AUDIO_DIR = DATASET_DIR / "audio"
DATASET_ALIGN_DIR = DATASET_DIR / "alignments"

ELIGIBLE_TIERS = {"high", "medium"}
ELIGIBLE_QUALITIES = {"studio", "clean_live"}
SPLIT_TRAIN_UPPER = 80  # 0-79
SPLIT_VAL_UPPER = 90    # 80-89
# 90-99 → test
BUILD_VERSION = 1


@dataclass
class TrainingRow:
    """One row in a split — HuggingFace-friendly shape."""
    sample_id: str
    segment_idx: int  # index within parent alignment's segments[]
    audio_path: str   # relative to dataset/ root
    audio_sha256: str | None
    start_sec: float
    end_sec: float
    duration_sec: float
    text_gurmukhi: str
    text_latin: str | None
    ang: int
    pangti_index: int
    shabad_id: str | None
    match_confidence: float | None
    coverage: float | None
    alignment_quality: str  # high | medium
    jatha: str | None
    raag: str | None
    recording_quality: str | None
    source_url: str | None
    license_notes: str | None


def split_for_sample(sample_id: str) -> str:
    """Deterministic split assignment by hash. Uses 4 bytes for clean 80/10/10."""
    h = hashlib.sha256(sample_id.encode("utf-8")).digest()
    bucket = int.from_bytes(h[:4], "big") % 100
    if bucket < SPLIT_TRAIN_UPPER:
        return "train"
    if bucket < SPLIT_VAL_UPPER:
        return "val"
    return "test"


def is_segment_eligible(segment: dict[str, Any]) -> tuple[bool, str]:
    """Check segment-level part of the eligibility predicate."""
    if segment.get("alignment_quality") not in ELIGIBLE_TIERS:
        return False, f"tier={segment.get('alignment_quality')}"
    if segment.get("kind") != "pangti":
        return False, f"kind={segment.get('kind')}"
    if not segment.get("text_gurmukhi"):
        return False, "no text_gurmukhi"
    if segment.get("repeat_group_id") is not None:
        return False, "repeat_group_id set"
    if segment.get("ang") is None or segment.get("pangti_index") is None:
        return False, "missing ang/pangti"
    return True, "ok"


def is_sample_eligible(sample: dict[str, Any]) -> tuple[bool, str]:
    """Check sample-level part of the eligibility predicate."""
    if sample.get("alignment_status") not in {"machine_aligned", "human_reviewed"}:
        return False, f"alignment_status={sample.get('alignment_status')}"
    if not sample.get("alignment_file"):
        return False, "no alignment_file"
    if sample.get("recording_quality") not in ELIGIBLE_QUALITIES:
        return False, f"recording_quality={sample.get('recording_quality')}"
    if not sample.get("filename"):
        return False, "no filename"
    return True, "ok"


def load_registry() -> dict[str, Any]:
    if not REGISTRY_PATH.exists():
        print(f"registry not found: {REGISTRY_PATH}", file=sys.stderr)
        sys.exit(1)
    return json.loads(REGISTRY_PATH.read_text())


def link_audio(src: Path, dst: Path, *, copy: bool) -> None:
    """Symlink (default) or copy the audio file into dataset/audio/."""
    if dst.exists() or dst.is_symlink():
        dst.unlink()
    if copy:
        import shutil
        shutil.copy2(src, dst)
    else:
        # Relative symlink so the dataset is portable
        rel_src = os.path.relpath(src, dst.parent)
        os.symlink(rel_src, dst)


def link_alignment(src: Path, dst: Path) -> None:
    """Copy alignment JSON into dataset/alignments/ — small, content-addressed by sample id."""
    dst.write_text(src.read_text())


@dataclass
class BuildReport:
    samples_total: int = 0
    samples_eligible: int = 0
    samples_skipped: list[tuple[str, str]] = field(default_factory=list)
    rows_total: int = 0
    rows_per_split: dict[str, int] = field(default_factory=lambda: {"train": 0, "val": 0, "test": 0})
    rows_per_tier: dict[str, int] = field(default_factory=lambda: {"high": 0, "medium": 0})
    distinct_pangtis: set[tuple[int, int]] = field(default_factory=set)
    distinct_jathas: set[str] = field(default_factory=set)
    distinct_raags: set[str] = field(default_factory=set)
    total_duration_sec: float = 0.0
    segments_skipped: list[tuple[str, int, str]] = field(default_factory=list)

    def coverage_summary(self) -> dict[str, Any]:
        return {
            "rows": self.rows_total,
            "duration_sec": round(self.total_duration_sec, 1),
            "duration_hours": round(self.total_duration_sec / 3600.0, 2),
            "rows_per_split": dict(self.rows_per_split),
            "rows_per_tier": dict(self.rows_per_tier),
            "distinct_pangtis": len(self.distinct_pangtis),
            "distinct_jathas": len(self.distinct_jathas),
            "distinct_raags": len(self.distinct_raags),
        }


def gather_rows(registry: dict[str, Any], report: BuildReport) -> dict[str, list[TrainingRow]]:
    """Walk the registry, load alignments, emit eligible rows by split."""
    by_split: dict[str, list[TrainingRow]] = {"train": [], "val": [], "test": []}

    for sample in registry.get("samples", []):
        report.samples_total += 1
        sample_id = sample.get("id") or sample.get("filename")
        ok, reason = is_sample_eligible(sample)
        if not ok:
            report.samples_skipped.append((str(sample_id), reason))
            continue
        align_path = ROOT / sample["alignment_file"]
        if not align_path.exists():
            report.samples_skipped.append((str(sample_id), f"alignment missing: {align_path}"))
            continue
        try:
            alignment = json.loads(align_path.read_text())
        except json.JSONDecodeError as exc:
            report.samples_skipped.append((str(sample_id), f"alignment JSON invalid: {exc}"))
            continue

        report.samples_eligible += 1
        split = split_for_sample(str(sample_id))

        for idx, segment in enumerate(alignment.get("segments", [])):
            seg_ok, seg_reason = is_segment_eligible(segment)
            if not seg_ok:
                report.segments_skipped.append((str(sample_id), idx, seg_reason))
                continue

            duration = float(segment["end_sec"]) - float(segment["start_sec"])
            row = TrainingRow(
                sample_id=str(sample_id),
                segment_idx=idx,
                audio_path=f"audio/{sample['filename']}",
                audio_sha256=sample.get("audio_sha256"),
                start_sec=float(segment["start_sec"]),
                end_sec=float(segment["end_sec"]),
                duration_sec=duration,
                text_gurmukhi=segment["text_gurmukhi"],
                text_latin=segment.get("text_latin"),
                ang=int(segment["ang"]),
                pangti_index=int(segment["pangti_index"]),
                shabad_id=segment.get("shabad_id"),
                match_confidence=segment.get("match_confidence"),
                coverage=segment.get("coverage"),
                alignment_quality=segment["alignment_quality"],
                jatha=sample.get("jatha"),
                raag=sample.get("raag"),
                recording_quality=sample.get("recording_quality"),
                source_url=sample.get("source_url"),
                license_notes=sample.get("license_notes"),
            )
            by_split[split].append(row)
            report.rows_total += 1
            report.rows_per_split[split] += 1
            report.rows_per_tier[row.alignment_quality] = report.rows_per_tier.get(row.alignment_quality, 0) + 1
            report.distinct_pangtis.add((row.ang, row.pangti_index))
            if row.jatha:
                report.distinct_jathas.add(row.jatha)
            if row.raag:
                report.distinct_raags.add(row.raag)
            report.total_duration_sec += duration

    return by_split


def write_build(
    registry: dict[str, Any],
    by_split: dict[str, list[TrainingRow]],
    report: BuildReport,
    *,
    copy_audio: bool,
) -> None:
    DATASET_SPLITS_DIR.mkdir(parents=True, exist_ok=True)
    DATASET_AUDIO_DIR.mkdir(parents=True, exist_ok=True)
    DATASET_ALIGN_DIR.mkdir(parents=True, exist_ok=True)

    # Write splits as JSON arrays (HF datasets accepts JSON/JSONL via load_dataset)
    for split, rows in by_split.items():
        out = DATASET_SPLITS_DIR / f"{split}.json"
        out.write_text(json.dumps(
            [_row_to_dict(r) for r in rows],
            indent=2, ensure_ascii=False,
        ))

    # Link audio + copy alignments for eligible samples only
    linked_samples = []
    audio_linked = set()
    align_copied = set()
    for rows in by_split.values():
        for r in rows:
            if r.sample_id in audio_linked:
                continue
            # Find the registry entry to get the source filename
            sample = next(
                (s for s in registry["samples"]
                 if (s.get("id") or s.get("filename")) == r.sample_id),
                None,
            )
            if sample is None:
                continue
            src_audio = ROOT / "samples" / sample["filename"]
            dst_audio = DATASET_AUDIO_DIR / sample["filename"]
            if src_audio.exists():
                link_audio(src_audio, dst_audio, copy=copy_audio)
                audio_linked.add(r.sample_id)
            src_align = ROOT / sample["alignment_file"]
            dst_align = DATASET_ALIGN_DIR / f"{r.sample_id}.json"
            if src_align.exists() and r.sample_id not in align_copied:
                link_alignment(src_align, dst_align)
                align_copied.add(r.sample_id)
            linked_samples.append({
                "id": r.sample_id,
                "filename": sample["filename"],
                "audio_sha256": sample.get("audio_sha256"),
                "split": split_for_sample(r.sample_id),
                "alignment_file": f"alignments/{r.sample_id}.json",
                "source_url": sample.get("source_url"),
                "license_notes": sample.get("license_notes"),
            })

    # Deduplicate linked_samples by id (we hit each id once per split anyway, but be safe)
    seen_ids = set()
    unique_samples = []
    for s in linked_samples:
        if s["id"] in seen_ids:
            continue
        seen_ids.add(s["id"])
        unique_samples.append(s)

    manifest = {
        "schema_version": BUILD_VERSION,
        "build_id": _compute_build_id(unique_samples),
        "produced_by": "scripts/build_dataset.py",
        "registry_path": str(REGISTRY_PATH.relative_to(ROOT)),
        "eligibility_predicate": {
            "tiers": sorted(ELIGIBLE_TIERS),
            "kinds": ["pangti"],
            "require_text_gurmukhi": True,
            "exclude_repeat_groups": True,
            "recording_qualities": sorted(ELIGIBLE_QUALITIES),
            "doc": "docs/alignment_accuracy.md §6",
        },
        "splits": {
            "train": {"file": "splits/train.json", "rows": report.rows_per_split["train"]},
            "val": {"file": "splits/val.json", "rows": report.rows_per_split["val"]},
            "test": {"file": "splits/test.json", "rows": report.rows_per_split["test"]},
        },
        "coverage": report.coverage_summary(),
        "v1_targets": registry.get("coverage_targets_v1"),
        "samples": unique_samples,
        "audio_storage": "copied" if copy_audio else "symlinked",
    }
    DATASET_MANIFEST.write_text(json.dumps(manifest, indent=2, ensure_ascii=False))


def _row_to_dict(r: TrainingRow) -> dict[str, Any]:
    return {
        "sample_id": r.sample_id,
        "segment_idx": r.segment_idx,
        "audio": r.audio_path,  # HF Audio feature reads from here
        "audio_sha256": r.audio_sha256,
        "start_sec": round(r.start_sec, 3),
        "end_sec": round(r.end_sec, 3),
        "duration_sec": round(r.duration_sec, 3),
        "sentence": r.text_gurmukhi,  # 'sentence' = HF Whisper-fine-tune convention
        "text_latin": r.text_latin,
        "ang": r.ang,
        "pangti_index": r.pangti_index,
        "shabad_id": r.shabad_id,
        "match_confidence": r.match_confidence,
        "coverage": r.coverage,
        "alignment_quality": r.alignment_quality,
        "jatha": r.jatha,
        "raag": r.raag,
        "recording_quality": r.recording_quality,
        "source_url": r.source_url,
        "license_notes": r.license_notes,
    }


def _compute_build_id(samples: list[dict[str, Any]]) -> str:
    """Content-addressed build id: hash of sample SHA-256s in canonical order."""
    h = hashlib.sha256()
    for s in sorted(samples, key=lambda x: x["id"]):
        h.update(f"{s['id']}|{s.get('audio_sha256') or ''}\n".encode("utf-8"))
    return h.hexdigest()[:16]


# ─── CLI subcommands ─────────────────────────────────────────────────────────


def cmd_build(args: argparse.Namespace) -> int:
    registry = load_registry()
    report = BuildReport()
    by_split = gather_rows(registry, report)

    print(f"samples scanned: {report.samples_total}")
    print(f"samples eligible: {report.samples_eligible}")
    if report.samples_skipped:
        print(f"samples skipped: {len(report.samples_skipped)}")
        for sid, reason in report.samples_skipped[:10]:
            print(f"  - {sid}: {reason}")
        if len(report.samples_skipped) > 10:
            print(f"  ... +{len(report.samples_skipped) - 10} more")
    print(f"\ntraining rows produced: {report.rows_total}")
    for split, n in report.rows_per_split.items():
        print(f"  {split}: {n}")
    print(f"\ncoverage vs v1 targets:")
    cov = report.coverage_summary()
    targets = registry.get("coverage_targets_v1", {})
    for key, target in [
        ("duration_hours", targets.get("high_tier_audio_hours")),
        ("distinct_jathas", targets.get("distinct_jathas")),
        ("distinct_raags", targets.get("distinct_raags")),
        ("distinct_pangtis", targets.get("distinct_pangtis")),
    ]:
        got = cov.get(key)
        if target is not None:
            status = "✓" if (got or 0) >= target else "·"
            print(f"  {status} {key}: {got} / {target}")
        else:
            print(f"    {key}: {got}")

    if args.dry_run:
        print("\n(dry-run — nothing written)")
        return 0

    write_build(registry, by_split, report, copy_audio=args.copy)
    print(f"\nwrote {DATASET_MANIFEST.relative_to(ROOT)}")
    print(f"wrote splits to {DATASET_SPLITS_DIR.relative_to(ROOT)}/")
    return 0


def cmd_validate(_args: argparse.Namespace) -> int:
    """Check the on-disk dataset is internally consistent."""
    if not DATASET_MANIFEST.exists():
        print(f"no manifest at {DATASET_MANIFEST} — run `build` first", file=sys.stderr)
        return 1
    manifest = json.loads(DATASET_MANIFEST.read_text())
    errors: list[str] = []

    # Every sample in manifest.samples should have its alignment + (optionally) audio on disk
    for s in manifest["samples"]:
        align_path = DATASET_DIR / s["alignment_file"]
        if not align_path.exists():
            errors.append(f"alignment missing: {align_path}")
        audio_path = DATASET_AUDIO_DIR / s["filename"]
        if not audio_path.exists() and not audio_path.is_symlink():
            errors.append(f"audio missing: {audio_path}")

    # Every split file should exist and row counts should match manifest
    for split, info in manifest["splits"].items():
        split_path = DATASET_DIR / info["file"]
        if not split_path.exists():
            errors.append(f"split file missing: {split_path}")
            continue
        rows = json.loads(split_path.read_text())
        if len(rows) != info["rows"]:
            errors.append(f"{split}: manifest says {info['rows']} rows, file has {len(rows)}")

    if errors:
        print("VALIDATION FAIL:")
        for e in errors:
            print(f"  - {e}")
        return 1
    print(f"VALIDATION PASS — {len(manifest['samples'])} samples, "
          f"{sum(info['rows'] for info in manifest['splits'].values())} rows")
    return 0


def cmd_stats(_args: argparse.Namespace) -> int:
    if not DATASET_MANIFEST.exists():
        print(f"no manifest at {DATASET_MANIFEST} — run `build` first", file=sys.stderr)
        return 1
    manifest = json.loads(DATASET_MANIFEST.read_text())
    print(f"build_id: {manifest['build_id']}")
    print(f"samples: {len(manifest['samples'])}")
    print(f"coverage: {json.dumps(manifest['coverage'], indent=2)}")
    print(f"splits:")
    for split, info in manifest["splits"].items():
        print(f"  {split}: {info['rows']} rows ({info['file']})")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    p_build = sub.add_parser("build", help="Build splits from current registry + alignments")
    p_build.add_argument("--dry-run", action="store_true", help="Don't write anything")
    p_build.add_argument("--copy", action="store_true", help="Copy audio into dataset/audio/ instead of symlinking")
    p_build.set_defaults(func=cmd_build)

    p_val = sub.add_parser("validate", help="Check on-disk consistency of a built dataset")
    p_val.set_defaults(func=cmd_validate)

    p_stats = sub.add_parser("stats", help="Print stats about the current build")
    p_stats.set_defaults(func=cmd_stats)

    args = ap.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
