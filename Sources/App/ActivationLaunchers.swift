import AppKit

@MainActor
final class ActivationLaunchers: NSObject {
    private static let buttonSize = CGSize(width: 26, height: 24)
    private static let edgeInset: CGFloat = 4

    private let onOpen: () -> Void
    private let makeMenu: () -> NSMenu
    private var corner: CornerButtonPosition?
    private(set) var menuBarItem: NSStatusItem?
    private(set) var cornerPanel: NSPanel?

    init(onOpen: @escaping () -> Void, makeMenu: @escaping () -> NSMenu) {
        self.onOpen = onOpen
        self.makeMenu = makeMenu
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(screenChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(screenChanged), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil
        )
    }

    func update(_ preferences: LauncherPreferences) {
        setMenuBarVisible(preferences.mode.showsMenuBar)
        corner = preferences.mode.showsCornerButton ? preferences.corner : nil
        updateCornerButton()
    }

    func close() {
        setMenuBarVisible(false)
        corner = nil
        updateCornerButton()
    }

    private func setMenuBarVisible(_ visible: Bool) {
        guard visible else {
            if let menuBarItem { NSStatusBar.system.removeStatusItem(menuBarItem) }
            menuBarItem = nil
            return
        }
        guard menuBarItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = launcherImage
        item.button?.toolTip = String(localized: "Open Glyph Desk")
        item.button?.target = self
        item.button?.action = #selector(menuBarClicked(_:))
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        menuBarItem = item
    }

    @objc private func menuBarClicked(_ button: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            makeMenu().popUp(positioning: nil, at: CGPoint(x: 0, y: button.bounds.maxY + 4), in: button)
        } else {
            onOpen()
        }
    }

    @objc private func screenChanged(_ notification: Notification) {
        updateCornerButton()
    }

    private func updateCornerButton() {
        guard let corner, let screen = NSScreen.screens.first else {
            cornerPanel?.orderOut(nil)
            cornerPanel = nil
            return
        }
        let panel = cornerPanel ?? makeCornerPanel()
        cornerPanel = panel
        let frame = Self.frame(in: screen.visibleFrame, position: corner)
        panel.setFrame(frame, display: true)
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    private static func frame(in screen: CGRect, position: CornerButtonPosition) -> CGRect {
        let x = position == .topLeft ? screen.minX + edgeInset : screen.maxX - buttonSize.width - edgeInset
        return CGRect(origin: CGPoint(x: x, y: screen.maxY - buttonSize.height - edgeInset), size: buttonSize)
    }

    private func makeCornerPanel() -> NSPanel {
        let bounds = CGRect(origin: .zero, size: Self.buttonSize)
        let panel = NSPanel(
            contentRect: bounds, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        let surface = NSVisualEffectView(frame: bounds)
        surface.material = .popover
        surface.blendingMode = .behindWindow
        surface.state = .active
        surface.wantsLayer = true
        surface.layer?.cornerRadius = 6
        surface.layer?.masksToBounds = true

        let button = CornerButton(frame: bounds)
        let label = String(localized: "Open Glyph Desk")
        button.setButtonType(.momentaryPushIn)
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.image = launcherImage?.withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))
        button.target = self
        button.action = #selector(cornerClicked)
        button.menu = makeMenu()
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.autoresizingMask = [.width, .height]
        surface.addSubview(button)
        panel.contentView = surface
        return panel
    }

    @objc private func cornerClicked() {
        onOpen()
    }

    private var launcherImage: NSImage? {
        let label = String(localized: "Glyph Desk")
        return NSImage(systemSymbolName: "character.book.closed", accessibilityDescription: label)
            ?? NSImage(systemSymbolName: "textformat", accessibilityDescription: label)
    }
}

private final class CornerButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
