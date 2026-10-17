import AppKit
import SwiftUI

final class ShelfPanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: ShelfWindow.collapsed.width, height: ShelfWindow.collapsed.height),
                   styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        isMovableByWindowBackground = true
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    override var canBecomeKey: Bool { true }
}

/// Accepts files dropped onto a shelf.
final class ShelfDropView: NSView {
    weak var model: ShelfModel?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        // Our own drags (from this very shelf) shouldn't re-add.
        if (sender.draggingSource as? DragSourceView)?.window === window { return [] }
        model?.isTargeted = true
        return acceptableOperation(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if (sender.draggingSource as? DragSourceView)?.window === window { return [] }
        return acceptableOperation(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { model?.isTargeted = false }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        model?.isTargeted = false
        let opts: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: opts) as? [URL] ?? []
        guard !urls.isEmpty else { return false }
        model?.add(urls)
        Feedback.tick()
        return true
    }
}

final class ShelfWindow: NSObject, NSWindowDelegate {
    static let collapsed = NSSize(width: 200, height: 220)

    let model = ShelfModel()
    private let panel = ShelfPanel()
    private weak var manager: ShelfManager?

    init(manager: ShelfManager) {
        self.manager = manager
        super.init()
        panel.delegate = self
        let drop = ShelfDropView(frame: NSRect(origin: .zero, size: Self.collapsed))
        drop.model = model
        let host = NSHostingView(rootView: ShelfView(model: model))
        host.frame = drop.bounds
        host.autoresizingMask = [.width, .height]
        drop.addSubview(host)
        panel.contentView = drop

        model.onResize = { [weak self] in self?.fitToContent(animated: true) }
        model.onClose = { [weak self] in self?.close() }
    }

    func show(near point: NSPoint) {
        let size = Self.collapsed
        var origin = NSPoint(x: point.x - size.width / 2, y: point.y - size.height / 2)
        if let vf = (NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main)?.visibleFrame {
            origin.x = min(max(origin.x, vf.minX + 8), vf.maxX - size.width - 8)
            origin.y = min(max(origin.y, vf.minY + 8), vf.maxY - size.height - 8)
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            panel.animator().alphaValue = 1
        }
    }

    func close() {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.panel.close()
        })
    }

    func windowWillClose(_ notification: Notification) {
        manager?.closed(self)
    }

    /// A little nudge when files are added to an existing shelf.
    func bounce() {
        panel.orderFrontRegardless()
        var f = panel.frame
        f.origin.y += 6
        panel.setFrame(f, display: true, animate: true)
        f.origin.y -= 6
        panel.setFrame(f, display: true, animate: true)
    }

    private func fitToContent(animated: Bool) {
        let size = targetSize()
        var frame = panel.frame
        // Grow/shrink from the top-left corner so the header stays under the pointer.
        frame.origin.y = frame.maxY - size.height
        frame.size = size
        if let vf = panel.screen?.visibleFrame {
            frame.origin.x = min(max(frame.origin.x, vf.minX + 8), vf.maxX - size.width - 8)
            frame.origin.y = max(frame.origin.y, vf.minY + 8)
        }
        panel.setFrame(frame, display: true, animate: animated && panel.isVisible)
    }

    private func targetSize() -> NSSize {
        guard model.expanded else { return Self.collapsed }
        let n = model.items.count + 1 // + "Reveal in Finder"
        switch model.layout {
        case .grid:
            let rows = Int(ceil(Double(n) / 3))
            return NSSize(width: 440, height: min(84 + CGFloat(rows) * 128, 520))
        case .list:
            return NSSize(width: 400, height: min(84 + CGFloat(model.items.count) * 46 + 52, 520))
        }
    }
}

// MARK: - Drag source

/// AppKit view that drags files out of a shelf with "move" semantics (cut & paste),
/// and reports clicks and hover. SwiftUI's own drag API can't choose the operation.
final class DragSourceView: NSView, NSDraggingSource {
    var urls: () -> [URL] = { [] }
    var preview: () -> NSImage? = { nil }
    var onClick: (Int) -> Void = { _ in }
    var onHover: (Bool) -> Void = { _ in }
    var onEnded: () -> Void = {}

    private var downEvent: NSEvent?
    private var tracking: NSTrackingArea?

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) { onHover(true) }
    override func mouseExited(with event: NSEvent) { onHover(false) }

    override func mouseDown(with event: NSEvent) { downEvent = event }

    override func mouseUp(with event: NSEvent) {
        if downEvent != nil { onClick(event.clickCount) }
        downEvent = nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard let down = downEvent else { return }
        let dx = event.locationInWindow.x - down.locationInWindow.x
        let dy = event.locationInWindow.y - down.locationInWindow.y
        guard dx * dx + dy * dy > 9 else { return }
        downEvent = nil

        let list = urls()
        guard !list.isEmpty else { return }
        let p = convert(down.locationInWindow, from: nil)
        let items: [NSDraggingItem] = list.prefix(50).enumerated().map { i, url in
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            let image = (i == 0 ? preview() : nil) ?? NSWorkspace.shared.icon(forFile: url.path)
            let offset = CGFloat(min(i, 4)) * 4
            item.setDraggingFrame(NSRect(x: p.x - 32 + offset, y: p.y - 32 - offset, width: 64, height: 64), contents: image)
            return item
        }
        let session = beginDraggingSession(with: items, event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .pile
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        if context == .withinApplication { return [.copy, .generic] }
        // Cut & paste by default; hold Option to leave the original in place.
        if Prefs.shared.floatCutMode && !NSEvent.modifierFlags.contains(.option) { return [.move, .generic] }
        return [.copy, .generic]
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        // Finder may finish moving a moment after the drop.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in self?.onEnded() }
    }
}

struct DragSource: NSViewRepresentable {
    let urls: () -> [URL]
    var preview: () -> NSImage? = { nil }
    var onClick: (Int) -> Void = { _ in }
    var onHover: (Bool) -> Void = { _ in }
    let onEnded: () -> Void

    func makeNSView(context: Context) -> DragSourceView {
        let v = DragSourceView()
        update(v)
        return v
    }

    func updateNSView(_ nsView: DragSourceView, context: Context) { update(nsView) }

    private func update(_ v: DragSourceView) {
        v.urls = urls
        v.preview = preview
        v.onClick = onClick
        v.onHover = onHover
        v.onEnded = onEnded
    }
}
