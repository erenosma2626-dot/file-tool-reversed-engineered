import AppKit

/// Watches the whole system for file drags (from Finder, the desktop, or any app) without
/// needing Accessibility or Input Monitoring permission:
/// - mouse events come from a global NSEvent monitor,
/// - "is this a file drag?" comes from the shared drag pasteboard,
/// - modifier taps are polled from `NSEvent.modifierFlags`, which reads the hardware state.
final class DragMonitor {
    var onDragBegan: (([URL], NSPoint) -> Void)?
    var onDragMoved: ((NSPoint) -> Void)?
    var onDragEnded: (() -> Void)?
    /// Fired when keys are *added* to the held modifiers during a file drag.
    var onModifiersPressed: ((ModifierCombo, NSPoint) -> Void)?
    var onShake: ((NSPoint) -> Void)?

    private(set) var isDragging = false
    private(set) var urls: [URL] = []

    private var monitors: [Any] = []
    private var pollTimer: Timer?
    private var downChangeCount = 0
    private var mouseIsDown = false
    private var lastFlags: NSEvent.ModifierFlags = []
    private let shake = ShakeDetector()
    private let dragPasteboard = NSPasteboard(name: .drag)

    func start() {
        guard monitors.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        if let m = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] e in self?.handle(e) }) {
            monitors.append(m)
        }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        endDrag()
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            mouseIsDown = true
            downChangeCount = dragPasteboard.changeCount
        case .leftMouseDragged:
            if !mouseIsDown {
                // Some drags start before we saw the mouse-down (e.g. app launched mid-drag).
                mouseIsDown = true
                downChangeCount = dragPasteboard.changeCount - 1
            }
            dragged()
        case .leftMouseUp:
            mouseIsDown = false
            endDrag()
        default:
            break
        }
    }

    private func dragged() {
        let point = NSEvent.mouseLocation
        if !isDragging {
            // Finder writes the pasteboard a moment after the drag starts, so keep checking.
            guard dragPasteboard.changeCount != downChangeCount else { return }
            let found = fileURLs(on: dragPasteboard)
            guard !found.isEmpty else { return }
            beginDrag(found, at: point)
        }
        onDragMoved?(point)
        pollModifiers()
        if Prefs.shared.shakeToFloat, shake.feed(point) {
            onShake?(point)
        }
    }

    private func beginDrag(_ found: [URL], at point: NSPoint) {
        isDragging = true
        urls = found
        // Keys already held when the drag starts (⌥ to copy, ⌘ to move in Finder) don't count.
        lastFlags = NSEvent.modifierFlags.intersection(ModifierCombo.relevant)
        shake.reset()
        onDragBegan?(found, point)

        // The global monitor only fires when the mouse moves; poll so a tap registers while
        // the pointer is still. 60 Hz for the duration of the drag only.
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func tick() {
        // During a drag the system owns the mouse, so a release may not reach the monitor.
        if NSEvent.pressedMouseButtons & 1 == 0 {
            mouseIsDown = false
            endDrag()
            return
        }
        pollModifiers()
    }

    private func pollModifiers() {
        let flags = NSEvent.modifierFlags.intersection(ModifierCombo.relevant)
        defer { lastFlags = flags }
        guard flags != lastFlags else { return }
        // Only react when a key is added; releasing keys keeps the wheel as it is.
        let added = flags.subtracting(lastFlags)
        guard !added.isEmpty else { return }
        onModifiersPressed?(ModifierCombo(flags), NSEvent.mouseLocation)
    }

    private func endDrag() {
        pollTimer?.invalidate()
        pollTimer = nil
        guard isDragging else { return }
        isDragging = false
        urls = []
        onDragEnded?()
    }

    private func fileURLs(on pb: NSPasteboard) -> [URL] {
        let opts: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let read = pb.readObjects(forClasses: [NSURL.self], options: opts) as? [URL] ?? []
        return read.filter { $0.isFileURL }
    }
}

/// Detects the "shake while dragging" gesture: several quick horizontal direction changes.
final class ShakeDetector {
    private var lastPoint: NSPoint?
    private var direction: CGFloat = 0
    private var travel: CGFloat = 0
    private var reversals: [TimeInterval] = []
    private var cooldownUntil: TimeInterval = 0

    func reset() {
        lastPoint = nil
        direction = 0
        travel = 0
        reversals.removeAll()
    }

    /// Returns true once per shake.
    func feed(_ p: NSPoint) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        defer { lastPoint = p }
        guard let last = lastPoint else { return false }
        let dx = p.x - last.x
        guard abs(dx) > 0.5 else { return false }
        let dir: CGFloat = dx > 0 ? 1 : -1
        if dir == direction {
            travel += abs(dx)
            return false
        }
        // A reversal only counts after a real swing in the previous direction.
        if direction != 0 && travel > 28 { reversals.append(now) }
        direction = dir
        travel = abs(dx)
        reversals.removeAll { now - $0 > 0.7 }
        guard now > cooldownUntil, reversals.count >= 4 else { return false }
        reversals.removeAll()
        cooldownUntil = now + 1.2
        return true
    }
}
