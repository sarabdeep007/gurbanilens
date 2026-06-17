// POST /transcribe — multipart audio in, JSON transcript out.
//
// Privacy:
//   - Audio bytes are written to a private per-process temp file. The
//     handler deletes the file in a finally{} block, so cancellation,
//     errors, and success all clean up.
//   - Transcript text is returned in the response body but never logged.
//   - Headers (Authorization in particular) are stripped by the privacy
//     middleware before any log line is emitted.
//
// Limits:
//   - file size  ≤ 10 MB (enforced by @fastify/multipart `limits.fileSize`)
//   - duration   ≤ 60 s  (enforced post-upload via ffprobe)
//   - rate-limit 60/hr/session (enforced by middleware before this handler)

import { randomBytes } from "node:crypto";
import { mkdir, rm, writeFile, stat } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, extname } from "node:path";
import { spawn } from "node:child_process";

import { runWhisperWorker, TranscribeError } from "../asr/runner.js";

const MAX_BYTES = 10 * 1024 * 1024;
const MAX_DURATION_SEC = 60;
const ALLOWED_EXTS = new Set([".wav", ".mp3", ".m4a", ".flac", ".ogg"]);
const ALLOWED_MIME_PREFIXES = ["audio/"];

/**
 * Probe duration with ffprobe. Returns seconds or throws.
 */
function probeDuration(audioPath) {
  return new Promise((resolve, reject) => {
    const child = spawn("ffprobe", [
      "-v", "error",
      "-show_entries", "format=duration",
      "-of", "default=noprint_wrappers=1:nokey=1",
      audioPath,
    ], { stdio: ["ignore", "pipe", "pipe"] });
    let out = "";
    let err = "";
    child.stdout.on("data", (b) => { out += b.toString(); });
    child.stderr.on("data", (b) => { err += b.toString(); });
    child.on("error", (e) => reject(new Error("ffprobe_spawn_failed: " + e.message)));
    child.on("close", (code) => {
      if (code !== 0) return reject(new Error("ffprobe_exit_" + code + ": " + err.trim()));
      const sec = Number.parseFloat(out.trim());
      if (!Number.isFinite(sec)) return reject(new Error("ffprobe_non_numeric_duration"));
      resolve(sec);
    });
  });
}

function safeExt(filename, mimetype) {
  if (typeof filename === "string") {
    const ext = extname(filename).toLowerCase();
    if (ALLOWED_EXTS.has(ext)) return ext;
  }
  if (typeof mimetype === "string") {
    if (mimetype.startsWith("audio/")) {
      // Best-effort: map mimetype to extension; fall back to .bin.
      const map = {
        "audio/wav": ".wav", "audio/x-wav": ".wav", "audio/wave": ".wav",
        "audio/mpeg": ".mp3", "audio/mp3": ".mp3",
        "audio/mp4": ".m4a", "audio/x-m4a": ".m4a",
        "audio/flac": ".flac", "audio/x-flac": ".flac",
        "audio/ogg": ".ogg",
      };
      return map[mimetype] || ".bin";
    }
  }
  return ".bin";
}

/**
 * Register POST /transcribe on the Fastify app.
 */
export function registerTranscribeRoute(app, {
  pythonPath,
  workerPath,
  model,
  preHandlers = [],
}) {
  app.post("/transcribe", {
    preHandler: preHandlers,
  }, async (req, reply) => {
    let parts;
    try {
      parts = await req.file({ limits: { fileSize: MAX_BYTES, files: 1 } });
    } catch (e) {
      return reply.code(400).send({ error: "multipart_parse_failed" });
    }
    if (!parts) return reply.code(400).send({ error: "missing_audio_file" });

    // mimetype/filename are attacker-controlled — we use them only for
    // hint-level extension selection, then validate with ffprobe.
    const mime = parts.mimetype || "";
    const filenameExt = typeof parts.filename === "string"
      ? extname(parts.filename).toLowerCase()
      : "";
    const mimeLooksAudio = ALLOWED_MIME_PREFIXES.some((p) => mime.startsWith(p));
    const extLooksAudio = ALLOWED_EXTS.has(filenameExt);
    if (!mimeLooksAudio && !extLooksAudio) {
      return reply.code(415).send({
        error: "unsupported_media_type",
        mimetype: mime,
        filename_ext: filenameExt,
      });
    }

    const ext = safeExt(parts.filename, mime);
    const tmpDir = join(tmpdir(), "gurbanilens-asr");
    await mkdir(tmpDir, { recursive: true });
    const tmpPath = join(tmpDir, randomBytes(16).toString("hex") + ext);

    let bytesWritten = 0;
    try {
      // Drain stream into memory buffer, then writeFile atomically.
      // @fastify/multipart enforces the byte cap via limits.fileSize and
      // sets parts.file.truncated when it trips.
      const chunks = [];
      for await (const chunk of parts.file) {
        bytesWritten += chunk.length;
        chunks.push(chunk);
      }
      if (parts.file.truncated || bytesWritten > MAX_BYTES) {
        return reply.code(413).send({ error: "file_too_large", max_bytes: MAX_BYTES });
      }
      if (bytesWritten === 0) {
        return reply.code(400).send({ error: "empty_audio_file" });
      }
      await writeFile(tmpPath, Buffer.concat(chunks));

      // Duration check via ffprobe.
      let duration;
      try {
        duration = await probeDuration(tmpPath);
      } catch (e) {
        return reply.code(400).send({ error: "unreadable_audio" });
      }
      if (duration > MAX_DURATION_SEC) {
        return reply.code(413).send({
          error: "audio_too_long",
          duration_seconds: duration,
          max_duration_seconds: MAX_DURATION_SEC,
        });
      }

      // Run faster-whisper. The worker prints one JSON object.
      let result;
      try {
        result = await runWhisperWorker({
          pythonPath,
          workerPath,
          audioPath: tmpPath,
          model,
          language: null, // auto-detect; client can pass `?language=pa` later
        });
      } catch (e) {
        const ex = /** @type {TranscribeError} */ (e);
        const status = ex.kind === "timeout" ? 504 : 500;
        return reply.code(status).send({ error: "transcribe_failed", kind: ex.kind });
      }

      return reply.send({
        transcript: result.transcript,
        language: result.language,
        duration: result.duration,
        model: result.model,
      });
    } finally {
      // Always delete the temp file, including on cancellation.
      await rm(tmpPath, { force: true }).catch(() => {});
    }
  });
}

export const TRANSCRIBE_LIMITS = {
  MAX_BYTES,
  MAX_DURATION_SEC,
};
