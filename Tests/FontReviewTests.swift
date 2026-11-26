import AppKit
import CoreText
import PDFKit
import XCTest
@testable import GlyphDesk

final class FontReviewTests: XCTestCase {
    @MainActor
    func testProjectProofReopensWithOrderedFacesAndNamedSamples() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FontReviewStore(url: directory.appendingPathComponent("Projects.json"))
        let model = FontReviewModel(store: store)

        model.createProject()
        let projectID = try XCTUnwrap(model.project?.id)
        let sampleID = try XCTUnwrap(model.project?.activeSample?.id)
        let candidates = ["Helvetica", "Georgia", "Menlo-Regular"].map { name in
            let font = CTFontCreateWithName(name as CFString, 28, nil)
            return FontReviewCandidate(reference: FontReviewFonts.reference(for: font))
        }
        model.updateProject(projectID) { project in
            project.name = "Book proof"
            project.candidates = candidates
        }
        model.moveCandidate(candidates[2].id, in: projectID, by: -1)
        model.updateSample(sampleID, in: projectID) { sample in
            sample.name = "Title"
            sample.text = "São Tomé"
            sample.size = 36
            sample.measure = 320
            sample.lineSpacing = 8
        }
        model.addSample(to: projectID)
        let secondID = try XCTUnwrap(model.project?.activeSample?.id)
        model.updateSample(secondID, in: projectID) { sample in
            sample.name = "Body"
            sample.text = "Compare the same paragraph in every face."
        }
        model.saveImmediately()
        XCTAssertNil(model.storageError)

        let reopened = FontReviewModel(store: store)
        XCTAssertEqual(reopened.project?.id, projectID)
        XCTAssertEqual(reopened.project?.name, "Book proof")
        XCTAssertEqual(reopened.project?.candidates.map(\.id), [candidates[0].id, candidates[2].id, candidates[1].id])
        XCTAssertEqual(reopened.project?.samples.map(\.name), ["Title", "Body"])
        XCTAssertEqual(reopened.project?.activeSample?.id, secondID)
        let title = try XCTUnwrap(reopened.project?.samples.first)
        XCTAssertEqual(title.text, "São Tomé")
        XCTAssertEqual([title.size, title.measure, title.lineSpacing], [36, 320, 8])
        let font = CTFontCreateWithName("Helvetica" as CFString, title.size, nil)
        let layout = ReviewSpecimen(sample: title, font: font)
        XCTAssertEqual(layout.width, 320)
        XCTAssertEqual(layout.visibleLength, title.text.utf16.count)
    }

    func testVariableAxisChangesTheProofAndResetsToDefault() throws {
        let skia = CTFontCreateWithName("Skia-Regular" as CFString, 42, nil)
        let axis = try XCTUnwrap(ReviewTypography.axes(in: skia).first)
        let chosen = axis.defaultValue == axis.maximum ? axis.minimum : axis.maximum
        let settings = ReviewTypeSettings(axes: [axis.id: chosen])
        let rendered = ReviewTypography.apply(settings, to: skia)
        let axes = CTFontCopyVariation(rendered) as? [NSNumber: NSNumber]
        XCTAssertEqual(try XCTUnwrap(axes?[NSNumber(value: axis.id)]).doubleValue, chosen, accuracy: 0.001)
        let glyph = try XCTUnwrap(directGlyph("A", in: skia))
        let normalSize = CTFontCreatePathForGlyph(skia, glyph, nil)?.boundingBoxOfPath
        let changedSize = CTFontCreatePathForGlyph(rendered, glyph, nil)?.boundingBoxOfPath
        XCTAssertNotEqual(normalSize, changedSize)
        XCTAssertTrue(CFEqual(ReviewTypography.apply(ReviewTypeSettings(), to: skia), skia))

        var candidate = FontReviewCandidate(reference: FontReviewFonts.reference(for: skia))
        candidate.typography = settings
        let decoded = try JSONDecoder().decode(FontReviewCandidate.self, from: JSONEncoder().encode(candidate))
        XCTAssertEqual(decoded.typography, settings)
        XCTAssertEqual(decoded.id, candidate.id)
    }

    func testOpenTypeLigatureToggleShapesTheSameTextDifferently() throws {
        let font = CTFontCreateWithName("STIXGeneral-Regular" as CFString, 48, nil)
        XCTAssertTrue(ReviewTypography.axes(in: font).isEmpty)
        XCTAssertTrue(ReviewTypography.features(in: font).contains { $0.id == "liga" })
        let enabled = ReviewTypography.apply(ReviewTypeSettings(features: ["liga": true]), to: font)
        let disabled = ReviewTypography.apply(ReviewTypeSettings(features: ["liga": false]), to: font)
        func count(_ face: CTFont) -> Int {
            let text = NSAttributedString(string: "ffi fi fl", attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): face
            ])
            return CTLineGetGlyphCount(CTLineCreateWithAttributedString(text))
        }
        XCTAssertLessThan(count(enabled), count(disabled))
    }

    func testFontFileBookmarkKeepsTheFileFaceSeparateFromTheInstalledFace() throws {
        let library = FontLibrary()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let system = URL(fileURLWithPath: "/System/Library/Fonts/Supplemental/Skia.ttf")
        let copied = directory.appendingPathComponent("Copied.ttf")
        try FileManager.default.copyItem(at: system, to: copied)
        let faces = try FontReviewFonts.open(copied)
        let chosen = try XCTUnwrap(faces.first { $0.reference.postScriptName == "Skia-Regular" })
        let reference = try JSONDecoder().decode(FontReviewReference.self, from: JSONEncoder().encode(chosen.reference))
        let resolved = try XCTUnwrap(FontReviewFonts.resolve(reference, size: 26, library: library))
        let metadata = FontReviewFonts.metadata(for: resolved, reviewingFile: true, library: library)
        XCTAssertEqual(metadata.reference.filePath, copied.resolvingSymlinksInPath().path)
        XCTAssertEqual(CTFontGetSize(resolved), 26)
        XCTAssertTrue(metadata.installedMatches.contains { $0.filePath == system.path })

        let black = try XCTUnwrap(faces.first { $0.reference.postScriptName == "Skia-Regular_Black" })
        let instance = try XCTUnwrap(FontReviewFonts.resolve(black.reference, size: 26, library: library))
        let originalAxes = Dictionary(uniqueKeysWithValues: ReviewTypography.axes(in: resolved).map { ($0.id, $0) })
        let axis = try XCTUnwrap(ReviewTypography.axes(in: instance).first {
            originalAxes[$0.id]?.defaultValue != $0.defaultValue
        })
        let changed = ReviewTypography.apply(ReviewTypeSettings(axes: [axis.id: axis.minimum]), to: instance)
        let values = CTFontCopyVariation(changed) as? [NSNumber: NSNumber]
        XCTAssertEqual(try XCTUnwrap(values?[NSNumber(value: axis.id)]).doubleValue, axis.minimum, accuracy: 0.001)
        XCTAssertEqual(FontReviewFonts.sourceURL(of: changed), FontReviewFonts.sourceURL(of: instance))
        XCTAssertTrue(CFEqual(ReviewTypography.apply(ReviewTypeSettings(), to: instance), instance))
        let layout = ReviewSpecimen(sample: FontReviewSample(text: "ABC", size: 26), font: changed)
        XCTAssertEqual(ReviewCoverage(layout: layout, font: changed).native, 3)

        let moved = directory.appendingPathComponent("Moved.ttf")
        try FileManager.default.moveItem(at: copied, to: moved)
        let reopened = try XCTUnwrap(FontReviewFonts.resolve(reference, size: 26, library: library))
        XCTAssertEqual(FontReviewFonts.sourceURL(of: reopened)?.path, moved.resolvingSymlinksInPath().path)
        try FileManager.default.removeItem(at: moved)
        XCTAssertNil(FontReviewFonts.resolve(reference, size: 26, library: library))
        try FileManager.default.copyItem(at: system, to: copied)
        let relinked = try XCTUnwrap(FontReviewFonts.open(copied).first {
            $0.reference.postScriptName == reference.postScriptName
        })
        XCTAssertNotNil(FontReviewFonts.resolve(relinked.reference, size: 26, library: library))
    }

    func testCollectionFacesAndOpenTypeFilesResolveIndividually() throws {
        let library = FontLibrary()
        let paths = ["/System/Library/Fonts/Helvetica.ttc", "/System/Library/Fonts/Supplemental/STIXGeneral.otf"]
        for path in paths {
            let faces = try FontReviewFonts.open(URL(fileURLWithPath: path))
            XCTAssertGreaterThanOrEqual(faces.count, path.hasSuffix(".ttc") ? 2 : 1)
            XCTAssertEqual(Set(faces.map { $0.reference.postScriptName }).count, faces.count)
            for face in faces {
                let font = try XCTUnwrap(FontReviewFonts.resolve(face.reference, size: 19, library: library))
                XCTAssertEqual(CTFontCopyPostScriptName(font) as String, face.reference.postScriptName)
                XCTAssertEqual(FontReviewFonts.sourceURL(of: font)?.path, path)
            }
        }
    }

    func testProjectExportsContainNamedSamplesAndShortlistMetadata() throws {
        let library = FontLibrary()
        let font = CTFontCreateWithName("Helvetica" as CFString, 28, nil)
        let face = FontReviewCandidate(reference: FontReviewFonts.reference(for: font))
        let project = FontReviewProject(name: "São Tomé, \"Book\"", candidates: [face],
                                        samples: [FontReviewSample(name: "Title", text: "São Tomé"),
                                                  FontReviewSample(name: "Body", text: "Repeat this sample.\n", measure: 660)])
        let pdf = try XCTUnwrap(PDFDocument(data: try XCTUnwrap(ReviewProjectExport.pdf(project, library: library))))
        XCTAssertEqual(pdf.pageCount, 2)
        XCTAssertEqual(pdf.page(at: 0)?.bounds(for: .mediaBox).width, 732)
        XCTAssertTrue(pdf.page(at: 0)?.string?.contains("Title") == true)
        XCTAssertTrue(pdf.page(at: 1)?.string?.contains("Repeat this sample.") == true)
        let csv = String(decoding: ReviewProjectExport.csv(project, library: library), as: UTF8.self)
        XCTAssertTrue(csv.contains("\"São Tomé, \"\"Book\"\"\""))
        XCTAssertTrue(csv.contains("\"Helvetica\",\"Helvetica\",\"Yes\",\"Installed\""))
        XCTAssertTrue(csv.contains("Helvetica.ttc"))
    }

    func testCoverageCountsLigaturesAndCombiningMarksByVisibleCluster() throws {
        let font = CTFontCreateWithName("STIXGeneral-Regular" as CFString, 32, nil)
        let sample = FontReviewSample(text: "São Tomé à ffi \u{2060}\n")
        let styled = ReviewTypography.apply(ReviewTypeSettings(features: ["liga": true]), to: font)
        let layout = ReviewSpecimen(sample: sample, font: styled)
        let coverage = ReviewCoverage(layout: layout, font: styled)
        XCTAssertEqual(layout.visibleLength, sample.text.utf16.count)
        XCTAssertEqual(coverage.native, 11)
        XCTAssertTrue(coverage.isAllNative)
        XCTAssertTrue(coverage.issues.isEmpty)
    }

    func testCoverageNamesActualFallbackAndFindsMissingClustersInMixedText() throws {
        let font = CTFontCreateWithName("Helvetica" as CFString, 28, nil)
        let emoji = "👨‍👩‍👧‍👦"
        let rtl = "العربية"
        let absent = "\u{0378}"
        let sample = FontReviewSample(name: "Mixed", text: "A \(emoji) \(rtl) \(absent)")
        let library = FontLibrary()
        let candidate = FontReviewCandidate(reference: FontReviewFonts.reference(for: font))
        let proof = ReviewCandidateProof(candidate: candidate, sample: sample, library: library)
        let coverage = try XCTUnwrap(proof.coverage)
        XCTAssertEqual(coverage.native, 1)
        XCTAssertEqual(coverage.fallback, rtl.count + 1)
        XCTAssertEqual(coverage.missing, 1)
        let emojiIssue = try XCTUnwrap(coverage.issues.first { $0.text == emoji })
        XCTAssertTrue(emojiIssue.fallbackFaces.contains { $0.postScriptName == "AppleColorEmoji" })
        XCTAssertEqual(emojiIssue.range.count, emoji.utf16.count)
        XCTAssertEqual(coverage.issues.filter { $0.state == .missing }.map(\.text), [absent])
        XCTAssertEqual(coverage.issues.filter { $0.state == .fallback }.dropFirst().map(\.text).joined(), rtl)
        XCTAssertTrue(coverage.highlights.values.flatMap { $0 }.contains { $0.state == .missing })

        let project = FontReviewProject(name: "Coverage", candidates: [candidate], samples: [sample])
        let pdf = try XCTUnwrap(PDFDocument(data: try XCTUnwrap(ReviewProjectExport.pdf(project, library: library))))
        let page = try XCTUnwrap(pdf.page(at: 0)?.string)
        XCTAssertTrue(page.contains("1 native · 8 fallback · 1 missing"))
        XCTAssertTrue(page.contains("AppleColorEmoji") || page.contains("Apple Color Emoji"))
        let csv = String(decoding: ReviewProjectExport.csv(project, library: library), as: UTF8.self)
        XCTAssertTrue(csv.contains("\"1\",\"8\",\"1\""))
        XCTAssertTrue(csv.contains("Fallback · \(emoji) ·"))
        XCTAssertTrue(csv.contains("Missing · \(absent)"))
    }

    func testProjectPDFKeepsTheLastLineOfAPaginatedSample() throws {
        let font = CTFontCreateWithName("Helvetica" as CFString, 28, nil)
        let candidate = FontReviewCandidate(reference: FontReviewFonts.reference(for: font))
        let text = String(repeating: "Example proof line.\n", count: 62) + "End of specimen."
        let sample = FontReviewSample(text: text)
        let project = FontReviewProject(name: "Long proof", candidates: [candidate], samples: [sample])
        let pdf = try XCTUnwrap(PDFDocument(data: try XCTUnwrap(ReviewProjectExport.pdf(project, library: FontLibrary()))))
        XCTAssertGreaterThan(pdf.pageCount, 1)
        XCTAssertTrue(pdf.page(at: pdf.pageCount - 1)?.string?.contains("End of specimen.") == true)
    }

    @MainActor
    func testUnreadableProjectLibraryIsPreserved() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let original = Data("Invalid JSON".utf8)
        try original.write(to: file)
        let model = FontReviewModel(store: FontReviewStore(url: file))
        XCTAssertNotNil(model.storageError)
        model.createProject()
        model.saveImmediately()
        XCTAssertEqual(try Data(contentsOf: file), original)
    }
}
