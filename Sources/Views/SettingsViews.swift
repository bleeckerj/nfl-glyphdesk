import AppKit
import Carbon
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

struct DeskSettings: View {
    @ObservedObject var model: DeskModel
    let delegate: DeskDelegate
    @State private var login = SMAppService.mainApp.status == .enabled
    @State private var recording = false

    var body: some View {
        Form {
            Section("Activation") {
                HStack {
                    Text("Global shortcut")
                    Spacer()
                    Button(recording ? "Press keys…" : model.preferences.hotkey?.title ?? "Set shortcut") {
                        recording.toggle()
                    }
                    Button("Clear") {
                        model.preferences.hotkey = nil
                        delegate.configureActivation()
                    }
                    .disabled(model.preferences.hotkey == nil)
                }
                if recording {
                    HotkeyRecorder { key in
                        recording = false
                        if let key {
                            model.preferences.hotkey = key
                            delegate.configureActivation()
                        }
                    }
                    .frame(width: 1, height: 1)
                }
                Picker("Screen corner", selection: $model.preferences.corner) {
                    ForEach(Corner.allCases) { corner in
                        Text(LocalizedStringKey(corner.rawValue)).tag(corner)
                    }
                }
                .onChange(of: model.preferences.corner) { _ in delegate.configureActivation() }
                Toggle("Launch at login", isOn: $login)
                    .onChange(of: login) { delegate.setLogin($0) }
                Toggle("Open the compact palette", isOn: $model.preferences.compactByDefault)
                Toggle("Keep the palette open after insertion", isOn: $model.preferences.keepPaletteOpen)
            }
            Section("Insertion") {
                Picker("HTML references", selection: $model.preferences.htmlStyle) {
                    ForEach(EntityStyle.allCases) { style in
                        Text(LocalizedStringKey(style.rawValue)).tag(style)
                    }
                }
                HStack {
                    Button("Allow Accessibility…") { InsertionService.requestPermission() }
                    Button("Check Clipboard Access") {
                        let clipboard = NSPasteboard.general
                        _ = clipboard.string(forType: .string)
                        if #available(macOS 26, *), clipboard.accessBehavior != .alwaysAllow {
                            model.message = "For formatted and picture insertion, allow Glyph Desk access to the pasteboard in System Settings."
                        } else {
                            model.message = "Clipboard access is available."
                        }
                    }
                }
                Text("Accessibility enables direct insertion. Clipboard access lets Glyph Desk restore your previous clipboard after a rich paste.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Browsing") {
                Toggle("Show the magnifier", isOn: $model.preferences.magnifier)
                Stepper(value: $model.preferences.recentLimit, in: 0...300) {
                    Text("Keep \(model.preferences.recentLimit) recent characters")
                }
                Button("Clear recents") {
                    model.preferences.recents.removeAll()
                    model.preferences.recentFonts.removeAll()
                    model.refresh()
                }
                Button("Refresh installed fonts", action: model.reloadFonts)
            }
            Section("Help") {
                Button("Open the guide") {
                    if let guide = Bundle.main.url(forResource: "Guide", withExtension: "txt") {
                        NSWorkspace.shared.open(guide)
                    }
                }
                Button("Export diagnostics…") { WorkspaceFiles.exportDiagnostics(model) }
                if let versions = model.catalog?.versions() {
                    Text(versions).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 530, height: 555)
        .safeAreaInset(edge: .bottom, spacing: 0) { MessageBar(model: model) }
    }
}

struct LayoutEditor: View {
    @ObservedObject var model: DeskModel
    @State var original: LayoutDocument
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Custom layout").font(.title2.weight(.semibold))
            TextField("Layout name", text: $original.name)
                .textFieldStyle(.roundedBorder)
            TextEditor(text: $original.contents)
                .font(.system(.body, design: .monospaced))
                .overlay(Rectangle().strokeBorder(.secondary.opacity(0.3)))
                .accessibilityLabel("Layout contents")
            if let error { Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save layout") {
                    do {
                        original.name = original.name.trimmingCharacters(in: .whitespacesAndNewlines)
                        try model.loadLayout(original)
                        dismiss()
                    } catch { self.error = error.localizedDescription }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(original.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 500, height: 395)
    }
}

enum WorkspaceFiles {
    @MainActor
    static func importLayout(_ model: DeskModel) {
        guard let path = read(type: .plainText) else { return }
        do {
            let value = try String(contentsOf: path, encoding: .utf8)
            let layout = LayoutDocument(name: path.deletingPathExtension().lastPathComponent, contents: value)
            try model.loadLayout(layout)
        } catch { model.message = error.localizedDescription }
    }

    @MainActor
    static func exportLayout(_ document: LayoutDocument, model: DeskModel) {
        save(Data(document.contents.utf8), type: .plainText, name: document.name + ".txt", model: model)
    }

    @MainActor
    static func exportFavorites(_ model: DeskModel) {
        do { save(try model.favoritesData(), type: .json, name: "Glyph Desk Favorites.json", model: model) }
        catch { model.message = error.localizedDescription }
    }

    @MainActor
    static func importFavorites(_ model: DeskModel) {
        guard let path = read(type: .json) else { return }
        do { try model.readFavorites(Data(contentsOf: path)) }
        catch { model.message = error.localizedDescription }
    }

    @MainActor
    static func exportDiagnostics(_ model: DeskModel) {
        let fields: [String: Any] = [
            "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
            "glyphDesk": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            "catalog": model.catalog?.versions() ?? "unavailable",
            "fontFamilies": model.fontCount,
            "fontFaces": model.library.faces.count,
            "accessibility": InsertionService.hasPermission,
            "loginItem": SMAppService.mainApp.status == .enabled
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: fields, options: [.prettyPrinted, .sortedKeys])
            let preview = NSAlert()
            preview.messageText = "Review diagnostics"
            preview.informativeText = String(decoding: data, as: UTF8.self)
            preview.addButton(withTitle: "Save…")
            preview.addButton(withTitle: "Cancel")
            if preview.runModal() == .alertFirstButtonReturn {
                save(data, type: .json, name: "Glyph Desk diagnostics.json", model: model)
            }
        } catch { model.message = error.localizedDescription }
    }

    @MainActor
    private static func read(type: UTType) -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [type]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    @MainActor
    static func save(_ data: Data, type: UTType, name: String, model: DeskModel) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        panel.nameFieldStringValue = name
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do { try data.write(to: destination, options: .atomic) }
        catch { model.message = error.localizedDescription }
    }
}

private struct HotkeyRecorder: NSViewRepresentable {
    let finished: (HotkeyPreference?) -> Void

    func makeNSView(context: Context) -> KeyField {
        let field = KeyField(frame: .zero)
        field.finished = finished
        DispatchQueue.main.async { _ = field.window?.makeFirstResponder(field) }
        return field
    }

    func updateNSView(_ view: KeyField, context: Context) { view.finished = finished }

    final class KeyField: NSView {
        var finished: ((HotkeyPreference?) -> Void)?
        override var acceptsFirstResponder: Bool { true }

        override func keyDown(with event: NSEvent) {
            if event.keyCode == 53 { finished?(nil); return }
            let modifiers: [(NSEvent.ModifierFlags, Int, String)] = [
                (.control, controlKey, "⌃"), (.option, optionKey, "⌥"), (.shift, shiftKey, "⇧"), (.command, cmdKey, "⌘")
            ]
            let pressed = modifiers.filter { event.modifierFlags.contains($0.0) }
            guard pressed.contains(where: { [.control, .option, .command].contains($0.0) }) else {
                NSSound.beep()
                return
            }
            let mask = pressed.reduce(0) { $0 | $1.1 }
            let labels: [UInt16: String] = [49: "Space", 48: "Tab", 36: "Return", 123: "←", 124: "→", 125: "↓", 126: "↑"]
            let keyName = labels[event.keyCode] ?? event.charactersIgnoringModifiers?.uppercased() ?? "\(event.keyCode)"
            finished?(HotkeyPreference(key: UInt32(event.keyCode), modifiers: UInt32(mask),
                                       title: pressed.map(\.2).joined() + keyName))
        }
    }
}
