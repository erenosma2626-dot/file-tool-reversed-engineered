import AppKit
import SwiftUI

/// Floating progress cards ("Converting to MP4 · geese.mov") shown near where the drop happened.
final class HUDController {
    static let shared = HUDController()

    private let width: CGFloat = 340
    private lazy var panel: OverlayPanel = {
        let p = OverlayPanel(size: NSSize(width: width, height: 400))
        p.level = .floating
        let host = NSHostingView(rootView: HUDStack(center: JobCenter.shared))
        host.frame = NSRect(x: 0, y: 0, width: width, height: 400)
        host.autoresizingMask = [.width, .height]
        p.contentView = host
        return p
    }()
    private var anchored = false

    func show(near point: NSPoint?) {
        if !panel.isVisible || !anchored {
            let p = point ?? NSEvent.mouseLocation
            let screen = NSScreen.screens.first { NSMouseInRect(p, $0.frame, false) } ?? NSScreen.main
            let vf = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            var x = p.x - width / 2
            x = min(max(x, vf.minX + 12), vf.maxX - width - 12)
            // Cards grow upward from just below the drop point.
            var y = p.y - 400 - 40
            y = min(max(y, vf.minY + 12), vf.maxY - 400)
            panel.setFrameOrigin(NSPoint(x: x, y: y))
            anchored = true
        }
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
        anchored = false
    }
}

private struct HUDStack: View {
    @ObservedObject var center: JobCenter

    var body: some View {
        VStack(spacing: 8) {
            Spacer(minLength: 0)
            ForEach(center.jobs) { job in
                JobCard(job: job)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(10)
        .animation(.spring(response: 0.32, dampingFraction: 0.85), value: center.jobs.map(\.id))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }
}

private struct JobCard: View {
    @ObservedObject var job: Job

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            statusIcon
            VStack(alignment: .leading, spacing: 4) {
                Text(job.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(isFailed ? Color.red.opacity(0.9) : Color.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                if job.state == .running {
                    ProgressBar(value: job.progress)
                        .frame(height: 5)
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: 320)
        .facetSurface(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 5)
    }

    @ViewBuilder private var statusIcon: some View {
        switch job.state {
        case .running:
            GlassIconButton(symbol: "xmark", size: 26) { job.cancel() }
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 22))
                .foregroundStyle(Color.accentColor)
                .symbolRenderingMode(.hierarchical)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 20))
                .foregroundStyle(.orange)
                .symbolRenderingMode(.hierarchical)
        }
    }

    private var isFailed: Bool { if case .failed = job.state { return true } else { return false } }

    private var detail: String {
        switch job.state {
        case .running: return job.subtitle
        case .done(let s): return s
        case .failed(let s): return s
        }
    }
}

/// Thin capsule progress bar; animates a shimmer while the value is unknown.
struct ProgressBar: View {
    var value: Double?
    @State private var phase: CGFloat = -0.4

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                if let v = value {
                    Capsule()
                        .fill(Color.accentColor.opacity(0.75))
                        .frame(width: max(5, geo.size.width * CGFloat(v)))
                        .animation(.linear(duration: 0.15), value: v)
                } else {
                    Capsule()
                        .fill(Color.accentColor.opacity(0.6))
                        .frame(width: geo.size.width * 0.35)
                        .offset(x: geo.size.width * phase)
                        .onAppear {
                            withAnimation(.easeInOut(duration: 1).repeatForever(autoreverses: true)) { phase = 0.65 }
                        }
                }
            }
            .clipShape(Capsule())
        }
    }
}
