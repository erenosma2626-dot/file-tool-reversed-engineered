import AppKit
import SwiftUI

/// Transparent, non-activating panel that sits above everything (including full-screen apps).
final class OverlayPanel: NSPanel {
    init(size: NSSize) {
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Picks an operation the drag source allows. Holding ⌘ or ⌃ during a Finder drag narrows
/// the source mask to generic/link, so a fixed `.copy` would make the drop bounce.
func acceptableOperation(_ sender: NSDraggingInfo) -> NSDragOperation {
    let mask = sender.draggingSourceOperationMask
    for op in [NSDragOperation.copy, .generic, .link, .move] where mask.contains(op) { return op }
    return []
}

/// Receives the drop while the wheel is open and maps the pointer to a segment.
final class WheelDropView: NSView {
    weak var controller: WheelController?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    private func update(_ sender: NSDraggingInfo) -> NSDragOperation {
        let p = convert(sender.draggingLocation, from: nil)
        controller?.hover(at: p)
        return controller?.model.hovered == nil ? [] : acceptableOperation(sender)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { update(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { update(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { controller?.hover(at: nil) }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { controller?.model.hovered != nil }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let opts: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: opts) as? [URL] ?? []
        return controller?.drop(urls: urls, at: NSEvent.mouseLocation) ?? false
    }
}

/// Owns the wheel panel and turns drag events into wheel state.
final class WheelController {
    let model = WheelModel()
    private let panel: OverlayPanel
    private let dropView: WheelDropView
    private var hideWork: DispatchWorkItem?

    init() {
        let size = NSSize(width: WheelModel.size, height: WheelModel.size)
        panel = OverlayPanel(size: size)
        dropView = WheelDropView(frame: NSRect(origin: .zero, size: size))
        let host = NSHostingView(rootView: WheelView(model: model))
        host.frame = dropView.bounds
        host.autoresizingMask = [.width, .height]
        dropView.addSubview(host)
        panel.contentView = dropView
        dropView.controller = self
    }

    var isOpen: Bool { model.visible }

    /// Opens (or switches) the wheel for a modifier combination pressed mid-drag.
    func handle(combo: ModifierCombo, urls: [URL], at point: NSPoint) {
        let prefs = Prefs.shared
        let kind: WheelKind? = WheelKind.allCases.first { prefs.key(for: $0) == combo }
        guard let kind else { return }
        // Tapping the same keys again closes the wheel.
        if isOpen && model.kind == kind {
            close()
            return
        }
        open(kind, urls: urls, at: point)
    }

    func open(_ kind: WheelKind, urls: [URL], at point: NSPoint) {
        // Unknown file types (and folders) still get the actions wheel.
        let known = dominantCategory(urls)
        guard let category = known ?? (kind == .actions && !urls.isEmpty ? .document : nil) else { return }
        hideWork?.cancel()
        let relevant = kind == .actions || known == nil ? urls : urls.filter { Category.of($0) == category }
        model.urls = relevant
        model.category = category
        model.kind = kind
        model.items = Catalog.items(for: kind, category: category, urls: relevant)
        model.hovered = nil

        if !isOpen {
            let s = WheelModel.size
            var origin = NSPoint(x: point.x - s / 2, y: point.y - s / 2)
            if let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) {
                let f = screen.frame
                origin.x = min(max(origin.x, f.minX - s * 0.25), f.maxX - s * 0.75)
                origin.y = min(max(origin.y, f.minY - s * 0.25), f.maxY - s * 0.75)
            }
            panel.setFrameOrigin(origin)
            panel.orderFrontRegardless()
            DispatchQueue.main.async { self.model.visible = true }
        }
        Feedback.open()
    }

    func close() {
        model.visible = false
        model.hovered = nil
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.model.visible else { return }
            self.panel.orderOut(nil)
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    /// Called when the system drag ends. A drop on the wheel arrives around the same time,
    /// so give it a moment before tearing the wheel down.
    func dragEnded() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.close()
        }
    }

    func hover(at p: CGPoint?) {
        let i = p.flatMap { model.index(at: $0) }
        if i != model.hovered {
            model.hovered = i
            if i != nil { Feedback.tick() }
        }
    }

    func drop(urls: [URL], at point: NSPoint) -> Bool {
        guard let i = model.hovered, i < model.items.count else { return false }
        let item = model.items[i]
        let category = model.category
        var files = urls
        if case .action = item {} else { files = urls.filter { Category.of($0) == category } }
        close()
        // Let the drag session finish before doing real work.
        DispatchQueue.main.async {
            Actions.perform(item, urls: files.isEmpty ? urls : files, category: category, at: point)
        }
        return true
    }

    private func dominantCategory(_ urls: [URL]) -> Category? {
        var counts: [Category: Int] = [:]
        for u in urls { if let c = Category.of(u) { counts[c, default: 0] += 1 } }
        return counts.max { $0.value < $1.value }?.key
    }
}
