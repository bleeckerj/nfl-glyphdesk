import Foundation

func run() throws -> Int32 {
    var arguments = Array(CommandLine.arguments.dropFirst())
    guard arguments.first == "lookup" else {
        print("Usage: glyphdesk lookup [--json] [--first] [--catalog-file PATH] QUERY")
        return arguments.isEmpty || arguments.first == "--help" ? 0 : 2
    }
    arguments.removeFirst()
    var catalogURL: URL?
    var json = false
    var first = false
    while let firstArgument = arguments.first, firstArgument.hasPrefix("--"), firstArgument != "--" {
        arguments.removeFirst()
        switch firstArgument {
        case "--json": json = true
        case "--first": first = true
        case "--catalog-file":
            guard !arguments.isEmpty else { return 2 }
            catalogURL = URL(fileURLWithPath: arguments.removeFirst())
        default:
            FileHandle.standardError.write(Data("Unknown option: \(firstArgument)\n".utf8))
            return 2
        }
    }
    if arguments.first == "--" { arguments.removeFirst() }
    let query = arguments.joined(separator: " ")
    guard !query.isEmpty else { return 2 }
    let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    let contents = executable.deletingLastPathComponent().deletingLastPathComponent()
    let sameBundle = contents.appendingPathComponent("Resources/Unicode.sqlite3")
    let neighbor = executable.deletingLastPathComponent().appendingPathComponent("GlyphDesk.app/Contents/Resources/Unicode.sqlite3")
    guard let catalog = (catalogURL.map { [UnicodeCatalog(url: $0)] } ?? [UnicodeCatalog(url: sameBundle), UnicodeCatalog(url: neighbor)])
        .compactMap({ $0 }).first else {
        FileHandle.standardError.write(Data("Unicode catalog unavailable. Use --catalog-file.\n".utf8))
        return 1
    }

    let rows = catalog.search(query, limit: first ? 1 : 40)
    if json {
        let output = try JSONEncoder().encode(rows)
        FileHandle.standardOutput.write(output)
        FileHandle.standardOutput.write(Data("\n".utf8))
    } else if first {
        if let entry = rows.first { print(entry.text) }
    } else {
        for entry in rows { print("\(entry.text)\t\(entry.codes)\t\(entry.name)") }
    }
    return rows.isEmpty ? 1 : 0
}

do {
    exit(try run())
} catch {
    FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
    exit(1)
}
