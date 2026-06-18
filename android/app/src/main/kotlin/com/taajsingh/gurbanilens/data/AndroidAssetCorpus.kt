package com.taajsingh.gurbanilens.data

import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.util.Log
import com.taajsingh.gurbanilens.core.Corpus
import com.taajsingh.gurbanilens.core.Line
import java.io.File
import java.io.FileOutputStream

/**
 * Android-side [Corpus] implementation. Reads the SGGS SQLite that's bundled
 * in `app/src/main/assets/`. Because SQLite can't open from a compressed APK
 * asset directly, on first run we copy it into the app's files dir (one-time
 * ~150 MB write; trim to ~77 MB Anvaad-augmented build will replace this).
 *
 * Mirrors `core/gurbanilens/corpus.py:Corpus`.
 */
class AndroidAssetCorpus(
    private val ctx: Context,
    private val assetName: String = "sggs.sqlite",
) : Corpus, AutoCloseable {

    private val db: SQLiteDatabase
    private val sggsSourceId: Int
    private val englishLanguageId: Int

    init {
        val target = File(ctx.filesDir, "corpus/$assetName")
        if (!target.exists() || target.length() == 0L) {
            target.parentFile?.mkdirs()
            ctx.assets.open(assetName).use { input ->
                FileOutputStream(target).use { out -> input.copyTo(out) }
            }
            Log.i(TAG, "Copied $assetName → ${target.absolutePath} (${target.length()} B)")
        }

        db = SQLiteDatabase.openDatabase(
            target.absolutePath,
            null,
            SQLiteDatabase.OPEN_READONLY,
        )

        sggsSourceId = resolveId(
            "sources", "name_english LIKE ? || '%'", "Sri Guru Granth Sahib"
        ) ?: error("Could not resolve SGGS source id from bundled corpus")

        englishLanguageId = resolveId(
            "languages", "name_english = ?", "English"
        ) ?: error("Could not resolve English language id from bundled corpus")
    }

    private fun resolveId(table: String, where: String, value: String): Int? {
        db.rawQuery("SELECT id FROM $table WHERE $where", arrayOf(value)).use { c ->
            if (c.moveToFirst()) return c.getInt(0)
        }
        return null
    }

    private val lineSelect = """
        SELECT l.id, l.shabad_id, l.source_page, l.source_line, l.gurmukhi,
               l.first_letters, l.order_id,
               lt.name_english AS line_type,
               t.transliteration AS transliteration_en
        FROM lines l
        JOIN shabads s ON l.shabad_id = s.id
        LEFT JOIN line_types lt ON l.type_id = lt.id
        LEFT JOIN transliterations t
            ON t.line_id = l.id AND t.language_id = ?
        WHERE s.source_id = ?
    """.trimIndent()

    override fun allLines(): Sequence<Line> = sequence {
        val cursor = db.rawQuery(
            "$lineSelect ORDER BY l.order_id",
            arrayOf(englishLanguageId.toString(), sggsSourceId.toString()),
        )
        cursor.use {
            while (it.moveToNext()) yield(rowToLine(it))
        }
    }

    override fun lookup(ang: Int, pangti: Int): List<Line> {
        val out = ArrayList<Line>(2)
        val sql = "$lineSelect AND l.source_page = ? AND l.source_line = ? ORDER BY l.order_id"
        db.rawQuery(
            sql,
            arrayOf(
                englishLanguageId.toString(),
                sggsSourceId.toString(),
                ang.toString(),
                pangti.toString(),
            ),
        ).use { c ->
            while (c.moveToNext()) out.add(rowToLine(c))
        }
        return out
    }

    private fun rowToLine(c: android.database.Cursor): Line {
        val pangtiIdx = c.getColumnIndexOrThrow("source_line")
        val pangtiNullable = if (c.isNull(pangtiIdx)) null else c.getInt(pangtiIdx)
        return Line(
            id = c.getString(c.getColumnIndexOrThrow("id")),
            shabadId = c.getString(c.getColumnIndexOrThrow("shabad_id")),
            ang = c.getInt(c.getColumnIndexOrThrow("source_page")),
            pangti = pangtiNullable,
            lineType = c.getStringOrNull("line_type"),
            gurmukhi = c.getString(c.getColumnIndexOrThrow("gurmukhi")),
            gurmukhiUnicode = null,    // Anvaad-augmented column not yet bundled here
            transliterationEn = c.getStringOrNull("transliteration_en"),
            firstLetters = c.getStringOrNull("first_letters"),
            orderId = c.getInt(c.getColumnIndexOrThrow("order_id")),
        )
    }

    private fun android.database.Cursor.getStringOrNull(col: String): String? {
        val idx = getColumnIndex(col)
        return if (idx < 0 || isNull(idx)) null else getString(idx)
    }

    override fun close() {
        db.close()
    }

    companion object {
        private const val TAG = "AndroidAssetCorpus"
    }
}
