import Foundation

struct CharacterEntry: Identifiable, Hashable, Codable, Sendable {
    let scalars: [UInt32]
    let name: String
    let block: String
    let script: String
    let category: String
    let faceName: String?
    let glyphID: UInt16?

    init(scalars: [UInt32], name: String, block: String = "", script: String = "",
         category: String = "", faceName: String? = nil, glyphID: UInt16? = nil) {
        self.scalars = scalars
        self.name = name
        self.block = block
        self.script = script
        self.category = category
        self.faceName = faceName
        self.glyphID = glyphID
    }

    var key: String { scalars.map { String($0, radix: 16, uppercase: true) }.joined(separator: " ") }
    var id: String {
        if let symbolName { return "SF:" + symbolName }
        if let faceName, let glyphID { return "\(faceName)/\(glyphID)/\(key)" }
        return key
    }
    var text: String { String(String.UnicodeScalarView(scalars.compactMap(Unicode.Scalar.init))) }
    var codes: String { scalars.map { String(format: "U+%04X", $0) }.joined(separator: " ") }
    var decimal: String { scalars.map(String.init).joined(separator: " ") }
    var swift: String { scalars.map { "\\u{\(String($0, radix: 16, uppercase: true))}" }.joined() }
    var utf8: String { text.utf8.map { String(format: "%02X", $0) }.joined(separator: " ") }
    var utf16: String { text.utf16.map { String(format: "%04X", $0) }.joined(separator: " ") }
    var utf32: String { scalars.map { String(format: "%08X", $0) }.joined(separator: " ") }
    var isPrivateUse: Bool { scalars.contains { Unicode.Scalar($0)?.properties.generalCategory == .privateUse } }
    var symbolName: String? { category == "SF Symbol" ? name : nil }
    var readablePreview: String {
        if category == "Mn" || category == "Me" || category == "Mc" { return "◌" + text }
        if scalars == [32] { return "␠" }
        if category == "Cf" || category == "Cc" || category == "Zl" || category == "Zp" { return "⋯" }
        return text
    }
}

enum InsertFormat: String, CaseIterable, Codable, Identifiable {
    case plain = "Plain"
    case formatted = "Formatted"
    case html = "HTML"
    case swift = "Swift"
    case decimal = "Decimal"
    case hex = "Hex"
    case name = "Name"
    case description = "Description"
    case picture = "Picture"
    var id: String { rawValue }
}

enum EntityStyle: String, CaseIterable, Codable, Identifiable {
    case named = "Named when available"
    case decimal = "Decimal"
    case hex = "Hexadecimal"
    var id: String { rawValue }
}

enum CharacterScope: String, CaseIterable, Codable, Identifiable {
    case face = "Selected face"
    case installed = "Installed fonts"
    case unicode = "All Unicode"
    case glyphs = "Every glyph"
    var id: String { rawValue }
}

struct CharacterGroup: Identifiable, Sendable {
    var id: String
    var title: String
    var entries: [CharacterEntry]
}
