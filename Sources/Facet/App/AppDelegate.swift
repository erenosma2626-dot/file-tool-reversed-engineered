import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var shared: AppDelegate?

    private let drag = DragMonitor()
    private let wheel = WheelController()
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        updateStatusItem()

        drag.onModifiersPressed = { [weak self] combo, point in
            guard let self else { return }
            self.wheel.handle(combo: combo, urls: self.drag.urls, at: point)
        }
        drag.onDragEnded = { [weak self] in
            self?.wheel.dragEnded()
            ShelfManager.shared.dragEnded()
        }
        drag.onShake = { [weak self] point in
            guard let self, !self.wheel.isOpen else { return }
            ShelfManager.shared.shakeDetected(at: point)
        }
        drag.start()

        if !UserDefaults.standard.bool(forKey: "didOnboard") {
            UserDefaults.standard.set(true, forKey: "didOnboard")
            SettingsWindow.shared.show(tab: .general)
        }
    }

    /// Launching the app again (Finder, Spotlight) opens Settings — useful when the menu bar
    /// icon is hidden.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SettingsWindow.shared.show()
        return true
    }

    func updateStatusItem() {
        if Prefs.shared.showMenuBarIcon {
            guard statusItem == nil else { return }
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            if let button = item.button {
                // 36px template glyph drawn at 18pt; falls back to an SF Symbol.
                let image = Bundle.main.image(forResource: "MenuBarIcon")
                    ?? NSImage(systemSymbolName: "circle.hexagongrid", accessibilityDescription: "Facet")
                image?.size = NSSize(width: 18, height: 18)
                image?.isTemplate = true
                button.image = image
            }
            item.menu = makeMenu()
            statusItem = item
        } else if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "New Shelf", action: #selector(newShelf), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "About Facet", action: #selector(openAbout), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Facet", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }

    @objc private func newShelf() { ShelfManager.shared.newShelf(with: [], at: NSEvent.mouseLocation) }
    @objc private func openSettings() { SettingsWindow.shared.show() }
    @objc private func openAbout() { SettingsWindow.shared.show(tab: .about) }
}
