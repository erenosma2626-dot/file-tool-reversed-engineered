import Foundation

struct EPUBChapter {
    var title: String
    var bodyHTML: String   // inner HTML of <body>, XHTML-ish
}

// MARK: - Shared XML helper

enum XMLText {
    /// Escapes & < > " ' and drops characters that are invalid in XML 1.0
    /// (control characters other than tab, newline and carriage return).
    static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.utf8.count)
        for scalar in s.unicodeScalars {
            let v = scalar.value
            switch v {
            case 0x26: out += "&amp;"
            case 0x3C: out += "&lt;"
            case 0x3E: out += "&gt;"
            case 0x22: out += "&quot;"
            case 0x27: out += "&apos;"
            default:
                if isValidXMLScalar(v) {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out
    }

    static func isValidXMLScalar(_ v: UInt32) -> Bool {
        switch v {
        case 0x9, 0xA, 0xD:
            return true
        case 0x0...0x1F:
            return false
        case 0xFFFE, 0xFFFF:
            return false
        case 0xD800...0xDFFF:
            return false
        default:
            return v <= 0x10FFFF
        }
    }
}

// MARK: - File-private helpers

/// "opf:item" -> "item"
fileprivate func epubLocalName(_ qualified: String) -> String {
    if let colon = qualified.lastIndex(of: ":") {
        return String(qualified[qualified.index(after: colon)...])
    }
    return qualified
}

/// Regex replace with a literal-ish template ($1 etc. allowed).
fileprivate func epubReplace(_ text: String,
                             _ pattern: String,
                             _ template: String,
                             options: NSRegularExpression.Options = []) -> String {
    guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
        return text
    }
    let length = NSString(string: text).length
    return regex.stringByReplacingMatches(in: text,
                                          options: [],
                                          range: NSRange(location: 0, length: length),
                                          withTemplate: template)
}

fileprivate struct EPUBManifestItem {
    let href: String
    let mediaType: String
}

fileprivate final class EPUBContainerDelegate: NSObject, XMLParserDelegate {
    var fullPath: String?

    func parser(_ parser: XMLParser,
                didStartElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?,
                attributes attributeDict: [String: String]) {
        if fullPath == nil, epubLocalName(elementName) == "rootfile" {
            fullPath = attributeDict["full-path"]
        }
    }
}

fileprivate final class EPUBOPFDelegate: NSObject, XMLParserDelegate {
    var title: String = ""
    var author: String?
    var manifestOrder: [String] = []
    var manifest: [String: EPUBManifestItem] = [:]
    var spine: [String] = []
    private var capturing: String?
    private var buffer: String = ""

    func parser(_ parser: XMLParser,
                didStartElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?,
                attributes attributeDict: [String: String]) {
        let name = epubLocalName(elementName)
        switch name {
        case "title":
            if title.isEmpty && capturing == nil {
                capturing = "title"
                buffer = ""
            }
        case "creator":
            if author == nil && capturing == nil {
                capturing = "creator"
                buffer = ""
            }
        case "item":
            if let id = attributeDict["id"], let href = attributeDict["href"] {
                manifestOrder.append(id)
                manifest[id] = EPUBManifestItem(href: href, mediaType: attributeDict["media-type"] ?? "")
            }
        case "itemref":
            if let idref = attributeDict["idref"] {
                spine.append(idref)
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser,
                didEndElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?) {
        let name = epubLocalName(elementName)
        if let cap = capturing, cap == name {
            let value = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if cap == "title" {
                title = value
            } else if !value.isEmpty {
                author = value
            }
            capturing = nil
            buffer = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if capturing != nil {
            buffer += string
        }
    }
}

// MARK: - Reader

enum EPUBReader {

    /// Returns book title and ONE combined standalone HTML document containing all spine chapters in order.
    static func read(url: URL) throws -> (title: String, author: String?, html: String) {
        let book = try loadBook(url: url)
        let joined = book.chapters.map { $0.bodyHTML }.joined(separator: "<div style=\"page-break-before:always\"></div>")
        let head = "<!DOCTYPE html><html><head><meta charset=\"utf-8\"><title>\(XMLText.escape(book.title))</title>"
        let style = "<style>body{font-family:-apple-system,Georgia,serif;line-height:1.5;} img{max-width:100%;}</style></head>"
        let html = "\(head)\(style)<body>\(joined)</body></html>"
        return (title: book.title, author: book.author, html: html)
    }

    /// Same as `read`, but returns the chapters separately.
    static func chapters(url: URL) throws -> (title: String, author: String?, chapters: [EPUBChapter]) {
        let book = try loadBook(url: url)
        return (title: book.title, author: book.author, chapters: book.chapters)
    }

    // MARK: Loading

    private struct Book {
        var title: String
        var author: String?
        var chapters: [EPUBChapter]
    }

    private static func loadBook(url: URL) throws -> Book {
        let zip = try ZipReader(url: url)

        guard let containerData = try? zip.data(for: "META-INF/container.xml") else {
            throw ZipError.invalidArchive
        }
        guard let opfPath = parseContainer(containerData), !opfPath.isEmpty else {
            throw ZipError.invalidArchive
        }

        let opfData = try zip.data(for: opfPath)
        let pkg = parseOPF(opfData)
        let opfDir = directory(of: opfPath)

        var docPaths: [String] = []
        for idref in pkg.spine {
            if let item = pkg.manifest[idref] {
                docPaths.append(resolve(item.href, relativeTo: opfDir))
            }
        }
        if docPaths.isEmpty {
            // Fallback: no usable spine, take XHTML/HTML manifest items in manifest order.
            for id in pkg.manifestOrder {
                if let item = pkg.manifest[id], item.mediaType.contains("html") {
                    docPaths.append(resolve(item.href, relativeTo: opfDir))
                }
            }
        }
        if docPaths.isEmpty {
            throw ZipError.invalidArchive
        }

        var title = pkg.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty {
            title = url.deletingPathExtension().lastPathComponent
        }

        var chapters: [EPUBChapter] = []
        for (index, docPath) in docPaths.enumerated() {
            guard let data = try? zip.data(for: docPath) else { continue }
            let raw = String(decoding: data, as: UTF8.self)
            let chapterTitle = chapterTitleText(in: raw) ?? "Chapter \(index + 1)"

            var body = bodyContent(of: raw)
            body = epubReplace(body, "<link\\b[^>]*>", "", options: [.caseInsensitive])
            body = epubReplace(body, "<script\\b[^>]*>.*?</script\\s*>", "",
                               options: [.caseInsensitive, .dotMatchesLineSeparators])
            body = inlineImages(in: body, chapterDir: directory(of: docPath), zip: zip)

            chapters.append(EPUBChapter(title: chapterTitle, bodyHTML: body))
        }
        if chapters.isEmpty {
            throw ZipError.invalidArchive
        }

        return Book(title: title, author: pkg.author, chapters: chapters)
    }

    private static func parseContainer(_ data: Data) -> String? {
        let parser = XMLParser(data: data)
        let delegate = EPUBContainerDelegate()
        parser.delegate = delegate
        _ = parser.parse()
        return delegate.fullPath
    }

    private static func parseOPF(_ data: Data) -> EPUBOPFDelegate {
        let parser = XMLParser(data: data)
        let delegate = EPUBOPFDelegate()
        parser.delegate = delegate
        _ = parser.parse()
        return delegate
    }

    // MARK: Paths

    private static func directory(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[path.startIndex..<slash])
    }

    /// Resolves an href relative to a base directory (percent-decoded, "." and ".." removed).
    private static func resolve(_ href: String, relativeTo baseDir: String) -> String {
        var h = href
        if let hash = h.firstIndex(of: "#") {
            h = String(h[h.startIndex..<hash])
        }
        h = h.removingPercentEncoding ?? h
        if h.hasPrefix("/") {
            return normalizePath(h)
        }
        let combined = baseDir.isEmpty ? h : baseDir + "/" + h
        return normalizePath(combined)
    }

    private static func normalizePath(_ path: String) -> String {
        var parts: [String] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            if component == "." {
                continue
            }
            if component == ".." {
                if !parts.isEmpty {
                    parts.removeLast()
                }
                continue
            }
            parts.append(String(component))
        }
        return parts.joined(separator: "/")
    }

    // MARK: Content

    /// Inner HTML of <body>, or the whole text when there is no body element.
    private static func bodyContent(of html: String) -> String {
        guard let openStart = html.range(of: "<body", options: .caseInsensitive) else {
            return html
        }
        guard let openEnd = html.range(of: ">", range: openStart.upperBound..<html.endIndex) else {
            return html
        }
        let contentStart = openEnd.upperBound
        if let closeStart = html.range(of: "</body", options: .caseInsensitive, range: contentStart..<html.endIndex) {
            return String(html[contentStart..<closeStart.lowerBound])
        }
        return String(html[contentStart...])
    }

    private static func chapterTitleText(in html: String) -> String? {
        if let heading = firstGroupText(in: bodyContent(of: html), "<(h1|h2)\\b[^>]*>(.*?)</\\1\\s*>", group: 2) {
            return heading
        }
        return firstGroupText(in: html, "<title\\b[^>]*>(.*?)</title\\s*>", group: 1)
    }

    private static func firstGroupText(in text: String, _ pattern: String, group: Int) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern,
                                                   options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return nil
        }
        let ns = NSString(string: text)
        guard let match = regex.firstMatch(in: text, options: [], range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }
        let range = match.range(at: group)
        if range.location == NSNotFound {
            return nil
        }
        let plain = plainText(ns.substring(with: range))
        return plain.isEmpty ? nil : plain
    }

    /// Strips tags, decodes a few common entities and collapses whitespace.
    private static func plainText(_ html: String) -> String {
        var s = epubReplace(html, "<[^>]+>", "")
        let pairs: [(String, String)] = [
            ("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""),
            ("&#39;", "'"), ("&apos;", "'"), ("&amp;", "&")
        ]
        for pair in pairs {
            s = s.replacingOccurrences(of: pair.0, with: pair.1)
        }
        let words = s.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        return words.joined(separator: " ")
    }

    // MARK: Images

    private static func inlineImages(in html: String, chapterDir: String, zip: ZipReader) -> String {
        var s = rewriteImageAttributes(in: html,
                                       pattern: "(<img[^>]*?\\ssrc\\s*=\\s*[\"'])([^\"']+)([\"'])",
                                       chapterDir: chapterDir,
                                       zip: zip)
        s = rewriteImageAttributes(in: s,
                                   pattern: "(<image[^>]*?\\sxlink:href\\s*=\\s*[\"'])([^\"']+)([\"'])",
                                   chapterDir: chapterDir,
                                   zip: zip)
        return s
    }

    private static func rewriteImageAttributes(in html: String,
                                               pattern: String,
                                               chapterDir: String,
                                               zip: ZipReader) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return html
        }
        let ns = NSString(string: html)
        let matches = regex.matches(in: html, options: [], range: NSRange(location: 0, length: ns.length))
        if matches.isEmpty {
            return html
        }

        var result = ""
        var cursor = 0
        for match in matches {
            let whole = match.range
            if whole.location > cursor {
                result += ns.substring(with: NSRange(location: cursor, length: whole.location - cursor))
            }
            let prefix = ns.substring(with: match.range(at: 1))
            let src = ns.substring(with: match.range(at: 2))
            let suffix = ns.substring(with: match.range(at: 3))
            result += prefix + inlineSource(src, chapterDir: chapterDir, zip: zip) + suffix
            cursor = whole.location + whole.length
        }
        if cursor < ns.length {
            result += ns.substring(from: cursor)
        }
        return result
    }

    /// Returns a data: URI for resources found in the archive, otherwise the original source.
    private static func inlineSource(_ src: String, chapterDir: String, zip: ZipReader) -> String {
        let trimmed = src.trimmingCharacters(in: .whitespaces)
        let lower = trimmed.lowercased()
        if lower.hasPrefix("data:") || lower.hasPrefix("http:") || lower.hasPrefix("https:") || lower.hasPrefix("#") {
            return src
        }
        let path = resolve(trimmed, relativeTo: chapterDir)
        guard let mime = mimeType(forPath: path) else { return src }
        guard let data = try? zip.data(for: path) else { return src }
        return "data:\(mime);base64,\(data.base64EncodedString())"
    }

    private static func mimeType(forPath path: String) -> String? {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        switch ext {
        case "png":
            return "image/png"
        case "jpg", "jpeg":
            return "image/jpeg"
        case "gif":
            return "image/gif"
        case "svg":
            return "image/svg+xml"
        case "webp":
            return "image/webp"
        default:
            return nil
        }
    }
}

// MARK: - Writer

enum EPUBWriter {

    static func write(title: String, author: String?, language: String = "en", chapters: [EPUBChapter], to url: URL) throws {
        var entries: [EPUBChapter] = []
        for (index, chapter) in chapters.enumerated() {
            let t = chapter.title.trimmingCharacters(in: .whitespacesAndNewlines)
            entries.append(EPUBChapter(title: t.isEmpty ? "Chapter \(index + 1)" : t, bodyHTML: chapter.bodyHTML))
        }
        if entries.isEmpty {
            entries.append(EPUBChapter(title: "Chapter 1", bodyHTML: ""))
        }

        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let bookTitle = trimmedTitle.isEmpty ? "Untitled" : trimmedTitle
        let bookID = "urn:uuid:" + UUID().uuidString.lowercased()
        let modified = isoTimestamp(Date())

        let zip = ZipWriter()
        zip.add(path: "mimetype", string: "application/epub+zip", compress: false)
        zip.add(path: "META-INF/container.xml", string: containerXML())
        zip.add(path: "OEBPS/content.opf",
                string: contentOPF(bookID: bookID,
                                   title: bookTitle,
                                   author: author,
                                   language: language,
                                   modified: modified,
                                   count: entries.count))
        zip.add(path: "OEBPS/nav.xhtml", string: navXHTML(title: bookTitle, chapters: entries))
        zip.add(path: "OEBPS/toc.ncx", string: tocNCX(bookID: bookID, title: bookTitle, chapters: entries))
        for (index, chapter) in entries.enumerated() {
            zip.add(path: "OEBPS/chap\(index + 1).xhtml", string: chapterXHTML(chapter))
        }
        try zip.write(to: url)
    }

    /// Makes chapter HTML well-formed XHTML: self-closes void elements, converts common
    /// named entities to numeric references and escapes bare ampersands.
    static func xhtmlSafe(_ html: String) -> String {
        var s = epubReplace(html,
                            "<(br|hr|img|meta|link|input|col|area|base|wbr)\\b([^>]*?)(?<!/)>",
                            "<$1$2/>",
                            options: [.caseInsensitive])
        let named: [(String, String)] = [
            ("&nbsp;", "&#160;"), ("&mdash;", "&#8212;"), ("&ndash;", "&#8211;"),
            ("&hellip;", "&#8230;"), ("&lsquo;", "&#8216;"), ("&rsquo;", "&#8217;"),
            ("&ldquo;", "&#8220;"), ("&rdquo;", "&#8221;"), ("&copy;", "&#169;"),
            ("&reg;", "&#174;"), ("&trade;", "&#8482;"), ("&bull;", "&#8226;"),
            ("&middot;", "&#183;")
        ]
        for pair in named {
            s = s.replacingOccurrences(of: pair.0, with: pair.1)
        }
        s = epubReplace(s, "&(?!#?[A-Za-z0-9]+;)", "&amp;")
        return s
    }

    // MARK: Package parts

    private static func containerXML() -> String {
        var s = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        s += "<container version=\"1.0\" xmlns=\"urn:oasis:names:tc:opendocument:xmlns:container\">\n"
        s += "<rootfiles>\n"
        s += "<rootfile full-path=\"OEBPS/content.opf\" media-type=\"application/oebps-package+xml\"/>\n"
        s += "</rootfiles>\n"
        s += "</container>\n"
        return s
    }

    private static func contentOPF(bookID: String,
                                   title: String,
                                   author: String?,
                                   language: String,
                                   modified: String,
                                   count: Int) -> String {
        var s = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        s += "<package xmlns=\"http://www.idpf.org/2007/opf\" version=\"3.0\" unique-identifier=\"book-id\">\n"
        s += "<metadata xmlns:dc=\"http://purl.org/dc/elements/1.1/\">\n"
        s += "<dc:identifier id=\"book-id\">\(XMLText.escape(bookID))</dc:identifier>\n"
        s += "<dc:title>\(XMLText.escape(title))</dc:title>\n"
        s += "<dc:language>\(XMLText.escape(language))</dc:language>\n"
        if let author = author, !author.isEmpty {
            s += "<dc:creator>\(XMLText.escape(author))</dc:creator>\n"
        }
        s += "<meta property=\"dcterms:modified\">\(modified)</meta>\n"
        s += "</metadata>\n"
        s += "<manifest>\n"
        s += "<item id=\"nav\" href=\"nav.xhtml\" media-type=\"application/xhtml+xml\" properties=\"nav\"/>\n"
        s += "<item id=\"ncx\" href=\"toc.ncx\" media-type=\"application/x-dtbncx+xml\"/>\n"
        for i in 1...count {
            s += "<item id=\"chap\(i)\" href=\"chap\(i).xhtml\" media-type=\"application/xhtml+xml\"/>\n"
        }
        s += "</manifest>\n"
        s += "<spine toc=\"ncx\">\n"
        for i in 1...count {
            s += "<itemref idref=\"chap\(i)\"/>\n"
        }
        s += "</spine>\n"
        s += "</package>\n"
        return s
    }

    private static func navXHTML(title: String, chapters: [EPUBChapter]) -> String {
        var s = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        s += "<!DOCTYPE html>\n"
        s += "<html xmlns=\"http://www.w3.org/1999/xhtml\" xmlns:epub=\"http://www.idpf.org/2007/ops\">\n"
        s += "<head>\n<meta charset=\"utf-8\"/>\n<title>\(XMLText.escape(title))</title>\n</head>\n"
        s += "<body>\n"
        s += "<nav epub:type=\"toc\" id=\"toc\">\n<ol>\n"
        for (index, chapter) in chapters.enumerated() {
            s += "<li><a href=\"chap\(index + 1).xhtml\">\(XMLText.escape(chapter.title))</a></li>\n"
        }
        s += "</ol>\n</nav>\n"
        s += "</body>\n</html>\n"
        return s
    }

    private static func tocNCX(bookID: String, title: String, chapters: [EPUBChapter]) -> String {
        var s = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        s += "<ncx xmlns=\"http://www.daisy.org/z3986/2005/ncx/\" version=\"2005-1\">\n"
        s += "<head>\n"
        s += "<meta name=\"dtb:uid\" content=\"\(XMLText.escape(bookID))\"/>\n"
        s += "<meta name=\"dtb:depth\" content=\"1\"/>\n"
        s += "<meta name=\"dtb:totalPageCount\" content=\"0\"/>\n"
        s += "<meta name=\"dtb:maxPageNumber\" content=\"0\"/>\n"
        s += "</head>\n"
        s += "<docTitle><text>\(XMLText.escape(title))</text></docTitle>\n"
        s += "<navMap>\n"
        for (index, chapter) in chapters.enumerated() {
            let n = index + 1
            s += "<navPoint id=\"navPoint-\(n)\" playOrder=\"\(n)\">"
            s += "<navLabel><text>\(XMLText.escape(chapter.title))</text></navLabel>"
            s += "<content src=\"chap\(n).xhtml\"/>"
            s += "</navPoint>\n"
        }
        s += "</navMap>\n"
        s += "</ncx>\n"
        return s
    }

    private static func chapterXHTML(_ chapter: EPUBChapter) -> String {
        var s = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        s += "<!DOCTYPE html>\n"
        s += "<html xmlns=\"http://www.w3.org/1999/xhtml\" xmlns:epub=\"http://www.idpf.org/2007/ops\">\n"
        s += "<head>\n<meta charset=\"utf-8\"/>\n<title>\(XMLText.escape(chapter.title))</title>\n</head>\n"
        s += "<body>\n"
        s += xhtmlSafe(chapter.bodyHTML)
        s += "\n</body>\n</html>\n"
        return s
    }

    private static func isoTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let utc: TimeZone = TimeZone(secondsFromGMT: 0) ?? TimeZone.current
        formatter.timeZone = utc
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return formatter.string(from: date)
    }
}
