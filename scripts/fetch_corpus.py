"""Download the Shabad OS SGGS SQLite corpus into data/sggs/.

Usage:
    python scripts/fetch_corpus.py [--version 4.8.7] [--force]

Downloads database.sqlite from
https://github.com/shabados/database/releases/download/<version>/database.sqlite
into data/sggs/database.sqlite.

We pin the version explicitly because v5 (currently 5.0.0-next.0) has a different
schema. corpus.py expects the v4 schema.
"""

from __future__ import annotations

import argparse
import sys
import urllib.request
from pathlib import Path

DEFAULT_VERSION = "4.8.7"
RELEASE_URL = "https://github.com/shabados/database/releases/download/{version}/database.sqlite"
TARGET = Path(__file__).resolve().parent.parent / "data" / "sggs" / "database.sqlite"


def fetch(version: str, force: bool) -> Path:
    TARGET.parent.mkdir(parents=True, exist_ok=True)
    if TARGET.exists() and not force:
        size_mb = TARGET.stat().st_size / 1024 / 1024
        print(f"Already exists: {TARGET} ({size_mb:.1f} MB). Use --force to redownload.")
        return TARGET

    url = RELEASE_URL.format(version=version)
    print(f"Downloading {url}")
    tmp = TARGET.with_suffix(".sqlite.part")

    def progress(blocks: int, block_size: int, total: int) -> None:
        downloaded = blocks * block_size
        if total > 0:
            pct = min(100, downloaded * 100 // total)
            print(
                f"\r  {downloaded / 1024 / 1024:6.1f} / {total / 1024 / 1024:6.1f} MB  ({pct}%)",
                end="",
                flush=True,
            )

    urllib.request.urlretrieve(url, tmp, reporthook=progress)
    print()
    tmp.rename(TARGET)
    print(f"Saved to {TARGET}")
    return TARGET


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", default=DEFAULT_VERSION, help="Shabad OS DB release tag")
    parser.add_argument("--force", action="store_true", help="Redownload even if already present")
    args = parser.parse_args()

    try:
        fetch(args.version, args.force)
    except urllib.error.HTTPError as e:
        print(f"Download failed: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
