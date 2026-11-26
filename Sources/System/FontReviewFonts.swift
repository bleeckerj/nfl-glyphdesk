import CoreText
import Foundation

enum FontReviewFonts {
    struct FileFace: Identifiable {
        let id: Int
        let reference: FontReviewReference
    }

    struct Metadata: Sendable {
        let reference: FontReviewReference
        let foundry: String?
        let licenseURL: String?
        let installedMatches: [FontReviewReference]
    }

    static func reference(for face: FontFace) -> FontReviewReference {
        reference(for: face.font(size: 18))
    }

    static func reference(for font: CTFont) -> FontReviewReference {
        FontReviewReference(
            postScriptName: CTFontCopyPostScriptName(font) as String,
            displayName: CTFontCopyDisplayName(font) as String,
            version: CTFontCopyName(font, kCTFontVersionNameKey) as String?,
            filePath: sourceURL(of: font)?.path
        )
    }

    static func open(_ url: URL) throws -> [FileFace] {
        guard ["otf", "ttf", "ttc"].contains(url.pathExtension.lowercased()) else { throw FileError.unreadable }
        let source = url.standardizedFileURL.resolvingSymlinksInPath()
        let bookmark = try source.bookmarkData(options: .minimalBookmark)
        let faces = descriptors(at: source).enumerated().compactMap { index, descriptor -> FileFace? in
            guard let font = fileFont(descriptor, at: source, size: 18) else { return nil }
            var item = reference(for: font)
            item.file = FontReviewFileReference(bookmark: bookmark, faceIndex: index)
            return FileFace(id: index, reference: item)
        }
        guard !faces.isEmpty else { throw FileError.unreadable }
        return faces
    }

    static func resolve(_ reference: FontReviewReference, size: CGFloat, library: FontLibrary) -> CTFont? {
        if let file = reference.file {
            var stale = false
            guard let resolved = try? URL(resolvingBookmarkData: file.bookmark,
                                          options: [.withoutUI, .withoutMounting], relativeTo: nil,
                                          bookmarkDataIsStale: &stale) else { return nil }
            let source = resolved.standardizedFileURL.resolvingSymlinksInPath()
            let faces = descriptors(at: source)
            guard faces.indices.contains(file.faceIndex),
                  let font = fileFont(faces[file.faceIndex], at: source, size: size),
                  referenceMatches(reference, font: font, checkPath: false) else { return nil }
            return font
        }
        return library.installedFonts(named: reference.postScriptName, size: size).first {
            referenceMatches(reference, font: $0, checkPath: true)
        }
    }

    static func metadata(for font: CTFont, reviewingFile: Bool, library: FontLibrary) -> Metadata {
        let source = reference(for: font)
        let matches = reviewingFile ? library.installedFonts(named: source.postScriptName, size: 18) : []
        var seen = Set<FontReviewReference>()
        return Metadata(
            reference: source,
            foundry: CTFontCopyName(font, kCTFontManufacturerNameKey) as String?,
            licenseURL: CTFontCopyName(font, kCTFontLicenseURLNameKey) as String?,
            installedMatches: matches.map { reference(for: $0) }.filter { seen.insert($0).inserted }
        )
    }

    static func sourceURL(of font: CTFont) -> URL? {
        (CTFontCopyAttribute(font, kCTFontURLAttribute) as? URL)?.standardizedFileURL.resolvingSymlinksInPath()
    }

    private static func descriptors(at url: URL) -> [CTFontDescriptor] {
        CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor] ?? []
    }

    private static func fileFont(_ descriptor: CTFontDescriptor, at url: URL, size: CGFloat) -> CTFont? {
        let font = CTFontCreateWithFontDescriptor(descriptor, size, nil)
        return sourceURL(of: font) == url ? font : nil
    }

    private static func referenceMatches(_ expected: FontReviewReference, font: CTFont, checkPath: Bool) -> Bool {
        let current = reference(for: font)
        return current.postScriptName == expected.postScriptName
            && (expected.version == nil || expected.version == current.version)
            && (!checkPath || expected.filePath == nil || expected.filePath == current.filePath)
    }

    enum FileError: LocalizedError {
        case unreadable

        var errorDescription: String? {
            String(localized: "This file could not be opened as an OpenType, TrueType, or TrueType collection font.")
        }
    }
}
