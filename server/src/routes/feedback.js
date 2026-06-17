// /feedback/* — opt-in correction queue endpoints.
//
// Spec: docs/feedback_channel_spec.md is the authoritative wire format.
// Body shape uses snake_case on the wire (matches the spec literally);
// we normalise to camelCase before calling the store.
//
// Auth model:
//   - POST /feedback/correction takes the session_token in the BODY
//     (per spec — explicitly no Authorization header for the wire).
//   - GET / DELETE /feedback/submissions take it as ?session_token=...
//   - Rate limit (20/hr) is keyed off the same token.
//
// Privacy:
//   - The DB layer HMACs the token before persistence; raw value never
//     hits disk.
//   - audio_base64 is accepted but DROPPED in v1. The spec already says
//     "Phase 2A polish; currently stubbed to accept-but-not-persist".

import { z } from "zod";

// --- input schema (matches docs/feedback_channel_spec.md "Wire format") ---

const matchSchema = z.object({
  ang: z.number().int().nonnegative().nullish(),
  pangti: z.number().int().nonnegative().nullish(),
  shabad_id: z.string().max(64).nullish(),
  score: z.number().nullish(),
  coverage: z.number().nullish(),
  line_type: z.string().max(32).nullish(),
}).passthrough();

const correctionSchema = z.object({
  type: z.enum(["wrong_pangti", "wrong_shabad", "not_gurbani", "unknown", "partial_match"]),
  ang: z.number().int().nonnegative().nullish(),
  pangti: z.number().int().nonnegative().nullish(),
  notes: z.string().max(2000).nullish(),
}).passthrough();

const correctionBodySchema = z.object({
  session_token:           z.string().min(8).max(256),
  app_version:             z.string().max(64).nullish(),
  platform:                z.string().max(64).nullish(),
  model_size:              z.string().max(32).nullish(),
  device_class:            z.string().max(32).nullish(),

  audio_base64:            z.string().max(2_000_000).nullish(),     // ~1.5MB opus max; dropped in v1
  audio_duration_sec:      z.number().min(0).max(60).nullish(),
  audio_codec:             z.string().max(32).nullish(),

  match:                   matchSchema.nullish(),
  correction:              correctionSchema,
  mode:                    z.string().max(32).nullish(),
  matcher_window_text_latin: z.string().max(4000).nullish(),
}).passthrough();

// snake_case → camelCase, dropping audio_base64 entirely
function toStoreShape(body) {
  return {
    appVersion:               body.app_version ?? null,
    platform:                 body.platform ?? null,
    modelSize:                body.model_size ?? null,
    deviceClass:              body.device_class ?? null,
    audioDurationSec:         body.audio_duration_sec ?? null,
    audioCodec:               body.audio_codec ?? null,
    match: body.match ? {
      ang:        body.match.ang ?? null,
      pangti:     body.match.pangti ?? null,
      shabadId:   body.match.shabad_id ?? null,
      score:      body.match.score ?? null,
      coverage:   body.match.coverage ?? null,
      lineType:   body.match.line_type ?? null,
    } : null,
    correction: {
      type:       body.correction.type,
      ang:        body.correction.ang ?? null,
      pangti:     body.correction.pangti ?? null,
      notes:      body.correction.notes ?? null,
    },
    mode:                     body.mode ?? null,
    matcherWindowTextLatin:   body.matcher_window_text_latin ?? null,
  };
}

function extractSessionToken(req, source = "body") {
  if (source === "body") {
    const t = req.body?.session_token;
    return typeof t === "string" ? t : null;
  }
  if (source === "query") {
    const t = req.query?.session_token;
    return typeof t === "string" ? t : null;
  }
  return null;
}

/**
 * Wire up the feedback routes onto Fastify.
 *
 * @param {import("fastify").FastifyInstance} app
 * @param {object} deps
 * @param {import("../db.js").FeedbackStore} deps.store
 * @param {import("../middleware/rate_limit.js").RateLimiter} deps.limiter
 */
export function registerFeedbackRoutes(app, { store, limiter }) {
  /**
   * Internal preHandler: parse the body once, attach the session token
   * to req.sessionToken, and consume from the rate limiter.
   */
  function feedbackAuthAndLimit(source) {
    return async (req, reply) => {
      const token = extractSessionToken(req, source);
      if (!token || token.length < 8) {
        reply.code(401).send({ error: "missing_or_malformed_session_token" });
        return;
      }
      req.sessionToken = token;

      const res = limiter.consume(token);
      reply.header("X-RateLimit-Limit", String(limiter.max));
      reply.header("X-RateLimit-Remaining", String(res.remaining));
      reply.header("X-RateLimit-Reset", String(Math.ceil(res.resetMs / 1000)));
      if (!res.allowed) {
        reply.code(429).send({
          error: "rate_limited",
          scope: "feedback",
          retry_after_seconds: Math.ceil(res.resetMs / 1000),
        });
        return;
      }
    };
  }

  app.post("/feedback/correction", {
    preHandler: feedbackAuthAndLimit("body"),
  }, async (req, reply) => {
    const parsed = correctionBodySchema.safeParse(req.body);
    if (!parsed.success) {
      reply.code(400);
      return {
        error: "invalid_body",
        issues: parsed.error.issues.map((i) => ({
          path: i.path.join("."), code: i.code, message: i.message,
        })),
      };
    }
    const shape = toStoreShape(parsed.data);
    const { id } = store.insert(shape, req.sessionToken);
    reply.code(202);
    return { id, status: "accepted" };
  });

  app.get("/feedback/submissions", {
    preHandler: feedbackAuthAndLimit("query"),
  }, async (req, reply) => {
    const rows = store.listForSession(req.sessionToken);
    return { submissions: rows };
  });

  app.delete("/feedback/submissions", {
    preHandler: feedbackAuthAndLimit("query"),
  }, async (req, reply) => {
    const { id } = req.query ?? {};
    if (typeof id === "string" && id) {
      return store.deleteOne(id, req.sessionToken);
    }
    return store.deleteAllForSession(req.sessionToken);
  });
}
