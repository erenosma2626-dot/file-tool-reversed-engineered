import AppKit
import PDFKit
import QuickLookThumbnailing
import SwiftUI

/// One file held on a shelf. Shelves hold references, never copies.
final class ShelfItem: ObservableObject, Identifiable {
    let id = UUID()
    let url: URL
    @Published var thumbnail: NSImage?
    @Published var detail: String = ""
    private(set) var byteSize: Int64 = 0

    init(url: URL) {
        self.url = url
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 128, height: 128)
        thumbnail = icon
        loadInfo()
    }

    var name: String { url.lastPathComponent }
    var exists: Bool { FileManager.default.fileExists(atPath: url.path) }

    private func loadInfo() {
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 160, height: 160),
                                                   scale: NSScreen.main?.backingScaleFactor ?? 2,
                                                   representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] rep, _ in
            guard let image = rep?.nsImage else { return }
            DispatchQueue.main.async { self?.thumbnail = image }
        }
        let url = self.url
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey, .totalFileAllocatedSizeKey])
            let isDir = values?.isDirectory ?? false
            let size = Int64(values?.fileSize ?? 0)
            var parts: [String] = []
            if isDir {
                let count = (try? FileManager.default.contentsOfDirectory(atPath: url.path).count) ?? 0
                parts.append("\(count) items")
            } else {
                parts.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                if url.pathExtension.lowercased() == "pdf", let n = PDFDocument(url: url)?.pageCount {
                    parts.append(n == 1 ? "1 page" : "\(n) pages")
                } else if Category.of(url) == .image,
                          let src = CGImageSourceCreateWithURL(url as CFURL, nil) {
                    let s = ImageEngine.pixelSize(src)
                    if s.width > 0 { parts.append("\(Int(s.width))×\(Int(s.height))") }
                }
            }
            DispatchQueue.main.async {
                self?.byteSize = size
                self?.detail = parts.joined(separator: " • ")
            }
        }
    }
}

enum ShelfLayout: String { case grid, list }

final class ShelfModel: ObservableObject {
    @Published var items: [ShelfItem] = []
    @Published var expanded = false { didSet { onResize?() } }
    @Published var layout: ShelfLayout = .grid { didSet { onResize?() } }
    @Published var isTargeted = false
    var onResize: (() -> Void)?
    var onClose: (() -> Void)?

    func add(_ urls: [URL]) {
        let existing = Set(items.map { $0.url.standardizedFileURL })
        let fresh = urls.filter { !existing.contains($0.standardizedFileURL) }.map(ShelfItem.init)
        guard !fresh.isEmpty else { return }
        items.append(contentsOf: fresh)
        onResize?()
    }

    func remove(_ ids: Set<UUID>) {
        items.removeAll { ids.contains($0.id) }
        if items.isEmpty { expanded = false }
        onResize?()
    }

    /// After a drag-out: drop items whose files were moved away (cut & paste).
    func pruneMoved() {
        let gone = Set(items.filter { !$0.exists }.map(\.id))
        if !gone.isEmpty { remove(gone) }
        if items.isEmpty { onClose?() }
    }

    var title: String {
        let n = items.count
        if n == 0 { return "Drop files here" }
        if n == 1 { return items[0].name }
        let kinds = Set(items.map { Category.of($0.url) })
        if kinds.count == 1, let first = kinds.first, let k = first {
            switch k {
            case .image: return "\(n) Images"
            case .video: return "\(n) Videos"
            case .pdf, .document, .ebook: return "\(n) Documents"
            case .spreadsheet: return "\(n) Spreadsheets"
            }
        }
        return "\(n) Files"
    }

    var totalSize: String {
        ByteCountFormatter.string(fromByteCount: items.reduce(0) { $0 + $1.byteSize }, countStyle: .file)
    }
}

/// Creates, positions and retires shelves.
final class ShelfManager {
    static let shared = ShelfManager()
    private var shelves: [ShelfWindow] = []
    /// Shelves opened by a shake that haven't received anything yet.
    private var pendingShakeShelf: ShelfWindow?

    /// The ⌃ wheel's Float action.
    func float(_ urls: [URL], at point: NSPoint) {
        if Prefs.shared.floatBehavior == .addToRecent, let last = shelves.last {
            last.model.add(urls)
            last.bounce()
        } else {
            newShelf(with: urls, at: point)
        }
    }

    @discardableResult
    func newShelf(with urls: [URL], at point: NSPoint) -> ShelfWindow {
        let shelf = ShelfWindow(manager: self)
        shelf.model.add(urls)
        shelf.show(near: point, stack: shelves.count)
        shelves.append(shelf)
        return shelf
    }

    func shakeDetected(at point: NSPoint) {
        guard pendingShakeShelf == nil else { return }
        Feedback.open()
        pendingShakeShelf = newShelf(with: [], at: point)
    }

    /// A system drag ended: a shake shelf that got nothing goes away again.
    func dragEnded() {
        guard let shelf = pendingShakeShelf else { return }
        pendingShakeShelf = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            if shelf.model.items.isEmpty { shelf.close() }
        }
    }

    func closed(_ shelf: ShelfWindow) {
        shelves.removeAll { $0 === shelf }
        if pendingShakeShelf === shelf { pendingShakeShelf = nil }
    }
}
