#!/usr/bin/env python3
"""Sarvam REST batch sanity check — Phase 2.

POST a 16kHz mono s16le WAV to https://api.sarvam.ai/speech-to-text
and dump the full response. If status=200 with a transcript field
populated, REST batch is confirmed working and we have a viable
v1 fallback even if streaming WS turns out to be infeasible.

Usage:  python3 test_rest_batch.py [variation]

variation is one of: default, lang-pa, lang-hi-IN, model-v2, model-v2.5,
   timestamps-false, bearer-auth, raw-body. Default tries the baseline
   contract per Sarvam docs (saaras:v3, pa-IN, multipart, api-subscription-key).
"""

import json
import os
import sys
import time
import pathlib
import requests

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _keys import SARVAM_API_KEY  # noqa

ROOT = pathlib.Path(__file__).parent
WAV  = ROOT / "test_audio" / "test.wav"
LOGS = ROOT / "logs"

URL  = "https://api.sarvam.ai/speech-to-text"

def log_result(variation, status, headers, body):
    ts = time.strftime("%Y%m%dT%H%M%S")
    rec = {
        "variation": variation,
        "url": URL,
        "status": status,
        "response_headers": dict(headers) if headers else {},
        "response_body": body[:4000] if isinstance(body, str) else body,
        "wav_size_bytes": WAV.stat().st_size,
        "ts": ts,
    }
    out = LOGS / f"rest_batch_{variation}_{ts}.json"
    out.write_text(json.dumps(rec, indent=2, ensure_ascii=False))
    print(f"  -> wrote {out}")

def run_variation(variation):
    print(f"\n=== variation: {variation} ===")
    with open(WAV, "rb") as f:
        wav_bytes = f.read()

    files = None
    data = None
    headers = {}
    body = None

    if variation == "default":
        files   = {"file": ("test.wav", wav_bytes, "audio/wav")}
        data    = {"model": "saaras:v3", "language_code": "pa-IN"}
        headers = {"api-subscription-key": SARVAM_API_KEY}
    elif variation == "lang-pa":
        files   = {"file": ("test.wav", wav_bytes, "audio/wav")}
        data    = {"model": "saaras:v3", "language_code": "pa"}
        headers = {"api-subscription-key": SARVAM_API_KEY}
    elif variation == "lang-hi-IN":
        files   = {"file": ("test.wav", wav_bytes, "audio/wav")}
        data    = {"model": "saaras:v3", "language_code": "hi-IN"}
        headers = {"api-subscription-key": SARVAM_API_KEY}
    elif variation == "model-v2":
        files   = {"file": ("test.wav", wav_bytes, "audio/wav")}
        data    = {"model": "saaras:v2", "language_code": "pa-IN"}
        headers = {"api-subscription-key": SARVAM_API_KEY}
    elif variation == "model-v2.5":
        files   = {"file": ("test.wav", wav_bytes, "audio/wav")}
        data    = {"model": "saaras:v2.5", "language_code": "pa-IN"}
        headers = {"api-subscription-key": SARVAM_API_KEY}
    elif variation == "model-saarika-v2.5":
        files   = {"file": ("test.wav", wav_bytes, "audio/wav")}
        data    = {"model": "saarika:v2.5", "language_code": "pa-IN"}
        headers = {"api-subscription-key": SARVAM_API_KEY}
    elif variation == "timestamps-false":
        files   = {"file": ("test.wav", wav_bytes, "audio/wav")}
        data    = {"model": "saaras:v3", "language_code": "pa-IN",
                   "with_timestamps": "false", "with_diarization": "false"}
        headers = {"api-subscription-key": SARVAM_API_KEY}
    elif variation == "bearer-auth":
        files   = {"file": ("test.wav", wav_bytes, "audio/wav")}
        data    = {"model": "saaras:v3", "language_code": "pa-IN"}
        headers = {"Authorization": f"Bearer {SARVAM_API_KEY}"}
    elif variation == "raw-body":
        body    = wav_bytes
        headers = {"api-subscription-key": SARVAM_API_KEY,
                   "Content-Type": "audio/wav"}
    else:
        print(f"Unknown variation: {variation}")
        sys.exit(2)

    try:
        if body is not None:
            r = requests.post(URL, data=body, headers=headers, timeout=60)
        else:
            r = requests.post(URL, files=files, data=data, headers=headers, timeout=60)
    except Exception as e:
        print(f"  EXCEPTION: {type(e).__name__}: {e}")
        log_result(variation, -1, {}, f"EXCEPTION: {e}")
        return None

    print(f"  status: {r.status_code}")
    print(f"  body (first 500 chars): {r.text[:500]}")
    log_result(variation, r.status_code, r.headers, r.text)
    return r.status_code, r.text

def main():
    LOGS.mkdir(exist_ok=True)
    variations = sys.argv[1:] or ["default"]
    for v in variations:
        run_variation(v)

if __name__ == "__main__":
    main()
