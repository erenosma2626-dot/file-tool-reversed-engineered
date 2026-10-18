import SwiftUI

/// State shared between the drop-target NSView and the SwiftUI wheel.
final class WheelModel: ObservableObject {
    @Published var kind: WheelKind = .convert
    @Published var category: Category = .image
    @Published var items: [WheelItem] = []
    @Published var hovered: Int?
    @Published var visible = false
    var urls: [URL] = []

    static let outerRadius: CGFloat = 128
    static let innerRadius: CGFloat = 50
    static let gap: CGFloat = 4          // gap between segments, in points
    static let corner: CGFloat = 12      // segment corner rounding
    static let size: CGFloat = 330       // panel size (room for shadow and the hint line)

    /// Index of the segment under `p` (view coordinates, origin top-left), or nil for the hub.
    func index(at p: CGPoint) -> Int? {
        guard !items.isEmpty else { return nil }
        let c = Self.size / 2
        let dx = Double(p.x - c), dy = Double(p.y - c)
        let r = (dx * dx + dy * dy).squareRoot()
        guard r > Double(Self.innerRadius) - 6, r < Double(Self.outerRadius) + 40 else { return nil }
        // 0° at 12 o'clock, clockwise.
        var deg = atan2(dx, -dy) * 180 / Double.pi
        if deg < 0 { deg += 360 }
        let step = 360 / Double(items.count)
        return Int(((deg + step / 2) / step).rounded(.down)) % items.count
    }
}

/// A rounded ring segment (annular sector). Built by stroking a slightly smaller sector with
/// round joins, which gives evenly rounded corners at any angle.
struct RingSegment: Shape {
    var start: Angle   // 0° = 12 o'clock, clockwise
    var end: Angle
    var inner: CGFloat
    var outer: CGFloat
    var gap: CGFloat = WheelModel.gap
    var corner: CGFloat = WheelModel.corner

    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let rIn = inner + corner
        let rOut = outer - corner
        guard rOut > rIn else { return Path() }
        // Half the gap plus the corner, converted to an angle at each radius.
        let pad = gap / 2 + corner
        let aIn = Double(pad / rIn), aOut = Double(pad / rOut)
        let s = start.radians - .pi / 2, e = end.radians - .pi / 2
        guard e - s > 2 * aIn else { return Path() }

        var p = Path()
        p.addArc(center: c, radius: rOut, startAngle: .radians(s + aOut), endAngle: .radians(e - aOut), clockwise: false)
        p.addArc(center: c, radius: rIn, startAngle: .radians(e - aIn), endAngle: .radians(s + aIn), clockwise: true)
        p.closeSubpath()

        let rounded = p.cgPath.copy(strokingWithWidth: corner * 2, lineCap: .round, lineJoin: .round, miterLimit: 10)
        return Path(p.cgPath.union(rounded))
    }
}

struct WheelView: View {
    @ObservedObject var model: WheelModel
    @ObservedObject private var prefs = Prefs.shared

    var body: some View {
        let size = WheelModel.size
        ZStack {
            if model.items.isEmpty {
                emptyHub
            } else {
                ring
                hub
            }
        }
        .frame(width: size, height: size)
        .scaleEffect(model.visible ? 1 : 0.86)
        .opacity(model.visible ? 1 : 0)
        .animation(.spring(response: 0.28, dampingFraction: 0.78), value: model.visible)
        .animation(.spring(response: 0.22, dampingFraction: 0.8), value: model.hovered)
        .animation(.easeOut(duration: 0.18), value: model.kind)
    }

    private var ring: some View {
        let n = model.items.count
        let step = 360.0 / Double(n)
        return ZStack {
            ForEach(Array(model.items.enumerated()), id: \.element.id) { i, item in
                let mid = Double(i) * step
                let isHot = model.hovered == i
                let shape = RingSegment(start: .degrees(mid - step / 2), end: .degrees(mid + step / 2),
                                        inner: WheelModel.innerRadius, outer: WheelModel.outerRadius)
                SegmentLabel(item: item, isHot: isHot)
                    .position(labelPoint(angle: mid))
                    .frame(width: WheelModel.size, height: WheelModel.size)
                    .facetSurface(shape, tint: isHot ? Tint.selection : Tint.segment)
                    .scaleEffect(isHot ? 1.035 : 1)
            }
        }
        .glassGroup(spacing: 8)
        .shadow(color: Color.accentColor.opacity(0.22), radius: 22)
        .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
    }

    private var hub: some View {
        VStack(spacing: 2) {
            Text(hubTitle)
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.5)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(hubDetail)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: (WheelModel.innerRadius - 10) * 2 - 8)
        .padding(.vertical, 10)
        .frame(width: (WheelModel.innerRadius - 10) * 2, height: (WheelModel.innerRadius - 10) * 2)
        .facetSurface(Circle(), tint: Tint.subtle)
        .overlay(alignment: .bottom) {
            Text(hint)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .facetSurface(Capsule())
                .fixedSize()
                .offset(y: WheelModel.outerRadius + 24)
                .opacity(model.hovered == nil ? 0 : 1)
        }
    }

    private var emptyHub: some View {
        VStack(spacing: 6) {
            Image(systemName: model.category.symbol)
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(.secondary)
            Text(model.kind == .tools ? "No tools for this format" : "Nothing to convert to")
                .font(.system(size: 12, weight: .medium))
                .multilineTextAlignment(.center)
            Text("Try \(prefs.convertKey.symbols) or \(prefs.actionsKey.symbols)")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(width: 164, height: 164)
        .facetSurface(Circle(), tint: Tint.subtle)
    }

    private var hubTitle: String {
        if let i = model.hovered, i < model.items.count { return model.items[i].title.uppercased() }
        return model.kind.title.uppercased()
    }

    private var hubDetail: String {
        let n = model.urls.count
        if n == 1 { return model.urls.first?.pathExtension.uppercased() ?? "" }
        return "\(n) files"
    }

    private var hint: String {
        if let i = model.hovered, i < model.items.count { return model.items[i].hint }
        return ""
    }

    private func labelPoint(angle deg: Double) -> CGPoint {
        let r = (WheelModel.innerRadius + WheelModel.outerRadius) / 2
        let a = (deg - 90) * .pi / 180
        let c = WheelModel.size / 2
        return CGPoint(x: c + r * CGFloat(cos(a)), y: c + r * CGFloat(sin(a)))
    }
}

private struct SegmentLabel: View {
    let item: WheelItem
    let isHot: Bool

    var body: some View {
        VStack(spacing: 4) {
            if let symbol = item.symbol {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(isHot ? Color.primary : Color.accentColor)
                Text(item.title.uppercased())
                    .font(.system(size: 8.5, weight: .semibold))
                    .tracking(0.4)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            } else {
                Text(item.title)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .tracking(0.3)
            }
        }
        .foregroundStyle(isHot ? Color.primary : Color.primary.opacity(0.82))
        .frame(width: 64)
    }
}
