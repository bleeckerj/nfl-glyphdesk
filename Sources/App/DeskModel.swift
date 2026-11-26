import AppKit
import Combine
import CoreText
import SwiftUI

enum WorkspacePage: String, CaseIterable, Identifiable {
    case browse = "Browse", compare = "Compare", proof = "Proof", fontInfo = "Font Info"
    var id: String { rawValue }
}

@MainActor
final class DeskModel: ObservableObject {
    @Published var query = "" {
        didSet {
            guard oldValue != query else { return }
            if !query.isEmpty {
                shapeTask?.cancel()
                computingMatches = false
                shapeMatches = nil
            }
            refresh()
        }
    }
    @Published var scope: CharacterScope
    @Published var selectedFace: FontFace?
    @Published var selection: CharacterEntry? { didSet { if oldValue?.id != selection?.id { inspect() } } }
    @Published var comparisonFace: FontFace?
    @Published var page: WorkspacePage = .browse
    @Published var shapePresented = false
    @Published var shapeMatches: [CharacterEntry]?
    @Published var message: String?
    @Published var target: InsertionTarget?
    @Published var working = false
    @Published var makingShapeIndex = false
    @Published var computingMatches = false
    @Published var visibleGroups: [CharacterGroup] = []
    @Published var coverage: [FontFace] = []
    @Published private(set) var installedCoverage: CharacterSet?
    @Published var coverageLoading = false
    @Published var keyboardEquivalent: String?
    @Published var flaggedFaces: Set<String> = []
    @Published var jumpID: String?
    @Published var foldedGroups: Set<String> = []
    @Published var fontFilter = ""
    @Published var fontCollection = "All fonts"
    @Published var showDrawer = true
    @Published private(set) var library: FontLibrary
    @Published var preferences: Preferences {
        didSet { scheduleSave() }
    }

    let catalog: UnicodeCatalog?
    let insertion = InsertionService()
    let fontReviews = FontReviewModel()
    var dismissForInsert: (() -> Void)?
    var preferencesDidChange: (() -> Void)?

    private var entries: [CharacterEntry] = []
    private var symbols: [CharacterEntry] = []
    private var shapeIndex: [IndexedShape] = []
    private var shapeIndexKey: String?
    private var catalogTask: Task<Void, Never>?
    private var workingTask: Task<Void, Never>?
    private var coverageTask: Task<Void, Never>?
    private var shapeTask: Task<Void, Never>?
    private var shapeBuildTask: Task<[IndexedShape], Never>?
    private var preferenceTask: Task<Void, Never>?
    private var faceEntries: [String: [CharacterEntry]] = [:]
    private var canPersistPreferences = true
    private var fontObservers: [NSObjectProtocol] = []

    let standardLayouts = ["Unicode Blocks", "Scripts and Symbols", "Alphabet", "Emoji", "MacRoman", "SF Symbols"]

    init(ephemeralPreferences: Preferences? = nil) {
        catalog = UnicodeCatalog()
        library = FontLibrary()
        let read = Result { try ephemeralPreferences ?? Preferences.load() }
        let saved = (try? read.get()) ?? Preferences()
        preferences = saved
        canPersistPreferences = ephemeralPreferences == nil
        scope = saved.lastScope
        selectedFace = library.faces.first { $0.id == saved.lastFace }
            ?? library.faces.first { $0.family == "Helvetica Neue" && $0.style == "Regular" }
            ?? library.faces.first
        if case .failure = read {
            canPersistPreferences = false
            message = "Preferences could not be opened. The existing file will be preserved."
        }
        if catalog == nil { message = "The bundled Unicode catalog could not be opened." }
        if let catalog {
            catalogTask = Task {
                let result = await Task.detached(priority: .utility) { UnicodeCatalog(url: catalog.url)?.all() ?? [] }.value
                guard !Task.isCancelled else { return }
                entries = result
                refresh()
            }
        }
        fontObservers.append(NotificationCenter.default.addObserver(
            forName: Notification.Name(kCTFontManagerRegisteredFontsChangedNotification as String), object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.reloadFonts() } })
        fontObservers.append(DistributedNotificationCenter.default().addObserver(
            forName: KeyboardMap.changed, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.inspect() } })
        refresh()
    }

    var layoutChoices: [String] { standardLayouts + preferences.layouts.map(\.name) }
    var layout: String {
        selectedFace.flatMap { preferences.faceLayouts[$0.id] } ?? preferences.globalLayout
    }
    var layoutLinked: Bool { selectedFace.flatMap { preferences.faceLayouts[$0.id] } != nil }
    var fontCount: Int { library.familyCount }
    var coverageCount: Int { Set(coverage.map(\.family)).count }
    var targetPreferenceKey: String { target?.key ?? "default" }
    var insertPreference: InsertionPreference { preferences.perApp[targetPreferenceKey] ?? InsertionPreference() }
    var zoom: Double { selectedFace.flatMap { preferences.zooms[$0.id] } ?? 42 }
    var fonts: [FontFace] {
        let collection = library.groups.first { $0.name == fontCollection }
        return library.faces.filter { face in
            guard fontFilter.isEmpty || face.title.localizedCaseInsensitiveContains(fontFilter)
                    || face.family.localizedCaseInsensitiveContains(fontFilter) else { return false }
            switch fontCollection {
            case "Recent fonts": return preferences.recentFonts.contains(face.id)
            case "Flagged": return flaggedFaces.contains(face.id)
            case "All fonts": return true
            default: return collection?.members.contains(face.id) ?? true
            }
        }
    }
    var allFontCollections: [String] { ["All fonts", "Recent fonts", "Flagged"] + library.groups.map(\.name) }
    var renderedFace: FontFace? {
        guard let selection else { return selectedFace }
        return rendering(selection)
    }
    var isFavorite: Bool { selection.map { item in preferences.favorites.contains { $0.id == item.id } } ?? false }
    var currentEncoding: String { selection.map(html) ?? "" }

    func open(over app: NSRunningApplication?) {
        updateInsertionTarget(over: app)
        message = nil
        if let target, let id = preferences.perApp[target.key]?.font ?? target.documentFont(),
           let face = library.faces.first(where: { $0.id == id || $0.title == id }) {
            pickFace(face, rememberForTarget: false)
        }
    }

    func updateInsertionTarget(over app: NSRunningApplication?) {
        let captured = InsertionTarget.capture(app)
        // Some apps clear their AX focus while inactive. Insertion re-verifies any saved field.
        if let captured, captured.element == nil, !captured.secure,
           let target, target.element != nil,
           target.app.processIdentifier == captured.app.processIdentifier { return }
        target = captured
    }

    func pickFace(_ face: FontFace, rememberForTarget: Bool = true) {
        if scope == .face || scope == .glyphs {
            shapeTask?.cancel()
            computingMatches = false
            shapeMatches = nil
        }
        selectedFace = face
        preferences.lastFace = face.id
        preferences.familyFaces[face.family] = face.id
        preferences.recentFonts.removeAll { $0 == face.id }
        preferences.recentFonts.insert(face.id, at: 0)
        preferences.recentFonts = Array(preferences.recentFonts.prefix(30))
        if rememberForTarget, target != nil { updateInsert { $0.font = face.id } }
        refresh()
    }

    func useDocumentFont() {
        updateInsert { $0.font = nil }
        guard let name = target?.documentFont(),
              let face = library.faces.first(where: { $0.id == name || $0.title == name }) else {
            message = "The target does not expose a document font. Glyph Desk will use the selected face."
            return
        }
        pickFace(face, rememberForTarget: false)
    }

    func pickScope(_ scope: CharacterScope) {
        shapeTask?.cancel()
        computingMatches = false
        self.scope = scope
        preferences.lastScope = scope
        shapeMatches = nil
        refresh()
    }

    func pickLayout(_ layout: String) {
        if layoutLinked, let face = selectedFace { preferences.faceLayouts[face.id] = layout }
        else { preferences.globalLayout = layout }
        shapeMatches = nil
        foldedGroups.removeAll()
        refresh()
    }

    func linkLayout() {
        guard let face = selectedFace else { return }
        if layoutLinked { preferences.faceLayouts.removeValue(forKey: face.id) }
        else { preferences.faceLayouts[face.id] = preferences.globalLayout }
        refresh()
    }

    func setZoom(_ value: Double) {
        guard let face = selectedFace else { return }
        preferences.zooms[face.id] = value
    }

    func updateInsert(_ change: (inout InsertionPreference) -> Void) {
        var snapshot = insertPreference
        change(&snapshot)
        preferences.perApp[targetPreferenceKey] = snapshot
    }

    func toggleFavorite(_ entry: CharacterEntry) {
        if preferences.favorites.contains(where: { $0.id == entry.id }) {
            preferences.favorites.removeAll { $0.id == entry.id }
        } else {
            preferences.favorites.append(entry)
        }
        refresh()
    }

    func alias(for entry: CharacterEntry) -> String { preferences.aliases[entry.id] ?? "" }

    func setAlias(_ alias: String, for entry: CharacterEntry) {
        let stripped = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        if stripped.isEmpty { preferences.aliases.removeValue(forKey: entry.id) }
        else { preferences.aliases[entry.id] = stripped }
    }

    func toggleFold(_ groupID: String, all: Bool = false) {
        if all { foldedGroups = foldedGroups.contains(groupID) ? [] : Set(visibleGroups.map(\.id)) }
        else if foldedGroups.contains(groupID) { foldedGroups.remove(groupID) }
        else { foldedGroups.insert(groupID) }
    }

    func chooseByOffset(_ offset: Int) {
        queryResultCloseIfNeeded()
        if let selection,
           let group = visibleGroups.first(where: { !foldedGroups.contains($0.id) && $0.entries.contains(where: { $0.id == selection.id }) }),
           let from = group.entries.firstIndex(where: { $0.id == selection.id }),
           group.entries.indices.contains(from + offset) {
            self.selection = group.entries[from + offset]
        } else {
            let valid = visibleGroups.filter { !$0.entries.isEmpty && !foldedGroups.contains($0.id) }
            let group = valid.firstIndex { $0.entries.contains { $0.id == self.selection?.id } }
            let next = group.map { max(0, min(valid.count - 1, $0 + (offset < 0 ? -1 : 1))) } ?? 0
            if valid.indices.contains(next) {
                selection = offset < 0 ? valid[next].entries.last : valid[next].entries.first
                jumpID = valid[next].id
            }
        }
    }

    func chooseFirst() {
        if let first = visibleGroups.first(where: { !foldedGroups.contains($0.id) })?.entries.first { selection = first }
    }

    func flagContaining() {
        flaggedFaces = Set(coverage.map(\.id))
        fontCollection = "Flagged"
    }

    func clearFlags() {
        flaggedFaces.removeAll()
        if fontCollection == "Flagged" { fontCollection = "All fonts" }
    }

    func swapComparison() {
        guard let alternative = comparisonFace, let current = selectedFace else { return }
        pickFace(alternative)
        comparisonFace = current
    }

    func clearSearch() {
        shapeTask?.cancel()
        computingMatches = false
        query = ""
        shapeMatches = nil
        refresh()
    }

    func reloadFonts() {
        let previous = selectedFace?.id
        library = FontLibrary()
        selectedFace = library.faces.first(where: { $0.id == previous }) ?? library.faces.first
        faceEntries.removeAll()
        installedCoverage = nil
        shapeIndex.removeAll()
        shapeTask?.cancel()
        shapeMatches = nil
        computingMatches = false
        makingShapeIndex = false
        shapeBuildTask?.cancel()
        shapeBuildTask = nil
        refresh()
        inspect()
    }

    func refresh() {
        workingTask?.cancel()
        let pendingQuery = query
        let active = scope
        let face = selectedFace
        let index = library
        let stored = preferences
        let layoutName = layout
        let matchingShapes = shapeMatches
        let base = entries
        let existingSymbols = symbols
        let catalog = catalog
        if base.isEmpty && pendingQuery.isEmpty && matchingShapes == nil {
            var first = [CharacterGroup]()
            if !stored.favorites.isEmpty { first.append(.init(id: "favorites", title: "Favorites", entries: stored.favorites)) }
            if !stored.recents.isEmpty { first.append(.init(id: "recents", title: "Recent characters", entries: stored.recents)) }
            visibleGroups = first
            return
        }
        let cacheKey = "\(face?.id ?? "")/\(active.rawValue)"
        let cachedFaceEntries = faceEntries[cacheKey]
        if !pendingQuery.isEmpty || matchingShapes != nil || visibleGroups.isEmpty { working = true }

        workingTask = Task {
            if !pendingQuery.isEmpty { try? await Task.sleep(nanoseconds: 70_000_000) }
            guard !Task.isCancelled else { return }
            let result = await Task.detached(priority: .userInitiated) {
                BrowseData.load(query: pendingQuery, shapeMatches: matchingShapes, scope: active, face: face,
                                layout: layoutName, preferences: stored, base: base, symbols: existingSymbols,
                                library: index, catalog: catalog, cachedFaceEntries: cachedFaceEntries)
            }.value
            guard !Task.isCancelled else { return }
            if let cached = result.faceEntries { faceEntries[cacheKey] = cached }
            if let new = result.symbols { symbols = new }
            if let new = result.union { installedCoverage = new }
            visibleGroups = result.groups
            working = false
            if !pendingQuery.isEmpty, let first = result.groups.first?.entries.first,
               result.groups.allSatisfy({ $0.entries.allSatisfy { $0.id != selection?.id } }) {
                selection = first
            }
        }
    }

    func rendering(_ entry: CharacterEntry) -> FontFace? {
        if let owner = entry.faceName { return library.faces.first { $0.id == owner } }
        guard let selectedFace else { return library.firstCovering(entry) }
        if library.covers(entry, in: library.support(for: selectedFace)) { return selectedFace }
        return coverage.first { library.covers(entry, in: library.support(for: $0)) }
            ?? library.firstCovering(entry)
    }

    func inspect() {
        coverageTask?.cancel()
        coverage = []
        keyboardEquivalent = nil
        coverageLoading = selection != nil
        guard let selection else { return }
        let library = library
        keyboardEquivalent = KeyboardMap.equivalent(for: selection)
        coverageTask = Task {
            let matches = await Task.detached(priority: .userInitiated) { library.covering(selection) }.value
            guard !Task.isCancelled else { return }
            coverage = matches
            coverageLoading = false
            if comparisonFace == nil || !matches.contains(where: { $0.id == comparisonFace?.id }) {
                comparisonFace = matches.first { $0.id != selectedFace?.id } ?? matches.first
            }
        }
    }

    func html(_ entry: CharacterEntry) -> String {
        catalog?.html(entry, style: preferences.htmlStyle) ?? entry.decimal
    }

    func preview(_ entry: CharacterEntry, format: InsertFormat) -> String {
        switch format {
        case .plain, .formatted: return entry.text
        case .html: return html(entry)
        case .swift: return entry.swift
        case .decimal: return entry.decimal
        case .hex: return entry.codes
        case .name: return entry.name
        case .description: return "\(entry.name) · \(entry.codes) · \(entry.block)"
        case .picture: return "\(insertPreference.imageSize) × \(insertPreference.imageSize) px"
        }
    }

    func payload(_ entry: CharacterEntry, format: InsertFormat) -> PastePayload? {
        if (format != .picture && format != .name && format != .description) && entry.scalars.isEmpty { return nil }
        switch format {
        case .formatted:
            let size = insertPreference.pointSize
            let face = rendering(entry)
            let font = face.flatMap { NSFont(name: $0.id, size: size) } ?? NSFont.systemFont(ofSize: size)
            let attributed = NSAttributedString(string: entry.text, attributes: [.font: font])
            let data = try? attributed.data(from: NSRange(location: 0, length: attributed.length),
                                           documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
            return PastePayload(text: entry.text, representations: data.map { [(.rtf, $0)] } ?? [])
        case .picture:
            guard let png = GlyphDrawing.image(entry, face: rendering(entry), pixels: insertPreference.imageSize) else { return nil }
            let tiff = NSBitmapImageRep(data: png)?.tiffRepresentation
            return PastePayload(representations: [(.png, png)] + (tiff.map { [(.tiff, $0)] } ?? []))
        default:
            return PastePayload(text: preview(entry, format: format))
        }
    }

    func insert(_ entry: CharacterEntry) {
        guard let payload = payload(entry, format: insertPreference.format) else {
            message = "This glyph has no text mapping. Choose Picture or Name."
            return
        }
        let destination = target
        Task {
            let result = await insertion.insert(payload, into: destination) {
                if !preferences.keepPaletteOpen { dismissForInsert?() }
            }
            switch result {
            case .posted:
                preferences.recents.removeAll { $0.id == entry.id }
                preferences.recents.insert(entry, at: 0)
                preferences.recents = Array(preferences.recents.prefix(preferences.recentLimit))
                refresh()
            case .copyRequired(let reason):
                message = reason
            }
        }
    }

    func copy(_ entry: CharacterEntry, format: InsertFormat = .plain) {
        guard let payload = payload(entry, format: format), payload.write(to: .general) else {
            message = "This format is unavailable for the selection."
            return
        }
        message = "Copied \(format.rawValue.lowercased())."
    }

    func copyText(_ content: String) {
        guard !content.isEmpty else { return }
        _ = PastePayload(text: content).write(to: .general)
        message = "Copied to the clipboard."
    }

    func copyGraphic(_ entry: CharacterEntry, pdf: Bool) {
        let face = rendering(entry)
        let size = insertPreference.imageSize
        let data = pdf ? GlyphDrawing.pdf(entry, face: face, points: size) : GlyphDrawing.image(entry, face: face, pixels: size)
        if let data, PastePayload(representations: [(pdf ? .pdf : .png, data)]).write(to: .general) {
            message = pdf ? "Copied PDF." : "Copied PNG."
        } else {
            message = "The character could not be rendered for copying."
        }
    }

    func searchSketch(_ strokes: [Stroke]) {
        searchShapes(ShapeSample(strokes: strokes))
    }

    func findSimilar() {
        guard let selection, let face = renderedFace else { return }
        searchShapes(ShapeIndex.sample(for: selection, face: face), excluding: selection.id)
    }

    func loadLayout(_ document: LayoutDocument) throws {
        _ = try LayoutProgram(document.contents)
        guard !standardLayouts.contains(document.name),
              !preferences.layouts.contains(where: { $0.name == document.name && $0.id != document.id }) else {
            throw LayoutError(line: 1, message: "A layout with this name already exists.")
        }
        if let index = preferences.layouts.firstIndex(where: { $0.id == document.id }) {
            let oldName = preferences.layouts[index].name
            preferences.layouts[index] = document
            if oldName != document.name {
                if preferences.globalLayout == oldName { preferences.globalLayout = document.name }
                for key in Array(preferences.faceLayouts.keys) where preferences.faceLayouts[key] == oldName {
                    preferences.faceLayouts[key] = document.name
                }
            }
        } else {
            preferences.layouts.append(document)
        }
        pickLayout(document.name)
    }

    func favoritesData() throws -> Data {
        try JSONEncoder().encode(FavoritesArchive(version: 1, entries: preferences.favorites,
                                                  aliases: preferences.aliases))
    }

    func readFavorites(_ data: Data) throws {
        let imported = try JSONDecoder().decode(FavoritesArchive.self, from: data)
        guard imported.version == 1 else { throw CocoaError(.fileReadUnknown) }
        guard imported.entries.allSatisfy({ $0.scalars.allSatisfy { Unicode.Scalar($0) != nil } }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var existing = Set(preferences.favorites.map(\.id))
        preferences.favorites += imported.entries.filter { existing.insert($0.id).inserted }
        preferences.aliases.merge(imported.aliases) { current, _ in current }
        refresh()
    }

    private func searchShapes(_ queryShape: ShapeSample?, excluding: String? = nil) {
        guard let queryShape else { message = "There is no renderable shape to search."; return }
        shapeTask?.cancel()
        computingMatches = true
        let library = library
        let preferred = selectedFace
        let catalog = catalog
        let base = entries
        let searchScope = scope
        let faceOnly = searchScope == .face || searchScope == .glyphs
        let key = faceOnly ? "\(searchScope.rawValue)/\(preferred?.id ?? "")" : "Installed fonts"
        if shapeIndexKey != key {
            shapeBuildTask?.cancel()
            shapeBuildTask = nil
            shapeIndex = []
            shapeIndexKey = key
        }
        if shapeIndex.isEmpty && shapeBuildTask == nil {
            makingShapeIndex = true
            shapeBuildTask = Task.detached(priority: .userInitiated) {
                let values = base.isEmpty ? catalog?.all() ?? [] : base
                if faceOnly, let preferred {
                    let faceEntries = library.entriesForFace(preferred, catalogEntries: values,
                                                              allGlyphs: searchScope == .glyphs)
                    return ShapeIndex.build(entries: faceEntries, fonts: library, preferred: preferred,
                                            selectedFaceOnly: true)
                }
                let union = library.unionCoverage()
                let installed = values.filter { value in
                    guard value.category != "Cc", value.category != "Cf", let code = value.scalars.first,
                          let scalar = Unicode.Scalar(code) else { return false }
                    return union.contains(scalar)
                }
                return ShapeIndex.build(entries: installed, fonts: library, preferred: preferred)
            }
        }
        shapeTask = Task {
            if let work = shapeBuildTask {
                let value = await work.value
                guard !Task.isCancelled else { return }
                shapeIndex = value
                shapeBuildTask = nil
                makingShapeIndex = false
            }
            let templates = shapeIndex
            let result = await Task.detached(priority: .userInitiated) {
                ShapeIndex.matches(queryShape, index: templates, excluding: excluding)
            }.value
            guard !Task.isCancelled else { return }
            query = ""
            shapeMatches = result
            computingMatches = false
            refresh()
        }
    }

    private func queryResultCloseIfNeeded() {
        if jumpID != nil { jumpID = nil }
    }

    private func scheduleSave() {
        preferenceTask?.cancel()
        preferenceTask = Task {
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            saveImmediately()
        }
    }

    func saveImmediately() {
        guard canPersistPreferences else { return }
        do { try preferences.save() }
        catch { message = "Settings could not be saved. \(error.localizedDescription)" }
    }
}
