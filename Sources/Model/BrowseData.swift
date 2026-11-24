import Foundation

struct BrowseData {
    let groups: [CharacterGroup]
    let faceEntries: [CharacterEntry]?
    let symbols: [CharacterEntry]?
    let union: CharacterSet?

    static func load(query: String, shapeMatches: [CharacterEntry]?, scope: CharacterScope, face: FontFace?,
                     layout: String, preferences: Preferences, base: [CharacterEntry], symbols: [CharacterEntry],
                     library: FontLibrary, catalog: UnicodeCatalog?, cachedFaceEntries: [CharacterEntry]?) -> Self {
        var shelf: [CharacterGroup] = []
        let wantLocalFont = scope == .face || scope == .glyphs
        let newSymbols = (layout == "SF Symbols" || query.contains(".") || query.localizedCaseInsensitiveContains("sf ")) && symbols.isEmpty
            ? SystemSymbols.entries() : nil
        let symbolList = newSymbols ?? symbols
        let union = scope == .installed || scope == .unicode ? library.unionCoverage() : CharacterSet()
        let fontSupport = face.map(library.support)
        func matchesScope(_ item: CharacterEntry) -> Bool {
            if item.symbolName != nil { return scope != .face && scope != .glyphs }
            switch scope {
            case .unicode: return !item.scalars.isEmpty
            case .installed: return item.faceName != nil || library.isInstalled(item, union: union)
            case .face, .glyphs: return fontSupport.map { library.covers(item, in: $0) } ?? false
            }
        }
        var newFaceEntries: [CharacterEntry]?
        func withFace() -> [CharacterEntry] {
            if let cachedFaceEntries { return cachedFaceEntries }
            guard let face, !base.isEmpty else { return [] }
            let values = library.entriesForFace(face, catalogEntries: base, allGlyphs: scope == .glyphs)
            newFaceEntries = values
            return values
        }
        if let shapeMatches {
            shelf = [.init(id: "shapes", title: "Shape matches", entries: shapeMatches.filter(matchesScope))]
        } else if !query.isEmpty {
            let userNames = preferences.aliases.filter { $0.value.localizedCaseInsensitiveContains(query) }
            let result = catalog?.search(query, limit: 1600) ?? []
            let owned = wantLocalFont ? withFace() : []
            let named = owned.filter { $0.name.localizedCaseInsensitiveContains(query) || $0.codes == query }
            let fontSpecificAliases = (preferences.favorites + preferences.recents + owned).filter { userNames[$0.id] != nil }
            let scalarAliases = userNames.keys.sorted().compactMap { id -> CharacterEntry? in
                let parts = id.split(separator: " ")
                let values = parts.compactMap { UInt32($0, radix: 16) }
                guard values.count == parts.count else { return nil }
                return catalog?.sequence(values)
            }
            let custom = fontSpecificAliases + scalarAliases
            let system = symbolList.filter { $0.name.localizedCaseInsensitiveContains(query.replacingOccurrences(of: "sf ", with: "")) }
            var seen: Set<String> = []
            let hits = Array((custom + named + result + system).filter { matchesScope($0) && seen.insert($0.id).inserted }.prefix(700))
            shelf = [.init(id: "search", title: "Search results", entries: hits)]
        } else {
            if !preferences.favorites.isEmpty { shelf.append(.init(id: "favorites", title: "Favorites", entries: preferences.favorites)) }
            if !preferences.recents.isEmpty { shelf.append(.init(id: "recents", title: "Recent characters", entries: preferences.recents)) }
            let source = wantLocalFont ? withFace() : base.filter(matchesScope)
            if layout == "Emoji" {
                shelf += (catalog?.emojiGroups() ?? []).compactMap { group in
                    let subset = group.entries.filter(matchesScope)
                    return subset.isEmpty ? nil : CharacterGroup(id: group.id, title: group.title, entries: subset)
                }
            } else if layout == "SF Symbols" {
                shelf.append(.init(id: "system-symbols", title: "SF Symbols", entries: symbolList))
            } else if let custom = preferences.layouts.first(where: { $0.name == layout }),
                      let program = try? LayoutProgram(custom.contents) {
                shelf += program.groups(in: source) { catalog?.search($0, limit: 25_000) ?? [] }
            } else if layout == "MacRoman" {
                let keys = (0..<256).compactMap { String(data: Data([UInt8($0)]), encoding: .macOSRoman) }
                    .flatMap { $0.unicodeScalars.map(\.value) }
                let covered = Dictionary(source.filter { $0.scalars.count == 1 }.map { ($0.scalars[0], $0) },
                                         uniquingKeysWith: { a, _ in a })
                shelf.append(.init(id: "macroman", title: "MacRoman", entries: keys.compactMap { covered[$0] }))
            } else {
                let values = layout == "Alphabet" ? source.filter { $0.category.hasPrefix("L") } : source
                var position: [String: Int] = [:]
                for item in values {
                    let key: String
                    if layout == "Scripts and Symbols" && ["Common", "Inherited", "Unknown", ""].contains(item.script) {
                        key = item.block
                    } else {
                        key = layout == "Scripts and Symbols" || layout == "Alphabet" ? item.script : item.block
                    }
                    if let existing = position[key] {
                        shelf[existing].entries.append(item)
                    } else {
                        position[key] = shelf.count
                        shelf.append(.init(id: "browse-\(key)", title: key, entries: [item]))
                    }
                }
            }
        }
        return Self(groups: shelf, faceEntries: newFaceEntries, symbols: newSymbols,
                    union: scope == .installed || scope == .unicode ? union : nil)
    }
}
