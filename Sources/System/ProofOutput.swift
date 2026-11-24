import AppKit
import CoreText
import PDFKit

enum ProofOutput {
    static let presets = ["Alphabet", "Lorem ipsum", "Pangram", "Numbers and punctuation", "Custom"]
    static let sizes: [CGFloat] = [9, 12, 16, 24, 36, 54, 72]

    static func text(for key: String) -> String {
        switch key {
        case "Lorem ipsum":
            let paragraph = "Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat."
            return [paragraph, paragraph, paragraph].joined(separator: "\n\n")
        case "Pangram": return "The quick brown fox jumps over the lazy dog.\nSphinx of black quartz, judge my vow."
        case "Numbers and punctuation": return "0123456789\n€ $ £ ¥ ₹ ¢ % ± × ÷\n“Quotes” · « Guillemets »\n( ) [ ] { } / %@ #"
        case "Custom": return ""
        default: return "ABCDEFGHIJKLMNOPQRSTUVWXYZ\nabcdefghijklmnopqrstuvwxyz\n0123456789\nAa Bb Cc Dd Ee Ff Gg Hh Ii Jj Kk Ll Mm Nn Oo Pp Qq Rr Ss Tt Uu Vv Ww Xx Yy Zz"
        }
    }

    static func attributed(_ text: String, face: FontFace, size: CGFloat, printer: Bool = false) -> NSAttributedString {
        let font = face.font(size: size)
        let fontKey = NSAttributedString.Key(kCTFontAttributeName as String)
        let colorKey = NSAttributedString.Key(kCTForegroundColorAttributeName as String)
        let color = printer ? CGColor(gray: 0, alpha: 1) : NSColor.labelColor.cgColor
        let result = NSMutableAttributedString(string: text, attributes: [fontKey: font, colorKey: color])
        let coverage = CTFontCopyCharacterSet(font) as CharacterSet
        let fullLine = CTLineCreateWithAttributedString(result)
        let expected = CTFontCopyPostScriptName(font) as String
        let runs = CTLineGetGlyphRuns(fullLine) as NSArray as? [CTRun] ?? []
        let missingColor = (printer ? NSColor(red: 0.62, green: 0, blue: 0.19, alpha: 1) : NSColor.systemPink).cgColor
        for run in runs {
            let attributes = CTRunGetAttributes(run) as NSDictionary
            guard let runFont = attributes[kCTFontAttributeName],
                  CTFontCopyPostScriptName(runFont as! CTFont) as String != expected else { continue }
            let range = CTRunGetStringRange(run)
            guard range.location >= 0, range.length > 0, range.location + range.length <= result.length else { continue }
            result.addAttribute(colorKey, value: missingColor, range: NSRange(location: range.location, length: range.length))
        }
        var start = 0
        for character in text {
            let value = String(character)
            let length = value.utf16.count
            if character.unicodeScalars.contains(where: {
                !coverage.contains($0) && !CharacterSet.whitespacesAndNewlines.contains($0)
                    && !CharacterSet.controlCharacters.contains($0) && $0.value != 0xFE0F && $0.value != 0xFE0E
            }) {
                result.addAttribute(colorKey, value: missingColor, range: NSRange(location: start, length: length))
                if !printer { result.addAttribute(.backgroundColor, value: NSColor.systemPink.withAlphaComponent(0.17),
                                                   range: NSRange(location: start, length: length)) }
            }
            start += length
        }
        return result
    }

    static func proof(_ text: String, face: FontFace, sizes: [CGFloat]) -> Data? {
        let result = NSMutableData()
        var media = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(data: result as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &media, nil) else { return nil }
        for size in sizes {
            let specimen = attributed(text, face: face, size: size, printer: true)
            let typesetter = CTFramesetterCreateWithAttributedString(specimen)
            var consumed = 0
            var page = 1
            repeat {
                context.beginPDFPage(nil)
                label("\(face.title) · \(Int(size)) pt", x: 36, y: 750, context: context, size: 13)
                label("Glyph Desk  ·  Proof  ·  \(page)", x: 36, y: 30, context: context)
                let path = CGPath(rect: CGRect(x: 36, y: 58, width: 540, height: 668), transform: nil)
                let frame = CTFramesetterCreateFrame(typesetter, CFRange(location: consumed, length: 0), path, nil)
                CTFrameDraw(frame, context)
                let length = CTFrameGetVisibleStringRange(frame).length
                context.endPDFPage()
                if length == 0 { break }
                consumed += length
                page += 1
            } while consumed < specimen.length
        }
        context.closePDF()
        return result as Data
    }

    static func glyphSheet(_ entries: [CharacterEntry], face: FontFace) -> Data? {
        guard !entries.isEmpty else { return nil }
        let result = NSMutableData()
        var media = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(data: result as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &media, nil) else { return nil }
        let columns = 8
        let rows = 11
        let pageSize = columns * rows
        for start in stride(from: 0, to: entries.count, by: pageSize) {
            context.beginPDFPage(nil)
            label(face.title, x: 36, y: 748, context: context, size: 16)
            label("Glyph Desk  ·  Character sheet  ·  \(start / pageSize + 1)", x: 36, y: 30, context: context)
            for (index, entry) in entries[start..<min(start + pageSize, entries.count)].enumerated() {
                let x = CGFloat(index % columns) * 67.5 + 36
                let y = 694 - CGFloat(index / columns) * 60
                let frame = CGRect(x: x + 1, y: y - 6, width: 65, height: 43)
                context.setStrokeColor(CGColor(gray: 0.84, alpha: 1))
                context.stroke(CGRect(x: x, y: y - 20, width: 67.5, height: 60))
                GlyphDrawing.draw(entry, face: face, in: frame, context: context, color: CGColor(gray: 0, alpha: 1))
                let code = entry.codes.isEmpty ? "Glyph \(entry.glyphID ?? 0)" : entry.codes
                label(code, x: x + 3, y: y - 15, context: context, size: code.count > 10 ? 5.5 : 7)
            }
            context.endPDFPage()
        }
        context.closePDF()
        return result as Data
    }

    static func print(_ data: Data) {
        let document = PDFDocument(data: data)
        let operation = document?.printOperation(for: NSPrintInfo.shared, scalingMode: .pageScaleToFit, autoRotate: false)
        operation?.run()
    }

    private static func label(_ value: String, x: CGFloat, y: CGFloat, context: CGContext, size: CGFloat = 9) {
        let attribute = NSAttributedString.Key(kCTFontAttributeName as String)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: value, attributes: [
            attribute: CTFontCreateUIFontForLanguage(.system, size, nil)!
        ]))
        context.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(line, context)
    }
}
