import CoreText
import Foundation

struct ReviewCoverage: Sendable {
    enum State: String, Sendable {
        case native = "Native"
        case fallback = "Fallback"
        case missing = "Missing"

        var highlightColor: CGColor {
            switch self {
            case .native: return CGColor(gray: 0, alpha: 0)
            case .fallback: return CGColor(red: 0.20, green: 0.52, blue: 0.84, alpha: 0.28)
            case .missing: return CGColor(red: 0.89, green: 0.25, blue: 0.47, alpha: 0.32)
            }
        }
    }

    struct FallbackFace: Hashable, Sendable {
        let name: String
        let postScriptName: String

        var label: String { name == postScriptName ? name : "\(name) (\(postScriptName))" }
    }

    struct Issue: Identifiable, Sendable {
        let range: Range<Int>
        let text: String
        let state: State
        let fallbackFaces: [FallbackFace]
        var id: Int { range.lowerBound }
    }

    struct Highlight: Sendable {
        let rect: CGRect
        let state: State
    }

    let native: Int
    let fallback: Int
    let missing: Int
    let issues: [Issue]
    let highlights: [Int: [Highlight]]

    var isAllNative: Bool { fallback == 0 && missing == 0 }

    private struct Cluster {
        let range: Range<Int>
        var painted = false
        var missing = false
        var fallbackFaces: Set<FallbackFace> = []

        var state: State {
            if missing || !painted { return .missing }
            return fallbackFaces.isEmpty ? .native : .fallback
        }
    }

    private struct Painting {
        let line: Int
        let clusters: Range<Int>
        let rect: CGRect
    }

    init(layout: ReviewSpecimen, font: CTFont) {
        var clusters: [Cluster] = []
        var cursor = 0
        for character in layout.text {
            let end = cursor + character.utf16.count
            if character.unicodeScalars.contains(where: Self.isVisible) {
                clusters.append(Cluster(range: cursor..<end))
            }
            cursor = end
        }
        let postScriptName = CTFontCopyPostScriptName(font) as String
        let source = FontReviewFonts.sourceURL(of: font)
        var paintings: [Painting] = []
        for (index, line) in layout.lines.enumerated() {
            let runs = CTLineGetGlyphRuns(line.value) as NSArray as? [CTRun] ?? []
            for run in runs {
                let attributes = CTRunGetAttributes(run) as NSDictionary
                let runFont = (attributes[kCTFontAttributeName] as! CTFont?) ?? font
                let name = CTFontCopyPostScriptName(runFont) as String
                let isLastResort = name.trimmingCharacters(in: CharacterSet(charactersIn: "."))
                    .lowercased().hasPrefix("lastresort")
                let isNative = name == postScriptName && FontReviewFonts.sourceURL(of: runFont) == source
                let substitute = isNative || isLastResort ? nil : FallbackFace(
                    name: CTFontCopyDisplayName(runFont) as String, postScriptName: name)
                for glyph in Self.glyphs(in: run) {
                    let first = Self.firstCluster(endingAfter: glyph.range.lowerBound, in: clusters)
                    var end = first
                    while end < clusters.count && clusters[end].range.lowerBound < glyph.range.upperBound {
                        clusters[end].painted = true
                        if glyph.id == 0 || isLastResort {
                            clusters[end].missing = true
                        } else if let substitute {
                            clusters[end].fallbackFaces.insert(substitute)
                        }
                        end += 1
                    }
                    if first < end {
                        let x = line.origin.x + glyph.position.x + min(glyph.advance, 0)
                        let rect = CGRect(x: x, y: line.bottom, width: max(3, abs(glyph.advance)),
                                          height: line.ascent + line.descent)
                        paintings.append(Painting(line: index, clusters: first..<end, rect: rect))
                    }
                }
            }
        }
        let sourceText = layout.text as NSString
        let issues = clusters.compactMap { cluster -> Issue? in
            let state = cluster.state
            guard state != .native else { return nil }
            let range = NSRange(location: cluster.range.lowerBound, length: cluster.range.count)
            return Issue(range: cluster.range, text: sourceText.substring(with: range), state: state,
                         fallbackFaces: cluster.fallbackFaces.sorted { $0.label < $1.label })
        }
        self.issues = issues
        native = clusters.count - issues.count
        fallback = issues.lazy.filter { $0.state == .fallback }.count
        missing = issues.count - fallback
        var highlights: [Int: [Highlight]] = [:]
        for paint in paintings {
            let span = clusters[paint.clusters]
            if span.contains(where: { $0.state == .missing }) {
                highlights[paint.line, default: []].append(Highlight(rect: paint.rect, state: .missing))
            } else if span.contains(where: { $0.state == .fallback }) {
                highlights[paint.line, default: []].append(Highlight(rect: paint.rect, state: .fallback))
            }
        }
        self.highlights = highlights
    }

    private static func isVisible(_ scalar: Unicode.Scalar) -> Bool {
        !scalar.properties.isWhitespace && !scalar.properties.isDefaultIgnorableCodePoint
            && scalar.properties.generalCategory != .control && scalar.properties.generalCategory != .format
    }

    private static func firstCluster(endingAfter offset: Int, in clusters: [Cluster]) -> Int {
        var lower = 0
        var upper = clusters.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if clusters[middle].range.upperBound <= offset { lower = middle + 1 } else { upper = middle }
        }
        return lower
    }

    private struct Glyph {
        let id: CGGlyph
        let range: Range<Int>
        let position: CGPoint
        let advance: CGFloat
    }

    private static func glyphs(in run: CTRun) -> [Glyph] {
        let count = CTRunGetGlyphCount(run)
        let runRange = CTRunGetStringRange(run)
        guard count > 0, runRange.location >= 0, runRange.length > 0 else { return [] }
        let runEnd = runRange.location + runRange.length
        var indices = [CFIndex](repeating: 0, count: count)
        var glyphs = [CGGlyph](repeating: 0, count: count)
        var positions = [CGPoint](repeating: .zero, count: count)
        var advances = [CGSize](repeating: .zero, count: count)
        let all = CFRange(location: 0, length: 0)
        CTRunGetStringIndices(run, all, &indices)
        CTRunGetGlyphs(run, all, &glyphs)
        CTRunGetPositions(run, all, &positions)
        CTRunGetAdvances(run, all, &advances)
        // Glyph order can be right-to-left. Use logical offsets to cover ligatures and combining marks.
        let offsets = Set(indices.filter { runRange.location <= $0 && $0 < runEnd }).sorted()
        let ends = Dictionary(uniqueKeysWithValues: zip(offsets, offsets.dropFirst() + [runEnd]))
        return indices.indices.compactMap { index in
            guard let end = ends[indices[index]] else { return nil }
            return Glyph(id: glyphs[index], range: indices[index]..<end, position: positions[index],
                         advance: advances[index].width)
        }
    }
}
