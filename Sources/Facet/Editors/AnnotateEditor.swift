import AppKit
import SwiftUI

enum MarkTool: String, CaseIterable, Identifiable {
    case pen, highlighter, arrow, rectangle, ellipse, text
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .pen: return "scribble"
        case .highlighter: return "highlighter"
        case .arrow: return "arrow.up.right"
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .text: return "textformat"
        }
    }
}

/// One annotation. Coordinates are normalised to the image (0…1, origin top-left) so the
/// same marks render identically in the preview and at full resolution.
struct Mark: Identifiable {
    let id = UUID()
    var tool: MarkTool
    var points: [CGPoint]
    var color: NSColor
    /// Stroke width as a fraction of the image's shorter side.
    var width: CGFloat
    var text = ""
}

enum MarkRenderer {
    /// Draws into a top-left-origin context of `size` points/pixels.
    static func draw(_ marks: [Mark], in ctx: CGContext, size: CGSize) {
        let unit = min(size.width, size.height)
        func p(_ n: CGPoint) -> CGPoint { CGPoint(x: n.x * size.width, y: n.y * size.height) }

        for m in marks {
            guard let first = m.points.first else { continue }
            let w = max(1, m.width * unit)
            ctx.saveGState()
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.setStrokeColor(m.color.cgColor)
            ctx.setFillColor(m.color.cgColor)
            ctx.setLineWidth(w)
            let a = p(first), b = p(m.points.last ?? first)
            let box = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))

            switch m.tool {
            case .pen, .highlighter:
                if m.tool == .highlighter {
                    ctx.setLineWidth(w * 4)
                    ctx.setLineCap(.square)
                    ctx.setStrokeColor(m.color.withAlphaComponent(0.38).cgColor)
                    ctx.setBlendMode(.multiply)
                }
                ctx.beginPath()
                ctx.move(to: a)
                for pt in m.points.dropFirst() { ctx.addLine(to: p(pt)) }
                ctx.strokePath()
            case .arrow:
                let angle = atan2(b.y - a.y, b.x - a.x)
                let head = max(w * 4, 10)
                let back = CGPoint(x: b.x - cos(angle) * head * 0.8, y: b.y - sin(angle) * head * 0.8)
                ctx.beginPath(); ctx.move(to: a); ctx.addLine(to: back); ctx.strokePath()
                ctx.beginPath()
                ctx.move(to: b)
                ctx.addLine(to: CGPoint(x: b.x - cos(angle - .pi / 7) * head, y: b.y - sin(angle - .pi / 7) * head))
                ctx.addLine(to: CGPoint(x: b.x - cos(angle + .pi / 7) * head, y: b.y - sin(angle + .pi / 7) * head))
                ctx.closePath()
                ctx.fillPath()
            case .rectangle:
                ctx.addPath(CGPath(roundedRect: box, cornerWidth: w, cornerHeight: w, transform: nil))
                ctx.strokePath()
            case .ellipse:
                ctx.strokeEllipse(in: box)
            case .text:
                let fontSize = max(10, m.width * unit * 6)
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
                    .foregroundColor: m.color,
                ]
                let previous = NSGraphicsContext.current
                NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
                (m.text as NSString).draw(at: a, withAttributes: attrs)
                NSGraphicsContext.current = previous
            }
            ctx.restoreGState()
        }
    }
}

struct AnnotateEditor: View {
    let url: URL
    let close: () -> Void

    @ViewState private var image: CGImage? = nil
    @ViewState private var preview: CGImage? = nil
    @ViewState private var marks: [Mark] = []
    @ViewState private var current: Mark? = nil
    @ViewState private var tool: MarkTool = .pen
    @ViewState private var colorIndex = 0
    @ViewState private var widthIndex = 1
    @ViewState private var editingText: UUID? = nil

    private let colors: [NSColor] = [.systemRed, .systemOrange, .systemYellow, .systemGreen, .systemBlue, .white, .black]
    private let widths: [CGFloat] = [0.004, 0.008, 0.014]

    var body: some View {
        EditorChrome(title: "Annotate", close: close) {
            VStack(spacing: 12) {
                toolbar
                GeometryReader { geo in
                    let size = image.map { fitted(CGSize(width: $0.width, height: $0.height), in: geo.size) } ?? .zero
                    ZStack {
                        if let preview {
                            Image(decorative: preview, scale: 1)
                                .resizable()
                                .frame(width: size.width, height: size.height)
                            Canvas { ctx, canvasSize in
                                ctx.withCGContext { cg in
                                    MarkRenderer.draw(marks + (current.map { [$0] } ?? []), in: cg, size: canvasSize)
                                }
                            }
                            .frame(width: size.width, height: size.height)
                            .contentShape(Rectangle())
                            .gesture(drawGesture(size))
                            textEditor(size)
                        } else {
                            ProgressView().controlSize(.small)
                        }
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                }
                .frame(minHeight: 320)
            }
        } footer: {
            SecondaryButton(title: "Undo", symbol: "arrow.uturn.backward") {
                if !marks.isEmpty { marks.removeLast() }
            }
            .keyboardShortcut("z", modifiers: .command)
            SecondaryButton(title: "Clear", symbol: "trash") { marks.removeAll() }
            Spacer()
            PrimaryButton(title: "Apply", disabled: marks.isEmpty) { apply() }
        }
        .onAppear(perform: load)
    }

    private var toolbar: some View {
        HStack(spacing: 6) {
            ForEach(MarkTool.allCases) { t in
                Button { tool = t } label: {
                    Image(systemName: t.symbol)
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 30, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .facetSurface(RoundedRectangle(cornerRadius: 9, style: .continuous),
                              tint: tool == t ? Tint.selection : nil, interactive: true)
            }
            Spacer(minLength: 8)
            ForEach(colors.indices, id: \.self) { i in
                Circle()
                    .fill(Color(nsColor: colors[i]))
                    .frame(width: 16, height: 16)
                    .overlay(Circle().stroke(Color.primary.opacity(colorIndex == i ? 0.9 : 0.15), lineWidth: colorIndex == i ? 2 : 0.5))
                    .padding(2)
                    .onTapGesture { colorIndex = i }
            }
            Picker("", selection: $widthIndex) {
                Text("S").tag(0); Text("M").tag(1); Text("L").tag(2)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 84)
        }
    }

    @ViewBuilder
    private func textEditor(_ size: CGSize) -> some View {
        if let id = editingText, let i = marks.firstIndex(where: { $0.id == id }), let pt = marks[i].points.first {
            TextField("Text", text: $marks[i].text)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .semibold))
                .padding(6)
                .frame(width: 180)
                .facetSurface(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .position(x: pt.x * size.width + 90, y: pt.y * size.height - 18)
                .onSubmit { editingText = nil }
        }
    }

    private func drawGesture(_ size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                guard size.width > 0, size.height > 0 else { return }
                let n = CGPoint(x: min(max(v.location.x / size.width, 0), 1), y: min(max(v.location.y / size.height, 0), 1))
                if tool == .text { return }
                if current == nil {
                    current = Mark(tool: tool, points: [n], color: colors[colorIndex], width: widths[widthIndex])
                } else if tool == .pen || tool == .highlighter {
                    current?.points.append(n)
                } else {
                    current?.points = [current?.points.first ?? n, n]
                }
            }
            .onEnded { v in
                if tool == .text {
                    let n = CGPoint(x: v.location.x / max(size.width, 1), y: v.location.y / max(size.height, 1))
                    let m = Mark(tool: .text, points: [n], color: colors[colorIndex], width: widths[widthIndex], text: "Text")
                    marks.append(m)
                    editingText = m.id
                    return
                }
                if let m = current, m.points.count > 1 || m.tool == .pen { marks.append(m) }
                current = nil
            }
    }

    private func load() {
        DispatchQueue.global(qos: .userInitiated).async {
            guard let img = try? ImageEngine.load(url) else { return }
            let small = ImageTools.scaled(img, width: min(img.width, 1400))
            DispatchQueue.main.async { image = img; preview = small }
        }
    }

    private func apply() {
        guard let image else { return }
        let marks = self.marks.filter { $0.tool != .text || !$0.text.isEmpty }
        let url = self.url
        close()
        JobCenter.shared.run("Annotating", subtitle: url.lastPathComponent) { _ in
            let w = image.width, h = image.height
            guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                ?? CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw FacetError("Couldn't draw on this image.")
            }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            // Flip to top-left origin, like the preview canvas.
            ctx.translateBy(x: 0, y: CGFloat(h))
            ctx.scaleBy(x: 1, y: -1)
            onMain { MarkRenderer.draw(marks, in: ctx, size: CGSize(width: w, height: h)) }
            guard let result = ctx.makeImage() else { throw FacetError("Couldn't draw on this image.") }
            let type = ImageEngine.sameType(as: url)
            let out = Output.url(for: url, ext: ImageEngine.outputExtension(for: url, type: type), suffix: "Annotated")
            try ImageEngine.write(result, to: out, type: type)
            return [out]
        }
    }
}
