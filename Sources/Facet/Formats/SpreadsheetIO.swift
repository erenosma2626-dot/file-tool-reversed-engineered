import Foundation

struct Sheet { var name: String; var rows: [[String]] }
struct Workbook { var sheets: [Sheet] }

enum SpreadsheetError: Error { case unsupported(String), malformed(String) }

// MARK: - Private XML support

private let xmlDeclaration = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"

/// Strips any "prefix:" from a qualified XML name.
private func xmlLocalName(_ qualified: String) -> String {
    if let colon = qualified.lastIndex(of: ":") {
        return String(qualified[qualified.index(after: colon)...])
    }
    return qualified
}

/// Minimal in-memory XML element tree. Text runs are kept as "#text" children in document order.
private final class XMLNode {
    let name: String
    let attributes: [String: String]
    var text: String
    var children: [XMLNode] = []

    init(name: String, attributes: [String: String], text: String = "") {
        self.name = name
        self.attributes = attributes
        self.text = text
    }
}

/// Builds an XMLNode tree from XMLParser events (namespaces disabled, prefixes stripped).
private final class XMLTreeBuilder: NSObject, XMLParserDelegate {
    private(set) var root: XMLNode?
    private var stack: [XMLNode] = []

    func parser(_ parser: XMLParser,
                didStartElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?,
                attributes attributeDict: [String: String]) {
        let node = XMLNode(name: xmlLocalName(elementName), attributes: attributeDict)
        if let parent = stack.last {
            parent.children.append(node)
        } else if root == nil {
            root = node
        }
        stack.append(node)
    }

    func parser(_ parser: XMLParser,
                didEndElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?) {
        if !stack.isEmpty {
            stack.removeLast()
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard let parent = stack.last else { return }
        if let last = parent.children.last, last.name == "#text" {
            last.text += string
        } else {
            parent.children.append(XMLNode(name: "#text", attributes: [:], text: string))
        }
    }
}

// MARK: - SpreadsheetIO

enum SpreadsheetIO {

    // MARK: Reading

    static func read(url: URL) throws -> Workbook {
        let ext = url.pathExtension.lowercased()
        let baseName = url.deletingPathExtension().lastPathComponent
        switch ext {
        case "csv":
            let text = try readText(url)
            return Workbook(sheets: [Sheet(name: baseName, rows: parseDelimited(text, separator: ","))])
        case "tsv":
            let text = try readText(url)
            return Workbook(sheets: [Sheet(name: baseName, rows: parseDelimited(text, separator: "\t"))])
        case "txt":
            let text = try readText(url)
            let separator: Character = text.contains(Character("\t")) ? "\t" : ","
            return Workbook(sheets: [Sheet(name: baseName, rows: parseDelimited(text, separator: separator))])
        case "xlsx":
            return try readXLSX(url)
        case "ods":
            return try readODS(url)
        default:
            throw SpreadsheetError.unsupported(ext)
        }
    }

    /// RFC 4180 parser: quoted fields, "" escapes, embedded separators and newlines.
    static func parseDelimited(_ text: String, separator: Character) -> [[String]] {
        // Character-level walk: "\r\n" is a single Character in Swift, so it is matched explicitly.
        let chars = Array(text)
        let total = chars.count
        let quote: Character = "\""
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var i = 0

        while i < total {
            let c = chars[i]
            if inQuotes {
                if c == quote {
                    if i + 1 < total && chars[i + 1] == quote {
                        field.append(quote)
                        i += 2
                        continue
                    }
                    inQuotes = false
                } else {
                    field.append(c)
                }
            } else if c == quote && field.isEmpty {
                inQuotes = true
            } else if c == separator {
                row.append(field)
                field = ""
            } else if c == "\n" || c == "\r" || c == "\r\n" {
                row.append(field)
                rows.append(row)
                row = []
                field = ""
            } else {
                field.append(c)
            }
            i += 1
        }

        // Flush the last record if the text did not end with a newline.
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }

        // Drop a single trailing blank row (produced by a final blank line).
        if let last = rows.last, last == [""] {
            rows.removeLast()
        }
        return rows
    }

    private static func readText(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return decodeText(data)
    }

    /// UTF-8 with fallback to ISO Latin-1; strips a leading BOM.
    private static func decodeText(_ data: Data) -> String {
        var text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
        if text.hasPrefix("\u{FEFF}") {
            text = String(text.dropFirst())
        }
        return text
    }

    // MARK: XLSX reading

    private static func readXLSX(_ url: URL) throws -> Workbook {
        let zip = try ZipReader(url: url)

        // Sheet list, in workbook order.
        let workbookData = try zip.data(for: "xl/workbook.xml")
        let workbookRoot = try parseXML(workbookData)
        let sheetNodes = findAll(workbookRoot, named: "sheet")

        // Relationship Id -> Target.
        var targets: [String: String] = [:]
        if zip.contains("xl/_rels/workbook.xml.rels") {
            let relsData = try zip.data(for: "xl/_rels/workbook.xml.rels")
            let relsRoot = try parseXML(relsData)
            for rel in findAll(relsRoot, named: "Relationship") {
                if let id = attr(rel, "Id"), let target = attr(rel, "Target") {
                    targets[id] = target
                }
            }
        }

        // Shared strings (optional).
        var shared: [String] = []
        if zip.contains("xl/sharedStrings.xml") {
            let sstData = try zip.data(for: "xl/sharedStrings.xml")
            let sstRoot = try parseXML(sstData)
            shared = findAll(sstRoot, named: "si").map { richText($0) }
        }

        var sheets: [Sheet] = []
        for (index, node) in sheetNodes.enumerated() {
            let name = attr(node, "name") ?? "Sheet\(index + 1)"
            var path = "xl/worksheets/sheet\(index + 1).xml"
            if let rid = attr(node, "id"), let target = targets[rid] {
                path = resolveXLSXTarget(target)
            }
            guard zip.contains(path) else {
                throw SpreadsheetError.malformed("missing worksheet part \(path)")
            }
            let sheetData = try zip.data(for: path)
            let sheetRoot = try parseXML(sheetData)
            let rows = parseSheet(sheetRoot, shared: shared)
            sheets.append(Sheet(name: name, rows: trimGrid(rows)))
        }

        guard !sheets.isEmpty else { throw SpreadsheetError.malformed("workbook has no sheets") }
        return Workbook(sheets: sheets)
    }

    /// Relationship targets are relative to xl/ unless they start with "/".
    private static func resolveXLSXTarget(_ target: String) -> String {
        if target.hasPrefix("/") {
            return String(target.dropFirst())
        }
        return "xl/" + target
    }

    private static func parseSheet(_ root: XMLNode, shared: [String]) -> [[String]] {
        var grid: [Int: [Int: String]] = [:]
        var nextRow = 0

        for rowNode in findAll(root, named: "row") {
            var rowIndex = nextRow
            if let r = attr(rowNode, "r"), let n = Int(r), n >= 1 {
                rowIndex = n - 1
            }
            nextRow = rowIndex + 1

            var nextCol = 0
            for cell in rowNode.children where cell.name == "c" {
                var colIndex = nextCol
                if let ref = attr(cell, "r"), let c = columnIndex(fromCellRef: ref) {
                    colIndex = c
                }
                nextCol = colIndex + 1

                let value = cellValue(cell, shared: shared)
                if !value.isEmpty {
                    var cols = grid[rowIndex] ?? [:]
                    cols[colIndex] = value
                    grid[rowIndex] = cols
                }
            }
        }

        guard let maxRow = grid.keys.max() else { return [] }
        var rows: [[String]] = []
        for r in 0...maxRow {
            guard let cols = grid[r], let maxCol = cols.keys.max() else {
                rows.append([])
                continue
            }
            var row = [String](repeating: "", count: maxCol + 1)
            for (c, v) in cols {
                row[c] = v
            }
            rows.append(row)
        }
        return rows
    }

    private static func cellValue(_ cell: XMLNode, shared: [String]) -> String {
        let type = attr(cell, "t") ?? "n"
        switch type {
        case "inlineStr":
            guard let isNode = child(cell, "is") else { return "" }
            return richText(isNode)
        case "s":
            guard let v = child(cell, "v"),
                  let idx = Int(trim(allText(v))),
                  idx >= 0, idx < shared.count else { return "" }
            return shared[idx]
        case "str", "e":
            guard let v = child(cell, "v") else { return "" }
            return allText(v)
        case "b":
            guard let v = child(cell, "v") else { return "" }
            return trim(allText(v)) == "1" ? "TRUE" : "FALSE"
        default:
            guard let v = child(cell, "v") else { return "" }
            return normalizeNumber(allText(v))
        }
    }

    /// Integral values print without ".0"; everything else is kept as written.
    private static func normalizeNumber(_ raw: String) -> String {
        let t = trim(raw)
        if let d = Double(t), d.isFinite, abs(d) < 1e15, d == d.rounded() {
            return String(Int64(d))
        }
        return t
    }

    // MARK: ODS reading

    private static func readODS(_ url: URL) throws -> Workbook {
        let zip = try ZipReader(url: url)
        let contentData = try zip.data(for: "content.xml")
        let root = try parseXML(contentData)

        var sheets: [Sheet] = []
        for table in findAll(root, named: "table") {
            let name = attr(table, "name") ?? "Sheet\(sheets.count + 1)"
            var rows: [[String]] = []
            collectODSRows(table, into: &rows)
            sheets.append(Sheet(name: name, rows: trimGrid(rows)))
        }

        guard !sheets.isEmpty else { throw SpreadsheetError.malformed("ODS has no tables") }
        return Workbook(sheets: sheets)
    }

    private static func collectODSRows(_ node: XMLNode, into rows: inout [[String]]) {
        for sub in node.children {
            switch sub.name {
            case "table-row":
                let repeatCount = max(1, intAttr(sub, "number-rows-repeated") ?? 1)
                let cells = odsRowCells(sub)
                let isEmpty = cells.allSatisfy { $0.isEmpty }
                // ODS pads sheets with huge repeat counts of empty rows; treat those as one row.
                let times = (isEmpty && repeatCount > 1000) ? 1 : repeatCount
                for _ in 0..<times {
                    rows.append(cells)
                }
            case "table-header-rows", "table-row-group", "table-rows":
                collectODSRows(sub, into: &rows)
            default:
                break
            }
        }
    }

    private static func odsRowCells(_ row: XMLNode) -> [String] {
        var cells: [String] = []
        for cell in row.children where cell.name == "table-cell" || cell.name == "covered-table-cell" {
            let repeatCount = max(1, intAttr(cell, "number-columns-repeated") ?? 1)
            let value = odsCellText(cell)
            if value.isEmpty && repeatCount > 1000 {
                cells.append("")
            } else {
                for _ in 0..<repeatCount {
                    cells.append(value)
                }
            }
        }
        return cells
    }

    private static func odsCellText(_ cell: XMLNode) -> String {
        var paragraphs: [String] = []
        for p in cell.children where p.name == "p" {
            var text = ""
            appendODSText(p, &text)
            paragraphs.append(text)
        }
        let joined = paragraphs.joined(separator: "\n")
        if !joined.isEmpty {
            return joined
        }

        // No text content: fall back to the typed office:* value.
        switch attr(cell, "value-type") ?? "" {
        case "boolean":
            return attr(cell, "boolean-value") == "true" ? "TRUE" : "FALSE"
        case "float", "percentage", "currency":
            if let v = attr(cell, "value") {
                return normalizeNumber(v)
            }
        case "date":
            if let d = attr(cell, "date-value") {
                return d
            }
        default:
            break
        }
        return ""
    }

    /// Text of a text:p subtree: text:s expands to spaces, text:tab to a tab, text:line-break to a newline.
    private static func appendODSText(_ node: XMLNode, _ out: inout String) {
        for sub in node.children {
            switch sub.name {
            case "#text":
                out += sub.text
            case "s":
                let count = intAttr(sub, "c") ?? 1
                out += String(repeating: " ", count: max(0, count))
            case "tab":
                out += "\t"
            case "line-break":
                out += "\n"
            case "annotation", "note":
                break
            default:
                appendODSText(sub, &out)
            }
        }
    }

    // MARK: XML tree helpers

    private static func parseXML(_ data: Data) throws -> XMLNode {
        let builder = XMLTreeBuilder()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.delegate = builder
        guard parser.parse(), let root = builder.root else {
            throw SpreadsheetError.malformed("invalid XML")
        }
        return root
    }

    /// Attribute lookup matching either the exact key or its local name (so "r:id" matches "id").
    private static func attr(_ node: XMLNode, _ name: String) -> String? {
        for (key, value) in node.attributes {
            if key == name || xmlLocalName(key) == name {
                return value
            }
        }
        return nil
    }

    private static func intAttr(_ node: XMLNode, _ name: String) -> Int? {
        guard let s = attr(node, name) else { return nil }
        return Int(trim(s))
    }

    private static func child(_ node: XMLNode, _ name: String) -> XMLNode? {
        return node.children.first(where: { $0.name == name })
    }

    private static func findAll(_ node: XMLNode, named name: String) -> [XMLNode] {
        var result: [XMLNode] = []
        collectNodes(node, named: name, into: &result)
        return result
    }

    private static func collectNodes(_ node: XMLNode, named name: String, into result: inout [XMLNode]) {
        if node.name == name {
            result.append(node)
        }
        for sub in node.children where sub.name != "#text" {
            collectNodes(sub, named: name, into: &result)
        }
    }

    /// All text under a node, in document order.
    private static func allText(_ node: XMLNode) -> String {
        if node.name == "#text" { return node.text }
        var out = ""
        for sub in node.children {
            out += allText(sub)
        }
        return out
    }

    /// Text of a rich-text container (si / is): concatenates <t> runs, ignoring phonetic <rPh> runs.
    private static func richText(_ node: XMLNode) -> String {
        var out = ""
        appendRichText(node, &out)
        return out
    }

    private static func appendRichText(_ node: XMLNode, _ out: inout String) {
        for sub in node.children {
            if sub.name == "t" {
                out += allText(sub)
            } else if sub.name == "rPh" || sub.name == "#text" {
                continue
            } else {
                appendRichText(sub, &out)
            }
        }
    }

    private static func trim(_ s: String) -> String {
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Drops trailing empty cells per row and trailing empty rows.
    private static func trimGrid(_ rows: [[String]]) -> [[String]] {
        var out: [[String]] = rows.map { (row: [String]) -> [String] in
            var r = row
            while let last = r.last, last.isEmpty {
                r.removeLast()
            }
            return r
        }
        while let last = out.last, last.isEmpty {
            out.removeLast()
        }
        return out
    }

    // MARK: Cell references

    /// Zero-based column index from a cell reference such as "B3" (A=0, Z=25, AA=26).
    static func columnIndex(fromCellRef ref: String) -> Int? {
        var result = 0
        var sawLetter = false
        for scalar in ref.unicodeScalars {
            let v = scalar.value
            if v >= 65 && v <= 90 {
                result = result * 26 + Int(v - 64)
                sawLetter = true
            } else if v >= 97 && v <= 122 {
                result = result * 26 + Int(v - 96)
                sawLetter = true
            } else {
                break
            }
        }
        return sawLetter ? result - 1 : nil
    }

    /// Column letters for a zero-based index (0 -> "A", 26 -> "AA").
    static func columnName(_ index: Int) -> String {
        var n = index + 1
        var letters: [Character] = []
        while n > 0 {
            let rem = (n - 1) % 26
            letters.append(Character(UnicodeScalar(UInt8(65 + rem))))
            n = (n - 1) / 26
        }
        return String(letters.reversed())
    }

    // MARK: Writing delimited text

    /// Quotes fields containing the separator, a quote, or a line break. Lines end with "\n".
    static func delimitedString(_ rows: [[String]], separator: Character) -> String {
        let sep = String(separator)
        var out = ""
        for row in rows {
            let cells = row.map { escapeDelimited($0, separator) }
            out += cells.joined(separator: sep)
            out += "\n"
        }
        return out
    }

    private static func escapeDelimited(_ field: String, _ separator: Character) -> String {
        let sepValue = String(separator).unicodeScalars.first?.value ?? 0x2C
        var needsQuoting = false
        for scalar in field.unicodeScalars {
            let v = scalar.value
            if v == sepValue || v == 0x22 || v == 0x0A || v == 0x0D {
                needsQuoting = true
                break
            }
        }
        if !needsQuoting {
            return field
        }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    static func writeDelimited(_ sheet: Sheet, separator: Character, to url: URL) throws {
        let text = delimitedString(sheet.rows, separator: separator)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: Writing XLSX

    static func writeXLSX(_ wb: Workbook, to url: URL) throws {
        let sheets = wb.sheets.isEmpty ? [Sheet(name: "Sheet1", rows: [])] : wb.sheets
        let names = sheetNames(sheets)

        let zip = ZipWriter()
        zip.add(path: "[Content_Types].xml", string: contentTypesXML(sheetCount: sheets.count))
        zip.add(path: "_rels/.rels", string: rootRelsXML())
        zip.add(path: "xl/workbook.xml", string: workbookXML(names: names))
        zip.add(path: "xl/_rels/workbook.xml.rels", string: workbookRelsXML(sheetCount: sheets.count))
        zip.add(path: "xl/styles.xml", string: stylesXML())
        for (index, sheet) in sheets.enumerated() {
            zip.add(path: "xl/worksheets/sheet\(index + 1).xml", string: sheetXML(trimGrid(sheet.rows)))
        }
        try zip.write(to: url)
    }

    private static func contentTypesXML(sheetCount: Int) -> String {
        var xml = xmlDeclaration
        xml += "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">"
        xml += "<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>"
        xml += "<Default Extension=\"xml\" ContentType=\"application/xml\"/>"
        xml += "<Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/>"
        for i in 0..<sheetCount {
            xml += "<Override PartName=\"/xl/worksheets/sheet\(i + 1).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>"
        }
        xml += "<Override PartName=\"/xl/styles.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml\"/>"
        xml += "</Types>"
        return xml
    }

    private static func rootRelsXML() -> String {
        var xml = xmlDeclaration
        xml += "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
        xml += "<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"xl/workbook.xml\"/>"
        xml += "</Relationships>"
        return xml
    }

    private static func workbookXML(names: [String]) -> String {
        var xml = xmlDeclaration
        xml += "<workbook xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\"><sheets>"
        for (index, name) in names.enumerated() {
            xml += "<sheet name=\"\(xmlEscape(name))\" sheetId=\"\(index + 1)\" r:id=\"rId\(index + 1)\"/>"
        }
        xml += "</sheets></workbook>"
        return xml
    }

    private static func workbookRelsXML(sheetCount: Int) -> String {
        let base = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
        var xml = xmlDeclaration
        xml += "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
        for i in 0..<sheetCount {
            xml += "<Relationship Id=\"rId\(i + 1)\" Type=\"\(base)/worksheet\" Target=\"worksheets/sheet\(i + 1).xml\"/>"
        }
        xml += "<Relationship Id=\"rId\(sheetCount + 1)\" Type=\"\(base)/styles\" Target=\"styles.xml\"/>"
        xml += "</Relationships>"
        return xml
    }

    private static func stylesXML() -> String {
        var xml = xmlDeclaration
        xml += "<styleSheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\">"
        xml += "<fonts count=\"1\"><font><sz val=\"11\"/><name val=\"Calibri\"/></font></fonts>"
        xml += "<fills count=\"2\"><fill><patternFill patternType=\"none\"/></fill><fill><patternFill patternType=\"gray125\"/></fill></fills>"
        xml += "<borders count=\"1\"><border><left/><right/><top/><bottom/><diagonal/></border></borders>"
        xml += "<cellStyleXfs count=\"1\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\"/></cellStyleXfs>"
        xml += "<cellXfs count=\"1\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\"/></cellXfs>"
        xml += "</styleSheet>"
        return xml
    }

    private static func sheetXML(_ rows: [[String]]) -> String {
        var xml = xmlDeclaration
        xml += "<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><sheetData>"
        for (r, row) in rows.enumerated() {
            let rowNumber = r + 1
            xml += "<row r=\"\(rowNumber)\">"
            for (c, value) in row.enumerated() where !value.isEmpty {
                let ref = columnName(c) + "\(rowNumber)"
                if isPlainNumber(value) {
                    xml += "<c r=\"\(ref)\"><v>\(value)</v></c>"
                } else {
                    xml += "<c r=\"\(ref)\" t=\"inlineStr\"><is><t xml:space=\"preserve\">\(xmlEscape(value))</t></is></c>"
                }
            }
            xml += "</row>"
        }
        xml += "</sheetData></worksheet>"
        return xml
    }

    // MARK: Writing ODS

    static func writeODS(_ wb: Workbook, to url: URL) throws {
        let sheets = wb.sheets.isEmpty ? [Sheet(name: "Sheet1", rows: [])] : wb.sheets
        let names = sheetNames(sheets)

        let zip = ZipWriter()
        // The mimetype entry must be first and stored uncompressed.
        zip.add(path: "mimetype", string: "application/vnd.oasis.opendocument.spreadsheet", compress: false)
        zip.add(path: "META-INF/manifest.xml", string: odsManifestXML())
        zip.add(path: "content.xml", string: odsContentXML(sheets, names: names))
        try zip.write(to: url)
    }

    private static func odsManifestXML() -> String {
        var xml = xmlDeclaration
        xml += "<manifest:manifest xmlns:manifest=\"urn:oasis:names:tc:opendocument:xmlns:manifest:1.0\" manifest:version=\"1.2\">"
        xml += "<manifest:file-entry manifest:full-path=\"/\" manifest:version=\"1.2\" manifest:media-type=\"application/vnd.oasis.opendocument.spreadsheet\"/>"
        xml += "<manifest:file-entry manifest:full-path=\"content.xml\" manifest:media-type=\"text/xml\"/>"
        xml += "</manifest:manifest>"
        return xml
    }

    private static func odsContentXML(_ sheets: [Sheet], names: [String]) -> String {
        var xml = xmlDeclaration
        xml += "<office:document-content xmlns:office=\"urn:oasis:names:tc:opendocument:xmlns:office:1.0\" xmlns:table=\"urn:oasis:names:tc:opendocument:xmlns:table:1.0\" xmlns:text=\"urn:oasis:names:tc:opendocument:xmlns:text:1.0\" office:version=\"1.2\">"
        xml += "<office:body><office:spreadsheet>"
        for (index, sheet) in sheets.enumerated() {
            xml += "<table:table table:name=\"\(xmlEscape(names[index]))\">"
            for row in trimGrid(sheet.rows) {
                xml += "<table:table-row>"
                for value in row {
                    xml += odsCellXML(value)
                }
                xml += "</table:table-row>"
            }
            xml += "</table:table>"
        }
        xml += "</office:spreadsheet></office:body></office:document-content>"
        return xml
    }

    private static func odsCellXML(_ value: String) -> String {
        if value.isEmpty {
            return "<table:table-cell/>"
        }
        if isPlainNumber(value) {
            return "<table:table-cell office:value-type=\"float\" office:value=\"\(value)\"><text:p>\(value)</text:p></table:table-cell>"
        }
        return "<table:table-cell office:value-type=\"string\"><text:p>\(odsParagraph(value))</text:p></table:table-cell>"
    }

    /// Escapes text for a text:p body: newlines become line breaks, tabs become text:tab, runs of spaces use text:s.
    private static func odsParagraph(_ text: String) -> String {
        var out = ""
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            if ch == "\r" {
                i += 1
                continue
            }
            if ch == "\n" || ch == "\r\n" {
                out += "<text:line-break/>"
                i += 1
                continue
            }
            if ch == "\t" {
                out += "<text:tab/>"
                i += 1
                continue
            }
            if ch == " " {
                var j = i
                while j < chars.count && chars[j] == " " {
                    j += 1
                }
                let run = j - i
                out += " "
                if run > 1 {
                    out += "<text:s text:c=\"\(run - 1)\"/>"
                }
                i = j
                continue
            }
            out += xmlEscape(String(ch))
            i += 1
        }
        return out
    }

    // MARK: Shared writer helpers

    /// Sheet names: sanitized, at most 31 characters, unique (case-insensitive).
    private static func sheetNames(_ sheets: [Sheet]) -> [String] {
        var used = Set<String>()
        var names: [String] = []
        for sheet in sheets {
            var base = sanitizeSheetName(sheet.name)
            if base.isEmpty {
                base = "Sheet1"
            }
            var candidate = base
            var counter = 2
            while used.contains(candidate.lowercased()) {
                let suffix = " (\(counter))"
                candidate = String(base.prefix(31 - suffix.count)) + suffix
                counter += 1
            }
            used.insert(candidate.lowercased())
            names.append(candidate)
        }
        return names
    }

    private static func sanitizeSheetName(_ name: String) -> String {
        let forbidden: Set<Character> = ["[", "]", ":", "*", "?", "/", "\\"]
        var out = ""
        for ch in name {
            let v = ch.unicodeScalars.first?.value ?? 0
            if v < 32 {
                continue
            }
            if forbidden.contains(ch) {
                out += "_"
            } else {
                out.append(ch)
            }
        }
        out = trim(out)
        return String(out.prefix(31))
    }

    /// Escapes XML text and attribute values; drops characters that are invalid in XML 1.0.
    private static func xmlEscape(_ s: String) -> String {
        var out = ""
        for scalar in s.unicodeScalars {
            let v = scalar.value
            switch v {
            case 0x09, 0x0A, 0x0D:
                out.unicodeScalars.append(scalar)
            case 0x00...0x1F, 0xFFFE, 0xFFFF:
                continue
            case 0x26:
                out += "&amp;"
            case 0x3C:
                out += "&lt;"
            case 0x3E:
                out += "&gt;"
            case 0x22:
                out += "&quot;"
            default:
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    private static func htmlEscape(_ s: String) -> String {
        var out = s.replacingOccurrences(of: "&", with: "&amp;")
        out = out.replacingOccurrences(of: "<", with: "&lt;")
        out = out.replacingOccurrences(of: ">", with: "&gt;")
        out = out.replacingOccurrences(of: "\"", with: "&quot;")
        return out
    }

    /// True for plain decimal numbers: -?\d+(\.\d+)?([eE][-+]?\d+)?, no leading zeros, at most 15 digits.
    private static func isPlainNumber(_ s: String) -> Bool {
        let chars = Array(s.utf8)
        let n = chars.count
        var i = 0

        func isDigit(_ c: UInt8) -> Bool {
            return c >= 48 && c <= 57
        }

        if i < n && chars[i] == 45 {          // '-'
            i += 1
        }
        let intStart = i
        while i < n && isDigit(chars[i]) {
            i += 1
        }
        let intLength = i - intStart
        if intLength == 0 { return false }
        if intLength > 1 && chars[intStart] == 48 { return false }   // leading zero

        if i < n && chars[i] == 46 {          // '.'
            i += 1
            let fracStart = i
            while i < n && isDigit(chars[i]) {
                i += 1
            }
            if i == fracStart { return false }
        }

        if i < n && (chars[i] == 101 || chars[i] == 69) {   // 'e' or 'E'
            i += 1
            if i < n && (chars[i] == 43 || chars[i] == 45) {  // '+' or '-'
                i += 1
            }
            let expStart = i
            while i < n && isDigit(chars[i]) {
                i += 1
            }
            if i == expStart { return false }
        }

        guard i == n else { return false }
        let digitCount = chars.filter { isDigit($0) }.count
        return digitCount <= 15
    }

    // MARK: HTML

    /// Full HTML document with one table per sheet (headings only when there is more than one sheet).
    static func html(_ wb: Workbook) -> String {
        var lines: [String] = []
        lines.append("<!DOCTYPE html>")
        lines.append("<html><head><meta charset=\"utf-8\"><style>")
        lines.append("body { font: 9pt -apple-system, BlinkMacSystemFont, sans-serif; color: #000; margin: 16px; }")
        lines.append("h2 { font-size: 11pt; margin: 16px 0 6px; }")
        lines.append("table { border-collapse: collapse; margin-bottom: 12px; }")
        lines.append("td, th { border: 0.5pt solid #bbb; padding: 3px 6px; text-align: left; vertical-align: top; }")
        lines.append("th { background: #f2f2f2; font-weight: 600; }")
        lines.append("</style></head><body>")

        let showHeadings = wb.sheets.count > 1
        for sheet in wb.sheets {
            if showHeadings {
                lines.append("<h2>\(htmlEscape(sheet.name))</h2>")
            }
            lines.append("<table>")
            for (r, row) in sheet.rows.enumerated() {
                let tag = r == 0 ? "th" : "td"
                lines.append("<tr>")
                for cell in row {
                    let text = htmlEscape(cell).replacingOccurrences(of: "\n", with: "<br>")
                    lines.append("<\(tag)>\(text)</\(tag)>")
                }
                lines.append("</tr>")
            }
            lines.append("</table>")
        }

        lines.append("</body></html>")
        return lines.joined(separator: "\n")
    }
}
