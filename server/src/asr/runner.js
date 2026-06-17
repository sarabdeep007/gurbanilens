// ASR runner — spawns the Python faster-whisper worker for a single file
// and resolves with the parsed JSON result. No transcript content is
// logged; only the worker's stdout JSON is parsed and forwarded.

import { spawn } from "node:child_process";

const DEFAULT_TIMEOUT_MS = 120_000; // 2 min cap per transcribe call

export class TranscribeError extends Error {
  constructor(message, { kind, exitCode, stderr } = {}) {
    super(message);
    this.name = "TranscribeError";
    this.kind = kind ?? "transcribe_failed";
    this.exitCode = exitCode;
    this.stderr = stderr;
  }
}

/**
 * Run the Python whisper worker on a single audio file.
 *
 * @param {object} opts
 * @param {string} opts.pythonPath - absolute path to the venv's python3
 * @param {string} opts.workerPath - absolute path to whisper_worker.py
 * @param {string} opts.audioPath  - absolute path to audio file
 * @param {string} opts.model      - whisper model name (e.g. 'large-v3')
 * @param {string|null} [opts.language] - ISO code; null/undefined for auto-detect
 * @param {number} [opts.timeoutMs] - hard timeout in ms
 * @returns {Promise<{transcript:string, language:string, duration:number, model:string}>}
 */
export function runWhisperWorker({
  pythonPath,
  workerPath,
  audioPath,
  model,
  language = null,
  timeoutMs = DEFAULT_TIMEOUT_MS,
}) {
  return new Promise((resolve, reject) => {
    const args = [workerPath, audioPath, "--model", model];
    if (language) args.push("--language", language);

    const child = spawn(pythonPath, args, {
      stdio: ["ignore", "pipe", "pipe"],
      // Detached false; we want the child to die with us on signal.
    });

    let stdout = "";
    let stderr = "";
    let timedOut = false;

    const timer = setTimeout(() => {
      timedOut = true;
      child.kill("SIGKILL");
    }, timeoutMs);

    child.stdout.on("data", (b) => { stdout += b.toString("utf8"); });
    child.stderr.on("data", (b) => { stderr += b.toString("utf8"); });

    child.on("error", (err) => {
      clearTimeout(timer);
      reject(new TranscribeError("spawn_failed: " + err.message, { kind: "spawn_failed" }));
    });

    child.on("close", (code) => {
      clearTimeout(timer);
      if (timedOut) {
        return reject(new TranscribeError("transcribe_timed_out",
          { kind: "timeout", exitCode: code }));
      }
      let payload;
      try {
        payload = JSON.parse(stdout.trim());
      } catch {
        return reject(new TranscribeError("non_json_worker_output",
          { kind: "parse_failed", exitCode: code, stderr }));
      }
      if (payload.error) {
        return reject(new TranscribeError(payload.error,
          { kind: payload.error, exitCode: code, stderr }));
      }
      if (code !== 0) {
        return reject(new TranscribeError("worker_exit_nonzero",
          { kind: "worker_exit", exitCode: code, stderr }));
      }
      resolve(payload);
    });
  });
}
