import AppKit
import PDFKit
import UniformTypeIdentifiers

enum PDFEngine {
    static func open(_ url: URL) throws -> PDFDocument {
        guard let doc = PDFDocument(url: url) else { throw FacetError("Can't open \(url.lastPathComponent).") }
        if doc.isLocked { throw FacetError("This PDF is password protected.") }
        return doc
    }

    static func convert(_ url: URL, to f: Format, progress: ProgressSlice) throws -> URL {
        let doc = try open(url)
        switch f {
        case .png, .jpg:
            return try renderPages(doc, source: url, format: f, progress: progress)
        case .txt:
            let out = Output.url(for: url, ext: "txt")
            try text(of: doc, progress: progress).write(to: out, atomically: true, encoding: .utf8)
            return out
        case .md:
            let out = Output.url(for: url, ext: "md")
            let attributed = try attributedText(of: doc, progress: progress)
            try Markdown.markdown(from: attributed).write(to: out, atomically: true, encoding: .utf8)
            return out
        case .xlsx:
            let out = Output.url(for: url, ext: "xlsx")
            try SpreadsheetIO.writeXLSX(PDFTables.workbook(from: doc, progress: progress), to: out)
            return out
        case .pptx:
            let out = Output.url(for: url, ext: "pptx")
            var slides: [Data] = []
            var size = CGSize(width: 960, height: 540)
            for i in 0..<doc.pageCount {
                try progress.check()
                guard let page = doc.page(at: i) else { continue }
                if i == 0 { size = page.bounds(for: .cropBox).size }
                if let data = pageImageData(page, scale: 2, type: UTType.jpeg.identifier) { slides.append(data) }
                progress.report(Double(i + 1) / Double(doc.pageCount))
            }
            try PPTXWriter.write(images: slides, slideSize: size, to: out)
            return out
        case .docx, .rtf, .html, .epub, .pages, .odt:
            let attributed = try attributedText(of: doc, progress: progress)
            return try DocumentEngine.write(attributed, title: url.deletingPathExtension().lastPathComponent,
                                            source: url, to: f, progress: progress)
        default:
            throw FacetError("Can't convert PDF to \(f.label).")
        }
    }

    /// Plain text with a form feed between pages, the way most tools separate them.
    static func text(of doc: PDFDocument, progress: ProgressSlice) throws -> String {
        var pages: [String] = []
        for i in 0..<doc.pageCount {
            try progress.check()
            pages.append(doc.page(at: i)?.string ?? "")
            progress.report(Double(i + 1) / Double(doc.pageCount))
        }
        return pages.joined(separator: "\n\n")
    }

    /// Styled text (fonts, sizes, bold/italic) with page breaks between pages.
    static func attributedText(of doc: PDFDocument, progress: ProgressSlice) throws -> NSAttributedString {
        let result = NSMutableAttributedString()
        for i in 0..<doc.pageCount {
            try progress.check()
            if let page = doc.page(at: i), let s = page.attributedString {
                if result.length > 0 { result.append(NSAttributedString(string: "\u{0C}")) }
                result.append(s)
            }
            progress.report(Double(i + 1) / Double(doc.pageCount) * 0.8)
        }
        if result.length == 0 {
            throw FacetError("This PDF has no text (it may be scanned). Try PNG or JPG instead.")
        }
        return result
    }

    static func pageImage(_ page: PDFPage, scale: CGFloat) -> CGImage? {
        // thumbnail(of:for:) applies the page rotation and paints a white background.
        let box = page.bounds(for: .cropBox)
        let rotated = abs(page.rotation) % 180 == 90
        let size = NSSize(width: ((rotated ? box.height : box.width) * scale).rounded(),
                          height: ((rotated ? box.width : box.height) * scale).rounded())
        guard size.width > 0, size.height > 0 else { return nil }
        let image = page.thumbnail(of: size, for: .cropBox)
        var rect = NSRect(origin: .zero, size: size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    static func pageImageData(_ page: PDFPage, scale: CGFloat, type: String) -> Data? {
        guard let image = pageImage(page, scale: scale) else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, type as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.88] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    /// Single page → one image next to the PDF; several pages → a folder of images.
    private static func renderPages(_ doc: PDFDocument, source: URL, format f: Format, progress: ProgressSlice) throws -> URL {
        let type = f == .png ? UTType.png.identifier : UTType.jpeg.identifier
        let n = doc.pageCount
        let folder = n > 1 ? try Output.folder(for: source, suffix: f.label) : nil
        var single: URL?
        let base = source.deletingPathExtension().lastPathComponent
        let digits = String(n).count
        for i in 0..<n {
            try progress.check()
            guard let page = doc.page(at: i), let image = pageImage(page, scale: 2) else { continue }
            let out: URL
            if let folder {
                let num = String(repeating: "0", count: max(0, digits - String(i + 1).count)) + String(i + 1)
                out = folder.appendingPathComponent("\(base) \(num)").appendingPathExtension(f.ext)
            } else {
                out = Output.url(for: source, ext: f.ext)
                single = out
            }
            try ImageEngine.write(image, to: out, type: type, quality: 0.9)
            progress.report(Double(i + 1) / Double(n))
        }
        guard let result = folder ?? single else { throw FacetError("This PDF has no pages.") }
        return result
    }
}

/// Rebuilds tables from PDF text positions: characters → lines → cells → aligned columns.
enum PDFTables {
    static func workbook(from doc: PDFDocument, progress: ProgressSlice) throws -> Workbook {
        var rows: [[String]] = []
        for i in 0..<doc.pageCount {
            try progress.check()
            if let page = doc.page(at: i) {
                if !rows.isEmpty { rows.append([]) }
                rows += table(on: page)
            }
            progress.report(Double(i + 1) / Double(doc.pageCount))
        }
        while let last = rows.last, last.allSatisfy({ $0.isEmpty }) { rows.removeLast() }
        guard !rows.isEmpty else { throw FacetError("No text found in this PDF.") }
        return Workbook(sheets: [Sheet(name: "Sheet1", rows: rows)])
    }

    private struct Glyph { let ch: Character; let rect: CGRect }
    private struct Cell { var text: String; var minX: CGFloat }

    static func table(on page: PDFPage) -> [[String]] {
        guard let string = page.string, !string.isEmpty else { return [] }
        // Collect visible characters with their boxes.
        var glyphs: [Glyph] = []
        var index = 0
        for ch in string {
            let units = String(ch).utf16.count
            defer { index += units }
            if ch.isWhitespace || ch.isNewline { continue }
            let r = page.characterBounds(at: index)
            if r.isEmpty || r.width.isNaN { continue }
            glyphs.append(Glyph(ch: ch, rect: r))
        }
        guard !glyphs.isEmpty else { return [] }

        // Group into lines by vertical centre (PDF y grows upward → sort descending).
        glyphs.sort { $0.rect.midY > $1.rect.midY }
        var lines: [[Glyph]] = []
        for g in glyphs {
            if var last = lines.last, let ref = last.first, abs(ref.rect.midY - g.rect.midY) < max(ref.rect.height, g.rect.height) * 0.45 {
                last.append(g)
                lines[lines.count - 1] = last
            } else {
                lines.append([g])
            }
        }

        // Split each line into cells at wide gaps.
        var cellLines: [[Cell]] = []
        for var line in lines {
            line.sort { $0.rect.minX < $1.rect.minX }
            let avgWidth = line.map(\.rect.width).reduce(0, +) / CGFloat(line.count)
            var cells: [Cell] = []
            var current = Cell(text: String(line[0].ch), minX: line[0].rect.minX)
            var prev = line[0].rect
            for g in line.dropFirst() {
                let gap = g.rect.minX - prev.maxX
                if gap > avgWidth * 1.8 {
                    cells.append(current)
                    current = Cell(text: String(g.ch), minX: g.rect.minX)
                } else {
                    if gap > avgWidth * 0.25 { current.text.append(" ") }
                    current.text.append(g.ch)
                }
                prev = g.rect
            }
            cells.append(current)
            cellLines.append(cells)
        }

        // Column anchors: cluster every cell's left edge.
        let starts = cellLines.flatMap { $0.map(\.minX) }.sorted()
        var anchors: [CGFloat] = []
        for x in starts {
            if let a = anchors.last, x - a < 12 { continue }
            anchors.append(x)
        }
        return cellLines.map { cells in
            var row = [String](repeating: "", count: anchors.count)
            for c in cells {
                // Rightmost anchor at or left of the cell start.
                let col = anchors.lastIndex(where: { $0 <= c.minX + 6 }) ?? 0
                row[col] = row[col].isEmpty ? c.text : row[col] + " " + c.text
            }
            while let last = row.last, last.isEmpty { row.removeLast() }
            return row
        }
    }
}

// MARK: - Tools

enum PDFTools {
    static func compress(_ url: URL, progress: ProgressSlice) throws -> URL {
        let doc = try open(url)
        let out = Output.url(for: url, ext: "pdf", suffix: "Compressed")
        progress.report(0.2)
        let options: [PDFDocumentWriteOption: Any] = [
            .saveImagesAsJPEGOption: true,
            .optimizeImagesForScreenOption: true,
        ]
        guard doc.write(to: out, withOptions: options) else { throw FacetError("Couldn't write the PDF.") }
        return try ImageTools.keepIfSmaller(out, than: url)
    }

    static func stripMetadata(_ url: URL) throws -> URL {
        let doc = try open(url)
        doc.documentAttributes = [:]
        let out = Output.url(for: url, ext: "pdf", suffix: "Clean")
        guard doc.write(to: out) else { throw FacetError("Couldn't write the PDF.") }
        return out
    }

    static func splitPages(_ url: URL, progress: ProgressSlice) throws -> URL {
        let doc = try open(url)
        guard doc.pageCount > 1 else { throw FacetError("This PDF has only one page.") }
        let folder = try Output.folder(for: url, suffix: "Pages")
        let base = url.deletingPathExtension().lastPathComponent
        let digits = String(doc.pageCount).count
        for i in 0..<doc.pageCount {
            try progress.check()
            guard let page = doc.page(at: i)?.copy() as? PDFPage else { continue }
            let single = PDFDocument()
            single.insert(page, at: 0)
            let num = String(repeating: "0", count: max(0, digits - String(i + 1).count)) + String(i + 1)
            _ = single.write(to: folder.appendingPathComponent("\(base) \(num).pdf"))
            progress.report(Double(i + 1) / Double(doc.pageCount))
        }
        return folder
    }

    static func merge(_ urls: [URL], progress: ProgressSlice) throws -> URL {
        let result = PDFDocument()
        for (i, url) in urls.enumerated() {
            try progress.check()
            let doc = try open(url)
            for p in 0..<doc.pageCount {
                if let page = doc.page(at: p)?.copy() as? PDFPage { result.insert(page, at: result.pageCount) }
            }
            progress.report(Double(i + 1) / Double(urls.count))
        }
        let out = Output.url(for: urls[0], ext: "pdf", suffix: "Merged")
        guard result.write(to: out) else { throw FacetError("Couldn't write the PDF.") }
        return out
    }

    /// Writes pages in a new order/rotation (from the Organize editor).
    static func save(pages: [(page: PDFPage, rotation: Int)], source: URL) throws -> URL {
        let result = PDFDocument()
        for item in pages {
            guard let page = item.page.copy() as? PDFPage else { continue }
            page.rotation = item.rotation
            result.insert(page, at: result.pageCount)
        }
        let out = Output.url(for: source, ext: "pdf", suffix: "Organized")
        guard result.write(to: out) else { throw FacetError("Couldn't write the PDF.") }
        return out
    }

    private static func open(_ url: URL) throws -> PDFDocument { try PDFEngine.open(url) }
}
