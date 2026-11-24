import CoreGraphics
import CoreText
import Foundation

struct Stroke: Identifiable {
    var id = UUID()
    var points: [CGPoint]
}

struct ShapeSample: Codable {
    var positions: [UInt16]
    var aspect: Float
    var componentCount: Int

    static let dimension = 24
    private static let length = dimension * dimension

    init?(path: CGPath, fill: Bool) {
        let bounds = path.boundingBoxOfPath
        guard !bounds.isNull, !bounds.isInfinite, bounds.width >= 0, bounds.height >= 0 else { return nil }
        let maxSide = max(bounds.width, bounds.height, 1)
        let side = Self.dimension
        let scale = CGFloat(side - 4) / maxSide
        let dx = (CGFloat(side) - bounds.width * scale) / 2 - bounds.minX * scale
        let dy = (CGFloat(side) - bounds.height * scale) / 2 - bounds.minY * scale
        var raster = [UInt8](repeating: 0, count: Self.length)
        let recorded = raster.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                          bytesPerRow: side, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0)
            else { return false }
            context.setFillColor(gray: 1, alpha: 1)
            context.setStrokeColor(gray: 1, alpha: 1)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.setLineWidth(1.5)
            var transform = CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: dx, ty: dy)
            guard let fitted = path.copy(using: &transform) else { return false }
            context.addPath(fitted)
            if fill { context.fillPath() } else { context.strokePath() }
            return true
        }
        guard recorded else { return nil }
        let pixels = raster.indices.filter { raster[$0] > 75 }
        guard !pixels.isEmpty else { return nil }
        positions = pixels.map(UInt16.init)
        aspect = Float((bounds.width + maxSide * 0.08) / (bounds.height + maxSide * 0.08))
        componentCount = Self.components(pixels)
    }

    init?(line: CTLine) {
        let inkBounds = CTLineGetImageBounds(line, nil)
        let bounds = inkBounds.isEmpty ? CTLineGetBoundsWithOptions(line, []) : inkBounds
        guard !bounds.isNull, !bounds.isInfinite, !bounds.isEmpty else { return nil }
        let side = Self.dimension
        let maxSide = max(bounds.width, bounds.height)
        let scale = CGFloat(side - 4) / maxSide
        let x = (CGFloat(side) - bounds.width * scale) / 2 - bounds.minX * scale
        let y = (CGFloat(side) - bounds.height * scale) / 2 - bounds.minY * scale
        var raster = [UInt8](repeating: 0, count: Self.length * 4)
        let recorded = raster.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                          bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                                              | CGBitmapInfo.byteOrder32Big.rawValue)
            else { return false }
            context.translateBy(x: x, y: y)
            context.scaleBy(x: scale, y: scale)
            context.textMatrix = .identity
            context.textPosition = .zero
            CTLineDraw(line, context)
            return true
        }
        guard recorded else { return nil }
        let pixels = (0..<Self.length).filter { raster[$0 * 4 + 3] > 75 }
        guard !pixels.isEmpty else { return nil }
        positions = pixels.map(UInt16.init)
        aspect = Float((bounds.width + maxSide * 0.08) / (bounds.height + maxSide * 0.08))
        componentCount = Self.components(pixels)
    }

    init?(strokes: [Stroke]) {
        let path = CGMutablePath()
        for stroke in strokes {
            guard let first = stroke.points.first else { continue }
            let start = CGPoint(x: first.x, y: -first.y)
            path.move(to: start)
            for point in stroke.points.dropFirst() {
                path.addLine(to: CGPoint(x: point.x, y: -point.y))
            }
            if stroke.points.count == 1 {
                path.addLine(to: CGPoint(x: start.x + 0.25, y: start.y + 0.25))
            }
        }
        self.init(path: path, fill: false)
    }

    func distances() -> [UInt8] {
        let side = Self.dimension
        var all = [UInt8](repeating: 100, count: Self.length)
        for index in positions { all[Int(index)] = 0 }
        for index in all.indices {
            let above = index >= side ? all[index - side] + 1 : 100
            let left = index % side > 0 ? all[index - 1] + 1 : 100
            all[index] = min(all[index], above, left)
        }
        for index in all.indices.reversed() {
            let below = index + side < all.count ? all[index + side] + 1 : 100
            let right = index % side < side - 1 ? all[index + 1] + 1 : 100
            all[index] = min(all[index], below, right)
        }
        return all
    }

    func distance(to other: ShapeSample, queryDistances: [UInt8], limit: Float) -> Float {
        let shape = abs(log(aspect / other.aspect)) * 1.6
            + Float(abs(componentCount - other.componentCount)) * 0.42
        guard shape < limit else { return shape }
        let forward = other.positions.reduce(0) { $0 + Int(queryDistances[Int($1)]) }
        let mean = Float(forward) / Float(other.positions.count)
        guard shape + mean < limit else { return shape + mean }
        let otherDistances = other.distances()
        let reverse = positions.reduce(0) { $0 + Int(otherDistances[Int($1)]) }
        return shape + mean + Float(reverse) / Float(positions.count)
    }

    private static func components(_ pixels: [Int]) -> Int {
        let side = dimension
        var remaining = Set(pixels)
        var count = 0
        while let first = remaining.popFirst() {
            var pending = [first]
            while let item = pending.popLast() {
                let x = item % side
                for next in [x > 0 ? item - 1 : -1, x < side - 1 ? item + 1 : -1, item - side, item + side]
                    where remaining.remove(next) != nil {
                    pending.append(next)
                }
            }
            count += 1
        }
        return count
    }
}

struct IndexedShape {
    let entry: CharacterEntry
    let sample: ShapeSample
}

enum ShapeIndex {
    static func sample(for entry: CharacterEntry, face: FontFace) -> ShapeSample? {
        sample(for: entry, font: face.font(size: 64))
    }

    static func build(entries: [CharacterEntry], fonts: FontLibrary, preferred: FontFace?,
                      selectedFaceOnly: Bool = false) -> [IndexedShape] {
        let preferredSupport = preferred.map(fonts.support)
        let support = selectedFaceOnly ? [] : fonts.supports()
        let fontsForSearch = (preferredSupport.map { [$0] } ?? []) + support
        var result: [IndexedShape] = []
        result.reserveCapacity(min(entries.count, 80_000))
        let ordered = entries.sorted {
            let first = $0.scalars.first ?? 0x110000
            let other = $1.scalars.first ?? 0x110000
            let firstPriority = (0x2000...0x2BFF).contains(first) || first < 0x0250
            let otherPriority = (0x2000...0x2BFF).contains(other) || other < 0x0250
            return firstPriority == otherPriority ? first < other : firstPriority
        }
        for entry in ordered {
            if Task.isCancelled { return [] }
            var used: Set<String> = []
            var added = 0
            let cap = entry.block == "Basic Latin" || entry.category.hasPrefix("S") ? 2 : 1
            for candidate in fontsForSearch where used.insert(candidate.face.id).inserted {
                guard fonts.covers(entry, in: candidate), let sample = sample(for: entry, font: candidate.font) else { continue }
                result.append(IndexedShape(entry: entry, sample: sample))
                added += 1
                if added >= cap { break }
            }
        }
        return result
    }

    static func matches(_ query: ShapeSample, index: [IndexedShape], excluding: String? = nil, count: Int = 40) -> [CharacterEntry] {
        let distances = query.distances()
        var samples: [(Float, CharacterEntry)] = []
        for item in index where item.entry.id != excluding {
            let threshold = samples.count >= count ? samples.last!.0 : .greatestFiniteMagnitude
            let distance = query.distance(to: item.sample, queryDistances: distances, limit: threshold)
            guard distance < threshold else { continue }
            if let previous = samples.firstIndex(where: { $0.1.id == item.entry.id }) {
                if samples[previous].0 <= distance { continue }
                samples.remove(at: previous)
            }
            let position = samples.firstIndex { $0.0 > distance } ?? samples.endIndex
            samples.insert((distance, item.entry), at: position)
            if samples.count > count { samples.removeLast() }
        }
        return samples.map(\.1)
    }

    private static func sample(for entry: CharacterEntry, font: CTFont) -> ShapeSample? {
        if let glyph = entry.glyphID, entry.faceName == CTFontCopyPostScriptName(font) as String,
           let path = CTFontCreatePathForGlyph(font, glyph, nil) {
            return ShapeSample(path: path, fill: true)
        }
        if entry.scalars.count == 1, let glyph = directGlyph(entry.text, in: font),
           let path = CTFontCreatePathForGlyph(font, glyph, nil) {
            return ShapeSample(path: path, fill: true)
        }
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: entry.text, attributes:
            [NSAttributedString.Key(kCTFontAttributeName as String): font]))
        let path = CGMutablePath()
        let runs = CTLineGetGlyphRuns(line) as NSArray as? [CTRun] ?? []
        for run in runs {
            let count = CTRunGetGlyphCount(run)
            guard count > 0 else { continue }
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)
            for (glyph, position) in zip(glyphs, positions) {
                var transform = CGAffineTransform(translationX: position.x, y: position.y)
                if let piece = CTFontCreatePathForGlyph(font, glyph, &transform) { path.addPath(piece) }
            }
        }
        return path.isEmpty ? ShapeSample(line: line) : ShapeSample(path: path, fill: true)
    }
}
