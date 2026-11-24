import AppKit

enum SystemSymbols {
    static func entries() -> [CharacterEntry] {
        let path = "/System/Library/CoreServices/CoreGlyphs.bundle/Contents/Resources/name_availability.plist"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
        else { return [] }
        let names = (plist["symbols"] as? [String: Any]) ?? plist
        return names.keys.sorted().compactMap { name in
            guard NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil else { return nil }
            return CharacterEntry(scalars: [], name: name, block: "SF Symbols", script: "Symbols", category: "SF Symbol")
        }
    }
}
