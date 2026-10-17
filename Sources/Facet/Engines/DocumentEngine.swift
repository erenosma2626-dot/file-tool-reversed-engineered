import AppKit
import PDFKit

/// Text documents and EPUB through Cocoa's text system, which reads and writes
/// DOCX, DOC, RTF, ODT and HTML natively.
enum DocumentEngine {
    static func convert(_ url: URL, to f: Format, progress: ProgressSlice) throws -> URL {
        let ext = url.pathExtension.lowercased()
        let title = url.deletingPathExtension().lastPathComponent

        // Fast paths that keep more structure than a round trip through rich text.
        if ext == "epub", f == .html {
            let out = Output.url(for: url, ext: "html")
            try EPUBReader.read(url: url).html.write(to: out, atomically: true, encoding: .utf8)
            return out
        }
        if ["md", "markdown"].contains(ext), f == .html {
            let out = Output.url(for: url, ext: "html")
            try Markdown.html(from: try readText(url)).write(to: out, atomically: true, encoding: .utf8)
            return out
        }
        if ext == "epub", f == .pdf || f == .docx || f == .pages {
            // Keep chapters on separate pages.
            let book = try EPUBReader.read(url: url)
            let attributed = try attributed(html: book.html, base: nil)
            progress.report(0.4)
            return try write(attributed, title: book.title.isEmpty ? title : book.title, source: url, to: f, progress: progress)
        }

        let attributed = try load(url)
        progress.report(0.4)
        return try write(attributed, title: title, source: url, to: f, progress: progress)
    }

    // MARK: Reading

    static func load(_ url: URL) throws -> NSAttributedString {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "docx": return try read(url, .officeOpenXML)
        case "doc": return try read(url, .docFormat)
        case "rtf": return try read(url, .rtf)
        case "rtfd": return try read(url, .rtfd)
        case "odt": return try read(url, .openDocument)
        case "webarchive": return try read(url, .webArchive)
        case "html", "htm": return try attributed(html: try readText(url), base: url.deletingLastPathComponent())
        case "md", "markdown": return try attributed(html: Markdown.html(from: try readText(url)), base: url.deletingLastPathComponent())
        case "epub": return try attributed(html: try EPUBReader.read(url: url).html, base: nil)
        case "pages":
            guard let pdf = PDFDocument(data: try PagesBridge.previewPDF(of: url)) else {
                throw FacetError("Can't read this Pages file.")
            }
            return try PDFEngine.attributedText(of: pdf, progress: ProgressSlice(job: Job(title: "", subtitle: "")))
        default:
            let text = try readText(url)
            return NSAttributedString(string: text, attributes: [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: NSColor.black,
            ])
        }
    }

    private static func read(_ url: URL, _ type: NSAttributedString.DocumentType) throws -> NSAttributedString {
        try onMain {
            try NSAttributedString(url: url, options: [.documentType: type], documentAttributes: nil)
        }
    }

    /// Cocoa's HTML importer uses WebKit and must run on the main thread.
    static func attributed(html: String, base: URL?) throws -> NSAttributedString {
        let data = Data(html.utf8)
        var options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue,
        ]
        if let base { options[.baseURL] = base }
        return try onMain {
            try NSAttributedString(data: data, options: options, documentAttributes: nil)
        }
    }

    static func readText(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        if let s = String(data: data, encoding: .utf8) { return s }
        if let s = String(data: data, encoding: .utf16) { return s }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Writing

    static func write(_ attributed: NSAttributedString, title: String, source: URL, to f: Format, progress: ProgressSlice) throws -> URL {
        let out = Output.url(for: source, ext: f.ext)
        let range = NSRange(location: 0, length: attributed.length)
        do {
            switch f {
            case .pdf:
                try pdfData(from: attributed).write(to: out)
            case .docx:
                try attributed.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML]).write(to: out)
            case .rtf:
                try attributed.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]).write(to: out)
            case .odt:
                try attributed.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.openDocument]).write(to: out)
            case .html:
                try htmlString(attributed, title: title).write(to: out, atomically: true, encoding: .utf8)
            case .txt:
                try attributed.string.replacingOccurrences(of: "\u{0C}", with: "\n\n")
                    .write(to: out, atomically: true, encoding: .utf8)
            case .md:
                try Markdown.markdown(from: attributed).write(to: out, atomically: true, encoding: .utf8)
            case .epub:
                let body = try bodyHTML(htmlString(attributed, title: title))
                try EPUBWriter.write(title: title, author: nil, chapters: [EPUBChapter(title: title, bodyHTML: body)], to: out)
            case .pages:
                // Hand Pages a DOCX and let it save the native format.
                let tmp = Output.temporary(ext: "docx")
                defer { try? FileManager.default.removeItem(at: tmp) }
                try attributed.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML]).write(to: tmp)
                try PagesBridge.save(tmp, as: out, progress: progress)
            default:
                throw FacetError("Can't convert to \(f.label).")
            }
        } catch {
            try? FileManager.default.removeItem(at: out)
            throw error
        }
        progress.report(1)
        return out
    }

    static func htmlString(_ attributed: NSAttributedString, title: String) throws -> String {
        let data = try attributed.data(from: NSRange(location: 0, length: attributed.length),
                                       documentAttributes: [.documentType: NSAttributedString.DocumentType.html,
                                                            .characterEncoding: String.Encoding.utf8.rawValue,
                                                            .title: title])
        return String(decoding: data, as: UTF8.self)
    }

    /// Inner HTML of <body>, with Cocoa's <style> block kept inline so formatting survives.
    static func bodyHTML(_ html: String) -> String {
        let lower = html.lowercased()
        var style = ""
        if let s = lower.range(of: "<style"), let e = lower.range(of: "</style>", range: s.upperBound..<lower.endIndex) {
            style = String(html[s.lowerBound..<e.upperBound])
        }
        guard let open = lower.range(of: "<body"),
              let openEnd = lower.range(of: ">", range: open.upperBound..<lower.endIndex),
              let close = lower.range(of: "</body>", options: .backwards) else { return html }
        return style + String(html[openEnd.upperBound..<close.lowerBound])
    }

    /// Paginates rich text onto pages of the user's default paper size (A4 or Letter).
    static func pdfData(from attributed: NSAttributedString, landscape: Bool = false) throws -> Data {
        var paper = NSPrintInfo.shared.paperSize
        if paper.width <= 0 || paper.height <= 0 { paper = NSSize(width: 595, height: 842) }
        if landscape { paper = NSSize(width: max(paper.width, paper.height), height: min(paper.width, paper.height)) }
        let margin: CGFloat = 56
        let content = NSSize(width: paper.width - margin * 2, height: paper.height - margin * 2)

        // Text with no explicit color would render with the dynamic label color (white in
        // Dark Mode); pin it to black for paper.
        let text = NSMutableAttributedString(attributedString: attributed)
        text.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            if value == nil { text.addAttribute(.foregroundColor, value: NSColor.black, range: range) }
        }

        let data = NSMutableData()
        try onMain {
            let storage = NSTextStorage(attributedString: text)
            let layout = NSLayoutManager()
            storage.addLayoutManager(layout)

            var containers: [NSTextContainer] = []
            while true {
                let container = NSTextContainer(size: content)
                container.lineFragmentPadding = 0
                layout.addTextContainer(container)
                containers.append(container)
                let glyphs = layout.glyphRange(for: container)
                if glyphs.length == 0 || NSMaxRange(glyphs) >= layout.numberOfGlyphs || containers.count > 5000 { break }
            }

            guard let consumer = CGDataConsumer(data: data as CFMutableData) else { throw FacetError("Couldn't create the PDF.") }
            var box = CGRect(origin: .zero, size: paper)
            guard let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { throw FacetError("Couldn't create the PDF.") }
            let previous = NSGraphicsContext.current
            for container in containers {
                let glyphs = layout.glyphRange(for: container)
                ctx.beginPDFPage(nil)
                ctx.saveGState()
                ctx.translateBy(x: 0, y: paper.height)
                ctx.scaleBy(x: 1, y: -1)
                NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
                let origin = NSPoint(x: margin, y: margin)
                layout.drawBackground(forGlyphRange: glyphs, at: origin)
                layout.drawGlyphs(forGlyphRange: glyphs, at: origin)
                ctx.restoreGState()
                ctx.endPDFPage()
            }
            NSGraphicsContext.current = previous
            ctx.closePDF()
        }
        return data as Data
    }
}

// MARK: - Spreadsheets

enum SpreadsheetEngine {
    static func convert(_ url: URL, to f: Format, progress: ProgressSlice) throws -> URL {
        let workbook = try SpreadsheetIO.read(url: url)
        guard !workbook.sheets.isEmpty else { throw FacetError("This spreadsheet is empty.") }
        progress.report(0.4)
        switch f {
        case .xlsx:
            let out = Output.url(for: url, ext: "xlsx")
            try SpreadsheetIO.writeXLSX(workbook, to: out)
            return out
        case .ods:
            let out = Output.url(for: url, ext: "ods")
            try SpreadsheetIO.writeODS(workbook, to: out)
            return out
        case .csv, .tsv:
            let sep: Character = f == .csv ? "," : "\t"
            let nonEmpty = workbook.sheets.filter { !$0.rows.isEmpty }
            let sheets = nonEmpty.isEmpty ? workbook.sheets : nonEmpty
            if sheets.count == 1 {
                let out = Output.url(for: url, ext: f.ext)
                try SpreadsheetIO.writeDelimited(sheets[0], separator: sep, to: out)
                return out
            }
            // One file per sheet, in a folder.
            let folder = try Output.folder(for: url, suffix: f.label)
            for sheet in sheets {
                let name = sheet.name.replacingOccurrences(of: "/", with: "-")
                try SpreadsheetIO.writeDelimited(sheet, separator: sep, to: folder.appendingPathComponent(name).appendingPathExtension(f.ext))
            }
            return folder
        case .pdf:
            let out = Output.url(for: url, ext: "pdf")
            let html = SpreadsheetIO.html(workbook)
            let attributed = try DocumentEngine.attributed(html: html, base: nil)
            let wide = (workbook.sheets.map { $0.rows.map(\.count).max() ?? 0 }.max() ?? 0) > 7
            try DocumentEngine.pdfData(from: attributed, landscape: wide).write(to: out)
            return out
        default:
            throw FacetError("Can't convert spreadsheet to \(f.label).")
        }
    }
}
