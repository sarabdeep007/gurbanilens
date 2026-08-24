#!/usr/bin/env python3
"""Sarvam WebSocket streaming hypothesis tester — Phase 3.

We KNOW the account + keys work (Phase 2 REST batch returned a real
Punjabi transcript). Any WS failure here is purely protocol-level.

Usage:  python3 test_ws_stream.py H1
        python3 test_ws_stream.py H2
        ...
        python3 test_ws_stream.py H7

Each hypothesis is one CONCRETE wire-format guess. We capture the
WebSocket CLOSE CODE + CLOSE REASON — that's the diagnostic data
the iOS [DIAG] logs never gave us.

Hypotheses (ordered most-likely-to-work first):
  H1 — JSON-wrapped base64, our commit-d22cd6b/de786bf shape:
         {"audio": {"data": b64, "sample_rate": "16000", "encoding": "audio/wav"}}
  H2 — Raw binary frames (BINARY opcode)
  H3 — Explicit start config message FIRST, then audio
  H4 — Different URL: /v1/speech-to-text/streaming
  H5 — Different URL: /speech-to-text/streaming (older form, vs /ws)
  H6 — Pipecat exact wire format (mirror their SDK serialization)
  H7 — Saarika model instead of Saaras (AVR uses saarika:v2.5)

Each test:
  1. Connect with documented URL + headers
  2. Send first message per hypothesis
  3. Read whatever the server sends until close
  4. Save full log to logs/ws_<HX>_<ts>.json
"""

import base64
import json
import os
import sys
import time
import pathlib
import threading
import websocket

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _keys import SARVAM_API_KEY  # noqa

ROOT = pathlib.Path(__file__).parent
WAV  = ROOT / "test_audio" / "test.wav"
LOGS = ROOT / "logs"

DEFAULT_URL = ("wss://api.sarvam.ai/speech-to-text/ws"
               "?model=saaras:v3&language-code=pa-IN&mode=transcribe"
               "&sample_rate=16000&input_audio_codec=pcm_s16le"
               "&high_vad_sensitivity=true")

CHUNK_BYTES = 3200   # 100 ms of 16 kHz s16le mono


def read_pcm():
    """Skip the 44-byte WAV header, return raw s16le PCM body."""
    with open(WAV, "rb") as f:
        f.read(44)
        return f.read()


def run(hypothesis: str, url: str, header: dict,
        prelude_messages: list, audio_strategy: str,
        chunk_bytes: int = CHUNK_BYTES,
        wait_for_close_sec: float = 6.0):
    """Run one hypothesis. audio_strategy is one of:
       'json_b64'    — {"audio":{"data": b64, ...}} text frames
       'binary'      — raw bytes as binary frames
       'json_pipecat'— pipecat-style {"audio": b64_str, "encoding": "audio/pcm_s16le", "sample_rate": 16000}
       'json_audio_only_str' — {"audio": b64_str, "sample_rate": "16000", "encoding": "audio/wav"} (flat, not nested)
       'json_alt_keys'— {"audio_chunk": b64, "format": "pcm_s16le", "sample_rate": 16000}
       'skip'        — no audio (connection-only test)
    """
    print(f"\n=== {hypothesis} ===")
    print(f"  URL: {url}")
    print(f"  prelude: {len(prelude_messages)} messages")
    print(f"  audio_strategy: {audio_strategy}")

    pcm = read_pcm()
    print(f"  pcm bytes: {len(pcm)}")

    events = []        # ordered timeline
    closed = threading.Event()

    def stamp(): return f"{time.time():.3f}"

    def push(kind, payload):
        evt = {"t": stamp(), "kind": kind, "payload": payload}
        events.append(evt)
        print(f"  [{evt['t']}] {kind}: "
              f"{str(payload)[:160] if not isinstance(payload, bytes) else f'<{len(payload)} bytes>'}")

    def on_open(ws):
        push("OPEN", "")
        # Send prelude messages
        for msg in prelude_messages:
            try:
                if isinstance(msg, str):
                    ws.send(msg)
                    push("SEND_TEXT", msg[:200])
                else:
                    ws.send(msg, websocket.ABNF.OPCODE_BINARY)
                    push("SEND_BINARY", f"<{len(msg)} bytes>")
            except Exception as e:
                push("SEND_PRELUDE_ERR", f"{type(e).__name__}: {e}")
                return

        if audio_strategy == "skip":
            push("AUDIO_SKIPPED", "")
            return

        # Stream audio in chunks
        def stream_audio():
            try:
                offset = 0
                chunk_idx = 0
                while offset < len(pcm):
                    chunk = pcm[offset:offset + chunk_bytes]
                    offset += chunk_bytes
                    chunk_idx += 1
                    if audio_strategy == "json_b64":
                        payload = json.dumps({
                            "audio": {
                                "data": base64.b64encode(chunk).decode("ascii"),
                                "sample_rate": "16000",
                                "encoding": "audio/wav",
                            }
                        })
                        ws.send(payload)
                    elif audio_strategy == "json_pipecat":
                        payload = json.dumps({
                            "audio": base64.b64encode(chunk).decode("ascii"),
                            "encoding": "audio/pcm_s16le",
                            "sample_rate": 16000,
                        })
                        ws.send(payload)
                    elif audio_strategy == "json_audio_only_str":
                        payload = json.dumps({
                            "audio": base64.b64encode(chunk).decode("ascii"),
                            "sample_rate": "16000",
                            "encoding": "audio/wav",
                        })
                        ws.send(payload)
                    elif audio_strategy == "json_alt_keys":
                        payload = json.dumps({
                            "audio_chunk": base64.b64encode(chunk).decode("ascii"),
                            "format": "pcm_s16le",
                            "sample_rate": 16000,
                        })
                        ws.send(payload)
                    elif audio_strategy == "binary":
                        ws.send(chunk, websocket.ABNF.OPCODE_BINARY)
                    else:
                        push("BAD_STRATEGY", audio_strategy)
                        return
                    if chunk_idx <= 2 or chunk_idx % 10 == 0:
                        push(f"SEND_AUDIO_{chunk_idx}", f"<{len(chunk)} bytes>")
                    time.sleep(0.05)  # pace at 50ms — slightly faster than 100ms chunk to leave room
                push("AUDIO_DONE", f"sent {chunk_idx} chunks")
                # Wait a bit for server to flush
                time.sleep(1.5)
                push("CLIENT_CLOSE", "graceful")
                ws.close()
            except Exception as e:
                push("STREAM_ERR", f"{type(e).__name__}: {e}")

        threading.Thread(target=stream_audio, daemon=True).start()

    def on_message(ws, message):
        if isinstance(message, bytes):
            push("RECV_BINARY", f"<{len(message)} bytes>")
        else:
            push("RECV_TEXT", message[:400])

    def on_error(ws, error):
        push("ERROR", f"{type(error).__name__}: {error}")

    def on_close(ws, code, reason):
        push("CLOSED", {"code": code, "reason": reason})
        closed.set()

    ws = websocket.WebSocketApp(url,
        header=header,
        on_open=on_open,
        on_message=on_message,
        on_error=on_error,
        on_close=on_close)

    def runner():
        ws.run_forever(ping_interval=0)
    t = threading.Thread(target=runner, daemon=True)
    t.start()

    # Wait up to N seconds for close, or hard-cut at 12s.
    closed.wait(timeout=12.0)
    if not closed.is_set():
        push("HARD_TIMEOUT", "12s")
        try: ws.close()
        except: pass

    # Save log
    ts = time.strftime("%Y%m%dT%H%M%S")
    out = LOGS / f"ws_{hypothesis}_{ts}.json"
    rec = {
        "hypothesis": hypothesis,
        "url": url,
        "headers": {k: ("<KEY>" if "subscription" in k.lower() or "auth" in k.lower() else v)
                    for k, v in header.items()},
        "prelude_count": len(prelude_messages),
        "audio_strategy": audio_strategy,
        "events": events,
    }
    out.write_text(json.dumps(rec, indent=2, ensure_ascii=False))
    print(f"  -> wrote {out}")

    # Did any RECV_TEXT contain a transcript field?
    success = False
    for e in events:
        if e["kind"] == "RECV_TEXT" and "transcript" in str(e["payload"]):
            success = True
            break
    print(f"  RESULT: {'SUCCESS (transcript received)' if success else 'no transcript'}")
    return success, events


HYPOTHESES = {
    "H1": dict(
        url=DEFAULT_URL,
        header={"api-subscription-key": SARVAM_API_KEY},
        prelude_messages=[],
        audio_strategy="json_b64",
    ),
    "H2": dict(
        url=DEFAULT_URL,
        header={"api-subscription-key": SARVAM_API_KEY},
        prelude_messages=[],
        audio_strategy="binary",
    ),
    "H3": dict(
        url=DEFAULT_URL,
        header={"api-subscription-key": SARVAM_API_KEY},
        prelude_messages=[json.dumps({
            "type": "config",
            "model": "saaras:v3",
            "language_code": "pa-IN",
            "encoding": "audio/x-raw;rate=16000;format=S16LE;channels=1",
        })],
        audio_strategy="json_b64",
    ),
    "H4": dict(
        url=("wss://api.sarvam.ai/v1/speech-to-text/streaming"
             "?model=saaras:v3&language-code=pa-IN&high_vad_sensitivity=true"),
        header={"api-subscription-key": SARVAM_API_KEY},
        prelude_messages=[],
        audio_strategy="json_b64",
    ),
    "H5": dict(
        url=("wss://api.sarvam.ai/speech-to-text/streaming"
             "?model=saaras:v3&language-code=pa-IN&high_vad_sensitivity=true"),
        header={"api-subscription-key": SARVAM_API_KEY},
        prelude_messages=[],
        audio_strategy="json_b64",
    ),
    "H6": dict(
        url=DEFAULT_URL,
        header={"api-subscription-key": SARVAM_API_KEY},
        prelude_messages=[],
        audio_strategy="json_pipecat",
    ),
    "H7": dict(
        url=("wss://api.sarvam.ai/speech-to-text/ws"
             "?model=saarika:v2.5&language-code=pa-IN&mode=transcribe"
             "&sample_rate=16000&input_audio_codec=pcm_s16le"),
        header={"api-subscription-key": SARVAM_API_KEY},
        prelude_messages=[],
        audio_strategy="json_b64",
    ),
    # Bonus: connection-only test (no audio) — diagnostic for "does server ack open?"
    "H0": dict(
        url=DEFAULT_URL,
        header={"api-subscription-key": SARVAM_API_KEY},
        prelude_messages=[],
        audio_strategy="skip",
    ),
}


def main():
    LOGS.mkdir(exist_ok=True)
    which = sys.argv[1:] or ["H1"]
    for h in which:
        if h not in HYPOTHESES:
            print(f"Unknown hypothesis: {h}. Available: {list(HYPOTHESES)}")
            continue
        ok, _ = run(h, **HYPOTHESES[h])
        if ok:
            print(f"\n*** {h} SUCCEEDED — stopping further hypotheses ***")
            break


if __name__ == "__main__":
    main()
