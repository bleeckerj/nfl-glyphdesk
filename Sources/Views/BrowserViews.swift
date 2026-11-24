import AppKit
import SwiftUI

struct PaletteView: View {
    @ObservedObject var model: DeskModel
    let delegate: DeskDelegate

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Glyph Desk", systemImage: "character.book.closed")
                    .font(.headline)
                Spacer()
                Button { delegate.openWorkspace() } label: {
                    Label("Workspace", systemImage: "macwindow")
                }
                Button { delegate.settings() } label: {
                    Image(systemName: "gearshape").accessibilityLabel("Settings")
                }
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 16)
            .padding(.top, 32)
            .padding(.bottom, 8)
            SearchControls(model: model, delegate: delegate)
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
            Divider()
            CharacterGrid(model: model, compact: true)
            Divider()
            if let selection = model.selection {
                InsertionControls(model: model, entry: selection, detailed: false)
            } else {
                Text("Search, browse, or draw a character.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
            MessageBar(model: model)
        }
        .frame(minWidth: 410, minHeight: 400)
        .background(Color(nsColor: .textBackgroundColor))
        .sheet(isPresented: $model.shapePresented) { ShapeSheet(model: model) }
    }
}

struct WorkspaceView: View {
    @ObservedObject var model: DeskModel
    let delegate: DeskDelegate
    @State private var jumpOpen = false
    @State private var editingLayout: LayoutDocument?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Label("Glyph Desk", systemImage: "character.book.closed")
                    .font(.headline)
                Picker("Workspace view", selection: $model.page) {
                    ForEach(WorkspacePage.allCases) { page in
                        Text(LocalizedStringKey(page.rawValue)).tag(page)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 360)
                Spacer(minLength: 12)
                Button("Quick palette", action: delegate.openPalette)
                Button { delegate.settings() } label: {
                    Image(systemName: "gearshape").accessibilityLabel("Settings")
                }
            }
            .padding(12)
            Divider()
            HSplitView {
                FontSidebar(model: model)
                    .frame(minWidth: 160, idealWidth: 220, maxWidth: 320)
                switch model.page {
                case .browse:
                    browse.frame(minWidth: 470)
                case .compare:
                    ComparisonView(model: model).frame(minWidth: 450)
                case .proof:
                    ProofView(model: model).frame(minWidth: 450)
                case .fontInfo:
                    FontInfoView(model: model).frame(minWidth: 450)
                }
            }
            MessageBar(model: model)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .sheet(isPresented: $model.shapePresented) { ShapeSheet(model: model) }
        .sheet(item: $editingLayout) { document in LayoutEditor(model: model, original: document) }
    }

    private var browse: some View {
        VStack(spacing: 0) {
            SearchControls(model: model, delegate: delegate).padding([.horizontal, .top], 12)
            HStack(spacing: 9) {
                Picker("Scope", selection: Binding(get: { model.scope }, set: model.pickScope)) {
                    ForEach(CharacterScope.allCases) { scope in
                        Text(LocalizedStringKey(scope.rawValue)).tag(scope)
                    }
                }
                .frame(maxWidth: 205)
                Picker("Layout", selection: Binding(get: { model.layout }, set: model.pickLayout)) {
                    ForEach(model.layoutChoices, id: \.self) { value in
                        Text(LocalizedStringKey(value)).tag(value)
                    }
                }
                .frame(maxWidth: 210)
                Button { model.linkLayout() } label: {
                    Image(systemName: model.layoutLinked ? "link.circle.fill" : "link")
                }
                .help(model.layoutLinked ? "Use the global layout for this font" : "Link this layout to the selected font")
                .accessibilityLabel(model.layoutLinked ? "Unlink font layout" : "Link layout to font")
                .disabled(model.selectedFace == nil)
                Spacer(minLength: 5)
                Button("Jump…", systemImage: "list.bullet") { jumpOpen.toggle() }
                    .labelStyle(.iconOnly)
                    .help("Jump to a group")
                    .accessibilityLabel("Jump to a group")
                    .popover(isPresented: $jumpOpen, arrowEdge: .bottom) {
                        GroupJump(model: model) { jumpOpen = false }
                    }
                Menu {
                    Button("New custom layout…") {
                        editingLayout = LayoutDocument(name: "", contents: LayoutDocument.example.contents)
                    }
                    if let current = model.preferences.layouts.first(where: { $0.name == model.layout }) {
                        Button("Edit this layout…") { editingLayout = current }
                        Button("Export this layout…") { WorkspaceFiles.exportLayout(current, model: model) }
                    }
                    Button("Import layout…") { WorkspaceFiles.importLayout(model) }
                    Divider()
                    Button("Export Favorites…") { WorkspaceFiles.exportFavorites(model) }
                    Button("Import Favorites…") { WorkspaceFiles.importFavorites(model) }
                } label: {
                    Image(systemName: "ellipsis.circle").accessibilityLabel("Layouts and Favorites")
                }
                .fixedSize()
                Button {
                    model.showDrawer.toggle()
                } label: {
                    Image(systemName: "sidebar.right").accessibilityLabel("Show character details")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            Divider()
            HSplitView {
                CharacterGrid(model: model, compact: false)
                    .frame(minWidth: 320)
                if model.showDrawer {
                    CharacterInspector(model: model)
                        .frame(minWidth: 232, idealWidth: 287, maxWidth: 380)
                }
            }
            Divider()
            HStack(spacing: 10) {
                if let face = model.selectedFace {
                    let variants = model.library.faces.filter { $0.family == face.family }
                    Picker("Style", selection: Binding(get: { face.id }, set: { value in
                        if let selected = variants.first(where: { $0.id == value }) { model.pickFace(selected) }
                    })) {
                        ForEach(variants) { item in Text(item.style).tag(item.id) }
                    }
                    .frame(maxWidth: 200)
                }
                Toggle("Magnifier", isOn: $model.preferences.magnifier)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                Spacer()
                Image(systemName: "textformat.size.smaller")
                Slider(value: Binding(get: { model.zoom }, set: model.setZoom), in: 26...82)
                    .frame(width: 110)
                    .accessibilityLabel("Character size")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }
}

struct SearchControls: View {
    @ObservedObject var model: DeskModel
    let delegate: DeskDelegate
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Name, character, or code point", text: $model.query)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit {
                        if !model.working { model.chooseFirst(); focused = false }
                    }
                    .onChange(of: model.query) { _ in
                        if model.shapeMatches != nil && !model.query.isEmpty {
                            model.shapeMatches = nil
                            model.refresh()
                        }
                    }
                if !model.query.isEmpty || model.shapeMatches != nil {
                    Button { model.clearSearch(); focused = true } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(9)
            .background(.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 8))
            Button { model.shapePresented = true } label: {
                Label("Draw", systemImage: "scribble")
            }
            .help("Find a character by drawing")
        }
        .onAppear {
            delegate.focusSearch { focused = true }
        }
    }
}

struct FontSidebar: View {
    @ObservedObject var model: DeskModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Fonts", selection: $model.fontCollection) {
                ForEach(model.allFontCollections, id: \.self) { name in
                    Text(LocalizedStringKey(name)).tag(name)
                }
            }
            TextField("Filter fonts", text: $model.fontFilter)
                .textFieldStyle(.roundedBorder)
            List {
                ForEach(families, id: \.0) { family, faces in
                    let readable = faces.first { $0.id == model.preferences.familyFaces[family] }
                        ?? faces.first { $0.style.caseInsensitiveCompare("Regular") == .orderedSame }
                        ?? faces[0]
                    Button {
                        model.pickFace(readable)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(family).font(.custom(readable.id, size: 15))
                                    .lineLimit(1)
                                if model.selectedFace?.family == family, let face = model.selectedFace {
                                    Text(face.style).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if faces.contains(where: { model.flaggedFaces.contains($0.id) }) {
                                Image(systemName: "flag.fill")
                                    .foregroundStyle(Color.accentColor)
                                    .accessibilityLabel("Contains selected character")
                            }
                        }
                        .padding(5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .background(model.selectedFace?.family == family ? Color.accentColor.opacity(0.14) : .clear,
                                    in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .help(family)
                    .contextMenu {
                        Button("Use document font", action: model.useDocumentFont).disabled(model.target == nil)
                        Button("Copy font name") { model.copyText(family) }
                        Button("Copy listed font names") { model.copyText(families.map(\.0).joined(separator: "\n")) }
                        Button("Clear flags", action: model.clearFlags)
                    }
                }
            }
            .listStyle(.plain)
            HStack {
                Text("\(families.count) families").foregroundStyle(.secondary)
                Spacer()
                if !model.flaggedFaces.isEmpty {
                    Button("Clear flags", action: model.clearFlags).buttonStyle(.link)
                }
            }
            .font(.caption)
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var families: [(String, [FontFace])] {
        Dictionary(grouping: model.fonts, by: \.family).sorted {
            $0.key.localizedStandardCompare($1.key) == .orderedAscending
        }.map { ($0.key, $0.value) }
    }
}

struct MessageBar: View {
    @ObservedObject var model: DeskModel

    var body: some View {
        if let message = model.message {
            HStack {
                Text(message).font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityAddTraits(.updatesFrequently)
                Button { model.message = nil } label: {
                    Image(systemName: "xmark").accessibilityLabel("Dismiss message")
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.accentColor.opacity(0.10))
        }
    }
}

private struct GroupJump: View {
    @ObservedObject var model: DeskModel
    var dismiss: () -> Void
    @State private var text = ""

    var body: some View {
        VStack(spacing: 8) {
            TextField("Find a group", text: $text)
                .textFieldStyle(.roundedBorder)
                .onSubmit { if let first = matching.first { jump(first) } }
            List(matching) { group in
                Button { jump(group) } label: {
                    HStack { Text(LocalizedStringKey(group.title)); Spacer(); Text(group.entries.count.formatted()).foregroundStyle(.secondary) }
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
        }
        .frame(width: 265, height: 290)
        .padding(10)
    }

    private var matching: [CharacterGroup] {
        model.visibleGroups.filter { text.isEmpty || $0.title.localizedCaseInsensitiveContains(text) }
    }

    private func jump(_ group: CharacterGroup) {
        model.foldedGroups.remove(group.id)
        model.jumpID = group.id
        model.selection = group.entries.first
        dismiss()
    }
}
