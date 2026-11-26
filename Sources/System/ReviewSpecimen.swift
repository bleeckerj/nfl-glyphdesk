import CoreText
import Foundation

struct ReviewSpecimen {
    struct Line {
        let value: CTLine
        let origin: CGPoint
        let ascent: CGFloat
        let descent: CGFloat

        var top: CGFloat { origin.y + ascent }
        var bottom: CGFloat { origin.y - descent }
    }

    let text: String
    let width: CGFloat
    let height: CGFloat
    let lines: [Line]
    let visibleLength: Int

    init(sample: FontReviewSample, font: CTFont) {
        text = sample.text
        width = max(1, sample.measure)
        var spacing = max(0, sample.lineSpacing)
        let paragraph = withUnsafePointer(to: &spacing) { pointer in
            let setting = CTParagraphStyleSetting(
                spec: .lineSpacingAdjustment, valueSize: MemoryLayout<CGFloat>.size, value: pointer
            )
            return CTParagraphStyleCreate([setting], 1)
        }
        let string = NSAttributedString(string: sample.text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTParagraphStyleAttributeName as String): paragraph,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true
        ])
        let framesetter = CTFramesetterCreateWithAttributedString(string)
        let bounds = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter, CFRange(location: 0, length: 0), nil,
            CGSize(width: width, height: .greatestFiniteMagnitude), nil
        )
        height = max(ceil(bounds.height) + 2, ceil(CTFontGetAscent(font) + CTFontGetDescent(font)) + 2)
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0),
                                             CGPath(rect: rect, transform: nil), nil)
        visibleLength = CTFrameGetVisibleStringRange(frame).length
        let values = CTFrameGetLines(frame) as NSArray as? [CTLine] ?? []
        var origins = [CGPoint](repeating: .zero, count: values.count)
        if !values.isEmpty { CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins) }
        lines = zip(values, origins).map { line, origin in
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            CTLineGetTypographicBounds(line, &ascent, &descent, nil)
            return Line(value: line, origin: origin, ascent: ascent, descent: descent)
        }
    }

    func pages(contentHeight: CGFloat) -> [Range<Int>] {
        guard !lines.isEmpty else { return [0..<0] }
        var pages: [Range<Int>] = []
        var start = 0
        for index in lines.indices.dropFirst() where lines[start].top - lines[index].bottom > contentHeight {
            pages.append(start..<index)
            start = index
        }
        pages.append(start..<lines.endIndex)
        return pages
    }

    func draw(in context: CGContext, highlights: [Int: [ReviewCoverage.Highlight]],
              lines range: Range<Int>? = nil, offset: CGPoint = .zero) {
        context.saveGState()
        context.translateBy(x: offset.x, y: offset.y)
        context.textMatrix = .identity
        let indices = range ?? lines.indices
        context.saveGState()
        for index in indices {
            guard let marks = highlights[index] else { continue }
            for state: ReviewCoverage.State in [.fallback, .missing] {
                let rectangles = marks.lazy.filter { $0.state == state }.map(\.rect)
                context.setFillColor(state.highlightColor)
                context.addRects(Array(rectangles))
                context.fillPath()
            }
        }
        context.restoreGState()
        for index in indices {
            let line = lines[index]
            context.textPosition = line.origin
            CTLineDraw(line.value, context)
        }
        context.restoreGState()
    }
}
