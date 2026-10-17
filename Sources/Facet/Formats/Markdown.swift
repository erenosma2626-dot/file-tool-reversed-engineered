import Foundation
import AppKit

// MARK: - Shared file-private helpers

fileprivate let mdLineBreakMarker = "\u{E000}"
fileprivate let mdTableBarMarker = "\u{E003}"

fileprivate let mdStylesheet = """
body{font-family:-apple-system,BlinkMacSystemFont,"Helvetica Neue",sans-serif;font-size:11pt;line-height:1.45;max-width:46em;margin:2em auto;padding:0 1em;color:#222;}
h1,h2,h3,h4,h5,h6{line-height:1.25;margin:1.2em 0 .5em;}
code{font-family:Menlo,Monaco,monospace;font-size:0.9em;background:#f4f4f4;padding:.1em .3em;border-radius:3px;}
pre{background:#f4f4f4;padding:.8em;overflow-x:auto;border-radius:4px;}
pre code{background:none;padding:0;}
blockquote{border-left:3px solid #ccc;margin:1em 0;padding:0 1em;color:#555;}
table{border-collapse:collapse;margin:1em 0;}
th,td{border:1px solid #bbb;padding:.3em .6em;}
th{background:#f0f0f0;}
img{max-width:100%;}
hr{border:none;border-top:1px solid #ccc;margin:1.5em 0;}
"""

/// Holds generated HTML fragments while inline markup is processed, so that
/// later emphasis rules cannot touch tags, URLs or code.
fileprivate final class MDInlineStash {
    private var items: [String] = []

    func add(_ html: String) -> String {
        items.append(html)
        return "\u{E001}\(items.count - 1)\u{E002}"
    }

    func restore(_ text: String) -> String {
        var out = text
        // Reverse order: an item may contain tokens of earlier items.
        for (index, html) in items.enumerated().reversed() {
            out = out.replacingOccurrences(of: "\u{E001}\(index)\u{E002}", with: html)
        }
        return out
    }
}

/// Calls `transform` with the capture groups (index 0 = whole match, "" for unmatched groups)
/// for every match and splices the returned text in place of the match.
fileprivate func mdRegexReplace(_ text: String, _ pattern: String, _ transform: ([String]) -> String) -> String {
    guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
        return text
    }
    let ns = NSString(string: text)
    let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length))
    if matches.isEmpty {
        return text
    }
    var out = ""
    var cursor = 0
    for match in matches {
        let whole = match.range
        if whole.location > cursor {
            out += ns.substring(with: NSRange(location: cursor, length: whole.location - cursor))
        }
        var groups: [String] = []
        for g in 0..<match.numberOfRanges {
            let r = match.range(at: g)
            groups.append(r.location == NSNotFound ? "" : ns.substring(with: r))
        }
        out += transform(groups)
        cursor = whole.location + whole.length
    }
    if cursor < ns.length {
        out += ns.substring(from: cursor)
    }
    return out
}

/// Escapes & (unless it starts an entity), < and >.
fileprivate func mdEscapeText(_ s: String) -> String {
    var t = mdRegexReplace(s, "&(?!#?[A-Za-z0-9]+;)") { _ in "&amp;" }
    t = t.replacingOccurrences(of: "<", with: "&lt;")
    t = t.replacingOccurrences(of: ">", with: "&gt;")
    return t
}

/// Escapes every HTML-special character, including quotes.
fileprivate func mdEscapeAll(_ s: String) -> String {
    var t = s.replacingOccurrences(of: "&", with: "&amp;")
    t = t.replacingOccurrences(of: "<", with: "&lt;")
    t = t.replacingOccurrences(of: ">", with: "&gt;")
    t = t.replacingOccurrences(of: "\"", with: "&quot;")
    return t
}

/// Makes a value safe inside a double-quoted attribute (input is already text-escaped).
fileprivate func mdAttr(_ s: String) -> String {
    return s.replacingOccurrences(of: "\"", with: "&quot;")
}

// MARK: - Block-level structures

fileprivate struct MDFence {
    let marker: Character
    let length: Int
    let info: String
}

fileprivate struct MDListMarker {
    let indent: Int
    let ordered: Bool
    let number: Int
    let content: String
}

fileprivate func mdLeadingSpaces(_ line: String) -> Int {
    return line.prefix(while: { $0 == " " }).count
}

fileprivate func mdFenceInfo(_ line: String) -> MDFence? {
    let t = line.trimmingCharacters(in: .whitespaces)
    guard let first = t.first, first == "`" || first == "~" else {
        return nil
    }
    var n = 0
    for ch in t {
        if ch == first {
            n += 1
        } else {
            break
        }
    }
    guard n >= 3 else { return nil }
    let info = String(t.dropFirst(n)).trimmingCharacters(in: .whitespaces)
    if first == "`" && info.contains("`") {
        return nil
    }
    return MDFence(marker: first, length: n, info: info)
}

fileprivate func mdIsClosingFence(_ line: String, _ fence: MDFence) -> Bool {
    let t = line.trimmingCharacters(in: .whitespaces)
    guard t.count >= fence.length else { return false }
    return t.allSatisfy { $0 == fence.marker }
}

fileprivate func mdParseATX(_ line: String) -> (level: Int, text: String)? {
    let t = line.trimmingCharacters(in: .whitespaces)
    let chars = Array(t)
    var n = 0
    while n < chars.count && chars[n] == "#" {
        n += 1
    }
    guard n >= 1 && n <= 6 else { return nil }
    if n < chars.count && chars[n] != " " {
        return nil
    }
    var text = n < chars.count ? String(chars[n...]).trimmingCharacters(in: .whitespaces) : ""
    // Remove an optional closing sequence of hashes.
    var stripped = text
    while stripped.hasSuffix("#") {
        stripped.removeLast()
    }
    if stripped.isEmpty {
        text = ""
    } else if stripped.hasSuffix(" ") {
        text = stripped.trimmingCharacters(in: .whitespaces)
    }
    return (level: n, text: text)
}

fileprivate func mdIsHorizontalRule(_ line: String) -> Bool {
    let t = line.filter { $0 != " " }
    guard t.count >= 3, let first = t.first, first == "-" || first == "*" || first == "_" else {
        return false
    }
    return t.allSatisfy { $0 == first }
}

fileprivate func mdParseListMarker(_ line: String) -> MDListMarker? {
    let chars = Array(line)
    var i = 0
    while i < chars.count && chars[i] == " " {
        i += 1
    }
    let indent = i
    guard i < chars.count else { return nil }

    let c = chars[i]
    if c == "-" || c == "*" || c == "+" {
        let after = i + 1
        if after == chars.count {
            return MDListMarker(indent: indent, ordered: false, number: 0, content: "")
        }
        guard chars[after] == " " else { return nil }
        let content = String(chars[(after + 1)...]).trimmingCharacters(in: .whitespaces)
        return MDListMarker(indent: indent, ordered: false, number: 0, content: content)
    }

    var j = i
    var digits = ""
    while j < chars.count && chars[j] >= "0" && chars[j] <= "9" {
        digits.append(chars[j])
        j += 1
    }
    guard !digits.isEmpty, digits.count <= 9, j < chars.count else { return nil }
    guard chars[j] == "." || chars[j] == ")" else { return nil }
    let number = Int(digits) ?? 1
    let after = j + 1
    if after == chars.count {
        return MDListMarker(indent: indent, ordered: true, number: number, content: "")
    }
    guard chars[after] == " " else { return nil }
    let content = String(chars[(after + 1)...]).trimmingCharacters(in: .whitespaces)
    return MDListMarker(indent: indent, ordered: true, number: number, content: content)
}

/// True when the line begins a block that interrupts a paragraph.
fileprivate func mdStartsBlock(_ line: String) -> Bool {
    let t = line.trimmingCharacters(in: .whitespaces)
    if t.isEmpty { return true }
    if mdFenceInfo(line) != nil { return true }
    if mdParseATX(line) != nil { return true }
    if mdIsHorizontalRule(t) { return true }
    if t.hasPrefix(">") { return true }
    if let marker = mdParseListMarker(line), !marker.ordered || marker.number == 1 {
        return true
    }
    return false
}

fileprivate func mdSplitTableRow(_ line: String) -> [String] {
    var t = line.trimmingCharacters(in: .whitespaces)
    t = t.replacingOccurrences(of: "\\|", with: mdTableBarMarker)
    if t.hasPrefix("|") {
        t.removeFirst()
    }
    if t.hasSuffix("|") {
        t.removeLast()
    }
    return t.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
}

fileprivate func mdAlignStyle(_ aligns: [String], _ index: Int) -> String {
    guard index < aligns.count, !aligns[index].isEmpty else { return "" }
    return " style=\"text-align:\(aligns[index])\""
}

fileprivate func mdTableCellHTML(_ cell: String) -> String {
    return mdInlineHTML(cell).replacingOccurrences(of: mdTableBarMarker, with: "|")
}

fileprivate func mdParseTable(_ lines: [String], start: Int) -> (html: String, next: Int)? {
    guard start + 1 < lines.count else { return nil }
    let header = lines[start]
    let separator = lines[start + 1]
    guard header.contains("|"), separator.contains("|"), separator.contains("-") else { return nil }
    let allowed: Set<Character> = ["|", ":", "-", " "]
    guard separator.allSatisfy({ allowed.contains($0) }) else { return nil }

    let headerCells = mdSplitTableRow(header)
    let separatorCells = mdSplitTableRow(separator)
    guard !headerCells.isEmpty, headerCells.count == separatorCells.count else { return nil }

    var aligns: [String] = []
    for cell in separatorCells {
        let left = cell.hasPrefix(":")
        let right = cell.hasSuffix(":")
        if left && right {
            aligns.append("center")
        } else if right {
            aligns.append("right")
        } else if left {
            aligns.append("left")
        } else {
            aligns.append("")
        }
    }

    var html = "<table>\n<thead>\n<tr>\n"
    for (k, cell) in headerCells.enumerated() {
        html += "<th\(mdAlignStyle(aligns, k))>" + mdTableCellHTML(cell) + "</th>\n"
    }
    html += "</tr>\n</thead>\n"

    var rows: [[String]] = []
    var j = start + 2
    while j < lines.count {
        let l = lines[j]
        if l.trimmingCharacters(in: .whitespaces).isEmpty || !l.contains("|") {
            break
        }
        rows.append(mdSplitTableRow(l))
        j += 1
    }
    if !rows.isEmpty {
        html += "<tbody>\n"
        for row in rows {
            html += "<tr>\n"
            for (k, cell) in row.enumerated() {
                html += "<td\(mdAlignStyle(aligns, k))>" + mdTableCellHTML(cell) + "</td>\n"
            }
            html += "</tr>\n"
        }
        html += "</tbody>\n"
    }
    html += "</table>\n"
    return (html: html, next: j)
}

fileprivate func mdCodeBlock(_ code: String, language: String) -> String {
    let lang = language.split(separator: " ").first.map { String($0) } ?? ""
    let cls = lang.isEmpty ? "" : " class=\"language-\(mdAttr(mdEscapeAll(lang)))\""
    return "<pre><code\(cls)>" + mdEscapeAll(code) + "</code></pre>\n"
}

fileprivate func mdParagraphHTML(_ lines: [String], tight: Bool) -> String {
    var joined = ""
    for (index, raw) in lines.enumerated() {
        let piece = raw.trimmingCharacters(in: .whitespaces)
        if index == lines.count - 1 {
            joined += piece
        } else if raw.hasSuffix("  ") {
            joined += piece + mdLineBreakMarker
        } else {
            joined += piece + " "
        }
    }
    let inner = mdInlineHTML(joined).replacingOccurrences(of: mdLineBreakMarker, with: "<br>")
    return tight ? inner + "\n" : "<p>" + inner + "</p>\n"
}

/// Renders a list starting at `start`. Items are rendered recursively, so nested
/// lists (indented by two or more spaces) become sub-lists.
fileprivate func mdRenderList(_ lines: [String], start: Int) -> (html: String, next: Int) {
    guard let first = mdParseListMarker(lines[start]) else {
        return (html: "", next: start + 1)
    }
    let baseIndent = first.indent
    let ordered = first.ordered

    var items: [[String]] = []
    var current: [String] = [first.content]
    var i = start + 1

    while i < lines.count {
        let line = lines[i]
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        if trimmed.isEmpty {
            var j = i
            while j < lines.count && lines[j].trimmingCharacters(in: .whitespaces).isEmpty {
                j += 1
            }
            if j >= lines.count {
                break
            }
            let nextIndent = mdLeadingSpaces(lines[j])
            if nextIndent <= baseIndent + 1,
               !mdIsHorizontalRule(lines[j]),
               let marker = mdParseListMarker(lines[j]),
               marker.ordered == ordered {
                i = j
                continue
            }
            if nextIndent > baseIndent {
                current.append("")
                i = j
                continue
            }
            break
        }

        let indent = mdLeadingSpaces(line)
        if indent <= baseIndent + 1, !mdIsHorizontalRule(trimmed), let marker = mdParseListMarker(line) {
            if marker.ordered == ordered {
                items.append(current)
                current = [marker.content]
                i += 1
                continue
            }
            break
        }

        if indent > baseIndent {
            // Continuation or nested content: strip the item's own indentation.
            current.append(String(line.dropFirst(min(indent, baseIndent + 2))))
            i += 1
            continue
        }

        // Lazy continuation of the previous paragraph inside the item.
        if i > 0, !lines[i - 1].trimmingCharacters(in: .whitespaces).isEmpty, !mdStartsBlock(line) {
            current.append(trimmed)
            i += 1
            continue
        }
        break
    }
    items.append(current)

    var html: String
    if ordered {
        html = first.number == 1 ? "<ol>\n" : "<ol start=\"\(first.number)\">\n"
    } else {
        html = "<ul>\n"
    }
    for item in items {
        html += "<li>" + mdRenderBlocks(item, tight: true) + "</li>\n"
    }
    html += ordered ? "</ol>\n" : "</ul>\n"
    return (html: html, next: i)
}

/// Block-level parser. Operates on already-split lines and recurses for containers.
fileprivate func mdRenderBlocks(_ lines: [String], tight: Bool) -> String {
    var out = ""
    var i = 0
    while i < lines.count {
        let line = lines[i]
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            i += 1
            continue
        }

        // Fenced code block
        if let fence = mdFenceInfo(line) {
            var code: [String] = []
            i += 1
            while i < lines.count && !mdIsClosingFence(lines[i], fence) {
                code.append(lines[i])
                i += 1
            }
            if i < lines.count {
                i += 1 // skip the closing fence
            }
            out += mdCodeBlock(code.joined(separator: "\n"), language: fence.info)
            continue
        }

        // ATX heading
        if let heading = mdParseATX(line) {
            out += "<h\(heading.level)>" + mdInlineHTML(heading.text) + "</h\(heading.level)>\n"
            i += 1
            continue
        }

        // Horizontal rule (checked before lists, since "* * *" is both)
        if mdIsHorizontalRule(trimmed) {
            out += "<hr>\n"
            i += 1
            continue
        }

        // Blockquote
        if trimmed.hasPrefix(">") {
            var inner: [String] = []
            while i < lines.count {
                let t = lines[i].trimmingCharacters(in: .whitespaces)
                guard t.hasPrefix(">") else { break }
                var content = String(t.dropFirst())
                if content.hasPrefix(" ") {
                    content = String(content.dropFirst())
                }
                inner.append(content)
                i += 1
            }
            out += "<blockquote>\n" + mdRenderBlocks(inner, tight: false) + "</blockquote>\n"
            continue
        }

        // Lists
        if mdParseListMarker(line) != nil {
            let result = mdRenderList(lines, start: i)
            out += result.html
            i = result.next
            continue
        }

        // Pipe table
        if let table = mdParseTable(lines, start: i) {
            out += table.html
            i = table.next
            continue
        }

        // Indented code block
        if line.hasPrefix("    ") {
            var code: [String] = []
            while i < lines.count
                    && (lines[i].hasPrefix("    ") || lines[i].trimmingCharacters(in: .whitespaces).isEmpty) {
                if lines[i].hasPrefix("    ") {
                    code.append(String(lines[i].dropFirst(4)))
                } else {
                    code.append("")
                }
                i += 1
            }
            while let last = code.last, last.isEmpty {
                code.removeLast()
            }
            out += mdCodeBlock(code.joined(separator: "\n"), language: "")
            continue
        }

        // Paragraph (the first line is always consumed)
        var paragraph: [String] = [line]
        i += 1
        while i < lines.count {
            let next = lines[i]
            if next.trimmingCharacters(in: .whitespaces).isEmpty || mdStartsBlock(next) {
                break
            }
            paragraph.append(next)
            i += 1
        }
        out += mdParagraphHTML(paragraph, tight: tight)
    }
    return out
}

// MARK: - Inline processing

/// Replaces code spans with stash tokens so their content receives no further formatting.
fileprivate func mdExtractCodeSpans(_ text: String, _ stash: MDInlineStash) -> String {
    let chars = Array(text)
    var out = ""
    var i = 0
    while i < chars.count {
        guard chars[i] == "`" else {
            out.append(chars[i])
            i += 1
            continue
        }

        var runLength = 0
        var j = i
        while j < chars.count && chars[j] == "`" {
            runLength += 1
            j += 1
        }

        // Look for a closing run of exactly the same length.
        var closeStart = -1
        var k = j
        while k < chars.count && closeStart < 0 {
            if chars[k] == "`" {
                var m = k
                while m < chars.count && chars[m] == "`" {
                    m += 1
                }
                if m - k == runLength {
                    closeStart = k
                } else {
                    k = m
                }
            } else {
                k += 1
            }
        }

        if closeStart < 0 {
            out += String(repeating: "`", count: runLength)
            i = j
            continue
        }

        var content = String(chars[j..<closeStart])
        if content.count >= 2,
           content.hasPrefix(" "),
           content.hasSuffix(" "),
           !content.trimmingCharacters(in: .whitespaces).isEmpty {
            content = String(content.dropFirst().dropLast())
        }
        out += stash.add("<code>" + mdEscapeAll(content) + "</code>")
        i = closeStart + runLength
    }
    return out
}

fileprivate func mdInlineHTML(_ text: String) -> String {
    let stash = MDInlineStash()

    // 1. Code spans (content is literal)
    var s = mdExtractCodeSpans(text, stash)

    // 2. Backslash escapes
    s = mdRegexReplace(s, "\\\\([\\\\`*_{}\\[\\]()#+\\-.!|~<>])") { g in
        stash.add(mdEscapeAll(g[1]))
    }

    // 3. HTML escaping of the remaining text
    s = mdEscapeText(s)

    // 4. Autolinks <http://...>
    s = mdRegexReplace(s, "&lt;((?:https?|mailto):[^\\s]+?)&gt;") { g in
        stash.add("<a href=\"\(mdAttr(g[1]))\">\(g[1])</a>")
    }

    // 5. Images
    s = mdRegexReplace(s, "!\\[([^\\]]*)\\]\\(\\s*([^)\\s]+)(?:\\s+\"([^\"]*)\")?\\s*\\)") { g in
        let titleAttr = g[3].isEmpty ? "" : " title=\"\(mdAttr(g[3]))\""
        return stash.add("<img src=\"\(mdAttr(g[2]))\" alt=\"\(mdAttr(g[1]))\"\(titleAttr)>")
    }

    // 6. Links (the link text stays in place so emphasis still applies inside it)
    s = mdRegexReplace(s, "\\[([^\\]]+)\\]\\(\\s*([^)\\s]+)(?:\\s+\"([^\"]*)\")?\\s*\\)") { g in
        let titleAttr = g[3].isEmpty ? "" : " title=\"\(mdAttr(g[3]))\""
        let openTag = stash.add("<a href=\"\(mdAttr(g[2]))\"\(titleAttr)>")
        let closeTag = stash.add("</a>")
        return openTag + g[1] + closeTag
    }

    // 7. Emphasis
    s = mdRegexReplace(s, "\\*\\*(?!\\s)(.+?)(?<!\\s)\\*\\*") { g in
        "<strong>\(g[1])</strong>"
    }
    s = mdRegexReplace(s, "(?<![A-Za-z0-9])__(?!\\s)(.+?)(?<!\\s)__(?![A-Za-z0-9])") { g in
        "<strong>\(g[1])</strong>"
    }
    s = mdRegexReplace(s, "(?<!\\*)\\*(?![\\s*])(.+?)(?<![\\s*])\\*(?!\\*)") { g in
        "<em>\(g[1])</em>"
    }
    s = mdRegexReplace(s, "(?<![A-Za-z0-9_])_(?![\\s_])(.+?)(?<![\\s_])_(?![A-Za-z0-9_])") { g in
        "<em>\(g[1])</em>"
    }
    s = mdRegexReplace(s, "~~(?!\\s)(.+?)(?<!\\s)~~") { g in
        "<del>\(g[1])</del>"
    }

    // 8. Put the generated HTML back
    return stash.restore(s)
}

// MARK: - Attributed string helpers

fileprivate struct MDRun {
    var text: String
    var bold: Bool
    var italic: Bool
    var code: Bool
    var link: String?
}

fileprivate struct MDBlock {
    let text: String
    let isListItem: Bool
}

fileprivate func mdParagraphRanges(_ s: NSString) -> [NSRange] {
    var ranges: [NSRange] = []
    var start = 0
    var i = 0
    let n = s.length
    while i < n {
        let c = s.character(at: i)
        // "\n" and U+2029 end a paragraph.
        if c == 10 || c == 0x2029 {
            ranges.append(NSRange(location: start, length: i - start))
            start = i + 1
        }
        i += 1
    }
    ranges.append(NSRange(location: start, length: n - start))
    return ranges
}

/// Most common font size, weighted by character count.
fileprivate func mdDominantFontSize(_ attributed: NSAttributedString) -> Double {
    var weights: [Double: Int] = [:]
    let fullRange = NSRange(location: 0, length: attributed.length)
    attributed.enumerateAttribute(.font, in: fullRange, options: []) { value, range, _ in
        guard let font = value as? NSFont else { return }
        let key = Double(font.pointSize)
        weights[key, default: 0] += range.length
    }
    guard let best = weights.max(by: { $0.value < $1.value }) else {
        return 12
    }
    return best.key
}

/// Removes a leading list marker such as "\t•\t" or "\t1.\t" that Cocoa puts into the text.
fileprivate func mdStripListMarker(_ s: String) -> String {
    var body = Substring(s)
    if body.hasPrefix("\t") {
        body = body.dropFirst()
    }
    guard let tab = body.firstIndex(of: "\t") else {
        return String(body)
    }
    let marker = body[body.startIndex..<tab]
    if marker.count <= 8 {
        return String(body[body.index(after: tab)...])
    }
    return String(body)
}

fileprivate func mdCollectRuns(_ attributed: NSAttributedString, _ full: NSString, _ range: NSRange) -> (runs: [MDRun], maxSize: Double) {
    var runs: [MDRun] = []
    var maxSize: Double = 0
    if range.length <= 0 {
        return (runs: runs, maxSize: maxSize)
    }

    attributed.enumerateAttributes(in: range, options: []) { attrs, subRange, _ in
        let text = full.substring(with: subRange).replacingOccurrences(of: "\u{FFFC}", with: "")
        if text.isEmpty { return }

        var bold = false
        var italic = false
        var mono = false
        if let font = attrs[.font] as? NSFont {
            let traits = font.fontDescriptor.symbolicTraits
            let manager = NSFontManager.shared.traits(of: font)
            bold = traits.contains(.bold) || manager.contains(.boldFontMask)
            italic = traits.contains(.italic) || manager.contains(.italicFontMask)
            mono = font.isFixedPitch || traits.contains(.monoSpace)
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                maxSize = max(maxSize, Double(font.pointSize))
            }
        }

        var link: String? = nil
        if let url = attrs[.link] as? URL {
            link = url.absoluteString
        } else if let str = attrs[.link] as? String {
            link = str
        }

        runs.append(MDRun(text: text, bold: bold, italic: italic, code: mono, link: link))
    }
    return (runs: runs, maxSize: maxSize)
}

/// Merges neighbouring runs that share the same formatting.
fileprivate func mdMergeRuns(_ runs: [MDRun]) -> [MDRun] {
    var out: [MDRun] = []
    for run in runs {
        if var last = out.last,
           last.bold == run.bold,
           last.italic == run.italic,
           last.code == run.code,
           last.link == run.link {
            last.text += run.text
            out[out.count - 1] = last
        } else {
            out.append(run)
        }
    }
    return out
}

fileprivate func mdEscapeMarkdown(_ s: String) -> String {
    var out = ""
    for ch in s {
        if ch == "\\" || ch == "*" || ch == "_" || ch == "`" || ch == "[" || ch == "]" {
            out.append("\\")
        }
        out.append(ch)
    }
    return out
}

fileprivate func mdEncodeURL(_ url: String) -> String {
    return url
        .replacingOccurrences(of: " ", with: "%20")
        .replacingOccurrences(of: "(", with: "%28")
        .replacingOccurrences(of: ")", with: "%29")
}

fileprivate func mdWrapRun(_ run: MDRun, stripBold: Bool) -> String {
    var core = run.text
    let lead = String(core.prefix(while: { $0.isWhitespace }))
    core = String(core.dropFirst(lead.count))
    var trail = ""
    while let last = core.last, last.isWhitespace {
        core.removeLast()
        trail = String(last) + trail
    }
    if core.isEmpty {
        return lead + trail
    }

    var inner: String
    if run.code {
        let fence = core.contains("`") ? "``" : "`"
        inner = fence + core + fence
    } else {
        inner = mdEscapeMarkdown(core)
        let bold = run.bold && !stripBold
        if bold && run.italic {
            inner = "***" + inner + "***"
        } else if bold {
            inner = "**" + inner + "**"
        } else if run.italic {
            inner = "*" + inner + "*"
        }
    }
    if let url = run.link {
        inner = "[" + inner + "](" + mdEncodeURL(url) + ")"
    }
    return lead + inner + trail
}

fileprivate func mdRenderRuns(_ runs: [MDRun], stripBold: Bool) -> String {
    var out = ""
    for run in mdMergeRuns(runs) {
        out += mdWrapRun(run, stripBold: stripBold)
    }
    return out
}

// MARK: - Public API

enum Markdown {

    /// CommonMark-ish subset to a standalone HTML document.
    static func html(from markdown: String) -> String {
        let normalized = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\t", with: "    ")
        let lines = normalized.components(separatedBy: "\n")

        let firstHeading = lines.compactMap { mdParseATX($0)?.text }.first(where: { !$0.isEmpty })
        let title = firstHeading.map { mdEscapeAll($0) } ?? "Document"

        let body = mdRenderBlocks(lines, tight: false)

        var output = "<!DOCTYPE html>\n<html><head><meta charset=\"utf-8\">"
        output += "<title>\(title)</title>\n<style>\n"
        output += mdStylesheet
        output += "\n</style></head>\n<body>\n"
        output += body
        output += "</body>\n</html>\n"
        return output
    }

    /// NSAttributedString (from docx, rtf or html) to Markdown.
    static func markdown(from attributed: NSAttributedString) -> String {
        guard attributed.length > 0 else { return "" }

        let full = NSString(string: attributed.string)
        let baseSize = mdDominantFontSize(attributed)
        var blocks: [MDBlock] = []

        for para in mdParagraphRanges(full) {
            if para.length == 0 { continue }

            let raw = full.substring(with: para)
            let attrs = attributed.attributes(at: para.location, effectiveRange: nil)
            let style = attrs[.paragraphStyle] as? NSParagraphStyle
            let lists = style?.textLists ?? []

            var isList = false
            var ordered = false
            var level = 0
            var contentRange = para
            if let innermost = lists.last {
                isList = true
                ordered = innermost.markerFormat.rawValue.contains("decimal")
                level = lists.count - 1
                let stripped = mdStripListMarker(raw)
                let markerLength = raw.utf16.count - stripped.utf16.count
                contentRange = NSRange(location: para.location + markerLength,
                                       length: para.length - markerLength)
            }

            let collected = mdCollectRuns(attributed, full, contentRange)
            let plainLength = collected.runs.reduce(0) { $0 + $1.text.count }
            if plainLength == 0 { continue }

            var headingLevel = 0
            if !isList && plainLength < 200 && collected.maxSize > 0 {
                let size = collected.maxSize
                if size >= baseSize * 1.8 {
                    headingLevel = 1
                } else if size >= baseSize * 1.45 {
                    headingLevel = 2
                } else if size >= baseSize * 1.2 {
                    headingLevel = 3
                }
            }

            let rendered = mdRenderRuns(collected.runs, stripBold: headingLevel > 0)
            let text = rendered.trimmingCharacters(in: .whitespaces)
            if text.isEmpty { continue }

            if headingLevel > 0 {
                let hashes = String(repeating: "#", count: headingLevel)
                blocks.append(MDBlock(text: hashes + " " + text, isListItem: false))
            } else {
                var body = text
                if let first = body.first, first == "#" || first == ">" || first == "+" || first == "-" {
                    body = "\\" + body
                }
                if isList {
                    let indent = String(repeating: "  ", count: level)
                    let marker = ordered ? "1. " : "- "
                    blocks.append(MDBlock(text: indent + marker + body, isListItem: true))
                } else {
                    blocks.append(MDBlock(text: body, isListItem: false))
                }
            }
        }

        var result = ""
        var previousWasList = false
        for block in blocks {
            if result.isEmpty {
                result = block.text
            } else {
                // Consecutive list items are separated by a single newline.
                result += (block.isListItem && previousWasList) ? "\n" : "\n\n"
                result += block.text
            }
            previousWasList = block.isListItem
        }

        while result.contains("\n\n\n") {
            result = result.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
