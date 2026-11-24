import AppKit
import CoreText
import SwiftUI

struct ComparisonView: View {
    @ObservedObject var model: DeskModel
    @State private var zoom = 1.0

    var body: some View {
        if let entry = model.selection {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry.name).font(.title3.bold())
                        Text("In \(model.coverageCount) of \(model.fontCount) font families")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(entry.codes).monospaced().foregroundStyle(.secondary)
                }
                HStack(alignment: .top, spacing: 10) {
                    sample(entry, face: model.selectedFace, label: "Current face")
                    VStack {
                        Spacer()
                        Button(action: model.swapComparison) {
                            Label("Swap fonts", systemImage: "arrow.left.arrow.right").labelStyle(.iconOnly)
                        }
                        .disabled(model.comparisonFace == nil)
                        Spacer()
                    }.frame(height: 185)
                    sample(entry, face: model.comparisonFace, label: "Compared with")
                }
                HStack {
                    Button("Flag supporting fonts", action: model.flagContaining).disabled(model.coverage.isEmpty)
                    Button("Copy font list") {
                        model.copyText(model.coverage.map(\.title).joined(separator: "\n"))
                    }.disabled(model.coverage.isEmpty)
                    Spacer()
                    Slider(value: $zoom, in: 0.6...1.3).frame(width: 140).accessibilityLabel("Comparison zoom")
                }
                Divider()
                if model.coverageLoading {
                    ProgressView("Checking font coverage…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 112), spacing: 10)], spacing: 10) {
                            ForEach(model.coverage) { font in
                                Button { model.comparisonFace = font } label: {
                                    VStack(spacing: 3) {
                                        GlyphCanvas(entry: entry, face: font, zoom: zoom)
                                            .frame(height: 51)
                                            .accessibilityHidden(true)
                                        Text(font.title).font(.caption).multilineTextAlignment(.center).lineLimit(2)
                                    }
                                    .padding(8)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 93)
                                    .background(model.comparisonFace == font ? Color.accentColor.opacity(0.15) : .primary.opacity(0.04),
                                                in: RoundedRectangle(cornerRadius: 8))
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .help(font.title)
                                .accessibilityAddTraits(model.comparisonFace == font ? .isSelected : [])
                            }
                        }
                        .padding(1)
                    }
                }
            }
            .padding(14)
        } else {
            EmptyPane(title: "Font comparison", detail: "Select a character in Browse to compare its shape in installed fonts.")
        }
    }

    private func sample(_ entry: CharacterEntry, face: FontFace?, label: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let face {
                GlyphCanvas(entry: entry, face: face, guides: true, zoom: zoom)
                    .frame(height: 176).accessibilityHidden(true)
                Text(face.title).font(.headline).lineLimit(2).help(face.title)
            } else {
                Text("Choose a supporting font").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 176)
            }
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct ProofView: View {
    @ObservedObject var model: DeskModel
    @State private var showEditor = false
    @State private var makingSheet = false

    var body: some View {
        if let face = model.selectedFace {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(face.title).font(.title3.weight(.semibold))
                    Spacer()
                    Menu("Print and export") {
                        Button("Print proof…") { makeProof(face, print: true) }
                        Button("Save proof PDF…") { makeProof(face, print: false) }
                        Divider()
                        Button("Print glyph sheet…") { makeSheet(face, print: true) }
                        Button("Save glyph sheet PDF…") { makeSheet(face, print: false) }
                    }
                    .disabled(makingSheet)
                }
                HStack {
                    Picker("Proof sizes", selection: $model.preferences.proofAllSizes) {
                        Text("One size").tag(false)
                        Text("All sizes").tag(true)
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 155)
                    Picker("Preset", selection: $model.preferences.proofPreset) {
                        ForEach(ProofOutput.presets, id: \.self) { Text(LocalizedStringKey($0)).tag($0) }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 175)
                    .onChange(of: model.preferences.proofPreset) { _ in
                        if model.preferences.proofPreset != "Custom" { showEditor = false }
                    }
                    Button(showEditor ? "Done editing" : "Edit text") { showEditor.toggle() }
                    Spacer()
                    if !model.preferences.proofAllSizes {
                        Slider(value: $model.preferences.proofSize, in: 9...72, step: 1)
                            .frame(width: 115)
                            .accessibilityLabel("Proof size")
                        Text("\(Int(model.preferences.proofSize)) pt").monospacedDigit()
                    }
                }
                if showEditor {
                    TextEditor(text: Binding(get: { text }, set: {
                        model.preferences.proofPreset = "Custom"
                        model.preferences.proofText = $0
                    }))
                    .font(.body)
                    .frame(minHeight: 90, maxHeight: 175)
                    .accessibilityLabel("Edit sample text")
                    .overlay(Rectangle().strokeBorder(.secondary.opacity(0.35)))
                }
                if makingSheet {
                    ProgressView("Preparing glyph sheet…").controlSize(.small)
                }
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(sizes, id: \.self) { size in
                            if model.preferences.proofAllSizes {
                                Text("\(Int(size)) pt").font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                            Text(styled(face, size: size))
                                .lineSpacing(4)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if model.preferences.proofAllSizes { Divider() }
                        }
                    }
                    .padding(4)
                }
                Label("Highlighted characters use a fallback or are missing.", systemImage: "circle.dashed")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(14)
        } else {
            EmptyPane(title: "Text proof", detail: "Select a font to preview your text.")
        }
    }

    private var text: String {
        if model.preferences.proofPreset == "Custom" { return model.preferences.proofText ?? "" }
        return ProofOutput.text(for: model.preferences.proofPreset)
    }

    private var sizes: [CGFloat] {
        model.preferences.proofAllSizes ? ProofOutput.sizes : [model.preferences.proofSize]
    }

    private func styled(_ face: FontFace, size: CGFloat) -> AttributedString {
        let coverage = model.library.support(for: face).coverage
        var result = AttributedString()
        var buffer = ""
        var missing = false
        func flush() {
            guard !buffer.isEmpty else { return }
            var run = AttributedString(buffer)
            run.font = .custom(face.id, size: size)
            if missing {
                run.foregroundColor = .pink
                run.backgroundColor = .pink.opacity(0.14)
            }
            result += run
            buffer = ""
        }
        for character in text {
            let next = character.unicodeScalars.contains {
                !coverage.contains($0) && !CharacterSet.whitespacesAndNewlines.contains($0)
                    && !CharacterSet.controlCharacters.contains($0) && $0.value != 0xFE0E && $0.value != 0xFE0F
            }
            if next != missing { flush(); missing = next }
            buffer.append(character)
        }
        flush()
        return result
    }

    private func makeProof(_ face: FontFace, print: Bool) {
        guard let data = ProofOutput.proof(text, face: face, sizes: sizes) else { return }
        if print { ProofOutput.print(data) }
        else { WorkspaceFiles.save(data, type: .pdf, name: "\(face.title) proof.pdf", model: model) }
    }

    private func makeSheet(_ face: FontFace, print: Bool) {
        let catalog = model.catalog
        let library = model.library
        makingSheet = true
        Task {
            let data = await Task.detached(priority: .userInitiated) {
                let entries = library.entriesForFace(face, catalogEntries: catalog?.all() ?? [], allGlyphs: false)
                return ProofOutput.glyphSheet(entries, face: face)
            }.value
            makingSheet = false
            guard let data else { model.message = "The glyph sheet could not be generated."; return }
            if print { ProofOutput.print(data) }
            else { WorkspaceFiles.save(data, type: .pdf, name: "\(face.title) glyph sheet.pdf", model: model) }
        }
    }
}

struct FontInfoView: View {
    @ObservedObject var model: DeskModel
    @State private var fields: [FontField] = []

    var body: some View {
        if let face = model.selectedFace {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Font Info").font(.title3.bold())
                    Spacer()
                    Button("Copy all available fields") {
                        model.copyText(fields.compactMap { field in field.value.map { "\(field.name): \($0)" } }
                            .joined(separator: "\n"))
                    }
                    .disabled(fields.isEmpty)
                }
                Text(face.title).foregroundStyle(.secondary)
                Divider()
                ScrollView {
                    Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                        ForEach(fields) { field in
                            GridRow(alignment: .top) {
                                Text(LocalizedStringKey(field.name)).foregroundStyle(.secondary)
                                    .frame(minWidth: 105, alignment: .leading)
                                Text(field.value ?? "Unavailable")
                                    .foregroundStyle(field.value == nil ? .secondary : .primary)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                if let value = field.value {
                                    Button { model.copyText(value) } label: {
                                        Image(systemName: "doc.on.doc").accessibilityLabel("Copy \(field.name)")
                                    }.buttonStyle(.borderless)
                                } else { Color.clear.frame(width: 14, height: 1) }
                            }
                        }
                    }
                    .padding(4)
                }
            }
            .padding(14)
            .task(id: face.id) {
                fields = []
                let library = model.library
                let data = await Task.detached(priority: .userInitiated) { library.metadata(for: face) }.value
                if !Task.isCancelled { fields = data }
            }
        } else {
            EmptyPane(title: "Font Info", detail: "Select a font to see its metadata.")
        }
    }
}

struct EmptyPane: View {
    let title: LocalizedStringKey
    let detail: LocalizedStringKey

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            Text(detail).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(18)
    }
}
