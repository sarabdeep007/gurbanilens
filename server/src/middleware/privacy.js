// Privacy middleware — bakes the README's privacy contract into code.
//
// Read this file when reviewing the project's privacy stance. Every
// commitment below corresponds to a line of code, not just prose.
//
// Commitments enforced here:
//   1. No IP addresses in logs. trustProxy=false at the framework level;
//      logger serializers exclude `remoteAddress` / `headers`.
//   2. No Authorization / X-Forwarded-For / X-Real-IP / Cookie headers
//      in logs. Logger serializers explicitly project method+url only.
//   3. No request body in logs. Body serializer is set to undefined.
//   4. No transcript text in logs. /transcribe replies with body and
//      logs nothing about the response payload.
//   5. Search-engine indexing disabled. X-Robots-Tag: noindex on every
//      response.
//   6. Cache disabled. Cache-Control: no-store on every response —
//      transcripts and corrections must never be cached by intermediaries.
//
// Layering: the Fastify `logger.serializers` option (set in index.js
// from `privacyLoggerConfig()`) is the *primary* guard. The `onSend`
// hook adds response headers. These are intentionally redundant — one
// reviewer-readable module that fully describes the privacy surface.

/** Drop everything from the first `?` onward. */
function stripQuery(url) {
  if (typeof url !== "string") return "";
  const q = url.indexOf("?");
  return q === -1 ? url : url.slice(0, q);
}

/**
 * Returns Fastify logger config that scrubs req/res down to the bare
 * minimum needed for operational logs (method, path, status, duration).
 * Plug into `Fastify({ logger: privacyLoggerConfig({...}) })`.
 */
export function privacyLoggerConfig({ level = "info" } = {}) {
  return {
    level,
    serializers: {
      // Explicit projection: only method + path (query stripped). Any
      // header, IP, cookie, or body field is dropped. Adding a new
      // field here requires explicit code review (treat as a
      // privacy-policy change).
      //
      // Query string is stripped because session_token is passed as a
      // query parameter for GET/DELETE /feedback/submissions — logging
      // the raw URL would leak the token to PM2 logs.
      req(req) {
        return { method: req.method, path: stripQuery(req.url) };
      },
      res(res) {
        return { statusCode: res.statusCode };
      },
      err(err) {
        // Errors get name+code+message — never the stack-embedded
        // arguments (they could carry user input).
        return {
          type: err.name,
          code: err.code,
          message: err.message,
        };
      },
    },
  };
}

/**
 * Register the response-header part of the contract. Sets
 *   X-Robots-Tag: noindex
 *   Cache-Control: no-store
 * on every reply. Optional: also wipe any Server header.
 */
export function registerPrivacyHooks(app) {
  app.addHook("onSend", async (_req, reply, payload) => {
    reply.header("X-Robots-Tag", "noindex");
    reply.header("Cache-Control", "no-store");
    // Drop fastify's default "x-powered-by" / Server fingerprinting.
    reply.removeHeader("Server");
    reply.removeHeader("X-Powered-By");
    return payload;
  });

  // Headers we *receive* — defence in depth: if the reverse proxy
  // didn't strip these, we still don't see them in any code path that
  // reads from req.headers via this allow-list. Express-style "always
  // delete forwarded headers off the request object" is a footgun in
  // Fastify (it doesn't have removeReqHeader); the actual guarantee
  // is that NOTHING in our code reads X-Forwarded-For or X-Real-IP.
  // Grep this directory to verify; CI test in test/privacy.test.js
  // pins the grep.
}

/**
 * List of request header names that this server NEVER reads. Used by
 * the privacy lint test to assert via grep that no source file
 * references them.
 */
export const FORBIDDEN_REQUEST_HEADER_READS = Object.freeze([
  "x-forwarded-for",
  "x-real-ip",
  "x-forwarded-host",
  "x-forwarded-proto",
  "forwarded",
  "cookie",
  "set-cookie",
]);
