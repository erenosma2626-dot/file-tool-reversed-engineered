import AppKit

struct FacetError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct CancelledError: Error {}

/// One unit of work shown in the progress HUD.
final class Job: ObservableObject, Identifiable {
    enum State: Equatable {
        case running
        case done(String)
        case failed(String)
    }

    let id = UUID()
    let title: String
    @Published var subtitle: String
    /// 0...1, or nil while the duration is unknown.
    @Published var progress: Double?
    @Published var state: State = .running

    private let lock = NSLock()
    private var cancelled = false
    private var cancelHandler: (() -> Void)?

    init(title: String, subtitle: String) {
        self.title = title
        self.subtitle = subtitle
    }

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    /// Thread-safe progress update (throttled to visible changes).
    func report(_ value: Double) {
        let v = min(max(value, 0), 1)
        DispatchQueue.main.async {
            if let p = self.progress, abs(p - v) < 0.004 { return }
            self.progress = v
        }
    }

    func setSubtitle(_ s: String) {
        DispatchQueue.main.async { self.subtitle = s }
    }

    func onCancel(_ handler: @escaping () -> Void) {
        lock.lock(); cancelHandler = handler; lock.unlock()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let h = cancelHandler
        lock.unlock()
        h?()
    }

    func checkCancelled() throws {
        if isCancelled { throw CancelledError() }
    }
}

/// Runs jobs off the main thread and keeps the HUD in sync.
final class JobCenter: ObservableObject {
    static let shared = JobCenter()
    @Published private(set) var jobs: [Job] = []

    /// `work` returns the files it produced.
    func run(_ title: String, subtitle: String, at point: NSPoint? = nil, work: @escaping (Job) throws -> [URL]) {
        let job = Job(title: title, subtitle: subtitle)
        jobs.append(job)
        HUDController.shared.show(near: point)

        DispatchQueue.global(qos: .userInitiated).async {
            let result: Result<[URL], Error>
            do { result = .success(try work(job)) } catch { result = .failure(error) }

            DispatchQueue.main.async {
                switch result {
                case .success(let urls):
                    job.progress = 1
                    job.state = .done(urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) files")
                    Feedback.success()
                    if Prefs.shared.revealOutput, !urls.isEmpty {
                        NSWorkspace.shared.activateFileViewerSelecting(urls)
                    }
                case .failure(let error):
                    if error is CancelledError {
                        self.remove(job, after: 0)
                        return
                    }
                    job.state = .failed(error.localizedDescription)
                    Feedback.failure()
                }
                self.remove(job, after: job.state == .running ? 0 : (result.isSuccess ? 1.6 : 5))
            }
        }
    }

    private func remove(_ job: Job, after delay: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            self.jobs.removeAll { $0.id == job.id }
            if self.jobs.isEmpty { HUDController.shared.hide() }
        }
    }

    /// Small confirmation toast (e.g. "Path copied").
    func toast(_ title: String, detail: String, at point: NSPoint? = nil) {
        let job = Job(title: title, subtitle: detail)
        job.progress = 1
        job.state = .done(detail)
        jobs.append(job)
        HUDController.shared.show(near: point)
        remove(job, after: 1.4)
    }
}

private extension Result {
    var isSuccess: Bool { if case .success = self { return true } else { return false } }
}

/// Where results go and how they are named.
enum Output {
    /// "photo.heic" → "photo.png", "photo Compressed.jpg", never overwriting.
    static func url(for source: URL, ext: String, suffix: String? = nil) -> URL {
        let dir = directory(for: source)
        var base = source.deletingPathExtension().lastPathComponent
        if let suffix, !suffix.isEmpty { base += " " + suffix }
        return unique(dir.appendingPathComponent(base).appendingPathExtension(ext))
    }

    /// A new folder next to the source, for multi-file results (pages as images, split PDFs…).
    static func folder(for source: URL, suffix: String) throws -> URL {
        let dir = directory(for: source)
        let base = source.deletingPathExtension().lastPathComponent + " " + suffix
        let url = unique(dir.appendingPathComponent(base))
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func directory(for source: URL) -> URL {
        let prefs = Prefs.shared
        if prefs.outputLocation == .folder {
            let folder = URL(fileURLWithPath: prefs.outputFolder, isDirectory: true)
            if FileManager.default.isWritableFile(atPath: folder.path) { return folder }
        }
        let dir = source.deletingLastPathComponent()
        if FileManager.default.isWritableFile(atPath: dir.path) { return dir }
        return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    }

    static func unique(_ url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let dir = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        var n = 2
        while true {
            var candidate = dir.appendingPathComponent("\(base) \(n)")
            if !ext.isEmpty { candidate = candidate.appendingPathExtension(ext) }
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            n += 1
        }
    }

    /// Temporary file that is removed by the caller.
    static func temporary(ext: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("facet-" + UUID().uuidString)
            .appendingPathExtension(ext)
    }

    static func finish(sources: [URL]) {
        guard Prefs.shared.trashOriginals else { return }
        DispatchQueue.main.async {
            NSWorkspace.shared.recycle(sources, completionHandler: nil)
        }
    }
}

/// Runs `body` on the main thread and returns its value (Cocoa's HTML importer and a few
/// other AppKit APIs must run there).
func onMain<T>(_ body: () throws -> T) rethrows -> T {
    if Thread.isMainThread { return try body() }
    return try DispatchQueue.main.sync(execute: body)
}

/// Runs a command-line tool, streaming stderr lines to `onLine`. Throws on non-zero exit.
@discardableResult
func runProcess(_ path: String, _ args: [String], job: Job? = nil, onLine: ((String) -> Void)? = nil) throws -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let out = Pipe(), err = Pipe()
    p.standardOutput = out
    p.standardError = err
    p.standardInput = FileHandle.nullDevice

    let buffer = ProcessBuffer()
    err.fileHandleForReading.readabilityHandler = { h in
        let chunk = h.availableData
        guard !chunk.isEmpty, let s = String(data: chunk, encoding: .utf8) else { return }
        let lines = buffer.appendError(s)
        if let onLine { lines.forEach(onLine) }
    }
    out.fileHandleForReading.readabilityHandler = { h in
        buffer.appendOutput(h.availableData)
    }

    try p.run()
    job?.onCancel { if p.isRunning { p.terminate() } }
    p.waitUntilExit()
    err.fileHandleForReading.readabilityHandler = nil
    out.fileHandleForReading.readabilityHandler = nil
    buffer.appendOutput(out.fileHandleForReading.readDataToEndOfFile())

    if let job, job.isCancelled { throw CancelledError() }
    guard p.terminationStatus == 0 else {
        let tail = buffer.errorTail()
        throw FacetError(tail.isEmpty ? "\((path as NSString).lastPathComponent) failed" : tail)
    }
    return buffer.outputString()
}

private final class ProcessBuffer {
    private let lock = NSLock()
    private var errText = ""
    private var pending = ""
    private var output = Data()

    /// Appends stderr text and returns the complete lines it finished.
    /// ffmpeg ends progress lines with \r, regular lines with \n.
    func appendError(_ s: String) -> [String] {
        lock.lock(); defer { lock.unlock() }
        errText += s
        if errText.count > 20_000 { errText = String(errText.suffix(10_000)) }
        pending += s
        var lines: [String] = []
        while let r = pending.firstIndex(where: { $0 == "\n" || $0 == "\r" }) {
            lines.append(String(pending[..<r]))
            pending = String(pending[pending.index(after: r)...])
        }
        return lines
    }

    func appendOutput(_ d: Data) {
        lock.lock(); output.append(d); lock.unlock()
    }

    func errorTail() -> String {
        lock.lock(); defer { lock.unlock() }
        return errText.split(separator: "\n").suffix(3).joined(separator: " ")
    }

    func outputString() -> String {
        lock.lock(); defer { lock.unlock() }
        return String(data: output, encoding: .utf8) ?? ""
    }
}

enum Feedback {
    static func tick() {
        guard Prefs.shared.feedback else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    static func open() {
        guard Prefs.shared.feedback else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
    }

    static func success() {
        guard Prefs.shared.feedback else { return }
        NSSound(named: NSSound.Name("Pop"))?.play()
    }

    static func failure() {
        guard Prefs.shared.feedback else { return }
        NSSound(named: NSSound.Name("Basso"))?.play()
    }
}
