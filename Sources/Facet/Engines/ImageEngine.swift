import AppKit
import ImageIO
import UniformTypeIdentifiers
import Vision

/// Image conversion on ImageIO (hardware HEIC/AVIF where available). ffmpeg is only a
/// fallback for WebP/AVIF *writing* on systems whose ImageIO can't encode them.
enum ImageEngine {
    static func canWrite(_ f: Format) -> Bool {
        if f == .pdf { return true }
        guard let id = f.utType?.identifier else { return false }
        if Catalog.imageWritableTypes.contains(id) { return true }
        return (f == .webp || f == .avif) && FFmpeg.isAvailable
    }

    static func convert(_ url: URL, to f: Format, progress: ProgressSlice) throws -> URL {
        let out = Output.url(for: url, ext: f.ext)
        do {
            if f == .pdf {
                try writePDF(from: [url], to: out, progress: progress)
            } else if let id = f.utType?.identifier, Catalog.imageWritableTypes.contains(id) {
                let src = try source(url)
                try write(src, to: out, type: id, quality: 0.9)
            } else {
                try ffmpegEncode(url, to: out, format: f, progress: progress)
            }
        } catch {
            try? FileManager.default.removeItem(at: out)
            throw error
        }
        progress.report(1)
        return out
    }

    // MARK: Building blocks (shared with ImageTools and the editors)

    static func source(_ url: URL) throws -> CGImageSource {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(src) > 0 else {
            throw FacetError("Can't read \(url.lastPathComponent).")
        }
        return src
    }

    static func properties(_ src: CGImageSource) -> [CFString: Any] {
        (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]) ?? [:]
    }

    static func orientation(_ src: CGImageSource) -> Int {
        (properties(src)[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
    }

    static func pixelSize(_ src: CGImageSource) -> CGSize {
        let p = properties(src)
        let w = (p[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? 0
        let h = (p[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? 0
        return CGSize(width: w, height: h)
    }

    static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default: return true
        }
    }

    /// Full-size image with the EXIF orientation applied to the pixels.
    static func orientedImage(_ src: CGImageSource) throws -> CGImage {
        let size = pixelSize(src)
        let maxSide = max(size.width, size.height)
        if orientation(src) == 1 || maxSide <= 0, let img = CGImageSourceCreateImageAtIndex(src, 0, nil) {
            return img
        }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxSide),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
            throw FacetError("Can't decode this image.")
        }
        return img
    }

    static func load(_ url: URL) throws -> CGImage { try orientedImage(try source(url)) }

    /// Re-encodes the first frame of `src`. Keeps metadata unless `stripMetadata` is set,
    /// bakes in orientation where needed and flattens transparency for JPEG.
    static func write(_ src: CGImageSource, to out: URL, type: String, quality: Double, stripMetadata: Bool = false) throws {
        guard let dest = CGImageDestinationCreateWithURL(out as CFURL, type as CFString, 1, nil) else {
            throw FacetError("This Mac can't write \(out.pathExtension.uppercased()).")
        }
        var props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        let isJPEG = type == UTType.jpeg.identifier
        let needsPixels = stripMetadata || orientation(src) != 1 || isJPEG
        if needsPixels {
            var image = try orientedImage(src)
            if isJPEG && hasAlpha(image) { image = flatten(image) }
            if !stripMetadata {
                // Keep EXIF/GPS etc. but the pixels are already upright now.
                for (k, v) in properties(src) where k != kCGImagePropertyOrientation { props[k] = v }
                props[kCGImagePropertyOrientation] = 1
                if var tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
                    tiff[kCGImagePropertyTIFFOrientation] = 1
                    props[kCGImagePropertyTIFFDictionary] = tiff
                }
            }
            CGImageDestinationAddImage(dest, image, props as CFDictionary)
        } else {
            CGImageDestinationAddImageFromSource(dest, src, 0, props as CFDictionary)
        }
        guard CGImageDestinationFinalize(dest) else { throw FacetError("Couldn't write \(out.lastPathComponent).") }
    }

    static func write(_ image: CGImage, to out: URL, type: String, quality: Double = 0.92) throws {
        guard let dest = CGImageDestinationCreateWithURL(out as CFURL, type as CFString, 1, nil) else {
            throw FacetError("This Mac can't write \(out.pathExtension.uppercased()).")
        }
        let img = type == UTType.jpeg.identifier && hasAlpha(image) ? flatten(image) : image
        CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw FacetError("Couldn't write \(out.lastPathComponent).") }
    }

    /// UTType identifier to use when writing back "the same kind" of image.
    static func sameType(as url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        if let t = UTType(filenameExtension: ext), Catalog.imageWritableTypes.contains(t.identifier) { return t.identifier }
        return UTType.png.identifier
    }

    /// Keeps the source's own extension when writing the same type ("jpeg" stays "jpeg").
    static func outputExtension(for url: URL, type: String) -> String {
        if UTType(filenameExtension: url.pathExtension.lowercased())?.identifier == type { return url.pathExtension }
        if type == UTType.jpeg.identifier { return "jpg" }
        return UTType(type)?.preferredFilenameExtension ?? "png"
    }

    static func flatten(_ image: CGImage, background: CGColor = CGColor(gray: 1, alpha: 1)) -> CGImage {
        let w = image.width, h = image.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            ?? CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                         space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return image }
        ctx.setFillColor(background)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? image
    }

    /// One page per image, page size from the image's DPI (72 when unknown).
    static func writePDF(from urls: [URL], to out: URL, progress: ProgressSlice) throws {
        guard let consumer = CGDataConsumer(url: out as CFURL),
              let ctx = CGContext(consumer: consumer, mediaBox: nil, nil) else {
            throw FacetError("Couldn't create the PDF.")
        }
        for (i, url) in urls.enumerated() {
            try progress.check()
            let src = try source(url)
            let image = try orientedImage(src)
            let dpi = (properties(src)[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue ?? 72
            let scale = 72 / max(dpi, 1)
            let box = CGRect(x: 0, y: 0, width: Double(image.width) * scale, height: Double(image.height) * scale)
            let info = [kCGPDFContextMediaBox as String: NSValue(rect: box)] as CFDictionary
            ctx.beginPDFPage(info)
            ctx.interpolationQuality = .high
            ctx.draw(image, in: box)
            ctx.endPDFPage()
            progress.report(Double(i + 1) / Double(urls.count))
        }
        ctx.closePDF()
    }

    /// WebP/AVIF through ffmpeg: decode with ImageIO first (ffmpeg can't read HEIC reliably).
    private static func ffmpegEncode(_ url: URL, to out: URL, format: Format, progress: ProgressSlice) throws {
        let tmp = Output.temporary(ext: "png")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try write(try load(url), to: tmp, type: UTType.png.identifier)
        var args = ["-i", tmp.path]
        switch format {
        case .webp: args += ["-c:v", "libwebp", "-quality", "88", "-compression_level", "5"]
        case .avif: args += ["-c:v", "libaom-av1", "-still-picture", "1", "-crf", "28", "-cpu-used", "6"]
        default: throw FacetError("Unsupported format.")
        }
        try FFmpeg.run(args + [out.path], progress: progress)
    }
}

// MARK: - Tools

enum ImageTools {
    static func compress(_ url: URL, progress: ProgressSlice) throws -> URL {
        let src = try ImageEngine.source(url)
        let type = ImageEngine.sameType(as: url)
        let out = Output.url(for: url, ext: ImageEngine.outputExtension(for: url, type: type), suffix: "Compressed")
        // Lossy formats get a perceptually safe quality and no metadata; PNG is re-encoded
        // without ancillary chunks and 16-bit channels are reduced to 8-bit.
        if type == UTType.png.identifier {
            var image = try ImageEngine.orientedImage(src)
            if image.bitsPerComponent > 8 { image = to8Bit(image) }
            try ImageEngine.write(image, to: out, type: type)
        } else {
            try ImageEngine.write(src, to: out, type: type, quality: 0.62, stripMetadata: true)
        }
        return try keepIfSmaller(out, than: url)
    }

    static func stripMetadata(_ url: URL) throws -> URL {
        let src = try ImageEngine.source(url)
        let type = ImageEngine.sameType(as: url)
        let out = Output.url(for: url, ext: ImageEngine.outputExtension(for: url, type: type), suffix: "Clean")
        try ImageEngine.write(src, to: out, type: type, quality: 0.95, stripMetadata: true)
        return out
    }

    static func removeBackground(_ url: URL) throws -> URL {
        let image = try ImageEngine.load(url)
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        let request = VNGenerateForegroundInstanceMaskRequest()
        try handler.perform([request])
        guard let result = request.results?.first, !result.allInstances.isEmpty else {
            throw FacetError("Couldn't find a subject in this image.")
        }
        let buffer = try result.generateMaskedImage(ofInstances: result.allInstances, from: handler, croppedToInstancesExtent: false)
        let ci = CIImage(cvPixelBuffer: buffer)
        guard let cg = CIContext().createCGImage(ci, from: ci.extent) else { throw FacetError("Couldn't render the cut-out.") }
        let out = Output.url(for: url, ext: "png", suffix: "No BG")
        try ImageEngine.write(cg, to: out, type: UTType.png.identifier)
        return out
    }

    /// Finds faces and sensitive text (emails, phone numbers, card numbers, IBANs, IPs,
    /// Turkish ID numbers). Faces are pixelated, text is covered with solid bars.
    static func redact(_ url: URL) throws -> URL {
        let image = try ImageEngine.load(url)
        let regions = try Redactor.findRegions(in: image)
        guard !regions.text.isEmpty || !regions.faces.isEmpty else {
            throw FacetError("Nothing sensitive found.")
        }
        let w = image.width, h = image.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw FacetError("Couldn't redact this image.")
        }
        let full = CGRect(x: 0, y: 0, width: w, height: h)
        ctx.draw(image, in: full)

        for face in regions.faces {
            let r = face.integral.intersection(full)
            guard r.width > 2, r.height > 2 else { continue }
            // Crop in top-left based image coordinates, then shrink and blow up = pixelation.
            let crop = CGRect(x: r.minX, y: CGFloat(h) - r.maxY, width: r.width, height: r.height)
            guard let piece = image.cropping(to: crop), let tiny = scaled(piece, width: 10) else { continue }
            ctx.saveGState()
            ctx.interpolationQuality = .none
            ctx.draw(tiny, in: r)
            ctx.restoreGState()
        }
        ctx.setFillColor(CGColor(gray: 0.05, alpha: 1))
        for r in regions.text {
            let pad = r.height * 0.18
            let box = r.insetBy(dx: -pad, dy: -pad)
            ctx.addPath(CGPath(roundedRect: box, cornerWidth: pad, cornerHeight: pad, transform: nil))
            ctx.fillPath()
        }
        guard let result = ctx.makeImage() else { throw FacetError("Couldn't redact this image.") }
        let type = ImageEngine.sameType(as: url)
        let out = Output.url(for: url, ext: ImageEngine.outputExtension(for: url, type: type), suffix: "Redacted")
        try ImageEngine.write(result, to: out, type: type)
        return out
    }

    static func combineToPDF(_ urls: [URL], progress: ProgressSlice) throws -> URL {
        let out = Output.url(for: urls[0], ext: "pdf", suffix: urls.count > 1 ? "and \(urls.count - 1) more" : nil)
        do { try ImageEngine.writePDF(from: urls, to: out, progress: progress) } catch {
            try? FileManager.default.removeItem(at: out)
            throw error
        }
        return out
    }

    // MARK: Helpers

    static func scaled(_ image: CGImage, width: Int) -> CGImage? {
        let height = max(1, Int(Double(image.height) * Double(width) / Double(max(image.width, 1))))
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }

    static func to8Bit(_ image: CGImage) -> CGImage {
        let alpha = ImageEngine.hasAlpha(image)
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: (alpha ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast).rawValue) else { return image }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage() ?? image
    }

    /// Deletes `out` and reports when compression didn't help.
    static func keepIfSmaller(_ out: URL, than original: URL) throws -> URL {
        let a = (try? out.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let b = (try? original.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? Int.max
        if a >= b {
            try? FileManager.default.removeItem(at: out)
            throw FacetError("Already as small as it gets.")
        }
        return out
    }
}

/// Locates what to hide in an image, in image pixel coordinates (origin bottom-left).
enum Redactor {
    struct Regions { var text: [CGRect] = []; var faces: [CGRect] = [] }

    static func findRegions(in image: CGImage) throws -> Regions {
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        let text = VNRecognizeTextRequest()
        text.recognitionLevel = .accurate
        text.usesLanguageCorrection = false
        let faces = VNDetectFaceRectanglesRequest()
        try handler.perform([text, faces])

        let w = CGFloat(image.width), h = CGFloat(image.height)
        func toPixels(_ r: CGRect) -> CGRect { CGRect(x: r.minX * w, y: r.minY * h, width: r.width * w, height: r.height * h) }

        var regions = Regions()
        for face in faces.results ?? [] {
            regions.faces.append(toPixels(face.boundingBox).insetBy(dx: -0.12 * face.boundingBox.width * w, dy: -0.18 * face.boundingBox.height * h))
        }
        for obs in text.results ?? [] {
            guard let candidate = obs.topCandidates(1).first else { continue }
            for range in sensitiveRanges(in: candidate.string) {
                if let box = try? candidate.boundingBox(for: range) {
                    regions.text.append(toPixels(box.boundingBox))
                }
            }
        }
        return regions
    }

    static func sensitiveRanges(in s: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        let ns = s as NSString
        let full = NSRange(location: 0, length: ns.length)

        let patterns = [
            "[A-Z0-9._%+-]+@[A-Z0-9.-]+\\.[A-Z]{2,}",                       // email
            "\\b[A-Z]{2}\\d{2}(?: ?[A-Z0-9]){11,30}\\b",                      // IBAN
            "\\b(?:\\d{1,3}\\.){3}\\d{1,3}\\b",                               // IPv4
        ]
        for p in patterns {
            guard let re = try? NSRegularExpression(pattern: p, options: [.caseInsensitive]) else { continue }
            for m in re.matches(in: s, range: full) {
                if let r = Range(m.range, in: s) { ranges.append(r) }
            }
        }
        // Card numbers (Luhn) and Turkish ID numbers (checksum).
        if let re = try? NSRegularExpression(pattern: "\\b\\d(?:[ -]?\\d){10,18}\\b") {
            for m in re.matches(in: s, range: full) {
                let digits = ns.substring(with: m.range).filter(\.isNumber)
                if (digits.count >= 13 && luhn(digits)) || (digits.count == 11 && turkishID(digits)) {
                    if let r = Range(m.range, in: s) { ranges.append(r) }
                }
            }
        }
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.phoneNumber.rawValue) {
            for m in detector.matches(in: s, range: full) {
                if let r = Range(m.range, in: s) { ranges.append(r) }
            }
        }
        return ranges
    }

    static func luhn(_ digits: String) -> Bool {
        var sum = 0
        for (i, ch) in digits.reversed().enumerated() {
            guard var d = ch.wholeNumberValue else { return false }
            if i % 2 == 1 { d *= 2; if d > 9 { d -= 9 } }
            sum += d
        }
        return sum % 10 == 0
    }

    static func turkishID(_ digits: String) -> Bool {
        let d = digits.compactMap(\.wholeNumberValue)
        guard d.count == 11, d[0] != 0 else { return false }
        let odd = d[0] + d[2] + d[4] + d[6] + d[8]
        let even = d[1] + d[3] + d[5] + d[7]
        let tenth = ((odd * 7 - even) % 10 + 10) % 10
        guard tenth == d[9] else { return false }
        return d[0..<10].reduce(0, +) % 10 == d[10]
    }
}
