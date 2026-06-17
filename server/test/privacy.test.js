// Privacy contract tests. These pin the things that, if they ever
// regress, break the promises the README makes.
//
// Two kinds of assertions:
//   1. Live request behaviour — log lines stay scrubbed, response
//      headers are set.
//   2. Source-grep — no source file outside privacy.js itself reads
//      headers we promise not to read.

import { describe, it, expect, beforeAll, afterAll } from "vitest";
import { readdirSync, readFileSync, statSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

import { FORBIDDEN_REQUEST_HEADER_READS } from "../src/middleware/privacy.js";

const HERE = dirname(fileURLToPath(import.meta.url));
const SRC_ROOT = join(HERE, "..", "src");

let app;
let captured = [];

beforeAll(async () => {
  process.env.PORT = "0";
  process.env.HOST = "127.0.0.1";
  process.env.WHISPER_DISABLED = "1";
  process.env.FEEDBACK_DISABLED = "1";
  process.env.LOG_LEVEL = "info";

  // Capture stdout so we can assert log lines don't leak.
  const origWrite = process.stdout.write.bind(process.stdout);
  captured = [];
  process.stdout.write = (chunk, ...rest) => {
    try { captured.push(chunk.toString()); } catch { /* binary chunks */ }
    return origWrite(chunk, ...rest);
  };

  const mod = await import("../src/test-harness.js");
  app = await mod.buildAppForTests();
  await app.ready();
});

afterAll(async () => {
  await app?.close();
});

describe("response headers — privacy hook", () => {
  it("sets X-Robots-Tag and Cache-Control on every response", async () => {
    const res = await app.inject({ method: "GET", url: "/healthz" });
    expect(res.headers["x-robots-tag"]).toBe("noindex");
    expect(res.headers["cache-control"]).toBe("no-store");
  });

  it("does not leak x-powered-by", async () => {
    const res = await app.inject({ method: "GET", url: "/healthz" });
    expect(res.headers["x-powered-by"]).toBeUndefined();
  });
});

describe("log scrubbing", () => {
  it("logs no Authorization header even when one is supplied", async () => {
    captured.length = 0;
    await app.inject({
      method: "GET",
      url: "/healthz",
      headers: { authorization: "Bearer SECRET-TOKEN-AAAA1111-BBBB2222" },
    });
    const all = captured.join("");
    expect(all).not.toMatch(/SECRET-TOKEN/);
    expect(all).not.toMatch(/authorization/i);
  });

  it("logs no X-Forwarded-For value", async () => {
    captured.length = 0;
    await app.inject({
      method: "GET",
      url: "/healthz",
      headers: {
        "x-forwarded-for": "203.0.113.42",
        "x-real-ip": "203.0.113.42",
      },
    });
    const all = captured.join("");
    expect(all).not.toMatch(/203\.0\.113\.42/);
    expect(all).not.toMatch(/x-forwarded-for/i);
    expect(all).not.toMatch(/x-real-ip/i);
  });

  it("logs no request body content", async () => {
    captured.length = 0;
    await app.inject({
      method: "POST",
      url: "/feedback/correction",
      headers: { "content-type": "application/json" },
      payload: { magic_marker: "SHOULD-NEVER-APPEAR-IN-LOGS-12345" },
    });
    const all = captured.join("");
    expect(all).not.toMatch(/SHOULD-NEVER-APPEAR-IN-LOGS/);
  });
});

describe("source grep — forbidden header reads", () => {
  function* walk(dir) {
    for (const entry of readdirSync(dir)) {
      const p = join(dir, entry);
      const s = statSync(p);
      if (s.isDirectory()) yield* walk(p);
      else if (entry.endsWith(".js")) yield p;
    }
  }

  it("no source file reads forbidden headers (except privacy.js itself)", () => {
    const offenders = [];
    for (const file of walk(SRC_ROOT)) {
      if (file.endsWith("middleware/privacy.js")) continue;
      const text = readFileSync(file, "utf8");
      for (const hdr of FORBIDDEN_REQUEST_HEADER_READS) {
        // Look for the header name appearing as a string literal that
        // could be used in req.headers[...] or headers.get(...).
        const re = new RegExp(`["'\`]${hdr.replace(/[-/\\^$*+?.()|[\]{}]/g, "\\$&")}["'\`]`, "i");
        if (re.test(text)) {
          offenders.push({ file: file.replace(SRC_ROOT, "<src>"), header: hdr });
        }
      }
    }
    expect(offenders).toEqual([]);
  });
});
