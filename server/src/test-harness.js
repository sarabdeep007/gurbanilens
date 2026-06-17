// Test harness that builds the same Fastify app as src/index.js but
// without binding a port. Used by Vitest. Kept tiny so the production
// entry point stays the source of truth; the harness only refactors
// `app.listen()` out.
//
// Reads the same env vars as src/index.js so each test can override.

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

export async function buildAppForTests() {
  const WHISPER_DISABLED = process.env.WHISPER_DISABLED === "1";
  const WHISPER_MODEL = process.env.WHISPER_MODEL ?? "tiny";
  const WHISPER_PYTHON = process.env.WHISPER_PYTHON
    ?? join(REPO_SERVER, ".venv-asr", "bin", "python");
  const WHISPER_WORKER = process.env.WHISPER_WORKER
    ?? join(REPO_SERVER, "src", "asr", "whisper_worker.py");
  const FEEDBACK_DB_PATH = process.env.FEEDBACK_DB_PATH
    ?? join(REPO_SERVER, "data", "feedback.db");
  const FEEDBACK_HMAC_SECRET = process.env.FEEDBACK_HMAC_SECRET
    ?? "test-secret-at-least-16-chars-please";
  const FEEDBACK_DISABLED = process.env.FEEDBACK_DISABLED === "1";

  const app = Fastify({
    logger: privacyLoggerConfig({ level: process.env.LOG_LEVEL ?? "info" }),
    trustProxy: false,
    bodyLimit: 12 * 1024 * 1024,
  });

  registerPrivacyHooks(app);

  await app.register(multipart, {
    limits: { fileSize: TRANSCRIBE_LIMITS.MAX_BYTES, files: 1, fields: 4 },
  });

  const transcribeLimiter = new RateLimiter({ windowMs: 60 * 60 * 1000, maxInWindow: 60 });
  const feedbackLimiter   = new RateLimiter({ windowMs: 60 * 60 * 1000, maxInWindow: 20 });

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
  }

  if (!FEEDBACK_DISABLED) {
    const store = await openFeedbackStore({
      path: FEEDBACK_DB_PATH,
      hmacSecret: FEEDBACK_HMAC_SECRET,
    });
    registerFeedbackRoutes(app, { store, limiter: feedbackLimiter });
    app.addHook("onClose", async () => store.close());
  }

  return app;
}
