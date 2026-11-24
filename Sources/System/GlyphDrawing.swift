import AppKit
import CoreText
import UniformTypeIdentifiers

enum GlyphDrawing {
    private static let fontKey = NSAttributedString.Key(kCTFontAttributeName as String)

    static func draw(_ entry: CharacterEntry, face: FontFace?, in frame: CGRect, context: CGContext,
                     color: CGColor, guides: Bool = false, zoom: CGFloat = 1) {
        if let name = entry.symbolName,
           let image = NSImage(systemSymbolName: name, accessibilityDescription: name) {
            let side = min(frame.width, frame.height) * 0.63
            let target = CGRect(x: frame.midX - side / 2, y: frame.midY - side / 2, width: side, height: side)
            let graphics = NSGraphicsContext(cgContext: context, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = graphics
            let config = NSImage.SymbolConfiguration(pointSize: side, weight: .regular)
                .applying(.init(hierarchicalColor: NSColor(cgColor: color) ?? .black))
            (image.withSymbolConfiguration(config) ?? image).draw(in: target)
            NSGraphicsContext.restoreGraphicsState()
            return
        }
        let preview = entry.readablePreview
        guard !preview.isEmpty || entry.glyphID != nil else { return }
        let size = max(6, min(frame.height * (guides ? 0.57 : 0.69), frame.width * (guides ? 0.50 : 0.77)) * zoom)
        let font = face?.font(size: size) ?? CTFontCreateUIFontForLanguage(.system, size, nil)!
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: preview, attributes: [
            fontKey: font, NSAttributedString.Key(kCTForegroundColorAttributeName as String): color
        ]))
        let tightBounds: CGRect
        if let glyph = entry.glyphID, entry.faceName == face?.id {
            tightBounds = CTFontGetBoundingRectsForGlyphs(font, .default, [glyph], nil, 1)
        } else {
            let exact = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
            tightBounds = exact.isEmpty ? CTLineGetBoundsWithOptions(line, []) : exact
        }
        let fitted = !guides && tightBounds.width > frame.width * 0.89 && tightBounds.width > 0 ? frame.width * 0.89 / tightBounds.width : 1
        let baseline = guides ? frame.minY + frame.height * 0.30 : frame.midY - tightBounds.midY * fitted

        context.saveGState()
        defer { context.restoreGState() }
        context.clip(to: frame)
        if guides {
            drawGuides(font, baseline: baseline, frame: frame, context: context, fitted: fitted)
        }
        context.setFillColor(color)
        context.translateBy(x: frame.midX - tightBounds.midX * fitted, y: baseline)
        context.scaleBy(x: fitted, y: fitted)
        if let glyph = entry.glyphID, entry.faceName == face?.id {
            CTFontDrawGlyphs(font, [glyph], [.zero], 1, context)
        } else {
            context.textPosition = .zero
            context.textMatrix = .identity
            CTLineDraw(line, context)
        }
    }

    static func image(_ entry: CharacterEntry, face: FontFace?, pixels: Int) -> Data? {
        guard (64...1024).contains(pixels),
              let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        draw(entry, face: face, in: CGRect(x: 0, y: 0, width: pixels, height: pixels), context: context,
             color: CGColor(gray: 0, alpha: 1))
        guard let image = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    static func pdf(_ entry: CharacterEntry, face: FontFace?, points: Int) -> Data? {
        let result = NSMutableData()
        var frame = CGRect(x: 0, y: 0, width: points, height: points)
        guard let consumer = CGDataConsumer(data: result as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &frame, nil) else { return nil }
        context.beginPDFPage(nil)
        draw(entry, face: face, in: frame, context: context, color: CGColor(gray: 0, alpha: 1))
        context.endPDFPage()
        context.closePDF()
        return result as Data
    }

    private static func drawGuides(_ font: CTFont, baseline: CGFloat, frame: CGRect,
                                   context: CGContext, fitted: CGFloat) {
        let heights: [(String, CGFloat)] = [
            ("Ascender", CTFontGetAscent(font)), ("Cap height", CTFontGetCapHeight(font)),
            ("x-height", CTFontGetXHeight(font)), ("Baseline", 0), ("Descender", -CTFontGetDescent(font))
        ]
        let lineColor = NSColor.secondaryLabelColor.withAlphaComponent(0.35).cgColor
        let labelColor = NSColor.secondaryLabelColor.cgColor
        for (label, offset) in heights {
            let y = baseline + offset * fitted
            guard y > frame.minY + 3, y < frame.maxY - 12 else { continue }
            context.setStrokeColor(lineColor)
            context.setLineWidth(0.7)
            context.setLineDash(phase: 0, lengths: label == "Baseline" ? [] : [3, 3])
            context.move(to: CGPoint(x: frame.minX + 3, y: y))
            context.addLine(to: CGPoint(x: frame.maxX - 3, y: y))
            context.strokePath()
            let line = CTLineCreateWithAttributedString(NSAttributedString(
                string: String(localized: String.LocalizationValue(label)), attributes: [
                    fontKey: CTFontCreateUIFontForLanguage(.miniSystem, 8, nil)!,
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): labelColor
                ]))
            context.textPosition = CGPoint(x: frame.minX + 7, y: y + 2)
            CTLineDraw(line, context)
        }
    }
}
