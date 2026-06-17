// Smoke test for /feedback/* — uses a temp SQLite DB and a fresh
// FeedbackStore. No network, no Whisper.

import { describe, it, beforeAll, afterAll, expect } from "vitest";
import { rmSync, mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

let app;
let tmpDir;

beforeAll(async () => {
  tmpDir = mkdtempSync(join(tmpdir(), "gl-feedback-test-"));

  process.env.PORT = "0";
  process.env.HOST = "127.0.0.1";
  process.env.WHISPER_DISABLED = "1";
  process.env.FEEDBACK_DISABLED = "0";
  process.env.FEEDBACK_DB_PATH = join(tmpDir, "feedback.db");
  process.env.FEEDBACK_HMAC_SECRET = "test-secret-at-least-16-chars-please";
  process.env.LOG_LEVEL = "warn";

  const mod = await import("../src/test-harness.js");
  app = await mod.buildAppForTests();
  await app.ready();
});

afterAll(async () => {
  await app?.close();
  if (tmpDir) rmSync(tmpDir, { recursive: true, force: true });
});

const SESSION_TOKEN = "session-aaaa1111-bbbb2222-cccc3333";

const validBody = {
  session_token: SESSION_TOKEN,
  app_version: "0.1.0",
  platform: "ios-17.4",
  model_size: "small",
  audio_duration_sec: 7.2,
  audio_codec: "opus",
  match: {
    ang: 462,
    pangti: 3,
    shabad_id: "ABC",
    score: 64.2,
    coverage: 0.78,
    line_type: "Pankti",
  },
  correction: {
    type: "wrong_pangti",
    ang: 462,
    pangti: 5,
  },
  mode: "voice_search",
  matcher_window_text_latin: "naanak gaaviyam gunee nidhaan",
};

describe("POST /feedback/correction", () => {
  it("rejects missing session_token", async () => {
    const res = await app.inject({
      method: "POST",
      url: "/feedback/correction",
      headers: { "content-type": "application/json" },
      payload: { ...validBody, session_token: "" },
    });
    expect(res.statusCode).toBe(401);
  });

  it("rejects invalid body shape", async () => {
    const res = await app.inject({
      method: "POST",
      url: "/feedback/correction",
      headers: { "content-type": "application/json" },
      payload: { session_token: SESSION_TOKEN, correction: { type: "not_a_real_type" } },
    });
    expect(res.statusCode).toBe(400);
    expect(JSON.parse(res.body).error).toBe("invalid_body");
  });

  it("accepts a well-formed correction with 202", async () => {
    const res = await app.inject({
      method: "POST",
      url: "/feedback/correction",
      headers: { "content-type": "application/json" },
      payload: validBody,
    });
    expect(res.statusCode).toBe(202);
    const body = JSON.parse(res.body);
    expect(body.status).toBe("accepted");
    expect(typeof body.id).toBe("string");
    expect(res.headers["cache-control"]).toBe("no-store");
  });

  it("audio_base64 is silently dropped (not persisted)", async () => {
    const withAudio = {
      ...validBody,
      audio_base64: Buffer.alloc(1024, "x").toString("base64"),
    };
    const res = await app.inject({
      method: "POST",
      url: "/feedback/correction",
      headers: { "content-type": "application/json" },
      payload: withAudio,
    });
    expect(res.statusCode).toBe(202);

    // List submissions — none should reference the audio.
    const list = await app.inject({
      method: "GET",
      url: `/feedback/submissions?session_token=${encodeURIComponent(SESSION_TOKEN)}`,
    });
    const submissions = JSON.parse(list.body).submissions;
    for (const row of submissions) {
      // The list endpoint doesn't return audio fields at all, but
      // sanity-check no raw audio leaked.
      expect(JSON.stringify(row)).not.toMatch(/[A-Za-z0-9+/]{200,}/);
    }
  });
});

describe("GET /feedback/submissions", () => {
  it("returns this session's rows", async () => {
    // We already inserted 2 above (validBody + withAudio).
    const res = await app.inject({
      method: "GET",
      url: `/feedback/submissions?session_token=${encodeURIComponent(SESSION_TOKEN)}`,
    });
    expect(res.statusCode).toBe(200);
    const body = JSON.parse(res.body);
    expect(Array.isArray(body.submissions)).toBe(true);
    expect(body.submissions.length).toBeGreaterThanOrEqual(2);
  });

  it("a different session sees nothing", async () => {
    const other = "session-different-aaaaaaaa-bbbbbbbb";
    const res = await app.inject({
      method: "GET",
      url: `/feedback/submissions?session_token=${encodeURIComponent(other)}`,
    });
    expect(res.statusCode).toBe(200);
    expect(JSON.parse(res.body).submissions).toEqual([]);
  });
});

describe("DELETE /feedback/submissions", () => {
  it("deletes all for the session", async () => {
    const res = await app.inject({
      method: "DELETE",
      url: `/feedback/submissions?session_token=${encodeURIComponent(SESSION_TOKEN)}`,
    });
    expect(res.statusCode).toBe(200);
    expect(JSON.parse(res.body).deleted).toBeGreaterThan(0);

    const list = await app.inject({
      method: "GET",
      url: `/feedback/submissions?session_token=${encodeURIComponent(SESSION_TOKEN)}`,
    });
    expect(JSON.parse(list.body).submissions).toEqual([]);
  });
});
