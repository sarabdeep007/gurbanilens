// Smoke test for POST /transcribe.
//
// We avoid actually running faster-whisper by pointing WHISPER_PYTHON
// at a fake script that emits a canned JSON response. This keeps the
// test deterministic and fast — Vitest runs it in milliseconds.

import { describe, it, beforeAll, afterAll, expect } from "vitest";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { writeFileSync, chmodSync, mkdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { randomBytes } from "node:crypto";

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = join(HERE, "..");

let app;
let fakePython;

beforeAll(async () => {
  // Build a fake "python" shim that emits a canned faster-whisper-style
  // response regardless of arguments.
  const tmp = join(tmpdir(), "gl-test-" + randomBytes(4).toString("hex"));
  mkdirSync(tmp, { recursive: true });
  fakePython = join(tmp, "fake-python.sh");
  writeFileSync(fakePython,
    "#!/usr/bin/env bash\n" +
    "echo '{\"transcript\":\"test transcript\",\"language\":\"en\",\"language_probability\":0.99,\"duration\":1.2,\"model\":\"tiny\"}'\n"
  );
  chmodSync(fakePython, 0o755);

  process.env.PORT = "0";          // ephemeral
  process.env.HOST = "127.0.0.1";
  process.env.WHISPER_PYTHON = fakePython;
  process.env.WHISPER_WORKER = "/dev/null";   // unused — fake script ignores argv
  process.env.WHISPER_MODEL = "tiny";
  process.env.FEEDBACK_DISABLED = "1";
  process.env.LOG_LEVEL = "warn";

  const mod = await import("../src/test-harness.js");
  app = await mod.buildAppForTests();
  await app.ready();
});

afterAll(async () => {
  await app?.close();
});

async function inject(opts) {
  return await app.inject(opts);
}

const FAKE_FLAC = Buffer.from([
  // Minimal-ish FLAC header. We bypass ffprobe by using WHISPER_DISABLED
  // path? — no, the route does ffprobe. So instead we provide a real
  // small audio. Generate via the helper below.
]);

// Helper: create a 1-second silent WAV file in memory (no ffmpeg
// needed). 16 kHz mono PCM.
function silentWav(seconds = 1) {
  const sampleRate = 16000;
  const numSamples = sampleRate * seconds;
  const dataSize = numSamples * 2; // mono int16
  const buf = Buffer.alloc(44 + dataSize);
  buf.write("RIFF", 0);
  buf.writeUInt32LE(36 + dataSize, 4);
  buf.write("WAVE", 8);
  buf.write("fmt ", 12);
  buf.writeUInt32LE(16, 16);        // PCM chunk size
  buf.writeUInt16LE(1, 20);         // PCM format
  buf.writeUInt16LE(1, 22);         // mono
  buf.writeUInt32LE(sampleRate, 24);
  buf.writeUInt32LE(sampleRate * 2, 28);
  buf.writeUInt16LE(2, 32);
  buf.writeUInt16LE(16, 34);
  buf.write("data", 36);
  buf.writeUInt32LE(dataSize, 40);
  // rest of buffer is zero — silent samples
  return buf;
}

function multipart(name, filename, contentType, body, boundary) {
  return Buffer.concat([
    Buffer.from(`--${boundary}\r\n`),
    Buffer.from(`Content-Disposition: form-data; name="${name}"; filename="${filename}"\r\n`),
    Buffer.from(`Content-Type: ${contentType}\r\n\r\n`),
    body,
    Buffer.from(`\r\n--${boundary}--\r\n`),
  ]);
}

describe("POST /transcribe", () => {
  it("rejects missing bearer with 401", async () => {
    const wav = silentWav(1);
    const boundary = "----test" + randomBytes(8).toString("hex");
    const res = await inject({
      method: "POST",
      url: "/transcribe",
      headers: { "content-type": `multipart/form-data; boundary=${boundary}` },
      payload: multipart("audio", "x.wav", "audio/wav", wav, boundary),
    });
    expect(res.statusCode).toBe(401);
    expect(JSON.parse(res.body).error).toBe("missing_or_malformed_bearer_token");
  });

  it("accepts a valid request and returns the canned transcript", async () => {
    const wav = silentWav(1);
    const boundary = "----test" + randomBytes(8).toString("hex");
    const res = await inject({
      method: "POST",
      url: "/transcribe",
      headers: {
        "content-type": `multipart/form-data; boundary=${boundary}`,
        "authorization": "Bearer test-token-abcdef",
      },
      payload: multipart("audio", "clip.wav", "audio/wav", wav, boundary),
    });
    expect(res.statusCode).toBe(200);
    const body = JSON.parse(res.body);
    expect(body).toEqual({
      transcript: "test transcript",
      language: "en",
      duration: 1.2,
      model: "tiny",
    });
    expect(res.headers["x-robots-tag"]).toBe("noindex");
    expect(res.headers["cache-control"]).toBe("no-store");
    expect(res.headers["x-ratelimit-limit"]).toBe("60");
  });

  it("rejects non-audio files with 415", async () => {
    const boundary = "----test" + randomBytes(8).toString("hex");
    const res = await inject({
      method: "POST",
      url: "/transcribe",
      headers: {
        "content-type": `multipart/form-data; boundary=${boundary}`,
        "authorization": "Bearer test-token-abcdef",
      },
      payload: multipart("audio", "evil.exe", "application/x-msdownload",
        Buffer.from("MZ"), boundary),
    });
    expect(res.statusCode).toBe(415);
  });
});

describe("GET /healthz", () => {
  it("returns ok", async () => {
    const res = await inject({ method: "GET", url: "/healthz" });
    expect(res.statusCode).toBe(200);
    expect(JSON.parse(res.body)).toMatchObject({ status: "ok" });
  });
});

describe("GET /readyz", () => {
  it("reports python/worker existence", async () => {
    const res = await inject({ method: "GET", url: "/readyz" });
    const body = JSON.parse(res.body);
    expect(body.checks.python_exists).toBe(true);
    // worker_path is /dev/null in this test — that's a "file"
    expect(typeof body.checks.worker_exists).toBe("boolean");
  });
});
