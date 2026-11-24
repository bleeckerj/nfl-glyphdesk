import AppKit
import SwiftUI

struct CharacterInspector: View {
    @ObservedObject var model: DeskModel

    var body: some View {
        ScrollView {
            if let entry = model.selection {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.name).font(.headline)
                            .accessibilityAddTraits(.isHeader)
                        if let keys = model.keyboardEquivalent {
                            Text("Type \(keys)").font(.callout.monospaced())
                        }
                    }
                    GlyphCanvas(entry: entry, face: model.renderedFace, guides: true)
                        .frame(height: 150)
                        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                        .accessibilityHidden(true)
                    if let font = model.renderedFace {
                        Label(font.title, systemImage: model.selectedFace == font ? "textformat" : "arrow.turn.down.right")
                            .font(.caption).foregroundStyle(.secondary)
                            .help(model.selectedFace == font ? "Selected face" : "Rendered with a fallback face")
                    } else if entry.symbolName == nil {
                        Label("No installed glyph", systemImage: "square.dashed").font(.caption).foregroundStyle(.secondary)
                    }
                    actions(entry)
                    InsertionControls(model: model, entry: entry, detailed: true)
                        .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                    TextField("Custom name", text: Binding(get: { model.alias(for: entry) },
                                                           set: { model.setAlias($0, for: entry) }))
                        .textFieldStyle(.roundedBorder)
                    encodings(entry)
                    Divider()
                    if model.coverageLoading { ProgressView().controlSize(.small) }
                    else {
                        Text("In \(model.coverageCount) of \(model.fontCount) font families")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    HStack {
                        Button("Flag supporting fonts", action: model.flagContaining).disabled(model.coverage.isEmpty)
                        Spacer(minLength: 0)
                        Button("Compare") { model.page = .compare }.disabled(model.coverage.isEmpty)
                    }
                    .controlSize(.small)
                }
                .padding(12)
                .id(entry.id)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Character details").font(.headline)
                    Text("Select a glyph in the grid.").font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func actions(_ entry: CharacterEntry) -> some View {
        HStack(spacing: 8) {
            Button {
                model.toggleFavorite(entry)
            } label: {
                Image(systemName: model.isFavorite ? "star.fill" : "star")
                    .accessibilityLabel(model.isFavorite ? "Remove from Favorites" : "Add to Favorites")
            }
            .help(model.isFavorite ? "Remove from Favorites" : "Add to Favorites")
            Menu {
                CopyMenu(model: model, entry: entry)
            } label: {
                Image(systemName: "doc.on.doc").accessibilityLabel("Copy options")
            }
            .fixedSize()
            ShareLink(item: entry.text.isEmpty ? entry.name : entry.text) {
                Image(systemName: "square.and.arrow.up").accessibilityLabel("Share character")
            }
            Button(action: model.findSimilar) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .accessibilityLabel("Find similar shapes")
            }
            .help("Find similar shapes")
            .disabled(model.renderedFace == nil)
            let variants = model.catalog?.skinTones(for: entry) ?? []
            if !variants.isEmpty {
                Menu("Skin tone") {
                    ForEach(variants) { choice in
                        Button("\(choice.text)  \(choice.name)") { model.selection = choice }
                    }
                }
                .fixedSize()
            }
        }
        .controlSize(.small)
    }

    @ViewBuilder
    private func encodings(_ entry: CharacterEntry) -> some View {
        if !entry.scalars.isEmpty {
            let rows = [("Code Point", "#\(entry.decimal)  [\(entry.codes)]"),
                        ("HTML", model.currentEncoding), ("UTF-8", entry.utf8),
                        ("UTF-16", entry.utf16), ("UTF-32", entry.utf32)]
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                ForEach(rows, id: \.0) { key, value in
                    GridRow(alignment: .top) {
                        Text(LocalizedStringKey(key)).foregroundStyle(.secondary)
                        Text(value).fontDesign(.monospaced).textSelection(.enabled)
                    }
                }
            }
            .font(.callout)
        } else if let glyph = entry.glyphID {
            Text("Glyph index \(glyph)").font(.callout.monospaced())
        }
    }
}

struct CopyMenu: View {
    @ObservedObject var model: DeskModel
    let entry: CharacterEntry

    var body: some View {
        ForEach(InsertFormat.allCases) { format in
            Button(LocalizedStringKey(format.rawValue)) { model.copy(entry, format: format) }
                .disabled(entry.scalars.isEmpty && format != .description && format != .picture && format != .name)
        }
        Divider()
        Button("PNG") { model.copyGraphic(entry, pdf: false) }
        Button("PDF") { model.copyGraphic(entry, pdf: true) }
    }
}

struct InsertionControls: View {
    @ObservedObject var model: DeskModel
    let entry: CharacterEntry
    let detailed: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                if let icon = model.target?.app.icon {
                    Image(nsImage: icon).resizable().scaledToFit().frame(width: 15, height: 15).accessibilityHidden(true)
                }
                if let target = model.target {
                    Text("To \(target.name)").lineLimit(1)
                } else { Text("Copy the selection") }
                Spacer(minLength: 3)
                if model.insertPreference.format != .picture {
                    let preview = model.preview(entry, format: model.insertPreference.format)
                    Text(preview.isEmpty ? entry.name : preview).lineLimit(1)
                        .font(.callout.monospaced())
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            HStack {
                Button("Insert") { model.insert(entry) }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.target == nil)
                Button("Copy") { model.copy(entry, format: model.insertPreference.format) }
                Spacer(minLength: 0)
                Picker("Format", selection: Binding(get: { model.insertPreference.format },
                                                    set: { value in model.updateInsert { $0.format = value } })) {
                    ForEach(InsertFormat.allCases) { format in
                        Text(LocalizedStringKey(format.rawValue)).tag(format)
                    }
                }
                .labelsHidden()
                .frame(minWidth: 82, maxWidth: detailed ? 92 : 112)
                .accessibilityLabel("Insertion format")
            }
            if model.insertPreference.format == .formatted {
                Stepper(value: Binding(get: { model.insertPreference.pointSize },
                                       set: { value in model.updateInsert { $0.pointSize = value } }), in: 9...72) {
                    Text("\(Int(model.insertPreference.pointSize)) pt")
                }
                .font(.callout)
            }
            if model.insertPreference.format == .picture {
                Picker("Image size", selection: Binding(get: { model.insertPreference.imageSize },
                                                         set: { value in model.updateInsert { $0.imageSize = value } })) {
                    ForEach([64, 128, 256, 512, 1024], id: \.self) { value in
                        Text("\(value) px").tag(value)
                    }
                }
            }
        }
        .padding(detailed ? 8 : 12)
        .controlSize(detailed ? .small : .regular)
    }
}
