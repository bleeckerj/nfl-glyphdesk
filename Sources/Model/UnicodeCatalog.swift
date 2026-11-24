import Foundation
import SQLite3

final class UnicodeCatalog: @unchecked Sendable {
    let url: URL
    private let database: OpaquePointer
    private let lock = NSLock()
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private let columns = "scalars, name, block, script, category"

    init?(url: URL? = Bundle.main.url(forResource: "Unicode", withExtension: "sqlite3")) {
        guard let url else { return nil }
        var connection: OpaquePointer?
        let status = sqlite3_open_v2(url.path, &connection, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
        guard status == SQLITE_OK, let connection else {
            if let connection { sqlite3_close(connection) }
            return nil
        }
        self.url = url
        database = connection
    }

    deinit { sqlite3_close(database) }

    func entry(_ scalars: [UInt32]) -> CharacterEntry? {
        guard !scalars.isEmpty, scalars.allSatisfy({ Unicode.Scalar($0) != nil }) else { return nil }
        let key = scalars.map { String($0, radix: 16, uppercase: true) }.joined(separator: " ")
        if let row = query("SELECT \(columns) FROM entry WHERE scalars = ?", [key]).first {
            return decode(row)
        }
        return nil
    }

    func all() -> [CharacterEntry] {
        query("SELECT \(columns) FROM entry ORDER BY point, id").compactMap(decode)
    }

    func emojiGroups() -> [CharacterGroup] {
        var result: [CharacterGroup] = []
        var indexes: [String: Int] = [:]
        let officialOrder = ["Smileys & Emotion", "People & Body", "Component", "Animals & Nature",
                             "Food & Drink", "Travel & Places", "Activities", "Objects", "Symbols", "Flags"]
        for row in query("SELECT \(columns), emoji FROM entry WHERE emoji != '' ORDER BY id") {
            guard let entry = decode(row) else { continue }
            let group = row[5]
            if let index = indexes[group] {
                result[index].entries.append(entry)
            } else {
                indexes[group] = result.count
                result.append(CharacterGroup(id: group, title: group, entries: [entry]))
            }
        }
        return result.sorted {
            (officialOrder.firstIndex(of: $0.title) ?? 999) < (officialOrder.firstIndex(of: $1.title) ?? 999)
        }
    }

    func search(_ text: String, limit: Int = 300) -> [CharacterEntry] {
        let queryText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if queryText.isEmpty {
            return text.isEmpty ? [] : entry(text.unicodeScalars.map(\.value)).map { [$0] } ?? []
        }
        if let codes = explicitCodes(queryText) {
            return exact(codes)
        }
        if let entity = entityScalars(queryText) {
            return exact(entity)
        }

        var matches: [CharacterEntry] = []
        let scalars = queryText.unicodeScalars.map(\.value)
        let shouldReadLiterally = queryText.count == 1 || queryText.unicodeScalars.contains {
            $0.value >= 128 && !CharacterSet.letters.contains($0)
        }
        if shouldReadLiterally {
            if queryText.count == 1, let combined = sequence(scalars) { matches = [combined] }
            else { matches = exact(scalars) }
        }
        let terms = queryText.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        if !terms.isEmpty {
            let fts = terms.prefix(20).map { "\"\($0)\"*" }.joined(separator: " AND ")
            let sql = """
                SELECT e.scalars, e.name, e.block, e.script, e.category
                FROM lookup JOIN entry AS e ON lookup.rowid = e.id
                WHERE lookup MATCH ?
                ORDER BY (e.name = ? COLLATE NOCASE) DESC,
                         CASE WHEN instr(lower(e.name), lower(?)) > 0
                              THEN length(e.name) ELSE 65535 END,
                         rank, e.id LIMIT ?
                """
            matches += query(sql, [fts, queryText, queryText, String(min(max(limit, 1), 25_000))]).compactMap(decode)
        }
        if matches.isEmpty, queryText.count < 50, !queryText.contains(" ") {
            let parts = queryText.unicodeScalars.filter { $0.value >= 128 }.map(\.value)
            if !parts.isEmpty { matches = parts.compactMap { entry([$0]) } }
        }
        var seen: Set<String> = []
        return Array(matches.filter { seen.insert($0.id).inserted }.prefix(limit))
    }

    func skinTones(for entry: CharacterEntry) -> [CharacterEntry] {
        guard let first = entry.scalars.first, (entry.category == "Emoji" || first >= 0x1F000) else { return [] }
        let tones: ClosedRange<UInt32> = 0x1F3FB...0x1F3FF
        let base = entry.scalars.filter { !tones.contains($0) }
        guard let baseFirst = base.first else { return [] }
        let prefix = String(baseFirst, radix: 16, uppercase: true)
        let candidates = query("SELECT \(columns) FROM entry WHERE emoji != '' AND (scalars = ? OR scalars LIKE ?) ORDER BY point, id",
                               [prefix, prefix + " %"]).compactMap(decode)
        let variants = candidates.filter { $0.scalars.filter { !tones.contains($0) } == base }
        return variants.count > 1 ? variants : []
    }

    func html(_ entry: CharacterEntry, style: EntityStyle) -> String {
        if style == .named {
            let names = query("SELECT name FROM entity WHERE scalars = ? ORDER BY length(name), name DESC", [entry.key])
            if let name = names.first?.first { return name }
        }
        return entry.scalars.map {
            style == .hex ? "&#x\(String($0, radix: 16, uppercase: true));" : "&#\($0);"
        }.joined()
    }

    func versions() -> String {
        query("SELECT name, version FROM metadata ORDER BY name").map { "\($0[0]) \($0[1])" }.joined(separator: " · ")
    }

    func sequence(_ scalars: [UInt32]) -> CharacterEntry? {
        if let existing = entry(scalars) { return existing }
        guard scalars.count > 1, scalars.count <= 64 else { return nil }
        let parts = scalars.compactMap { entry([$0]) }
        guard parts.count == scalars.count, let first = parts.first else { return nil }
        return CharacterEntry(scalars: scalars, name: parts.map(\.name).joined(separator: " + "),
                              block: first.block, script: first.script, category: "Sequence")
    }

    private func exact(_ scalars: [UInt32]) -> [CharacterEntry] {
        if let exact = sequence(scalars) { return [exact] }
        return scalars.compactMap { entry([$0]) }
    }

    private func entityScalars(_ value: String) -> [UInt32]? {
        guard value.hasPrefix("&"), value.hasSuffix(";") else { return nil }
        if value.hasPrefix("&#") {
            let numeric = value.dropFirst(2).dropLast()
            let hex = numeric.first?.lowercased() == "x"
            return UInt32(hex ? numeric.dropFirst() : numeric, radix: hex ? 16 : 10).map { [$0] }
        }
        return query("SELECT scalars FROM entity WHERE name = ?", [value]).first?.first.map(splitCodes)
    }

    private func explicitCodes(_ value: String) -> [UInt32]? {
        let pieces = value.split(whereSeparator: \.isWhitespace)
        let explicit = pieces.allSatisfy {
            let lower = $0.lowercased()
            return lower.hasPrefix("u+") || lower.hasPrefix("0x") || lower.hasPrefix("#") || lower.hasPrefix("\\u{")
        }
        if !explicit {
            guard pieces.count == 1, let piece = pieces.first, (4...6).contains(piece.count),
                  piece.allSatisfy(\.isHexDigit),
                  piece.contains(where: \.isNumber) else { return nil }
            return UInt32(piece, radix: 16).map { [$0] }
        }
        let decoded = pieces.compactMap { piece -> UInt32? in
            if piece.hasPrefix("#") { return UInt32(piece.dropFirst()) }
            if piece.hasPrefix("\\u{"), piece.hasSuffix("}") {
                return UInt32(piece.dropFirst(3).dropLast(), radix: 16)
            }
            return UInt32(piece.dropFirst(2), radix: 16)
        }
        return decoded.count == pieces.count ? decoded : nil
    }

    private func splitCodes(_ value: String) -> [UInt32] {
        value.split(separator: " ").compactMap { UInt32($0, radix: 16) }
    }

    private func decode(_ row: [String]) -> CharacterEntry? {
        guard row.count >= 5 else { return nil }
        return CharacterEntry(scalars: splitCodes(row[0]), name: row[1], block: row[2],
                              script: row[3], category: row[4])
    }

    private func query(_ sql: String, _ values: [String] = []) -> [[String]] {
        lock.lock()
        defer { lock.unlock() }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return [] }
        defer { sqlite3_finalize(statement) }
        for (index, value) in values.enumerated() {
            sqlite3_bind_text(statement, Int32(index + 1), value, -1, transient)
        }
        let columnCount = sqlite3_column_count(statement)
        var result: [[String]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            result.append((0..<columnCount).map { index in
                sqlite3_column_text(statement, index).map { String(cString: $0) } ?? ""
            })
        }
        return result
    }
}
