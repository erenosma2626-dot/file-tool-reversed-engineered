import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The file families Facet understands. Each one gets its own wheels.
enum Category: String, CaseIterable, Identifiable {
    case image, video, pdf, document, spreadsheet, ebook

    var id: String { rawValue }

    var title: String {
        switch self {
        case .image: return "Images"
        case .video: return "Video"
        case .pdf: return "PDF"
        case .document: return "Documents"
        case .spreadsheet: return "Spreadsheets"
        case .ebook: return "EPUB"
        }
    }

    var symbol: String {
        switch self {
        case .image: return "photo"
        case .video: return "play.rectangle"
        case .pdf: return "doc.richtext"
        case .document: return "doc.text"
        case .spreadsheet: return "tablecells"
        case .ebook: return "book.closed"
        }
    }

    static func of(_ url: URL) -> Category? {
        let ext = url.pathExtension.lowercased()
        if let hit = byExtension[ext] { return hit }
        guard let type = UTType(filenameExtension: ext) else { return nil }
        if type.conforms(to: .pdf) { return .pdf }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .movie) { return .video }
        if type.conforms(to: .spreadsheet) { return .spreadsheet }
        if type.conforms(to: .epub) { return .ebook }
        if type.conforms(to: .rtf) || type.conforms(to: .plainText) || type.conforms(to: .html) { return .document }
        return nil
    }

    private static let byExtension: [String: Category] = {
        var map: [String: Category] = [:]
        for e in ["png", "jpg", "jpeg", "heic", "heif", "webp", "avif", "tif", "tiff", "gif", "bmp", "jp2", "ico", "icns", "dng", "cr2", "cr3", "nef", "arw", "raf", "orf", "rw2", "psd", "tga", "exr"] { map[e] = .image }
        for e in ["mp4", "m4v", "mov", "mkv", "webm", "avi", "3gp", "mts", "m2ts", "ts", "flv", "wmv", "mpg", "mpeg", "ogv"] { map[e] = .video }
        map["pdf"] = .pdf
        for e in ["docx", "doc", "rtf", "rtfd", "odt", "txt", "text", "md", "markdown", "html", "htm", "webarchive", "pages"] { map[e] = .document }
        for e in ["xlsx", "ods", "csv", "tsv"] { map[e] = .spreadsheet }
        map["epub"] = .ebook
        return map
    }()

    /// Formats that need ffmpeg to be *read*.
    static func needsFFmpegToRead(_ url: URL) -> Bool {
        ["mkv", "webm", "avi", "flv", "wmv", "ogv", "mpg", "mpeg", "ts", "mts", "m2ts"].contains(url.pathExtension.lowercased())
    }
}

/// Output formats shown on the conversion wheel.
enum Format: String, CaseIterable, Identifiable {
    case png, jpg, heic, webp, avif, tiff, gif, pdf
    case mp4, mov, mkv, webm, m4a, mp3
    case docx, pages, rtf, odt, txt, md, html, epub
    case xlsx, ods, csv, tsv, pptx

    var id: String { rawValue }
    var ext: String { rawValue }
    var label: String { rawValue.uppercased() }

    var utType: UTType? {
        switch self {
        case .png: return .png
        case .jpg: return .jpeg
        case .heic: return .heic
        case .webp: return UTType("org.webmproject.webp")
        case .avif: return UTType("public.avif")
        case .tiff: return .tiff
        case .gif: return .gif
        case .pdf: return .pdf
        default: return UTType(filenameExtension: ext)
        }
    }

    /// Extensions that already are this format (so it is hidden from the wheel).
    var sameAs: Set<String> {
        switch self {
        case .jpg: return ["jpg", "jpeg"]
        case .tiff: return ["tif", "tiff"]
        case .heic: return ["heic", "heif"]
        case .mp4: return ["mp4", "m4v"]
        case .md: return ["md", "markdown"]
        case .html: return ["html", "htm"]
        case .txt: return ["txt", "text"]
        default: return [ext]
        }
    }
}

/// Editing tools (the ⌘ wheel).
enum Tool: String, CaseIterable, Identifiable {
    case compress, metadata, crop, adjust, annotate, removeBackground, redact, combinePDF
    case trim, split, speed, snapshot, mute
    case organize, merge, splitPDF

    var id: String { rawValue }

    var title: String {
        switch self {
        case .compress: return "Compress"
        case .metadata: return "Metadata"
        case .crop: return "Crop"
        case .adjust: return "Edit"
        case .annotate: return "Annotate"
        case .removeBackground: return "Remove BG"
        case .redact: return "Redact"
        case .combinePDF: return "To PDF"
        case .trim: return "Trim"
        case .split, .splitPDF: return "Split"
        case .speed: return "Speed"
        case .snapshot: return "Snapshot"
        case .mute: return "Mute"
        case .organize: return "Organize"
        case .merge: return "Merge"
        }
    }

    var symbol: String {
        switch self {
        case .compress: return "arrow.down.right.and.arrow.up.left"
        case .metadata: return "location.slash"
        case .crop: return "crop"
        case .adjust: return "slider.horizontal.3"
        case .annotate: return "pencil.tip.crop.circle"
        case .removeBackground: return "person.crop.rectangle"
        case .redact: return "eye.slash"
        case .combinePDF: return "doc.on.doc"
        case .trim: return "scissors"
        case .split, .splitPDF: return "square.split.2x1"
        case .speed: return "gauge.with.dots.needle.67percent"
        case .snapshot: return "camera"
        case .mute: return "speaker.slash"
        case .organize: return "square.grid.2x2"
        case .merge: return "rectangle.stack.badge.plus"
        }
    }

    /// Short line shown under the wheel while hovering.
    var hint: String {
        switch self {
        case .compress: return "Make it smaller"
        case .metadata: return "Strip location, camera and author data"
        case .crop: return "Crop"
        case .adjust: return "Rotate, resize and adjust colors"
        case .annotate: return "Draw, highlight and add text"
        case .removeBackground: return "Cut out the subject"
        case .redact: return "Hide faces, emails, phone and card numbers"
        case .combinePDF: return "Combine into one PDF"
        case .trim: return "Trim start and end"
        case .split: return "Split at the playhead"
        case .splitPDF: return "One PDF per page"
        case .speed: return "Change playback speed"
        case .snapshot: return "Save a frame as an image"
        case .mute: return "Remove the audio track"
        case .organize: return "Reorder, rotate and delete pages"
        case .merge: return "Merge into one PDF"
        }
    }
}

/// File actions (the ⌃ wheel).
enum FileAction: String, CaseIterable, Identifiable {
    case airdrop, float, copyPath

    var id: String { rawValue }

    var title: String {
        switch self {
        case .airdrop: return "AirDrop"
        case .float: return "Float"
        case .copyPath: return "Copy Path"
        }
    }

    var symbol: String {
        switch self {
        case .airdrop: return "dot.radiowaves.up.forward"
        case .float: return "pin"
        case .copyPath: return "doc.on.clipboard"
        }
    }

    var hint: String {
        switch self {
        case .airdrop: return "Send with AirDrop"
        case .float: return "Hold on a floating shelf"
        case .copyPath: return "Copy the full path"
        }
    }
}

enum WheelKind: String, CaseIterable, Identifiable {
    case convert, tools, actions
    var id: String { rawValue }
    var title: String {
        switch self {
        case .convert: return "Convert"
        case .tools: return "Tools"
        case .actions: return "Actions"
        }
    }
}

enum WheelItem: Hashable, Identifiable {
    case convert(Format)
    case tool(Tool)
    case action(FileAction)

    var id: String {
        switch self {
        case .convert(let f): return "convert." + f.rawValue
        case .tool(let t): return "tool." + t.rawValue
        case .action(let a): return "action." + a.rawValue
        }
    }

    var title: String {
        switch self {
        case .convert(let f): return f.label
        case .tool(let t): return t.title
        case .action(let a): return a.title
        }
    }

    var symbol: String? {
        switch self {
        case .convert: return nil
        case .tool(let t): return t.symbol
        case .action(let a): return a.symbol
        }
    }

    var hint: String {
        switch self {
        case .convert(let f): return "Convert to \(f.label)"
        case .tool(let t): return t.hint
        case .action(let a): return a.hint
        }
    }
}

/// Which items each wheel shows, after availability and the user's choices in Settings.
enum Catalog {
    static func convertFormats(for category: Category) -> [Format] {
        switch category {
        case .image: return [.png, .jpg, .heic, .webp, .avif, .tiff, .pdf]
        case .video: return [.mp4, .mov, .mkv, .webm, .gif, .m4a, .mp3]
        case .pdf: return [.docx, .pages, .pptx, .xlsx, .epub, .png, .jpg, .txt, .md]
        case .document: return [.pdf, .docx, .pages, .rtf, .odt, .txt, .md, .html, .epub]
        case .spreadsheet: return [.xlsx, .ods, .csv, .tsv, .pdf]
        case .ebook: return [.pdf, .docx, .pages, .html, .md, .txt]
        }
    }

    static func tools(for category: Category, count: Int) -> [Tool] {
        switch category {
        case .image:
            var t: [Tool] = [.compress, .metadata, .adjust, .annotate, .removeBackground, .crop, .redact]
            if count > 1 { t.append(.combinePDF) }
            return t
        case .video: return [.compress, .metadata, .mute, .trim, .crop, .speed, .snapshot, .split]
        case .pdf:
            var t: [Tool] = [.compress, .metadata, .splitPDF, .organize]
            if count > 1 { t.append(.merge) }
            return t
        case .document, .spreadsheet, .ebook: return []
        }
    }

    static func items(for kind: WheelKind, category: Category, urls: [URL]) -> [WheelItem] {
        let prefs = Prefs.shared
        switch kind {
        case .convert:
            let exts = Set(urls.map { $0.pathExtension.lowercased() })
            return convertFormats(for: category)
                .filter { isAvailable($0, category: category, sources: urls) }
                .filter { exts.isDisjoint(with: $0.sameAs) || urls.count > 1 && exts.count > 1 }
                .filter { prefs.isEnabled(category: category, itemID: "convert." + $0.rawValue) }
                .map { .convert($0) }
        case .tools:
            return tools(for: category, count: urls.count)
                .filter { isAvailable($0, sources: urls) }
                .filter { prefs.isEnabled(category: category, itemID: "tool." + $0.rawValue) }
                .map { .tool($0) }
        case .actions:
            return FileAction.allCases.map { .action($0) }
        }
    }

    static func isAvailable(_ format: Format, category: Category, sources: [URL]) -> Bool {
        let needsFFmpegInput = sources.contains(where: Category.needsFFmpegToRead)
        switch format {
        case .pages:
            return PagesBridge.isInstalled
        case .mkv, .webm, .mp3:
            return FFmpeg.isAvailable
        case .mp4, .mov, .m4a, .gif:
            return category != .video || !needsFFmpegInput || FFmpeg.isAvailable
        case .webp, .avif, .heic, .png, .jpg, .tiff:
            if category == .image { return ImageEngine.canWrite(format) }
            return true
        default:
            return true
        }
    }

    static func isAvailable(_ tool: Tool, sources: [URL]) -> Bool {
        if sources.contains(where: Category.needsFFmpegToRead) {
            // AVFoundation cannot open these containers; only ffmpeg-backed tools apply.
            return [.compress, .mute, .metadata].contains(tool) && FFmpeg.isAvailable
        }
        return true
    }

    /// Every item that may appear for a category (used by the Formats settings page).
    static func allItems(for category: Category) -> [WheelItem] {
        convertFormats(for: category).map { .convert($0) } + tools(for: category, count: 2).map { .tool($0) }
    }

    static let imageWritableTypes: Set<String> = {
        let ids = (CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? []
        return Set(ids)
    }()
}
