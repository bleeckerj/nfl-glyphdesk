import AppKit
import CoreText

struct FontFace: Identifiable, Hashable, Sendable {
    let id: String
    let family: String
    let style: String
    let title: String

    func font(size: CGFloat) -> CTFont { CTFontCreateWithName(id as CFString, size, nil) }
}

struct FontCollection: Identifiable {
    let name: String
    let members: Set<String>
    var id: String { name }
}

final class FontLibrary: @unchecked Sendable {
    struct FaceSupport {
        let face: FontFace
        let font: CTFont
        let coverage: CharacterSet
    }

    let faces: [FontFace]
    let groups: [FontCollection]
    private let descriptorsByName: [String: [CTFontDescriptor]]
    private let coverageLock = NSLock()
    private var allSupports: [FaceSupport]?
    private var combinedCoverage: CharacterSet?

    init() {
        let collection = CTFontCollectionCreateFromAvailableFonts(nil)
        let descriptors = CTFontCollectionCreateMatchingFontDescriptors(collection) as? [CTFontDescriptor] ?? []
        var available: [String: [CTFontDescriptor]] = [:]
        var seen: Set<String> = []
        faces = descriptors.compactMap { descriptor -> FontFace? in
            let font = CTFontCreateWithFontDescriptor(descriptor, 14, nil)
            let name = CTFontCopyPostScriptName(font) as String
            guard !name.isEmpty else { return nil }
            available[name, default: []].append(descriptor)
            guard seen.insert(name).inserted else { return nil }
            return FontFace(id: name, family: CTFontCopyFamilyName(font) as String,
                            style: (CTFontCopyName(font, kCTFontStyleNameKey) as String?) ?? "Regular",
                            title: CTFontCopyDisplayName(font) as String)
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        descriptorsByName = available

        groups = NSFontCollection.allFontCollectionNames.compactMap { name in
            guard let collection = NSFontCollection(name: name) else { return nil }
            let members = Set((collection.matchingDescriptors ?? []).compactMap(\.postscriptName))
            return FontCollection(name: name.rawValue, members: members)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var familyCount: Int { Set(faces.map(\.family)).count }

    func installedFonts(named postScriptName: String, size: CGFloat) -> [CTFont] {
        (descriptorsByName[postScriptName] ?? []).map { CTFontCreateWithFontDescriptor($0, size, nil) }
    }

    func support(for face: FontFace) -> FaceSupport {
        let font = face.font(size: 24)
        return FaceSupport(face: face, font: font, coverage: CTFontCopyCharacterSet(font) as CharacterSet)
    }

    func supports() -> [FaceSupport] {
        coverageLock.lock()
        defer { coverageLock.unlock() }
        if let allSupports { return allSupports }
        let value = faces.map(support)
        allSupports = value
        return value
    }

    func unionCoverage() -> CharacterSet {
        let all = supports()
        coverageLock.lock()
        defer { coverageLock.unlock() }
        if let combinedCoverage { return combinedCoverage }
        let result = all.reduce(into: CharacterSet()) { $0.formUnion($1.coverage) }
        combinedCoverage = result
        return result
    }

    func covers(_ entry: CharacterEntry, in support: FaceSupport) -> Bool {
        if let owningFace = entry.faceName, owningFace == support.face.id { return true }
        if entry.symbolName != nil || entry.isPrivateUse { return false }
        guard let first = entry.scalars.first, let scalar = Unicode.Scalar(first),
              support.coverage.contains(scalar) else { return false }
        if entry.scalars.count == 1 { return true }
        if entry.category == "Variant" {
            return FontTableReader(support.font).variationSupports(entry.scalars)
        }
        let font = support.font
        let text = NSAttributedString(string: entry.text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font
        ])
        let line = CTLineCreateWithAttributedString(text)
        let runs = CTLineGetGlyphRuns(line) as NSArray as? [CTRun] ?? []
        guard !runs.isEmpty, runs.allSatisfy({ run in
            let attributes = CTRunGetAttributes(run) as NSDictionary
            guard let runFont = attributes[kCTFontAttributeName] else { return false }
            return (CTFontCopyPostScriptName(runFont as! CTFont) as String) == support.face.id
                && glyphs(in: run).allSatisfy { $0 != 0 }
        }) else { return false }
        return !["Emoji", "Ligature"].contains(entry.category) || runs.reduce(0) { $0 + CTRunGetGlyphCount($1) } == 1
    }

    func covering(_ entry: CharacterEntry) -> [FontFace] {
        if entry.symbolName != nil { return [] }
        return supports().filter { covers(entry, in: $0) }.map(\.face)
    }

    func firstCovering(_ entry: CharacterEntry) -> FontFace? {
        supports().first { covers(entry, in: $0) }?.face
    }

    func isInstalled(_ entry: CharacterEntry, union: CharacterSet) -> Bool {
        if entry.symbolName != nil { return true }
        guard let code = entry.scalars.first, let scalar = Unicode.Scalar(code),
              union.contains(scalar) else { return false }
        return entry.scalars.count == 1 || firstCovering(entry) != nil
    }

    func entriesForFace(_ face: FontFace, catalogEntries: [CharacterEntry],
                        allGlyphs: Bool) -> [CharacterEntry] {
        let support = support(for: face)
        let parser = FontTableReader(support.font)
        var result: [CharacterEntry] = []
        var byGlyph: [CGGlyph: CharacterEntry] = [:]
        for entry in catalogEntries where covers(entry, in: support) {
            if entry.scalars.count == 1, let glyph = directGlyph(entry.text, in: support.font), byGlyph[glyph] == nil {
                byGlyph[glyph] = entry
            }
            if !allGlyphs { result.append(entry) }
        }
        let privateRanges = [0xE000...0xF8FF, 0xF0000...0xFFFFD, 0x100000...0x10FFFD]
        for interval in privateRanges {
            for cp in interval {
                guard let scalar = Unicode.Scalar(cp), support.coverage.contains(scalar),
                      let glyph = directGlyph(String(scalar), in: support.font) else { continue }
                let label = glyphName(glyph, in: support.font) ?? String(format: "Private use U+%04X", cp)
                let entry = CharacterEntry(scalars: [UInt32(cp)], name: label, block: "Private Use", script: "Private Use",
                                           category: "Co", faceName: face.id, glyphID: glyph)
                byGlyph[glyph] = entry
                if !allGlyphs { result.append(entry) }
            }
        }

        let ligatures = parser.ligatures().compactMap { substitution -> CharacterEntry? in
            let parts = substitution.inputs.compactMap { byGlyph[$0] }
            guard parts.count == substitution.inputs.count else { return nil }
            let scalars = parts.flatMap(\.scalars)
            return CharacterEntry(scalars: scalars, name: parts.map(\.text).joined() + " ligature",
                                  block: "Ligatures", script: parts.first?.script ?? "", category: "Ligature",
                                  faceName: face.id, glyphID: substitution.output)
        }
        if allGlyphs {
            let ligatureMap = Dictionary(ligatures.compactMap { entry in entry.glyphID.map { ($0, entry) } },
                                         uniquingKeysWith: { first, _ in first })
            return (0..<min(CTFontGetGlyphCount(support.font), 65536)).map { index in
                let glyph = CGGlyph(index)
                if let ligature = ligatureMap[glyph] { return ligature }
                let mapped = byGlyph[glyph]
                return CharacterEntry(scalars: mapped?.scalars ?? [],
                                      name: mapped?.name ?? glyphName(glyph, in: support.font) ?? "Glyph \(index)",
                                      block: "Glyph indexes", script: mapped?.script ?? "", category: mapped?.category ?? "Unencoded",
                                      faceName: face.id, glyphID: glyph)
            }
        }
        return result + ligatures
    }

    func metadata(for face: FontFace) -> [FontField] {
        let font = face.font(size: 18)
        let graphicsFont = CTFontCopyGraphicsFont(font, nil)
        let parser = FontTableReader(font)
        func value(_ key: CFString) -> String? { CTFontCopyName(font, key) as String? }
        func metric(_ value: CGFloat) -> String {
            String(Int((value * CGFloat(CTFontGetUnitsPerEm(font)) / CTFontGetSize(font)).rounded()))
        }
        let attribute = CTFontCopyAttribute(font, kCTFontFormatAttribute) as? NSNumber
        let formats = [1: "OpenType (PostScript)", 2: "OpenType (TrueType)", 3: "TrueType", 4: "PostScript", 5: "Bitmap"]
        let unicodeCount = parser.unicodeCount()
        let languages = (CTFontCopySupportedLanguages(font) as? [String] ?? []).map {
            Locale.current.localizedString(forIdentifier: $0) ?? $0
        }.joined(separator: ", ")
        let entries: [(String, String?)] = [
            ("Name", face.title), ("PostScript", face.id), ("Family", face.family), ("Style", face.style),
            ("Unique Name", value(kCTFontUniqueNameKey)), ("Format", attribute.flatMap { formats[$0.intValue] }),
            ("Version", value(kCTFontVersionNameKey)), ("Description", value(kCTFontDescriptionNameKey)),
            ("Foundry", value(kCTFontManufacturerNameKey)), ("Designer", value(kCTFontDesignerNameKey)),
            ("Copyright", value(kCTFontCopyrightNameKey)), ("Trademark", value(kCTFontTrademarkNameKey)),
            ("Foundry Site", value(kCTFontVendorURLNameKey)), ("Designer Site", value(kCTFontDesignerURLNameKey)),
            ("License URL", value(kCTFontLicenseURLNameKey)), ("Units per em", String(CTFontGetUnitsPerEm(font))),
            ("Ascender", metric(CTFontGetAscent(font))), ("Descender", metric(-CTFontGetDescent(font))),
            ("Cap height", metric(CTFontGetCapHeight(font))), ("x-height", metric(CTFontGetXHeight(font))),
            ("Glyphs", String(graphicsFont.numberOfGlyphs)), ("Unicode Characters", unicodeCount.map(String.init)),
            ("File", (CTFontCopyAttribute(font, kCTFontURLAttribute) as? URL)?.path),
            ("Ligatures", String(Set(parser.ligatures().map(\.output)).count)), ("Languages", languages)
        ]
        return entries.map { FontField(name: $0.0, value: $0.1.flatMap { $0.isEmpty ? nil : $0 }) }
    }
}

struct FontField: Identifiable {
    let name: String
    let value: String?
    var id: String { name }
}

func directGlyph(_ text: String, in font: CTFont) -> CGGlyph? {
    let units = Array(text.utf16)
    guard !units.isEmpty else { return nil }
    var output = [CGGlyph](repeating: 0, count: units.count)
    _ = CTFontGetGlyphsForCharacters(font, units, &output, units.count)
    return output.first.flatMap { $0 == 0 ? nil : $0 }
}

private func glyphs(in run: CTRun) -> [CGGlyph] {
    let count = CTRunGetGlyphCount(run)
    var output = [CGGlyph](repeating: 0, count: count)
    if count > 0 { CTRunGetGlyphs(run, CFRange(location: 0, length: count), &output) }
    return output
}

func glyphName(_ glyph: CGGlyph, in font: CTFont) -> String? {
    CTFontCopyGraphicsFont(font, nil).name(for: glyph) as String?
}
