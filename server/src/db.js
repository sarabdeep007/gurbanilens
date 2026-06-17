// SQLite-backed feedback queue, using sql.js (pure-JS WASM SQLite).
//
// Why sql.js instead of better-sqlite3:
//   - Pure JS / WASM → no native compile, no glibc binding, no
//     build-essential in the Dockerfile.
//   - Throughput is more than enough for our load (20 inserts/hr/session,
//     ≤ a few hundred sessions/day at v1 scale).
//   - Trade-off: the DB lives in memory; we persist by writing the full
//     file after each mutation. With kilobytes of data per row and an
//     append-only workload this is cheap. For >10 MB we'd revisit.
//
// Privacy rules baked into the schema:
//   - No IP column.
//   - No raw session_token column. We persist HMAC(token, SERVER_SECRET).
//   - audio_base64 is NEVER persisted in v1 — the column `audio_blob_path`
//     stays NULL. Persisting raw audio is a future Phase 3 decision that
//     would require a code change + fresh privacy review.
//
// Concurrency: Node is single-threaded for the inserts here. We never
// have two writers racing in this process. If we ever scale to N
// workers, swap to a real SQLite (sqlite3 / libsql / Postgres).

import initSqlJs from "sql.js";
import { createHmac, randomUUID } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, writeFileSync, renameSync } from "node:fs";
import { dirname } from "node:path";

const SCHEMA_VERSION = 1;

const SCHEMA = `
CREATE TABLE IF NOT EXISTS schema_version (
  version INTEGER PRIMARY KEY
);

CREATE TABLE IF NOT EXISTS feedback (
  id                          TEXT PRIMARY KEY,
  received_at_ms              INTEGER NOT NULL,

  app_version                 TEXT,
  platform                    TEXT,
  model_size                  TEXT,
  device_class                TEXT,

  audio_blob_path             TEXT,
  audio_duration_sec          REAL,
  audio_codec                 TEXT,

  matched_ang                 INTEGER,
  matched_pangti              INTEGER,
  matched_shabad_id           TEXT,
  matched_score               REAL,
  matched_coverage            REAL,
  matched_line_type           TEXT,
  matcher_window_text_latin   TEXT,

  correction_type             TEXT NOT NULL,
  corrected_ang               INTEGER,
  corrected_pangti            INTEGER,
  correction_notes            TEXT,

  mode                        TEXT,

  session_token_hmac          TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_feedback_session_hmac
  ON feedback(session_token_hmac);
CREATE INDEX IF NOT EXISTS idx_feedback_received_at
  ON feedback(received_at_ms);
`;

let SQL = null;

async function loadSqlJs() {
  if (SQL) return SQL;
  SQL = await initSqlJs();
  return SQL;
}

/**
 * Open the SQLite DB at `path`, run schema migrations idempotently,
 * and return a FeedbackStore. Async because sql.js needs WASM init.
 */
export async function openFeedbackStore({ path, hmacSecret }) {
  if (!hmacSecret || hmacSecret.length < 16) {
    throw new Error("FEEDBACK_HMAC_SECRET must be set and ≥ 16 chars");
  }
  mkdirSync(dirname(path), { recursive: true });
  const sql = await loadSqlJs();

  let db;
  if (existsSync(path)) {
    db = new sql.Database(readFileSync(path));
  } else {
    db = new sql.Database();
  }
  // Synchronous (single-threaded) SQLite — no need for WAL/journal.
  db.run(SCHEMA);
  db.run("INSERT OR IGNORE INTO schema_version (version) VALUES (?)", [SCHEMA_VERSION]);

  const store = new FeedbackStore(db, hmacSecret, path);
  store.flush(); // ensure file exists at the documented path
  return store;
}

export class FeedbackStore {
  constructor(db, hmacSecret, path) {
    this.db = db;
    this.hmacSecret = hmacSecret;
    this.path = path;
  }

  /** Persist current in-memory DB to disk atomically. */
  flush() {
    const buf = Buffer.from(this.db.export());
    const tmp = this.path + ".tmp";
    writeFileSync(tmp, buf);
    renameSync(tmp, this.path);
  }

  hmacToken(rawToken) {
    return createHmac("sha256", this.hmacSecret)
      .update(rawToken, "utf8")
      .digest("hex");
  }

  /**
   * Insert a feedback row. Returns { id }.
   * `parsed` is the validated, camelCased input (see routes/feedback.js).
   * `sessionToken` is the raw bearer/body token; HMAC'd here, never persisted raw.
   */
  insert(parsed, sessionToken) {
    const id = randomUUID();
    const params = {
      ":id":                            id,
      ":received_at_ms":                Date.now(),
      ":app_version":                   parsed.appVersion ?? null,
      ":platform":                      parsed.platform ?? null,
      ":model_size":                    parsed.modelSize ?? null,
      ":device_class":                  parsed.deviceClass ?? null,
      ":audio_blob_path":               null, // v1 never persists audio bytes
      ":audio_duration_sec":            parsed.audioDurationSec ?? null,
      ":audio_codec":                   parsed.audioCodec ?? null,
      ":matched_ang":                   parsed.match?.ang ?? null,
      ":matched_pangti":                parsed.match?.pangti ?? null,
      ":matched_shabad_id":             parsed.match?.shabadId ?? null,
      ":matched_score":                 parsed.match?.score ?? null,
      ":matched_coverage":              parsed.match?.coverage ?? null,
      ":matched_line_type":             parsed.match?.lineType ?? null,
      ":matcher_window_text_latin":     parsed.matcherWindowTextLatin ?? null,
      ":correction_type":               parsed.correction.type,
      ":corrected_ang":                 parsed.correction.ang ?? null,
      ":corrected_pangti":              parsed.correction.pangti ?? null,
      ":correction_notes":              parsed.correction.notes ?? null,
      ":mode":                          parsed.mode ?? null,
      ":session_token_hmac":            this.hmacToken(sessionToken),
    };
    this.db.run(`
      INSERT INTO feedback (
        id, received_at_ms,
        app_version, platform, model_size, device_class,
        audio_blob_path, audio_duration_sec, audio_codec,
        matched_ang, matched_pangti, matched_shabad_id,
        matched_score, matched_coverage, matched_line_type,
        matcher_window_text_latin,
        correction_type, corrected_ang, corrected_pangti, correction_notes,
        mode,
        session_token_hmac
      ) VALUES (
        :id, :received_at_ms,
        :app_version, :platform, :model_size, :device_class,
        :audio_blob_path, :audio_duration_sec, :audio_codec,
        :matched_ang, :matched_pangti, :matched_shabad_id,
        :matched_score, :matched_coverage, :matched_line_type,
        :matcher_window_text_latin,
        :correction_type, :corrected_ang, :corrected_pangti, :correction_notes,
        :mode,
        :session_token_hmac
      )
    `, params);
    this.flush();
    return { id };
  }

  /** Materialise sql.js result rows into plain JS objects. */
  _rowsFrom(execResult) {
    if (!execResult || execResult.length === 0) return [];
    const { columns, values } = execResult[0];
    return values.map((row) => {
      const obj = {};
      for (let i = 0; i < columns.length; i++) obj[columns[i]] = row[i];
      return obj;
    });
  }

  listForSession(rawSessionToken) {
    const hmac = this.hmacToken(rawSessionToken);
    const res = this.db.exec(`
      SELECT id, received_at_ms, matched_ang, matched_pangti,
             corrected_ang, corrected_pangti, correction_type, mode
        FROM feedback
       WHERE session_token_hmac = $hmac
       ORDER BY received_at_ms DESC
       LIMIT 500
    `, { $hmac: hmac });
    return this._rowsFrom(res);
  }

  deleteAllForSession(rawSessionToken) {
    const hmac = this.hmacToken(rawSessionToken);
    this.db.run("DELETE FROM feedback WHERE session_token_hmac = $hmac", { $hmac: hmac });
    const deleted = this.db.getRowsModified();
    this.flush();
    return { deleted };
  }

  deleteOne(id, rawSessionToken) {
    const hmac = this.hmacToken(rawSessionToken);
    this.db.run(
      "DELETE FROM feedback WHERE id = $id AND session_token_hmac = $hmac",
      { $id: id, $hmac: hmac }
    );
    const deleted = this.db.getRowsModified();
    this.flush();
    return { deleted };
  }

  count() {
    const res = this.db.exec("SELECT COUNT(*) AS n FROM feedback");
    return res[0]?.values[0][0] ?? 0;
  }

  close() {
    // Final flush + free wasm memory.
    try { this.flush(); } catch { /* file might be unwritable on shutdown */ }
    this.db.close();
  }
}
