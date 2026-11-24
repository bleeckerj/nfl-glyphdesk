import Foundation

struct LayoutDocument: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var contents: String

    init(id: UUID = UUID(), name: String, contents: String) {
        self.id = id
        self.name = name
        self.contents = contents
    }

    static let example = LayoutDocument(name: "Writing", contents: """
        Punctuation
        $2013-$2015 $2026 $2018-$201D

        Math and arrows
        [FIND infinity]
        [BLOCK Arrows]

        Ligatures
        [LIGATURES]

        Remaining characters
        [OTHER]
        """)
}

struct LayoutError: LocalizedError {
    let line: Int
    let message: String
    var errorDescription: String? { "Line \(line): \(message)" }
}

struct LayoutProgram {
    enum Term {
        case codes([UInt32]), range(ClosedRange<UInt32>), block(String), find(String)
        case otherInBlock(String), other, ligatures
    }

    var sections: [(String, [Term])]

    init(_ text: String) throws {
        sections = []
        var needsHeading = true
        var disabled = false
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let lexical = try NSRegularExpression(pattern: #"\[[^\[\]]+\]|(?:\$[A-Fa-f0-9]+|#[0-9]+|[^\s\[\]#$-])(?:-(?:\$[A-Fa-f0-9]+|#[0-9]+|[^\s\[\]#$-]))?"#)
        for (index, rawLine) in normalized.components(separatedBy: "\n").enumerated() {
            let line = rawLine.components(separatedBy: "//").first!.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                if rawLine.trimmingCharacters(in: .whitespaces).isEmpty { needsHeading = true }
                continue
            }
            if needsHeading {
                disabled = line.hasPrefix("-")
                if !disabled { sections.append((line, [])) }
                needsHeading = false
                continue
            }
            guard !disabled else { continue }
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            var lastEnd = line.startIndex
            let terms: [Term] = try lexical.matches(in: line, range: range).compactMap { match in
                guard let matchRange = Range(match.range, in: line) else { return nil }
                guard line[lastEnd..<matchRange.lowerBound].allSatisfy(\.isWhitespace) else {
                    throw LayoutError(line: index + 1, message: "Invalid token.")
                }
                lastEnd = matchRange.upperBound
                return try Self.parse(String(line[matchRange]), line: index + 1)
            }
            guard line[lastEnd...].allSatisfy(\.isWhitespace) else {
                throw LayoutError(line: index + 1, message: "Incomplete token.")
            }
            sections[sections.count - 1].1 += terms
        }
        guard !sections.isEmpty else { throw LayoutError(line: 1, message: "Add a group heading followed by characters.") }
    }

    func groups(in entries: [CharacterEntry], search: (String) -> [CharacterEntry]) -> [CharacterGroup] {
        let byKey = Dictionary(entries.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        let blockGroups = Dictionary(grouping: entries, by: \.block)
        let ligatures = entries.filter { $0.category == "Ligature" }
        var seen: Set<String> = []
        let materialized = sections.map { title, terms in
            (title, terms.map { term -> (Term, [CharacterEntry]) in
                let matches: [CharacterEntry]
                switch term {
                case let .codes(codes):
                    let key = codes.map { String($0, radix: 16, uppercase: true) }.joined(separator: " ")
                    matches = byKey[key].map { [$0] } ?? []
                case let .range(interval):
                    matches = entries.filter { $0.scalars.count == 1 && interval.contains($0.scalars[0]) }
                case let .block(block): matches = blockGroups[block] ?? []
                case let .find(query): matches = search(query).compactMap { byKey[$0.key] }
                case .ligatures: matches = ligatures
                case .other, .otherInBlock: matches = []
                }
                seen.formUnion(matches.map(\.id))
                return (term, matches)
            })
        }

        return materialized.enumerated().compactMap { index, section in
            let matches = section.1.flatMap { term, explicit -> [CharacterEntry] in
                let inScope: [CharacterEntry]
                switch term {
                case let .otherInBlock(block): inScope = blockGroups[block] ?? []
                case .other: inScope = entries
                default: return explicit
                }
                return inScope.filter { seen.insert($0.id).inserted }
            }
            guard !matches.isEmpty else { return nil }
            return CharacterGroup(id: "custom-\(index)", title: section.0, entries: matches)
        }
    }

    private static func parse(_ token: String, line: Int) throws -> Term {
        func fail() -> LayoutError { LayoutError(line: line, message: "Invalid character, range, or directive \(token).") }
        if token.hasPrefix("[") {
            let inner = String(token.dropFirst().dropLast())
            if inner == "OTHER" { return .other }
            if inner == "LIGATURES" { return .ligatures }
            for (prefix, wrap) in [("FIND ", Term.find), ("BLOCK ", Term.block), ("BLOCK-OTHER ", Term.otherInBlock)] {
                if inner.hasPrefix(prefix) { return wrap(String(inner.dropFirst(prefix.count))) }
            }
            let expression = try NSRegularExpression(pattern: #"\$[A-Fa-f0-9]+|#[0-9]+|[^\s#$\[\]]"#)
            let matches = expression.matches(in: inner, range: NSRange(inner.startIndex..<inner.endIndex, in: inner))
            var lastEnd = inner.startIndex
            var codes: [UInt32] = []
            for match in matches {
                guard let range = Range(match.range, in: inner),
                      inner[lastEnd..<range.lowerBound].allSatisfy(\.isWhitespace),
                      let decoded = scalar(String(inner[range])) else { throw fail() }
                lastEnd = range.upperBound
                codes.append(contentsOf: decoded)
            }
            guard !codes.isEmpty, inner[lastEnd...].allSatisfy(\.isWhitespace) else { throw fail() }
            return .codes(codes)
        }
        let split = token.components(separatedBy: "-")
        if split.count == 2, let start = scalar(split[0]), let end = scalar(split[1]),
           start.count == 1, end.count == 1, start[0] <= end[0] {
            return .range(start[0]...end[0])
        }
        guard let codes = scalar(token), !codes.isEmpty else { throw fail() }
        return .codes(codes)
    }

    private static func scalar(_ token: String) -> [UInt32]? {
        if token.hasPrefix("$") || token.hasPrefix("#") {
            guard let code = UInt32(token.dropFirst(), radix: token.hasPrefix("$") ? 16 : 10),
                  Unicode.Scalar(code) != nil else { return nil }
            return [code]
        }
        guard token.count == 1 && !token.contains("-") else { return nil }
        return token.unicodeScalars.map(\.value)
    }
}
