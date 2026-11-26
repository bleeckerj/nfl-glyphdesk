import AppKit
import SwiftUI

struct CharacterGrid: View {
    @ObservedObject var model: DeskModel
    let compact: Bool
    @State private var hover: CharacterEntry?

    var body: some View {
        let face = model.selectedFace
        GeometryReader { geometry in
            let tile = compact ? 44.0 : CGFloat(model.zoom + 12)
            let columnCount = max(1, Int((geometry.size.width - 22) / (tile + 3)))
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(model.visibleGroups) { group in
                            section(group, face: face, columns: columnCount, size: tile)
                                .id(group.id)
                        }
                        if model.visibleGroups.isEmpty || model.visibleGroups.allSatisfy({ $0.entries.isEmpty }) {
                            VStack(alignment: .leading, spacing: 9) {
                                if model.working || model.computingMatches {
                                    Label("Finding characters…", systemImage: "magnifyingglass")
                                } else {
                                    Label("No matches", systemImage: "magnifyingglass")
                                    Text("Try another name, code point, or font scope.")
                                        .font(.callout).foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                        }
                    }
                    .padding(10)
                }
                .onChange(of: model.jumpID) { id in
                    if let id { proxy.scrollTo(id, anchor: .top); model.jumpID = nil }
                }
                .onChange(of: model.query) { _ in proxy.scrollTo("search", anchor: .top) }
                .onChange(of: model.selection?.id) { id in
                    if let id, let group = model.visibleGroups.first(where: { $0.entries.contains { $0.id == id } }) {
                        proxy.scrollTo(group.id + "/" + id)
                    }
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            if model.working || model.computingMatches {
                ProgressView().controlSize(.small).padding(8)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                    .padding(5).allowsHitTesting(false)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if model.preferences.magnifier, let entry = hover ?? model.selection {
                VStack(alignment: .leading, spacing: 3) {
                    GlyphCanvas(entry: entry, face: model.rendering(entry))
                        .frame(height: 66)
                    Text(entry.name).font(.caption.weight(.semibold))
                    Text(entry.codes).font(.caption.monospaced())
                }
                .frame(width: 115)
                .padding(9)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
                .shadow(radius: 7, y: 2)
                .padding(13)
                .allowsHitTesting(false)
            }
        }
    }

    private func section(_ group: CharacterGroup, face: FontFace?, columns: Int, size: Double) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Button {
                model.toggleFold(group.id, all: NSEvent.modifierFlags.contains(.option))
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: model.foldedGroups.contains(group.id) ? "chevron.right" : "chevron.down")
                    Text(LocalizedStringKey(group.title)).fontWeight(.semibold)
                    Spacer()
                    Text(group.entries.count.formatted()).monospacedDigit()
                }
                .font(.caption)
                .padding(.vertical, 5)
                .padding(.horizontal, 8)
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 5))
            .contextMenu {
                Button("Copy group characters") { model.copyText(group.entries.map(\.text).joined()) }
                Button("Copy group descriptions") {
                    model.copyText(group.entries.map { model.preview($0, format: .description) }.joined(separator: "\n"))
                }
            }
            if !model.foldedGroups.contains(group.id) {
                let coverage = face.map(model.library.support)
                let favorites = Set(model.preferences.favorites.map(\.id))
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: columns), spacing: 3) {
                    ForEach(group.entries.indices, id: \.self) { index in
                        let entry = group.entries[index]
                        let native = coverage.map { model.library.covers(entry, in: $0) } ?? false
                        let missing = !native && entry.symbolName == nil && entry.scalars.first.flatMap(Unicode.Scalar.init).map {
                            model.installedCoverage?.contains($0) == false
                        } == true
                        CharacterTile(entry: entry, face: face, selected: model.selection?.id == entry.id,
                                      favorite: favorites.contains(entry.id), native: native, missing: missing, size: size)
                            .onTapGesture(count: 2) { model.selection = entry; model.insert(entry) }
                            .onTapGesture { model.selection = entry }
                            .onHover { inside in if model.preferences.magnifier { hover = inside ? entry : nil } }
                            .accessibilityAction { model.selection = entry }
                            .accessibilityAction(named: Text("Insert")) { model.selection = entry; model.insert(entry) }
                            .id(group.id + "/" + entry.id)
                            .contextMenu {
                                Button("Insert") { model.selection = entry; model.insert(entry) }
                                Button(favorites.contains(entry.id) ? "Remove from Favorites" : "Add to Favorites") {
                                    model.toggleFavorite(entry)
                                }
                                Menu("Copy as") { CopyMenu(model: model, entry: entry) }
                                Button("Find similar shapes") { model.selection = entry; model.findSimilar() }
                            }
                    }
                }
                // Shared characters can keep their old AppKit views when the selected face changes.
                .id(face?.id)
            }
        }
    }
}

private struct CharacterTile: View {
    let entry: CharacterEntry
    let face: FontFace?
    let selected: Bool
    let favorite: Bool
    let native: Bool
    let missing: Bool
    let size: Double

    var body: some View {
        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: 6)
                .fill(selected ? Color.accentColor.opacity(0.17) : Color.primary.opacity(0.04))
            if missing {
                Image(systemName: "questionmark.square.dashed")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityHidden(true)
            } else {
                GlyphCanvas(entry: entry, face: face)
                    .padding(2)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            if !native && !missing && entry.symbolName == nil {
                Image(systemName: "circle.dotted").font(.system(size: 8))
                    .foregroundStyle(.secondary).padding(3)
                    .accessibilityHidden(true)
            }
            if favorite {
                Image(systemName: "star.fill").font(.system(size: 8))
                    .foregroundStyle(Color.accentColor)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .padding(3)
                    .accessibilityHidden(true)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 1.5))
        .frame(height: max(34, size - 5))
        .contentShape(Rectangle())
        .help([entry.name, entry.codes, missing ? "No installed glyph" : native ? "" : "Outside selected face"].filter { !$0.isEmpty }.joined(separator: " · "))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entry.name)
        .accessibilityValue(entry.codes + (missing ? ", no installed glyph" : native ? "" : ", outside selected face"))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

struct GlyphCanvas: NSViewRepresentable {
    var entry: CharacterEntry
    var face: FontFace?
    var guides = false
    var zoom: CGFloat = 1

    func makeNSView(context: Context) -> GlyphCanvasView { GlyphCanvasView(frame: .zero) }

    func updateNSView(_ view: GlyphCanvasView, context: Context) {
        view.entry = entry
        view.face = face
        view.guides = guides
        view.zoom = zoom
        view.needsDisplay = true
    }
}

final class GlyphCanvasView: NSView {
    var entry: CharacterEntry?
    var face: FontFace?
    var guides = false
    var zoom: CGFloat = 1

    override func draw(_ dirtyRect: NSRect) {
        guard let entry, let context = NSGraphicsContext.current?.cgContext else { return }
        GlyphDrawing.draw(entry, face: face, in: bounds, context: context, color: NSColor.labelColor.cgColor,
                          guides: guides, zoom: zoom)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
