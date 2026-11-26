import Foundation

struct FontReviewReference: Codable, Equatable, Hashable, Sendable {
    var postScriptName: String
    var displayName: String
    var version: String?
    var filePath: String?
    var file: FontReviewFileReference?
}

struct FontReviewFileReference: Codable, Equatable, Hashable, Sendable {
    let bookmark: Data
    let faceIndex: Int
}

struct FontReviewCandidate: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var reference: FontReviewReference
    private var savedTypography: ReviewTypeSettings?

    init(reference: FontReviewReference) {
        self.reference = reference
    }

    var typography: ReviewTypeSettings {
        get { savedTypography ?? ReviewTypeSettings() }
        set { savedTypography = newValue.isDefault ? nil : newValue }
    }
}

struct ReviewTypeSettings: Codable, Equatable, Sendable {
    var axes: [UInt32: Double] = [:]
    var features: [String: Bool] = [:]
    var isDefault: Bool { axes.isEmpty && features.isEmpty }
}

struct FontReviewSample: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var name = "Specimen"
    var text = ""
    var size = 28.0
    var measure = 360.0
    var lineSpacing = 4.0
}

struct FontReviewProject: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var name: String
    var candidates: [FontReviewCandidate] = []
    var samples = [FontReviewSample()]
    var activeSampleID: UUID?

    var activeSample: FontReviewSample? {
        samples.first { $0.id == activeSampleID } ?? samples.first
    }
}

struct FontReviewLibrary: Codable {
    var projects: [FontReviewProject] = []
    var activeProjectID: UUID?
}

struct FontReviewStore {
    var url = Preferences.url.deletingLastPathComponent().appendingPathComponent("FontReviewProjects.json")

    func load() throws -> FontReviewLibrary {
        do {
            return try JSONDecoder().decode(FontReviewLibrary.self, from: Data(contentsOf: url))
        } catch CocoaError.fileReadNoSuchFile {
            return FontReviewLibrary()
        }
    }

    func save(_ library: FontReviewLibrary) throws {
        let data = try JSONEncoder().encode(library)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
