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
import { privacyLoggerConfig, registerPrivacyHooks } from "./middleware/privacy.js";
import { registerTranscribeRoute, TRANSCRIBE_LIMITS } from "./routes/transcribe.js";
import { registerFeedbackRoutes } from "./routes/feedback.js";
import { openFeedbackStore } from "./db.js";

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
const FEEDBACK_DB_PATH = process.env.FEEDBACK_DB_PATH
  ?? join(REPO_SERVER, "data", "feedback.db");
const FEEDBACK_HMAC_SECRET = process.env.FEEDBACK_HMAC_SECRET
  ?? "dev-only-change-me-32-chars-or-more-please-do-not-use-in-prod";
const FEEDBACK_DISABLED = process.env.FEEDBACK_DISABLED === "1";

const app = Fastify({
  logger: privacyLoggerConfig({ level: process.env.LOG_LEVEL ?? "info" }),
  trustProxy: false, // X-Forwarded-For is stripped at the reverse proxy
  disableRequestLogging: false,
  bodyLimit: 12 * 1024 * 1024, // 12 MB — slightly above /transcribe's 10 MB cap
});

registerPrivacyHooks(app);

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
const feedbackLimiter = new RateLimiter({
  windowMs: 60 * 60 * 1000,
  maxInWindow: 20,
});
setInterval(() => {
  transcribeLimiter.sweep();
  feedbackLimiter.sweep();
}, 5 * 60 * 1000).unref();

const feedbackStore = FEEDBACK_DISABLED
  ? null
  : await openFeedbackStore({ path: FEEDBACK_DB_PATH, hmacSecret: FEEDBACK_HMAC_SECRET });

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

if (feedbackStore) {
  registerFeedbackRoutes(app, {
    store: feedbackStore,
    limiter: feedbackLimiter,
  });
} else {
  app.post("/feedback/correction", async (_req, reply) => {
    reply.code(503).send({ error: "not_implemented", reason: "feedback_disabled" });
  });
}

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
    app.close().then(() => {
      if (feedbackStore) feedbackStore.close();
      process.exit(0);
    });
  });
}
