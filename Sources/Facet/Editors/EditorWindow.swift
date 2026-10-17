import AppKit
import SwiftUI

enum TimelineMode: String, CaseIterable, Identifiable {
    case trim, split, snapshot, speed
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum EditorKind {
    case imageCrop(URL)
    case videoCrop(URL)
    case imageAdjust(URL)
    case annotate(URL)
    case videoTimeline(URL, TimelineMode)
    case organize(URL)
}

/// Borderless glass panel that can take keyboard focus (for sliders and text).
final class EditorPanel: NSPanel {
    init(size: NSSize) {
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.borderless, .resizable, .fullSizeContentView],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func cancelOperation(_ sender: Any?) { close() }
}

final class EditorWindow: NSObject, NSWindowDelegate {
    private static var openWindows: [EditorWindow] = []
    private let panel: EditorPanel

    private init(size: NSSize) {
        panel = EditorPanel(size: size)
        super.init()
        panel.delegate = self
    }

    static func open(_ kind: EditorKind) {
        let size: NSSize
        switch kind {
        case .organize: size = NSSize(width: 640, height: 560)
        case .annotate: size = NSSize(width: 640, height: 600)
        case .videoTimeline: size = NSSize(width: 560, height: 520)
        default: size = NSSize(width: 440, height: 560)
        }
        let window = EditorWindow(size: size)
        let close: () -> Void = { [weak window] in window?.panel.close() }

        let root: AnyView
        switch kind {
        case .imageCrop(let url): root = AnyView(CropEditor(source: .image(url), close: close))
        case .videoCrop(let url): root = AnyView(CropEditor(source: .video(url), close: close))
        case .imageAdjust(let url): root = AnyView(AdjustEditor(url: url, close: close))
        case .annotate(let url): root = AnyView(AnnotateEditor(url: url, close: close))
        case .videoTimeline(let url, let mode): root = AnyView(TimelineEditor(url: url, mode: mode, close: close))
        case .organize(let url): root = AnyView(OrganizeEditor(url: url, close: close))
        }
        let host = NSHostingView(rootView: root)
        window.panel.contentView = host
        window.panel.minSize = NSSize(width: 380, height: 380)

        // Open centred on the screen with the pointer.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let vf = screen?.visibleFrame {
            window.panel.setFrameOrigin(NSPoint(x: vf.midX - size.width / 2, y: vf.midY - size.height / 2))
        }
        openWindows.append(window)
        NSApp.activate(ignoringOtherApps: true)
        window.panel.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        EditorWindow.openWindows.removeAll { $0 === self }
    }
}

/// Shared look for every editor: glass card, close button, centred title, footer actions.
struct EditorChrome<Content: View, Footer: View>: View {
    let title: String
    let close: () -> Void
    @ViewBuilder var content: Content
    @ViewBuilder var footer: Footer

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Text(title).font(.system(size: 14, weight: .semibold))
                HStack {
                    GlassIconButton(symbol: "xmark", size: 26, action: close)
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 10)

            content
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack(spacing: 10) { footer }
                .padding(14)
        }
        .facetSurface(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .padding(1)
    }
}

/// Accent-tinted capsule button used for the primary action ("Apply", "Save").
struct PrimaryButton: View {
    let title: String
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 16)
                .padding(.vertical, 7)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .facetSurface(Capsule(), tint: Color.accentColor.opacity(disabled ? 0.12 : 0.5), interactive: true)
        .opacity(disabled ? 0.5 : 1)
        .disabled(disabled)
        .keyboardShortcut(.defaultAction)
    }
}

struct SecondaryButton: View {
    let title: String
    var symbol: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol { Image(systemName: symbol) }
                if !title.isEmpty { Text(title) }
            }
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .facetSurface(Capsule(), interactive: true)
    }
}

/// Label + slider + value, the row style used across editors.
struct SliderRow: View {
    let label: String
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1
    var format: (Double) -> String = { "\(Int(($0 * 100).rounded()))%" }

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 74, alignment: .leading)
            Slider(value: $value, in: range)
                .controlSize(.small)
            Text(format(value))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 46, alignment: .trailing)
        }
    }
}

/// Fits a pixel size into a box, keeping aspect ratio.
func fitted(_ size: CGSize, in box: CGSize) -> CGSize {
    guard size.width > 0, size.height > 0 else { return box }
    let s = min(box.width / size.width, box.height / size.height)
    return CGSize(width: size.width * s, height: size.height * s)
}
