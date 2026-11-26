import AppKit
import Carbon
import ServiceManagement
import SwiftUI

struct GlyphDeskApp: App {
    @NSApplicationDelegateAdaptor(DeskDelegate.self) var delegate

    var body: some Scene {
        Settings { DeskSettings(model: delegate.model, delegate: delegate) }
    }
}

@MainActor
final class DeskDelegate: NSObject, NSApplicationDelegate {
    lazy var model = DeskModel()
    private lazy var launchers = ActivationLaunchers(onOpen: { [weak self] in self?.toggleDefault() }) { [weak self] in
        self?.activationMenu() ?? NSMenu()
    }
    private var palette: NSPanel?
    private var workspace: NSWindow?
    private var preferencesWindow: NSWindow?
    private var lastExternal: NSRunningApplication?
    private var applicationObserver: NSObjectProtocol?
    private var localEvents: Any?
    private var hotkey: HotkeyController?
    private var cornerTimer: Timer?
    private var pointerWasAtCorner = false
    private var responseToSearch: (() -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        lastExternal = NSWorkspace.shared.frontmostApplication
        applicationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notice in
            let app = notice.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            Task { @MainActor in
                if let app, app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                    self?.lastExternal = app
                }
            }
        }

        model.dismissForInsert = { [weak self] in self?.hideWindows() }
        model.reopenAfterInsert = { [weak self] compact in self?.show(compact: compact, retarget: false) }
        model.paletteIsVisible = { [weak self] in self?.palette?.isVisible ?? false }
        configureLaunchers()
        configureActivation()
        localEvents = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event) ?? event
        }
        if CommandLine.arguments.contains("--workspace") {
            show(compact: false)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if palette?.isVisible == true {
            show(compact: true, retarget: false)
        } else if workspace?.isVisible == true || workspace?.isMiniaturized == true {
            workspace?.deminiaturize(nil)
            show(compact: false, retarget: false)
        } else {
            show(compact: model.preferences.compactByDefault)
        }
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.saveImmediately()
        launchers.close()
        if let localEvents { NSEvent.removeMonitor(localEvents) }
        if let applicationObserver { NSWorkspace.shared.notificationCenter.removeObserver(applicationObserver) }
        cornerTimer?.invalidate()
    }

    func openWorkspace() { show(compact: false, retarget: false) }
    func openPalette() { show(compact: true, retarget: true) }
    func focusSearch(using action: @escaping () -> Void) { responseToSearch = action }

    func settings() {
        if preferencesWindow == nil {
            let window = NSWindow(contentRect: CGRect(x: 30, y: 40, width: 540, height: 560),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Glyph Desk Settings"
            window.contentViewController = NSHostingController(rootView: DeskSettings(model: model, delegate: self))
            window.isReleasedWhenClosed = false
            preferencesWindow = window
            window.center()
        }
        NSApp.activate(ignoringOtherApps: true)
        preferencesWindow?.makeKeyAndOrderFront(nil)
    }

    func configureLaunchers() {
        launchers.update(model.preferences.launcher)
    }

    func configureActivation() {
        hotkey = nil
        if let key = model.preferences.hotkey {
            hotkey = HotkeyController(preference: key) { [weak self] in self?.toggleDefault() }
            if hotkey == nil { model.message = "The shortcut is unavailable. Try another combination." }
        }
        cornerTimer?.invalidate()
        cornerTimer = nil
        pointerWasAtCorner = false
        if model.preferences.corner != .off {
            cornerTimer = Timer.scheduledTimer(withTimeInterval: 0.20, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.pollCorner() }
            }
        }
    }

    func setLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            model.message = "Launch at login could not be changed. \(error.localizedDescription)"
        }
    }

    private func activationMenu() -> NSMenu {
        let menu = NSMenu()
        for (title, action) in [("Open Palette", #selector(menuPalette)), ("Open Workspace", #selector(menuWorkspace)),
                                ("Settings…", #selector(menuSettings)), ("Quit Glyph Desk", #selector(quit))] {
            let item = NSMenuItem(title: String(localized: String.LocalizationValue(title)), action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        return menu
    }

    @objc private func menuPalette() { openPalette() }
    @objc private func menuWorkspace() { show(compact: false) }
    @objc private func menuSettings() { settings() }
    @objc private func quit() { NSApp.terminate(nil) }

    private func toggleDefault() {
        if palette?.isKeyWindow == true || workspace?.isKeyWindow == true { hideWindows() }
        else { show(compact: model.preferences.compactByDefault) }
    }

    private func hideWindows() {
        palette?.orderOut(nil)
        workspace?.orderOut(nil)
    }

    private func show(compact: Bool, retarget: Bool = true) {
        if retarget {
            let frontmost = NSWorkspace.shared.frontmostApplication
            let current = frontmost?.processIdentifier == ProcessInfo.processInfo.processIdentifier
                ? lastExternal : frontmost
            model.open(over: current)
        }
        NSApp.activate(ignoringOtherApps: true)
        if compact {
            workspace?.orderOut(nil)
            if palette == nil {
                let window = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 466, height: 570),
                                     styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                                     backing: .buffered, defer: false)
                window.title = "Glyph Desk"
                window.titleVisibility = .hidden
                window.titlebarAppearsTransparent = true
                window.isFloatingPanel = true
                window.hidesOnDeactivate = !model.preferences.keepPaletteOpen
                window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
                window.contentMinSize = CGSize(width: 410, height: 400)
                window.isReleasedWhenClosed = false
                window.contentViewController = NSHostingController(rootView: PaletteView(model: model, delegate: self))
                window.center()
                window.setFrameAutosaveName("Glyph Desk Palette")
                palette = window
            }
            palette?.hidesOnDeactivate = !model.preferences.keepPaletteOpen
            palette?.makeKeyAndOrderFront(nil)
        } else {
            palette?.orderOut(nil)
            if workspace == nil {
                let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1160, height: 770),
                                      styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                      backing: .buffered, defer: false)
                window.title = "Glyph Desk"
                window.isReleasedWhenClosed = false
                window.contentMinSize = CGSize(width: 840, height: 520)
                window.contentViewController = NSHostingController(rootView: WorkspaceView(model: model, delegate: self))
                window.center()
                window.setFrameAutosaveName("Glyph Desk Workspace")
                workspace = window
            }
            workspace?.makeKeyAndOrderFront(nil)
        }
    }

    private func pollCorner() {
        let location = NSEvent.mouseLocation
        let active = NSScreen.screens.contains { screen in
            let frame = screen.frame
            let left = model.preferences.corner == .left
            let x = left ? frame.minX : frame.maxX - 1
            return abs(location.x - x) <= 2 && abs(location.y - (frame.maxY - 1)) <= 2
        }
        if active && !pointerWasAtCorner && palette?.isVisible != true && workspace?.isVisible != true {
            show(compact: model.preferences.compactByDefault)
        }
        pointerWasAtCorner = active
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let window = event.window, window == workspace || window == palette else { return event }
        if event.keyCode == 53, !model.shapePresented {
            if !model.query.isEmpty || model.shapeMatches != nil { model.clearSearch() }
            else { hideWindows() }
            return nil
        }
        if event.modifierFlags.contains(.command) {
            let key = event.charactersIgnoringModifiers?.lowercased()
            if key == "f" { responseToSearch?(); return nil }
            if key == "," { settings(); return nil }
            if key == "1" { model.page = .browse; return nil }
            if key == "2" { model.page = .proof; return nil }
            if key == "3" { model.page = .compare; return nil }
            if key == "4" { model.page = .fontInfo; return nil }
        }
        if window.firstResponder is NSTextView || model.shapePresented { return event }
        if event.modifierFlags.contains(.command), let selection = model.selection {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "c": model.copy(selection); return nil
            case "b": model.toggleFavorite(selection); return nil
            default: break
            }
        }
        if model.page == .browse || palette?.isKeyWindow == true {
            switch event.keyCode {
            case 123: model.chooseByOffset(-1); return nil
            case 124: model.chooseByOffset(1); return nil
            case 125: model.chooseByOffset(8); return nil
            case 126: model.chooseByOffset(-8); return nil
            case 116, 121:
                let groups = model.visibleGroups
                if !groups.isEmpty {
                    let current = groups.firstIndex { $0.entries.contains { $0.id == model.selection?.id } } ?? 0
                    let next = min(groups.count - 1, max(0, current + (event.keyCode == 116 ? -1 : 1)))
                    model.jumpID = groups[next].id
                    model.selection = groups[next].entries.first
                }
                return nil
            case 36, 76:
                if let entry = model.selection { model.insert(entry) }
                else { model.chooseFirst() }
                return nil
            default: break
            }
        }
        return event
    }
}

private final class HotkeyController {
    var eventHandler: EventHandlerRef?
    var reference: EventHotKeyRef?
    let action: @MainActor () -> Void

    init?(preference: HotkeyPreference, action: @escaping @MainActor () -> Void) {
        self.action = action
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let install = InstallEventHandler(GetApplicationEventTarget(), { _, _, pointer in
            guard let pointer else { return OSStatus(eventNotHandledErr) }
            let controller = Unmanaged<HotkeyController>.fromOpaque(pointer).takeUnretainedValue()
            let action = controller.action
            Task { @MainActor in action() }
            return noErr
        }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
        guard install == noErr else { return nil }
        let id = EventHotKeyID(signature: 0x474c5950, id: 1)
        guard RegisterEventHotKey(preference.key, preference.modifiers, id, GetApplicationEventTarget(), 0, &reference) == noErr
        else { return nil }
    }

    deinit {
        if let reference { UnregisterEventHotKey(reference) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }
}
