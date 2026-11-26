import CoreText
import Foundation

struct FontTableReader {
    struct Ligature: Hashable {
        let inputs: [CGGlyph]
        let output: CGGlyph
    }

    let font: CTFont
    init(_ font: CTFont) { self.font = font }

    func featureTags() -> Set<String> {
        var tags: Set<String> = []
        for tag: UInt32 in [0x47535542, 0x47504F53] {
            guard let data = table(tag), let start = data.word(6), start > 0,
                  let count = data.word(start) else { continue }
            let first = start + 2
            for index in 0..<min(count, max(0, (data.bytes.count - first) / 6)) {
                let position = first + index * 6
                let tag = data.bytes[position..<(position + 4)]
                if let value = String(bytes: tag, encoding: .ascii) { tags.insert(value) }
            }
        }
        return tags
    }

    func ligatures() -> [Ligature] {
        guard let data = table(0x47535542),
              let start = data.word(8) else { return [] }
        var found: Set<Ligature> = []
        for lookup in data.offsets(start, countAt: start, first: start + 2) {
            guard let kind = data.word(lookup), kind == 4 || kind == 7 else { continue }
            for sub in data.offsets(lookup, countAt: lookup + 4, first: lookup + 6) {
                let offset: Int
                if kind == 7 {
                    guard data.word(sub + 2) == 4, let extensionOffset = data.long(sub + 4) else { continue }
                    offset = sub + extensionOffset
                } else {
                    offset = sub
                }
                guard data.word(offset) == 1, let relative = data.word(offset + 2) else { continue }
                let covered = coverageList(data, start: offset + relative)
                let sets = data.offsets(offset, countAt: offset + 4, first: offset + 6)
                for (first, set) in zip(covered, sets) {
                    for record in data.offsets(set, countAt: set, first: set + 2) {
                        guard let output = data.word(record), let count = data.word(record + 2), (2...64).contains(count) else { continue }
                        let tail = (0..<(count - 1)).compactMap { data.word(record + 4 + $0 * 2).map(CGGlyph.init) }
                        if tail.count == count - 1 {
                            found.insert(Ligature(inputs: [first] + tail, output: CGGlyph(output)))
                        }
                    }
                }
            }
        }
        return found.sorted { ($0.output, $0.inputs.map(String.init).joined(separator: ".")) < ($1.output, $1.inputs.map(String.init).joined(separator: ".")) }
    }

    func variationSupports(_ scalars: [UInt32]) -> Bool {
        guard scalars.count == 2,
              let cmap = table(0x636D6170),
              let count = cmap.word(2) else { return false }
        for index in 0..<min(count, 512) {
            let record = 4 + index * 8
            guard let offset = cmap.long(record + 4), cmap.word(offset) == 14,
                  let number = cmap.long(offset + 6) else { continue }
            for item in 0..<min(number, 4096) {
                let selector = offset + 10 + item * 11
                guard cmap.triple(selector) == Int(scalars[1]) else { continue }
                for (field, stride) in [(3, 4), (7, 5)] {
                    guard let relative = cmap.long(selector + field), relative > 0,
                          let count = cmap.long(offset + relative) else { continue }
                    let first = offset + relative + 4
                    for match in 0..<min(count, 65_536) {
                        let position = first + match * stride
                        guard let base = cmap.triple(position) else { break }
                        let extensionLength = stride == 4 ? cmap.byte(position + 3) ?? 0 : 0
                        if (base...(base + extensionLength)).contains(Int(scalars[0])) { return true }
                    }
                }
            }
        }
        return false
    }

    func unicodeCount() -> Int? {
        guard let cmap = table(0x636D6170), let count = cmap.word(2) else { return nil }
        var longCount: Int?
        var bmpCount: Int?
        for index in 0..<min(count, 512) {
            let record = 4 + index * 8
            guard let platform = cmap.word(record), let encoding = cmap.word(record + 2),
                  platform == 0 || (platform == 3 && encoding != 0),
                  let offset = cmap.long(record + 4) else { continue }
            if [12, 13].contains(cmap.word(offset) ?? -1), let groups = cmap.long(offset + 12) {
                var total = 0
                for group in 0..<min(groups, 200_000) {
                    let position = offset + 16 + group * 12
                    guard let first = cmap.long(position), let last = cmap.long(position + 4),
                          first <= last, last <= 0x10FFFF else { break }
                    total += last - first + 1
                }
                longCount = max(longCount ?? 0, total)
            }
            if cmap.word(offset) == 4, let segments = cmap.word(offset + 6).map({ $0 / 2 }) {
                var total = 0
                for index in 0..<segments {
                    guard let last = cmap.word(offset + 14 + index * 2),
                          let first = cmap.word(offset + 16 + segments * 2 + index * 2),
                          last >= first, last != 65535 else { continue }
                    total += last - first + 1
                }
                bmpCount = max(bmpCount ?? 0, total)
            }
        }
        return longCount ?? bmpCount
    }

    private func table(_ tag: UInt32) -> FontBytes? {
        guard let data = CTFontCopyTable(font, tag, []) else { return nil }
        return FontBytes(bytes: Array(data as Data))
    }

    private func coverageList(_ data: FontBytes, start: Int) -> [CGGlyph] {
        guard let format = data.word(start), let count = data.word(start + 2) else { return [] }
        if format == 1 {
            return (0..<count).compactMap { data.word(start + 4 + $0 * 2).map(CGGlyph.init) }
        }
        guard format == 2 else { return [] }
        var items: [CGGlyph] = []
        for index in 0..<count {
            let position = start + 4 + index * 6
            guard let first = data.word(position), let last = data.word(position + 2),
                  last >= first, items.count + last - first < 65536 else { break }
            items.append(contentsOf: (first...last).map(CGGlyph.init))
        }
        return items
    }
}

private struct FontBytes {
    let bytes: [UInt8]
    func byte(_ index: Int) -> Int? { bytes.indices.contains(index) ? Int(bytes[index]) : nil }
    func word(_ index: Int) -> Int? { number(index, length: 2) }
    func triple(_ index: Int) -> Int? { number(index, length: 3) }
    func long(_ index: Int) -> Int? { number(index, length: 4) }

    func offsets(_ root: Int, countAt: Int, first: Int) -> [Int] {
        guard let count = word(countAt) else { return [] }
        return (0..<count).compactMap { word(first + $0 * 2).map { root + $0 } }
    }

    private func number(_ index: Int, length: Int) -> Int? {
        guard index >= 0, index <= bytes.count - length else { return nil }
        return bytes[index..<(index + length)].reduce(0) { ($0 << 8) | Int($1) }
    }
}
