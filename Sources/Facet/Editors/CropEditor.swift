import AVFoundation
import SwiftUI

enum AspectChoice: String, CaseIterable, Identifiable {
    case free, original, square, r4x3, r3x2, r16x9, r9x16, r4x5
    var id: String { rawValue }

    var title: String {
        switch self {
        case .free: return "Freeform"
        case .original: return "Original"
        case .square: return "Square"
        case .r4x3: return "4:3"
        case .r3x2: return "3:2"
        case .r16x9: return "16:9"
        case .r9x16: return "9:16"
        case .r4x5: return "4:5"
        }
    }

    /// width / height in pixels, nil for freeform.
    func ratio(original: CGSize) -> CGFloat? {
        switch self {
        case .free: return nil
        case .original: return original.height > 0 ? original.width / original.height : nil
        case .square: return 1
        case .r4x3: return 4.0 / 3.0
        case .r3x2: return 3.0 / 2.0
        case .r16x9: return 16.0 / 9.0
        case .r9x16: return 9.0 / 16.0
        case .r4x5: return 4.0 / 5.0
        }
    }
}

struct CropEditor: View {
    enum Source {
        case image(URL), video(URL)
        var url: URL { switch self { case .image(let u), .video(let u): return u } }
        var isVideo: Bool { if case .video = self { return true } else { return false } }
    }

    let source: Source
    let close: () -> Void

    @State private var preview: CGImage?
    @State private var pixelSize: CGSize = .zero
    /// Normalised crop rect, origin top-left.
    @State private var crop = CGRect(x: 0, y: 0, width: 1, height: 1)
    @State private var aspect: AspectChoice = .free
    @State private var time: Double = 0
    @State private var duration: Double = 0
    @State private var generator: AVAssetImageGenerator?

    var body: some View {
        EditorChrome(title: source.isVideo ? "Crop Video" : "Crop Image", close: close) {
            VStack(spacing: 14) {
                GeometryReader { geo in
                    let box = fitted(pixelSize, in: geo.size)
                    ZStack {
                        if let preview {
                            Image(decorative: preview, scale: 1)
                                .resizable()
                                .interpolation(.high)
                                .frame(width: box.width, height: box.height)
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            CropOverlay(crop: $crop, ratio: normalizedRatio)
                                .frame(width: box.width, height: box.height)
                        } else {
                            ProgressView().controlSize(.small)
                        }
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                }
                .frame(minHeight: 260)

                controls
            }
        } footer: {
            SecondaryButton(title: "Reset", symbol: "arrow.counterclockwise") {
                withAnimation(.snappy) { crop = CGRect(x: 0, y: 0, width: 1, height: 1); aspect = .free }
            }
            Spacer()
            PrimaryButton(title: "Apply", disabled: preview == nil) { apply() }
        }
        .onAppear(perform: load)
        .onChange(of: aspect) { _ in enforceAspect() }
    }

    private var controls: some View {
        VStack(spacing: 10) {
            HStack {
                Text("Aspect ratio").font(.system(size: 12)).foregroundStyle(.secondary)
                Picker("", selection: $aspect) {
                    ForEach(AspectChoice.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .frame(width: 130)
                Spacer()
                Text("\(Int(crop.width * pixelSize.width)) × \(Int(crop.height * pixelSize.height)) px")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            SliderRow(label: "Width", value: sizeBinding(\.width), range: 0.05...1)
            SliderRow(label: "Height", value: sizeBinding(\.height), range: 0.05...1)
            if source.isVideo && duration > 0 {
                SliderRow(label: "Frame", value: $time, range: 0...duration, format: timecode)
                    .onChange(of: time) { _ in refreshFrame() }
            }
        }
    }

    /// Ratio in normalised units (accounts for non-square images).
    private var normalizedRatio: CGFloat? {
        guard let r = aspect.ratio(original: pixelSize), pixelSize.width > 0 else { return nil }
        return r * pixelSize.height / pixelSize.width
    }

    private func sizeBinding(_ key: WritableKeyPath<CGSize, CGFloat>) -> Binding<Double> {
        Binding(
            get: { Double(crop.size[keyPath: key]) },
            set: { v in
                var size = crop.size
                size[keyPath: key] = CGFloat(v)
                if let r = normalizedRatio {
                    if key == \CGSize.width { size.height = size.width / r } else { size.width = size.height * r }
                }
                size.width = min(size.width, 1); size.height = min(size.height, 1)
                let center = CGPoint(x: crop.midX, y: crop.midY)
                var rect = CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
                rect.origin.x = min(max(rect.minX, 0), 1 - rect.width)
                rect.origin.y = min(max(rect.minY, 0), 1 - rect.height)
                crop = rect
            })
    }

    private func enforceAspect() {
        guard let r = normalizedRatio else { return }
        var w = crop.width, h = crop.width / r
        if h > 1 { h = 1; w = r }
        if w > 1 { w = 1; h = 1 / r }
        let c = CGPoint(x: crop.midX, y: crop.midY)
        var rect = CGRect(x: c.x - w / 2, y: c.y - h / 2, width: w, height: h)
        rect.origin.x = min(max(rect.minX, 0), 1 - w)
        rect.origin.y = min(max(rect.minY, 0), 1 - h)
        withAnimation(.snappy) { crop = rect }
    }

    private func timecode(_ t: Double) -> String {
        String(format: "%d:%05.2f", Int(t) / 60, t.truncatingRemainder(dividingBy: 60))
    }

    // MARK: Loading

    private func load() {
        switch source {
        case .image(let url):
            DispatchQueue.global(qos: .userInitiated).async {
                let img = try? ImageEngine.load(url)
                let thumb = img.flatMap { ImageTools.scaled($0, width: min($0.width, 1400)) }
                DispatchQueue.main.async {
                    if let img { pixelSize = CGSize(width: img.width, height: img.height) }
                    preview = thumb
                }
            }
        case .video(let url):
            let asset = AVURLAsset(url: url)
            pixelSize = VideoEngine.displaySize(asset)
            duration = max(0, asset.duration.seconds)
            let gen = AVAssetImageGenerator(asset: asset)
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: 1200, height: 1200)
            gen.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 30)
            gen.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 30)
            generator = gen
            refreshFrame()
        }
    }

    private func refreshFrame() {
        guard let generator else { return }
        let t = CMTime(seconds: time, preferredTimescale: 600)
        generator.cancelAllCGImageGeneration()
        generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: t)]) { _, image, _, _, _ in
            guard let image else { return }
            DispatchQueue.main.async { preview = image }
        }
    }

    // MARK: Apply

    private func apply() {
        let px = CGRect(x: (crop.minX * pixelSize.width).rounded(), y: (crop.minY * pixelSize.height).rounded(),
                        width: (crop.width * pixelSize.width).rounded(), height: (crop.height * pixelSize.height).rounded())
        let url = source.url
        close()
        switch source {
        case .image:
            JobCenter.shared.run("Cropping image", subtitle: url.lastPathComponent) { _ in
                let image = try ImageEngine.load(url)
                guard let cropped = image.cropping(to: px) else { throw FacetError("Couldn't crop this image.") }
                let type = ImageEngine.sameType(as: url)
                let out = Output.url(for: url, ext: ImageEngine.outputExtension(for: url, type: type), suffix: "Cropped")
                try ImageEngine.write(cropped, to: out, type: type)
                return [out]
            }
        case .video:
            JobCenter.shared.run("Cropping video", subtitle: url.lastPathComponent) { job in
                [try VideoTools.crop(url, rect: px, progress: ProgressSlice(job: job))]
            }
        }
    }
}

/// Dimmed surroundings, a thirds grid while dragging, and draggable corners.
struct CropOverlay: View {
    @Binding var crop: CGRect
    var ratio: CGFloat?

    @State private var start: CGRect?
    @State private var dragging = false

    private enum Corner: CaseIterable { case topLeft, topRight, bottomLeft, bottomRight }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let rect = CGRect(x: crop.minX * size.width, y: crop.minY * size.height,
                              width: crop.width * size.width, height: crop.height * size.height)
            ZStack(alignment: .topLeading) {
                // Dim outside the crop.
                Path { p in
                    p.addRect(CGRect(origin: .zero, size: size))
                    p.addRect(rect)
                }
                .fill(Color.black.opacity(0.45), style: FillStyle(eoFill: true))

                // Frame + thirds.
                Path { p in
                    if dragging {
                        for i in 1...2 {
                            let x = rect.minX + rect.width * CGFloat(i) / 3
                            let y = rect.minY + rect.height * CGFloat(i) / 3
                            p.move(to: CGPoint(x: x, y: rect.minY)); p.addLine(to: CGPoint(x: x, y: rect.maxY))
                            p.move(to: CGPoint(x: rect.minX, y: y)); p.addLine(to: CGPoint(x: rect.maxX, y: y))
                        }
                    }
                }
                .stroke(Color.white.opacity(0.5), lineWidth: 0.5)
                Rectangle()
                    .strokeBorder(Color.white, lineWidth: 1.5)
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
                    .contentShape(Rectangle())
                    .gesture(moveGesture(size))

                ForEach(Corner.allCases, id: \.self) { corner in
                    handle
                        .position(point(corner, in: rect))
                        .gesture(resizeGesture(corner, size))
                }
            }
        }
    }

    private var handle: some View {
        Circle()
            .fill(Color.white)
            .frame(width: 14, height: 14)
            .shadow(color: .black.opacity(0.35), radius: 2)
            .frame(width: 30, height: 30)
            .contentShape(Rectangle())
    }

    private func point(_ c: Corner, in r: CGRect) -> CGPoint {
        switch c {
        case .topLeft: return CGPoint(x: r.minX, y: r.minY)
        case .topRight: return CGPoint(x: r.maxX, y: r.minY)
        case .bottomLeft: return CGPoint(x: r.minX, y: r.maxY)
        case .bottomRight: return CGPoint(x: r.maxX, y: r.maxY)
        }
    }

    private func moveGesture(_ size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { v in
                if start == nil { start = crop; dragging = true }
                guard let s = start else { return }
                var r = s.offsetBy(dx: v.translation.width / size.width, dy: v.translation.height / size.height)
                r.origin.x = min(max(r.minX, 0), 1 - r.width)
                r.origin.y = min(max(r.minY, 0), 1 - r.height)
                crop = r
            }
            .onEnded { _ in start = nil; dragging = false }
    }

    private func resizeGesture(_ corner: Corner, _ size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                if start == nil { start = crop; dragging = true }
                guard let s = start else { return }
                let dx = v.translation.width / size.width, dy = v.translation.height / size.height
                // The opposite corner stays put.
                var minX = s.minX, minY = s.minY, maxX = s.maxX, maxY = s.maxY
                switch corner {
                case .topLeft: minX += dx; minY += dy
                case .topRight: maxX += dx; minY += dy
                case .bottomLeft: minX += dx; maxY += dy
                case .bottomRight: maxX += dx; maxY += dy
                }
                minX = max(0, min(minX, maxX - 0.03)); maxX = min(1, max(maxX, minX + 0.03))
                minY = max(0, min(minY, maxY - 0.03)); maxY = min(1, max(maxY, minY + 0.03))
                var w = maxX - minX, h = maxY - minY
                if let ratio {
                    // Keep the ratio using the dominant drag direction, then clamp.
                    if abs(dx) > abs(dy) { h = w / ratio } else { w = h * ratio }
                    let limitW: CGFloat = (corner == .topLeft || corner == .bottomLeft) ? s.maxX : 1 - s.minX
                    let limitH: CGFloat = (corner == .topLeft || corner == .topRight) ? s.maxY : 1 - s.minY
                    if w > limitW { w = limitW; h = w / ratio }
                    if h > limitH { h = limitH; w = h * ratio }
                    switch corner {
                    case .topLeft: minX = s.maxX - w; minY = s.maxY - h
                    case .topRight: minX = s.minX; minY = s.maxY - h
                    case .bottomLeft: minX = s.maxX - w; minY = s.minY
                    case .bottomRight: minX = s.minX; minY = s.minY
                    }
                }
                crop = CGRect(x: minX, y: minY, width: w, height: h)
            }
            .onEnded { _ in start = nil; dragging = false }
    }
}
