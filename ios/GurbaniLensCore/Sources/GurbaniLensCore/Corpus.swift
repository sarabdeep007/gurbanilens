import Foundation
import SQLite3

/// Read-only SGGS corpus backed by the Shabad OS SQLite (v4 schema).
/// Mirrors core/gurbanilens/corpus.py:Corpus
public final class Corpus {
    public let dbPath: URL
    private var db: OpaquePointer?
    private let sggsSourceId: Int
    private let englishLanguageId: Int

    public enum CorpusError: Error {
        case dbOpenFailed(String)
        case sggsSourceNotFound
        case englishLanguageNotFound
    }

    public init(dbPath: URL) throws {
        self.dbPath = dbPath

        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI
        let result = sqlite3_open_v2(dbPath.path, &handle, flags, nil)
        guard result == SQLITE_OK, let db = handle else {
            let msg = handle.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(handle)
            throw CorpusError.dbOpenFailed(msg)
        }
        self.db = db

        // Resolve SGGS source id and English language id
        guard let id = Corpus.resolveId(db: db, table: "sources",
                                       where_: "name_english LIKE ? || '%'",
                                       value: "Sri Guru Granth Sahib") else {
            sqlite3_close(db)
            throw CorpusError.sggsSourceNotFound
        }
        self.sggsSourceId = id

        guard let lang = Corpus.resolveId(db: db, table: "languages",
                                         where_: "name_english = ?",
                                         value: "English") else {
            sqlite3_close(db)
            throw CorpusError.englishLanguageNotFound
        }
        self.englishLanguageId = lang
    }

    deinit {
        if let db = db { sqlite3_close(db) }
    }

    private static func resolveId(db: OpaquePointer, table: String,
                                  where_: String, value: String) -> Int? {
        let sql = "SELECT id FROM \(table) WHERE \(where_)"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, value, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    // ---------------------------------------------------------------------
    // Iteration: all SGGS lines in canonical order
    // ---------------------------------------------------------------------

    /// Iterate every SGGS line that has English transliteration. Used by
    /// the matcher to build its in-memory index.
    public func allLines() throws -> [Line] {
        let sql = """
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
        ORDER BY l.order_id
        """
        return try query(sql) { stmt in
            sqlite3_bind_int64(stmt, 1, Int64(englishLanguageId))
            sqlite3_bind_int64(stmt, 2, Int64(sggsSourceId))
        }
    }

    public func lookup(ang: Int, pangti: Int) throws -> [Line] {
        let sql = """
        SELECT l.id, l.shabad_id, l.source_page, l.source_line, l.gurmukhi,
               l.first_letters, l.order_id,
               lt.name_english AS line_type,
               t.transliteration AS transliteration_en
        FROM lines l
        JOIN shabads s ON l.shabad_id = s.id
        LEFT JOIN line_types lt ON l.type_id = lt.id
        LEFT JOIN transliterations t
            ON t.line_id = l.id AND t.language_id = ?
        WHERE s.source_id = ? AND l.source_page = ? AND l.source_line = ?
        ORDER BY l.order_id
        """
        return try query(sql) { stmt in
            sqlite3_bind_int64(stmt, 1, Int64(englishLanguageId))
            sqlite3_bind_int64(stmt, 2, Int64(sggsSourceId))
            sqlite3_bind_int64(stmt, 3, Int64(ang))
            sqlite3_bind_int64(stmt, 4, Int64(pangti))
        }
    }

    /// All lines in a single Shabad, ordered. Used by the v1 ShabadScreen
    /// after a voice-search match.
    public func shabadLines(shabadId: String) throws -> [Line] {
        let sql = """
        SELECT l.id, l.shabad_id, l.source_page, l.source_line, l.gurmukhi,
               l.first_letters, l.order_id,
               lt.name_english AS line_type,
               t.transliteration AS transliteration_en
        FROM lines l
        LEFT JOIN line_types lt ON l.type_id = lt.id
        LEFT JOIN transliterations t
            ON t.line_id = l.id AND t.language_id = ?
        WHERE l.shabad_id = ?
        ORDER BY l.order_id
        """
        guard let db = db else { return [] }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_int64(stmt, 1, Int64(englishLanguageId))
        sqlite3_bind_text(stmt, 2, shabadId, -1, SQLITE_TRANSIENT)
        var lines: [Line] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            lines.append(rowToLine(stmt))
        }
        return lines
    }

    // ---------------------------------------------------------------------
    // Internal helpers
    // ---------------------------------------------------------------------

    private func query(_ sql: String,
                       bind: (OpaquePointer?) -> Void) throws -> [Line] {
        guard let db = db else { return [] }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(stmt) }
        bind(stmt)

        var lines: [Line] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            lines.append(rowToLine(stmt))
        }
        return lines
    }

    private func rowToLine(_ stmt: OpaquePointer?) -> Line {
        // Column order matches the SQL above; no _unicode columns yet — the
        // Phase 2A build pipeline adds those in the app database, not in
        // the raw shabados/database used for port parity.
        let id = stringColumn(stmt, 0) ?? ""
        let shabadId = stringColumn(stmt, 1) ?? ""
        let ang = Int(sqlite3_column_int64(stmt, 2))
        let pangtiRaw = sqlite3_column_type(stmt, 3) == SQLITE_NULL
            ? nil
            : Optional(Int(sqlite3_column_int64(stmt, 3)))
        let gurmukhi = stringColumn(stmt, 4) ?? ""
        let firstLetters = stringColumn(stmt, 5)
        let orderId = Int(sqlite3_column_int64(stmt, 6))
        let lineType = stringColumn(stmt, 7)
        let transliterationEn = stringColumn(stmt, 8)
        return Line(
            id: id,
            shabadId: shabadId,
            ang: ang,
            pangti: pangtiRaw,
            lineType: lineType,
            gurmukhi: gurmukhi,
            gurmukhiUnicode: nil,
            transliterationEn: transliterationEn,
            firstLetters: firstLetters,
            orderId: orderId
        )
    }

    private func stringColumn(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        if sqlite3_column_type(stmt, index) == SQLITE_NULL { return nil }
        guard let ptr = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: ptr)
    }
}
