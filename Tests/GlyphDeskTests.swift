import AppKit
import PDFKit
import SwiftUI
import XCTest
@testable import GlyphDesk

final class GlyphDeskTests: XCTestCase {
    private func catalog() throws -> UnicodeCatalog {
        try XCTUnwrap(UnicodeCatalog())
    }

    func testUnicodeLookupAndEncodings() throws {
        let catalog = try catalog()
        let arrow = try XCTUnwrap(catalog.search("U+2192").first)
        XCTAssertEqual(arrow.text, "→")
        XCTAssertEqual(arrow.name, "RIGHTWARDS ARROW")
        XCTAssertEqual(arrow.swift, "\\u{2192}")
        XCTAssertEqual(arrow.utf8, "E2 86 92")
        XCTAssertEqual(arrow.utf16, "2192")
        XCTAssertEqual(arrow.utf32, "00002192")
        XCTAssertEqual(catalog.search("#8594").first, arrow)
        XCTAssertEqual(catalog.search("2192").first, arrow)
        XCTAssertEqual(catalog.search("&rarr;").first, arrow)
        XCTAssertEqual(catalog.html(arrow, style: .decimal), "&#8594;")
        XCTAssertEqual(catalog.html(arrow, style: .hex), "&#x2192;")
        XCTAssertEqual(catalog.search("arrow").first(where: { $0 == arrow }), arrow)
        XCTAssertEqual(catalog.search("&#169;").first?.text, "©")
        XCTAssertTrue(catalog.search("U+D800").isEmpty)
        XCTAssertTrue(catalog.versions().contains("Unicode 18.0.0"))
        XCTAssertEqual(catalog.search("U+4E00").first?.name, "CJK UNIFIED IDEOGRAPH-4E00")
    }

    func testEmojiCombiningAndSupplementaryScalars() throws {
        let catalog = try catalog()
        let flag = "🇨🇦"
        let emoji = "👩🏽‍💻"
        XCTAssertTrue(catalog.search("Canada").contains { $0.text == flag })
        let technologist = try XCTUnwrap(catalog.search(emoji).first)
        XCTAssertEqual(technologist.scalars, [0x1f469, 0x1f3fd, 0x200d, 0x1f4bb])
        XCTAssertGreaterThanOrEqual(catalog.skinTones(for: technologist).count, 6)
        let supplementary = try XCTUnwrap(catalog.search("U+1F469").first)
        XCTAssertEqual(supplementary.utf16, "D83D DC69")
        XCTAssertEqual(supplementary.utf32, "0001F469")
        let accents = CharacterEntry(scalars: [0x65, 0x301], name: "decomposed e acute")
        XCTAssertEqual(accents.text.unicodeScalars.map(\.value), [0x65, 0x301])
        XCTAssertEqual(accents.utf8, "65 CC 81")
        XCTAssertEqual(catalog.search("e\u{0301}").first?.scalars, [0x65, 0x301])
        XCTAssertEqual(catalog.search("é").first?.scalars, [0xE9])
        XCTAssertEqual(catalog.search("U+00AD").first?.scalars, [0xAD])
        XCTAssertEqual(catalog.search("∞").first?.scalars, [0x221E])
        XCTAssertEqual(catalog.search("※").first?.scalars, [0x203B])
    }

    func testLayoutParsingAndStableOrder() throws {
        let catalog = try catalog()
        let arrow = try XCTUnwrap(catalog.search("U+2192").first)
        let a = try XCTUnwrap(catalog.entry([65]))
        let b = try XCTUnwrap(catalog.entry([66]))
        let c = try XCTUnwrap(catalog.entry([67]))
        let accent = try XCTUnwrap(catalog.entry([0xE9]))
        let emoji = try XCTUnwrap(catalog.search("👩🏽‍💻").first)
        let source = [a, b, c, accent, arrow, emoji]
        let document = try LayoutProgram("""
            Letters\r
            A-B #65 // preserve duplicate placement\r
            \r
            -Disabled\r
            $ZZZZ\r
            \r
            Symbols\r
            [FIND rightwards arrow] [$1F469 $1F3FD $200D $1F4BB]\r
            \r
            Remainder\r
            [BLOCK-OTHER Basic Latin] [OTHER]
            """)
        let groups = document.groups(in: source) { _ in [arrow] }
        XCTAssertEqual(groups.map(\.title), ["Letters", "Symbols", "Remainder"])
        XCTAssertEqual(groups[0].entries, [a, b, a])
        XCTAssertEqual(groups[1].entries, [arrow, emoji])
        XCTAssertEqual(groups[2].entries, [c, accent])
        XCTAssertThrowsError(try LayoutProgram("Bad range\nB-A"))
        XCTAssertThrowsError(try LayoutProgram("Invalid scalar\n$110000")) {
            XCTAssertEqual(($0 as? LayoutError)?.line, 2)
        }
    }

    func testFontMetadataCoverageAndGlyphs() throws {
        let library = FontLibrary()
        let face = try XCTUnwrap(library.faces.first { $0.id == "Helvetica" } ?? library.faces.first)
        let catalog = try catalog()
        let entries = [try XCTUnwrap(catalog.entry([65])), try XCTUnwrap(catalog.entry([102])),
                       try XCTUnwrap(catalog.entry([105]))]
        XCTAssertTrue(library.covers(entries[0], in: library.support(for: face)))
        XCTAssertTrue(library.covering(entries[0]).contains(face))
        let metadata = library.metadata(for: face)
        XCTAssertEqual(metadata.count, 25)
        XCTAssertEqual(Array(metadata.suffix(3).map(\.name)), ["File", "Ligatures", "Languages"])
        XCTAssertNotNil(metadata.first { $0.name == "Units per em" }?.value)
        let glyphs = library.entriesForFace(face, catalogEntries: entries, allGlyphs: true)
        XCTAssertFalse(glyphs.isEmpty)
        XCTAssertTrue(glyphs.contains { $0.glyphID != nil && $0.faceName == face.id })
        XCTAssertEqual(Set(glyphs.compactMap(\.glyphID)).count, glyphs.count)
    }

    func testProofAndGraphicExports() throws {
        let face = try XCTUnwrap(FontLibrary().faces.first { $0.id == "Helvetica" })
        let sample = try XCTUnwrap(catalog().entry([65]))
        let png = try XCTUnwrap(GlyphDrawing.image(sample, face: face, pixels: 128))
        XCTAssertEqual(NSBitmapImageRep(data: png)?.pixelsWide, 128)
        XCTAssertEqual(NSBitmapImageRep(data: png)?.pixelsHigh, 128)
        let pdfData = try XCTUnwrap(GlyphDrawing.pdf(sample, face: face, points: 128))
        XCTAssertEqual(PDFDocument(data: pdfData)?.pageCount, 1)
        let proof = try XCTUnwrap(ProofOutput.proof("ABC xyz 012", face: face, sizes: [18, 38]))
        XCTAssertEqual(PDFDocument(data: proof)?.pageCount, 2)
        let sheet = try XCTUnwrap(ProofOutput.glyphSheet(Array(repeating: sample, count: 100), face: face))
        XCTAssertEqual(PDFDocument(data: sheet)?.pageCount, 2)
    }

    func testClipboardSnapshotDoesNotReplaceAConcurrentCopy() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        XCTAssertTrue(PastePayload(text: "original").write(to: pasteboard))
        let snapshot = try XCTUnwrap(ClipboardSnapshot(pasteboard))
        XCTAssertTrue(PastePayload(text: "temporary").write(to: pasteboard))
        snapshot.restore(to: pasteboard, ownedChange: pasteboard.changeCount)
        XCTAssertEqual(pasteboard.string(forType: .string), "original")
        let replacementSnapshot = try XCTUnwrap(ClipboardSnapshot(pasteboard))
        XCTAssertTrue(PastePayload(text: "temporary again").write(to: pasteboard))
        let ownedChange = pasteboard.changeCount
        XCTAssertTrue(PastePayload(text: "a later copy").write(to: pasteboard))
        replacementSnapshot.restore(to: pasteboard, ownedChange: ownedChange)
        XCTAssertEqual(pasteboard.string(forType: .string), "a later copy")
    }

    func testShapeSearchFindsSketchesOfInfinityAndReferenceMark() throws {
        let library = FontLibrary()
        let scoped = try catalog().all().filter {
            guard let value = $0.scalars.first, $0.scalars.count == 1 else { return false }
            return (0x2000...0x25FF).contains(value)
        }
        let index = ShapeIndex.build(entries: scoped, fonts: library, preferred: library.faces.first { $0.id == "Helvetica" })
        let angles = stride(from: 0.0, through: Double.pi * 2.05, by: 0.1)
        let loop: [CGPoint] = angles.map { theta in
            let horizontal = 89.0 * sin(theta)
            let vertical = 42.0 * sin(2.0 * theta)
            let jitterX = 1.8 * sin(7.0 * theta)
            let jitterY = 2.1 * sin(5.0 * theta)
            return CGPoint(x: 112.0 + horizontal + jitterX, y: 78.0 + vertical + jitterY)
        }
        let infinity = try XCTUnwrap(ShapeSample(strokes: [Stroke(points: loop)]))
        let infinityMatches = ShapeIndex.matches(infinity, index: index, count: 10)
        XCTAssertTrue(infinityMatches.contains { $0.text == "∞" }, "\(infinityMatches.map { $0.text })")

        let points: [[CGPoint]] = [
            [CGPoint(x: 10, y: 12), CGPoint(x: 88, y: 90)],
            [CGPoint(x: 13, y: 90), CGPoint(x: 90, y: 13)],
            [CGPoint(x: 50, y: 15)], [CGPoint(x: 51, y: 88)],
            [CGPoint(x: 19, y: 51)], [CGPoint(x: 83, y: 52)]
        ]
        let mark = try XCTUnwrap(ShapeSample(strokes: points.map { Stroke(points: $0) }))
        let markMatches = ShapeIndex.matches(mark, index: index, count: 10)
        XCTAssertTrue(markMatches.contains { $0.text == "※" }, "\(markMatches.map { $0.text })")
    }

    @MainActor
    func testNativeWorkspaceAndAllInsertionFormats() async throws {
        let model = DeskModel()
        let arrow = try XCTUnwrap(model.catalog?.entry([0x2192]))
        model.selection = arrow
        let expected: [InsertFormat: String] = [.plain: "→", .swift: "\\u{2192}", .hex: "U+2192", .decimal: "8594",
                                                .name: "RIGHTWARDS ARROW", .formatted: "→"]
        for format in InsertFormat.allCases {
            let payload = try XCTUnwrap(model.payload(arrow, format: format))
            if let value = expected[format] {
                XCTAssertEqual(payload.text, value)
            }
            if format == .picture { XCTAssertTrue(payload.representations.contains { $0.0 == .png }) }
            if format == .formatted { XCTAssertTrue(payload.representations.contains { $0.0 == .rtf }) }
            if format == .description { XCTAssertTrue(payload.text?.contains("RIGHTWARDS ARROW") == true) }
            if format == .html { XCTAssertTrue(payload.text?.hasSuffix(";") == true) }
        }

        let host = NSHostingView(rootView: WorkspaceView(model: model, delegate: DeskDelegate()))
        host.frame = CGRect(x: 0, y: 0, width: 1160, height: 770)
        for page in WorkspacePage.allCases {
            model.page = page
            host.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(host.fittingSize.width, 0)
        }
        let insertion = InsertionService()
        let refusal = await insertion.insert(PastePayload(text: "→"), into: nil) {
            XCTFail("An absent destination must leave the test UI alone.")
        }
        if case .posted = refusal { XCTFail("An absent destination must never receive an insertion.") }
    }

    func testSavedSettingsAndFavoritesRoundTrip() throws {
        let emoji = CharacterEntry(scalars: [0x1f469, 0x1f3fd, 0x200d, 0x1f4bb], name: "technologist")
        var prefs = Preferences()
        prefs.favorites = [emoji]
        prefs.aliases[emoji.id] = "work"
        prefs.faceLayouts["TestFace"] = "Writing"
        prefs.layouts = [.example]
        prefs.perApp["example.editor"] = InsertionPreference(format: .html, pointSize: 13, imageSize: 512)
        let decoded = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(prefs))
        XCTAssertEqual(decoded.favorites, [emoji])
        XCTAssertEqual(decoded.aliases[emoji.id], "work")
        XCTAssertEqual(decoded.layouts, [.example])
        XCTAssertEqual(decoded.perApp["example.editor"]?.format, .html)
        let archive = FavoritesArchive(version: 1, entries: decoded.favorites, aliases: decoded.aliases)
        let loaded = try JSONDecoder().decode(FavoritesArchive.self, from: JSONEncoder().encode(archive))
        XCTAssertEqual(loaded.entries.first?.scalars, emoji.scalars)
    }
}
