package com.taajsingh.gurbanilens.core

import java.sql.Connection
import java.sql.DriverManager
import java.sql.ResultSet

/**
 * JVM-side [Corpus] implementation backed by the raw Shabad OS SQLite v4 file
 * via `org.xerial:sqlite-jdbc`. Used by [PortParityTest] only — not shipped
 * with the Android app. The Android :app module provides its own
 * `AndroidAssetCorpus` using `android.database.sqlite`.
 *
 * Mirrors `core/gurbanilens/corpus.py:Corpus`.
 */
class JvmSqliteCorpus(dbPath: String) : Corpus, AutoCloseable {

    private val conn: Connection
    private val sggsSourceId: Int
    private val englishLanguageId: Int

    init {
        Class.forName("org.sqlite.JDBC")
        // xerial sqlite-jdbc requires read-only set via SQLiteConfig before
        // the connection is opened; setting `isReadOnly` after fails.
        val config = org.sqlite.SQLiteConfig().apply { setReadOnly(true) }
        conn = config.createConnection("jdbc:sqlite:$dbPath")

        sggsSourceId = resolveId(
            "sources", "name_english LIKE ? || '%'", "Sri Guru Granth Sahib"
        ) ?: error("Could not resolve SGGS source id")

        englishLanguageId = resolveId(
            "languages", "name_english = ?", "English"
        ) ?: error("Could not resolve English language id")
    }

    private fun resolveId(table: String, where: String, value: String): Int? {
        conn.prepareStatement("SELECT id FROM $table WHERE $where").use { ps ->
            ps.setString(1, value)
            ps.executeQuery().use { rs ->
                if (rs.next()) return rs.getInt("id")
            }
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
        conn.prepareStatement("$lineSelect ORDER BY l.order_id").use { ps ->
            ps.setInt(1, englishLanguageId)
            ps.setInt(2, sggsSourceId)
            ps.executeQuery().use { rs ->
                while (rs.next()) yield(rowToLine(rs))
            }
        }
    }

    override fun lookup(ang: Int, pangti: Int): List<Line> {
        val sql = "$lineSelect AND l.source_page = ? AND l.source_line = ? ORDER BY l.order_id"
        val out = ArrayList<Line>()
        conn.prepareStatement(sql).use { ps ->
            ps.setInt(1, englishLanguageId)
            ps.setInt(2, sggsSourceId)
            ps.setInt(3, ang)
            ps.setInt(4, pangti)
            ps.executeQuery().use { rs ->
                while (rs.next()) out.add(rowToLine(rs))
            }
        }
        return out
    }

    private fun rowToLine(rs: ResultSet): Line {
        val pangtiNullable = rs.getObject("source_line")?.let { (it as Number).toInt() }
        return Line(
            id = rs.getString("id") ?: "",
            shabadId = rs.getString("shabad_id") ?: "",
            ang = rs.getInt("source_page"),
            pangti = pangtiNullable,
            lineType = rs.getString("line_type"),
            gurmukhi = rs.getString("gurmukhi") ?: "",
            gurmukhiUnicode = null,
            transliterationEn = rs.getString("transliteration_en"),
            firstLetters = rs.getString("first_letters"),
            orderId = rs.getInt("order_id"),
        )
    }

    override fun close() {
        conn.close()
    }
}
