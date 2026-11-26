import Foundation

struct InsertionPreference: Codable, Equatable {
    var format: InsertFormat = .plain
    var pointSize: Double = 18
    var imageSize: Int = 256
    var font: String?
}

struct FavoritesArchive: Codable {
    var version: Int
    var entries: [CharacterEntry]
    var aliases: [String: String]
}

struct HotkeyPreference: Codable, Equatable {
    var key: UInt32 = 49
    var modifiers: UInt32 = 6144
    var title = "⌃⌥Space"
}

enum Corner: String, Codable, CaseIterable, Identifiable {
    case off = "Off", left = "Top left", right = "Top right"
    var id: String { rawValue }
}

enum LauncherMode: String, Codable, CaseIterable, Identifiable {
    case menuBar = "Menu bar", cornerButton = "Corner button", both = "Both"

    var id: String { rawValue }
    var showsMenuBar: Bool { self != .cornerButton }
    var showsCornerButton: Bool { self != .menuBar }
}

enum CornerButtonPosition: String, Codable, CaseIterable, Identifiable {
    case topLeft = "Top left", topRight = "Top right"

    var id: String { rawValue }
}

struct LauncherPreferences: Codable, Equatable {
    var mode: LauncherMode = .menuBar
    var corner: CornerButtonPosition = .topLeft
}

struct WindowPreferences: Codable, Equatable {
    var floatPalette = true
    var floatWorkspace = false
}

struct Preferences: Codable {
    var favorites: [CharacterEntry] = []
    var recents: [CharacterEntry] = []
    var recentFonts: [String] = []
    var aliases: [String: String] = [:]
    var layouts: [LayoutDocument] = []
    var globalLayout = "Unicode Blocks"
    var faceLayouts: [String: String] = [:]
    var zooms: [String: Double] = [:]
    var familyFaces: [String: String] = [:]
    var perApp: [String: InsertionPreference] = [:]
    var lastFace: String?
    var lastScope: CharacterScope = .installed
    var htmlStyle: EntityStyle = .named
    var hotkey: HotkeyPreference? = HotkeyPreference()
    var corner: Corner = .off
    private var savedLauncher: LauncherPreferences?
    private var savedWindows: WindowPreferences?
    var keepPaletteOpen = false
    var magnifier = false
    var compactByDefault = true
    var recentLimit = 52
    var proofText: String?
    var proofPreset = "Alphabet"
    var proofSize = 28.0
    var proofAllSizes = false

    var launcher: LauncherPreferences {
        get { savedLauncher ?? LauncherPreferences() }
        set { savedLauncher = newValue }
    }

    var windows: WindowPreferences {
        get { savedWindows ?? WindowPreferences() }
        set { savedWindows = newValue }
    }

    static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Glyph Desk", isDirectory: true)
            .appendingPathComponent("Preferences.json")
    }

    static func load() throws -> Self {
        guard FileManager.default.fileExists(atPath: url.path) else { return Self() }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }

    func save() throws {
        let folder = Self.url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(self)
        try data.write(to: Self.url, options: .atomic)
    }
}
