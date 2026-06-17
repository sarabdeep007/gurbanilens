// In-memory sliding-window rate limiter keyed by an arbitrary string
// (we use the session token). Simple and dependency-free; good enough
// for v1. A Redis-backed limiter can swap in later behind the same
// `RateLimiter.consume()` shape.

export class RateLimiter {
  /**
   * @param {object} opts
   * @param {number} opts.windowMs   - window length in ms (e.g. 3_600_000 for 1h)
   * @param {number} opts.maxInWindow - max requests per key per window
   */
  constructor({ windowMs, maxInWindow }) {
    this.windowMs = windowMs;
    this.max = maxInWindow;
    /** @type {Map<string, number[]>} */
    this.hits = new Map();
  }

  /**
   * Record an attempt and return { allowed, remaining, resetMs }.
   * `resetMs` is ms until the oldest hit in the window expires.
   */
  consume(key) {
    const now = Date.now();
    const cutoff = now - this.windowMs;
    let arr = this.hits.get(key);
    if (!arr) {
      arr = [];
      this.hits.set(key, arr);
    }
    // Drop expired hits.
    while (arr.length && arr[0] < cutoff) arr.shift();

    if (arr.length >= this.max) {
      const resetMs = arr[0] + this.windowMs - now;
      return { allowed: false, remaining: 0, resetMs: Math.max(0, resetMs) };
    }
    arr.push(now);
    return { allowed: true, remaining: this.max - arr.length, resetMs: this.windowMs };
  }

  /** Periodic cleanup so untouched keys don't accumulate. */
  sweep() {
    const cutoff = Date.now() - this.windowMs;
    for (const [k, arr] of this.hits) {
      while (arr.length && arr[0] < cutoff) arr.shift();
      if (arr.length === 0) this.hits.delete(k);
    }
  }
}

/**
 * Fastify preHandler factory. Returns a handler that consumes one hit
 * from the given limiter using req.sessionToken as the key, and 429s
 * if the limit is exceeded.
 */
export function makeRateLimitHook(limiter, { label }) {
  return function rateLimitHook(req, reply, done) {
    const key = req.sessionToken;
    if (!key) {
      // Should never happen — requireBearer runs before this.
      reply.code(401).send({ error: "missing_session_token" });
      return;
    }
    const res = limiter.consume(key);
    reply.header("X-RateLimit-Limit", String(limiter.max));
    reply.header("X-RateLimit-Remaining", String(res.remaining));
    reply.header("X-RateLimit-Reset", String(Math.ceil(res.resetMs / 1000)));
    if (!res.allowed) {
      reply.code(429).send({
        error: "rate_limited",
        scope: label,
        retry_after_seconds: Math.ceil(res.resetMs / 1000),
      });
      return;
    }
    done();
  };
}
