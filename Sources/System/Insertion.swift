import AppKit
import ApplicationServices
import Carbon

struct PastePayload {
    let text: String?
    let representations: [(NSPasteboard.PasteboardType, Data)]

    init(text: String? = nil, representations: [(NSPasteboard.PasteboardType, Data)] = []) {
        self.text = text
        self.representations = representations
    }

    func write(to pasteboard: NSPasteboard) -> Bool {
        let item = NSPasteboardItem()
        if let text { item.setString(text, forType: .string) }
        for (type, data) in representations { item.setData(data, forType: type) }
        guard !item.types.isEmpty else { return false }
        pasteboard.clearContents()
        return pasteboard.writeObjects([item])
    }
}

struct InsertionTarget {
    let app: NSRunningApplication
    let element: AXUIElement?
    let window: AXUIElement?
    let secure: Bool

    var name: String { app.localizedName ?? app.bundleIdentifier ?? "Current app" }
    var key: String { app.bundleIdentifier ?? "unidentified" }

    static func capture(_ app: NSRunningApplication? = NSWorkspace.shared.frontmostApplication) -> Self? {
        guard let app, app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.25)
        let element = axElement(root, kAXFocusedUIElementAttribute)
        let subrole = element.flatMap { axValue($0, kAXSubroleAttribute) as? String }
        return Self(app: app, element: element, window: axElement(root, kAXFocusedWindowAttribute),
                    secure: subrole == kAXSecureTextFieldSubrole || IsSecureEventInputEnabled())
    }

    func matchesFocus() -> Bool {
        guard let current = Self.capture(app), !current.secure,
              let element, let newElement = current.element, CFEqual(element, newElement) else { return false }
        guard let window else { return true }
        return current.window.map { CFEqual(window, $0) } ?? false
    }

    func documentFont() -> String? {
        guard let element,
              let range = axValue(element, kAXSelectedTextRangeAttribute),
              CFGetTypeID(range) == AXValueGetTypeID() else { return nil }
        var selection = CFRange()
        guard AXValueGetValue(range as! AXValue, .cfRange, &selection) else { return nil }
        selection.location = max(0, selection.location - (selection.length == 0 && selection.location > 0 ? 1 : 0))
        selection.length = 1
        guard let parameter = AXValueCreate(.cfRange, &selection) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXAttributedStringForRangeParameterizedAttribute as CFString, parameter, &value) == .success,
              let text = value as? NSAttributedString, text.length > 0 else { return nil }
        if let font = text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont { return font.fontName }
        return (text.attribute(NSAttributedString.Key(kAXFontTextAttribute.takeUnretainedValue() as String), at: 0, effectiveRange: nil)
                as? [String: Any])?[kAXFontNameKey.takeUnretainedValue() as String] as? String
    }
}

private func axValue(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
    return value
}

private func axElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
    guard let value = axValue(element, attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return (value as! AXUIElement)
}

enum InsertionResult: Equatable {
    case posted
    case copyRequired(String)
}

@MainActor
final class InsertionService {
    private var busy = false

    static var hasPermission: Bool { AXIsProcessTrusted() && CGPreflightPostEventAccess() }

    static func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    func insert(_ payload: PastePayload, into target: InsertionTarget?, dismiss: () -> Void) async -> InsertionResult {
        guard !busy else { return .copyRequired("Wait for the current insertion to finish.") }
        busy = true
        defer { busy = false }

        guard Self.hasPermission else { return .copyRequired("Allow Accessibility for direct insertion, or use Copy.") }
        guard let target, !target.app.isTerminated, target.element != nil, !target.secure else {
            return .copyRequired("A writable destination could not be verified. Use Copy to paste it yourself.")
        }

        let clipboard = NSPasteboard.general
        guard let snapshot = ClipboardSnapshot(clipboard) else {
            return .copyRequired("The existing clipboard could not be preserved. Use Copy if you want to replace it.")
        }
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: false) else {
            return .copyRequired("A paste event could not be created.")
        }
        dismiss()
        _ = target.app.activate(options: [])
        var ready = false
        for _ in 0..<20 {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == target.app.processIdentifier,
               target.matchesFocus() {
                ready = true
                break
            }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }

        guard ready, clipboard.changeCount == snapshot.changeCount else {
            return .copyRequired("The destination or clipboard changed. Open the palette again or use Copy.")
        }

        guard payload.write(to: clipboard) else {
            snapshot.restore(to: clipboard, ownedChange: clipboard.changeCount)
            return .copyRequired("The clipboard rejected this format.")
        }

        let ownedChange = clipboard.changeCount
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.postToPid(target.app.processIdentifier)
        up.postToPid(target.app.processIdentifier)
        try? await Task.sleep(nanoseconds: 450_000_000)
        snapshot.restore(to: clipboard, ownedChange: ownedChange)
        return .posted
    }
}

struct ClipboardSnapshot {
    let changeCount: Int
    private let items: [[(NSPasteboard.PasteboardType, Data)]]

    init?(_ pasteboard: NSPasteboard) {
        if #available(macOS 26, *), pasteboard.name == .general,
           pasteboard.accessBehavior == .alwaysDeny { return nil }
        changeCount = pasteboard.changeCount
        let readable = pasteboard.pasteboardItems
        if #available(macOS 26, *), pasteboard.name == .general,
           pasteboard.accessBehavior != .alwaysAllow, readable == nil { return nil }
        var collected: [[(NSPasteboard.PasteboardType, Data)]] = []
        for item in readable ?? [] {
            var entry: [(NSPasteboard.PasteboardType, Data)] = []
            for type in item.types {
                guard !type.rawValue.localizedCaseInsensitiveContains("promise"),
                      !type.rawValue.localizedCaseInsensitiveContains("concealed"),
                      let data = item.data(forType: type), data.count <= 16 * 1024 * 1024 else { return nil }
                entry.append((type, data))
            }
            collected.append(entry)
        }
        guard changeCount == pasteboard.changeCount else { return nil }
        items = collected
    }

    func restore(to pasteboard: NSPasteboard, ownedChange: Int) {
        guard pasteboard.changeCount == ownedChange else { return }
        pasteboard.clearContents()
        let objects = items.map { values in
            let item = NSPasteboardItem()
            for (type, data) in values { item.setData(data, forType: type) }
            return item
        }
        if !objects.isEmpty { pasteboard.writeObjects(objects) }
    }
}
