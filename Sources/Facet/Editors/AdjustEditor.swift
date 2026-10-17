import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

/// Rotate, flip, resize and basic color adjustments, previewed live with Core Image.
struct AdjustEditor: View {
    let url: URL
    let close: () -> Void

    @ViewState private var original: CGImage? = nil
    @ViewState private var previewSource: CIImage? = nil
    @ViewState private var preview: CGImage? = nil
    @ViewState private var settings = Adjustments()

    private static let context = CIContext(options: [.cacheIntermediates: false])

    var body: some View {
        EditorChrome(title: "Edit Image", close: close) {
            VStack(spacing: 14) {
                GeometryReader { geo in
                    ZStack {
                        if let preview {
                            Image(decorative: preview, scale: 1)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        } else {
                            ProgressView().controlSize(.small)
                        }
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                }
                .frame(minHeight: 240)

                HStack(spacing: 8) {
                    SecondaryButton(title: "", symbol: "rotate.left") { settings.quarterTurns = (settings.quarterTurns + 3) % 4 }
                    SecondaryButton(title: "", symbol: "rotate.right") { settings.quarterTurns = (settings.quarterTurns + 1) % 4 }
                    SecondaryButton(title: "", symbol: "arrow.left.and.right.righttriangle.left.righttriangle.right") { settings.flipH.toggle() }
                    SecondaryButton(title: "", symbol: "arrow.up.and.down.righttriangle.up.righttriangle.down") { settings.flipV.toggle() }
                    Spacer()
                    Text(outputSizeLabel)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                VStack(spacing: 8) {
                    SliderRow(label: "Size", value: $settings.scale, range: 0.1...1)
                    SliderRow(label: "Brightness", value: $settings.brightness, range: -0.4...0.4, format: signed)
                    SliderRow(label: "Contrast", value: $settings.contrast, range: 0.5...1.5, format: signedFromOne)
                    SliderRow(label: "Saturation", value: $settings.saturation, range: 0...2, format: signedFromOne)
                    SliderRow(label: "Warmth", value: $settings.warmth, range: -1...1, format: signed)
                }
            }
        } footer: {
            SecondaryButton(title: "Reset", symbol: "arrow.counterclockwise") { settings = Adjustments() }
            Spacer()
            PrimaryButton(title: "Apply", disabled: original == nil || settings.isIdentity) { apply() }
        }
        .onAppear(perform: load)
        .onChange(of: settings) { _ in render() }
    }

    private var outputSizeLabel: String {
        guard let original else { return "" }
        var w = Double(original.width) * settings.scale, h = Double(original.height) * settings.scale
        if settings.quarterTurns % 2 == 1 { swap(&w, &h) }
        return "\(Int(w)) × \(Int(h)) px"
    }

    private func signed(_ v: Double) -> String { String(format: "%+d", Int((v * 100).rounded())) }
    private func signedFromOne(_ v: Double) -> String { String(format: "%+d", Int(((v - 1) * 100).rounded())) }

    private func load() {
        DispatchQueue.global(qos: .userInitiated).async {
            guard let img = try? ImageEngine.load(url) else { return }
            let small = ImageTools.scaled(img, width: min(img.width, 1000)) ?? img
            DispatchQueue.main.async {
                original = img
                previewSource = CIImage(cgImage: small)
                render()
            }
        }
    }

    private func render() {
        guard let src = previewSource else { return }
        var s = settings
        s.scale = 1 // the preview is always shown fitted
        let out = s.apply(to: src)
        preview = Self.context.createCGImage(out, from: out.extent)
    }

    private func apply() {
        guard let original else { return }
        let s = settings
        let url = self.url
        close()
        JobCenter.shared.run("Editing image", subtitle: url.lastPathComponent) { _ in
            let out = s.apply(to: CIImage(cgImage: original))
            guard let cg = AdjustEditor.context.createCGImage(out, from: out.extent,
                                                               format: .RGBA8,
                                                               colorSpace: original.colorSpace ?? CGColorSpaceCreateDeviceRGB()) else {
                throw FacetError("Couldn't render the edited image.")
            }
            let type = ImageEngine.sameType(as: url)
            let dest = Output.url(for: url, ext: ImageEngine.outputExtension(for: url, type: type), suffix: "Edited")
            try ImageEngine.write(cg, to: dest, type: type)
            return [dest]
        }
    }
}

struct Adjustments: Equatable {
    var quarterTurns = 0
    var flipH = false
    var flipV = false
    var scale = 1.0
    var brightness = 0.0
    var contrast = 1.0
    var saturation = 1.0
    var warmth = 0.0

    var isIdentity: Bool { self == Adjustments() }

    func apply(to input: CIImage) -> CIImage {
        var img = input
        if brightness != 0 || contrast != 1 || saturation != 1 {
            let f = CIFilter.colorControls()
            f.inputImage = img
            f.brightness = Float(brightness)
            f.contrast = Float(contrast)
            f.saturation = Float(saturation)
            img = f.outputImage ?? img
        }
        if warmth != 0 {
            let f = CIFilter.temperatureAndTint()
            f.inputImage = img
            f.neutral = CIVector(x: 6500, y: 0)
            f.targetNeutral = CIVector(x: 6500 + CGFloat(warmth) * 2500, y: 0)
            img = f.outputImage ?? img
        }
        if flipH { img = img.oriented(.upMirrored) }
        if flipV { img = img.oriented(.downMirrored) }
        for _ in 0..<quarterTurns { img = img.oriented(.right) }
        if scale < 0.999 {
            let f = CIFilter.lanczosScaleTransform()
            f.inputImage = img
            f.scale = Float(scale)
            f.aspectRatio = 1
            img = f.outputImage ?? img
        }
        // Color filters can grow the extent by fractions of a pixel; snap back.
        let extent = img.extent.integral
        img = img.cropped(to: extent)
        return img.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
    }
}
