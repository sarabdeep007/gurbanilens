// GurbaniLens optional server — entry point.
//
// Privacy contract (enforced in code; see README for prose version):
//   - Audio bytes live in process memory or a per-request temp file
//     deleted in a finally{} block; never persisted long-term.
//   - Transcript text is returned in the response only, never logged.
//   - Request logs contain method/url/duration/status only — no headers,
//     no IPs, no bodies, no Authorization tokens.
//   - Session tokens are opaque, ephemeral, never persisted beyond the
//     in-memory rate-limit bucket.

import Fastify from "fastify";
import multipart from "@fastify/multipart";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { existsSync } from "node:fs";

import { requireBearer } from "./middleware/auth.js";
import { RateLimiter, makeRateLimitHook } from "./middleware/rate_limit.js";
import { registerTranscribeRoute, TRANSCRIBE_LIMITS } from "./routes/transcribe.js";

const __dirname = dirname(fileURLToPath(import.meta.url));
const REPO_SERVER = resolve(__dirname, "..");

const PORT = Number(process.env.PORT ?? 4040);
const HOST = process.env.HOST ?? "0.0.0.0";
const WHISPER_DISABLED = process.env.WHISPER_DISABLED === "1";
const WHISPER_MODEL = process.env.WHISPER_MODEL ?? "large-v3";
const WHISPER_PYTHON = process.env.WHISPER_PYTHON
  ?? join(REPO_SERVER, ".venv-asr", "bin", "python");
const WHISPER_WORKER = process.env.WHISPER_WORKER
  ?? join(REPO_SERVER, "src", "asr", "whisper_worker.py");

const app = Fastify({
  logger: {
    level: process.env.LOG_LEVEL ?? "info",
    serializers: {
      // Privacy: no headers, no IPs, no bodies. Only method+url+status+duration.
      req: (req) => ({ method: req.method, url: req.url }),
      res: (res) => ({ statusCode: res.statusCode }),
    },
  },
  trustProxy: false, // X-Forwarded-For is stripped at the reverse proxy
  disableRequestLogging: false,
  bodyLimit: 12 * 1024 * 1024, // 12 MB — slightly above /transcribe's 10 MB cap
});

// Global response headers — set on every response.
app.addHook("onSend", async (req, reply) => {
  reply.header("X-Robots-Tag", "noindex");
  reply.header("Cache-Control", "no-store");
});

await app.register(multipart, {
  limits: {
    fileSize: TRANSCRIBE_LIMITS.MAX_BYTES,
    files: 1,
    fields: 4,
  },
});

// Rate limiters — keyed by session token.
const transcribeLimiter = new RateLimiter({
  windowMs: 60 * 60 * 1000,
  maxInWindow: 60,
});
setInterval(() => transcribeLimiter.sweep(), 5 * 60 * 1000).unref();

// --- routes ---

app.get("/healthz", async () => ({
  status: "ok",
  whisper_disabled: WHISPER_DISABLED,
}));

app.get("/readyz", async (_req, reply) => {
  const checks = {
    python_exists: existsSync(WHISPER_PYTHON),
    worker_exists: existsSync(WHISPER_WORKER),
    whisper_disabled: WHISPER_DISABLED,
  };
  const ready = checks.python_exists && checks.worker_exists && !checks.whisper_disabled;
  if (!ready) reply.code(503);
  return { ready, checks };
});

if (!WHISPER_DISABLED) {
  registerTranscribeRoute(app, {
    pythonPath: WHISPER_PYTHON,
    workerPath: WHISPER_WORKER,
    model: WHISPER_MODEL,
    preHandlers: [
      requireBearer,
      makeRateLimitHook(transcribeLimiter, { label: "transcribe" }),
    ],
  });
} else {
  app.post("/transcribe", async (_req, reply) => {
    reply.code(503).send({ error: "not_implemented", reason: "whisper_disabled" });
  });
}

// Feedback routes (implemented in Task 3) — keep stub shape for now.
app.post("/feedback/correction", async (_req, reply) => {
  reply.code(501).send({ error: "not_implemented", reason: "pending_task_3" });
});

// --- boot ---

try {
  await app.listen({ port: PORT, host: HOST });
  app.log.info({
    port: PORT,
    host: HOST,
    whisperDisabled: WHISPER_DISABLED,
    whisperModel: WHISPER_DISABLED ? null : WHISPER_MODEL,
  }, "gurbanilens server listening");
} catch (err) {
  app.log.error(err);
  process.exit(1);
}

// Graceful shutdown so PM2 restarts don't leak temp files in flight.
for (const sig of ["SIGINT", "SIGTERM"]) {
  process.on(sig, () => {
    app.log.info({ sig }, "shutdown requested");
    app.close().then(() => process.exit(0));
  });
}
