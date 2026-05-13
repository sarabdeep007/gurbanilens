#!/usr/bin/env node
/**
 * Convert Anmol Lipi font-encoded Gurmukhi columns in the Shabad OS SQLite
 * to proper Unicode Gurmukhi via anvaad-js.
 *
 * Reads:   ../data/sggs/database.sqlite        (raw v4.8.7)
 * Writes:  ./intermediate_unicode.sqlite       (raw + gurmukhi_unicode columns)
 *
 * Per the script_and_matching_surface.md memory: never hand-roll Anmol Lipi
 * → Unicode conversion. anvaad-js is the canonical Sikh-community impl.
 */

import { readFileSync, copyFileSync, existsSync, mkdirSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import Database from "better-sqlite3";

// anvaad-js ships a UMD bundle that expects a browser-like `self`. Shim it
// before importing so it loads cleanly in Node.
globalThis.self = globalThis;
const anvaadModule = await import("anvaad-js");
const anvaad = anvaadModule.default ?? anvaadModule;

const __dirname = dirname(fileURLToPath(import.meta.url));
const SRC = resolve(__dirname, "../data/sggs/database.sqlite");
const OUT = resolve(__dirname, "intermediate_unicode.sqlite");

if (!existsSync(SRC)) {
  console.error(`Source DB not found: ${SRC}`);
  console.error("Run: python scripts/fetch_corpus.py");
  process.exit(1);
}

console.log(`Copying ${SRC}\n     -> ${OUT}`);
copyFileSync(SRC, OUT);

const db = new Database(OUT);

// Tables/columns that contain Anmol Lipi Gurmukhi text. For each, we add a
// sibling _unicode column with the converted text.
const COLUMNS = [
  { table: "lines",                column: "gurmukhi"          },
  { table: "lines",                column: "first_letters"     },
  { table: "lines",                column: "vishraam_first_letters" },
  { table: "shabads",              column: null /* none */     }, // shabads has no gurmukhi text
  { table: "banis",                column: "name_gurmukhi"     },
  { table: "languages",            column: "name_gurmukhi"     },
  { table: "line_types",           column: "name_gurmukhi"     },
  { table: "sections",             column: "name_gurmukhi"     },
  { table: "sources",              column: "name_gurmukhi"     },
  { table: "sources",              column: "page_name_gurmukhi" },
  { table: "subsections",          column: "name_gurmukhi"     },
  { table: "translation_sources",  column: "name_gurmukhi"     },
  { table: "writers",              column: "name_gurmukhi"     },
];

function convertCell(text) {
  if (text == null || text === "") return text;
  // anvaad.unicode(...) converts Anmol Lipi → Unicode Gurmukhi
  return anvaad.unicode(text);
}

function addUnicodeColumn(table, column) {
  if (!column) return;
  const uniColumn = `${column}_unicode`;
  console.log(`  ${table}.${column} -> ${table}.${uniColumn}`);

  // Add column if not present
  const columns = db.prepare(`PRAGMA table_info(${table})`).all().map(c => c.name);
  if (!columns.includes(uniColumn)) {
    db.exec(`ALTER TABLE ${table} ADD COLUMN ${uniColumn} TEXT`);
  }

  // PK detection — most tables have id, lines has id (text), translations has composite
  const pk = db.prepare(`PRAGMA table_info(${table})`)
               .all()
               .filter(c => c.pk > 0)
               .sort((a, b) => a.pk - b.pk);
  if (pk.length === 0) {
    console.warn(`    WARNING: no primary key on ${table}; skipping update`);
    return;
  }

  // Streaming update — read-row, convert, write-row
  const pkCols = pk.map(c => c.name).join(", ");
  const pkBinders = pk.map(c => `${c.name} = ?`).join(" AND ");
  const rows = db.prepare(`SELECT ${pkCols}, ${column} FROM ${table}`).all();
  const update = db.prepare(`UPDATE ${table} SET ${uniColumn} = ? WHERE ${pkBinders}`);

  const trx = db.transaction(() => {
    for (const row of rows) {
      const converted = convertCell(row[column]);
      const pkVals = pk.map(c => row[c.name]);
      update.run(converted, ...pkVals);
    }
  });
  trx();
  console.log(`    ${rows.length.toLocaleString()} rows updated`);
}

console.log("\nConverting Anmol Lipi columns to Unicode Gurmukhi...");
for (const { table, column } of COLUMNS) {
  addUnicodeColumn(table, column);
}

// Sanity check: peek at line 1 (Mool Mantar)
const sample = db.prepare(`
  SELECT l.source_page, l.source_line, l.gurmukhi, l.gurmukhi_unicode
  FROM lines l
  JOIN shabads s ON l.shabad_id = s.id
  WHERE s.source_id = (SELECT id FROM sources WHERE name_english LIKE 'Sri Guru Granth%')
    AND l.source_page = 1 AND l.source_line = 1
`).get();
console.log("\nSanity check (Mool Mantar):");
console.log(`  Anmol Lipi   : ${sample.gurmukhi}`);
console.log(`  Unicode      : ${sample.gurmukhi_unicode}`);

db.close();
console.log(`\nDone. Intermediate DB: ${OUT}`);
console.log("Next: python build/build_app_database.py");
