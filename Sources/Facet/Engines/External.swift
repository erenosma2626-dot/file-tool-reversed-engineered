import AppKit

/// Optional ffmpeg, only used for MKV / WebM / MP3 and for reading containers AVFoundation can't open.
enum FFmpeg {
    static let path: String? = {
        var candidates: [String] = []
        if let helpers = Bundle.main.executableURL?.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Helpers/ffmpeg").path {
            candidates.append(helpers)
        }
        candidates += ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/opt/local/bin/ffmpeg"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    static var isAvailable: Bool { path != nil }

    /// Runs ffmpeg with progress parsed from its `time=` output.
    /// `duration` is in seconds; when nil it is read from ffmpeg's own "Duration:" line.
    static func run(_ args: [String], duration: Double? = nil, progress: ProgressSlice) throws {
        guard let path else { throw FacetError("This needs ffmpeg. See Settings → About.") }
        var total = duration ?? 0
        let all = ["-hide_banner", "-nostdin", "-y"] + args
        try runProcess(path, all, job: progress.job) { line in
            if total <= 0, let r = line.range(of: "Duration: ") {
                total = parseTime(String(line[r.upperBound...].prefix(11))) ?? 0
            }
            if total > 0, let r = line.range(of: "time=") {
                let t = parseTime(String(line[r.upperBound...].prefix(11))) ?? 0
                progress.report(t / total)
            }
        }
    }

    /// "00:01:02.50" → 62.5
    static func parseTime(_ s: String) -> Double? {
        let parts = s.split(separator: ":")
        guard parts.count == 3, let h = Double(parts[0]), let m = Double(parts[1]),
              let sec = Double(parts[2].trimmingCharacters(in: .whitespaces)) else { return nil }
        return h * 3600 + m * 60 + sec
    }
}

/// Pages is free on every Mac; when installed, Facet asks it to save .pages files.
enum PagesBridge {
    static let bundleID = "com.apple.iWork.Pages"

    static var isInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }

    /// Opens `source` (docx, rtf, txt…) in Pages and saves it as `destination` (.pages).
    static func save(_ source: URL, as destination: URL, progress: ProgressSlice) throws {
        guard isInstalled else { throw FacetError("Pages isn't installed.") }
        let script = """
        set src to POSIX file \(quoted(source.path))
        set dst to POSIX file \(quoted(destination.path))
        tell application id "\(bundleID)"
            set d to open src
            save d in dst
            close d saving no
        end tell
        """
        progress.report(0.3)
        try runProcess("/usr/bin/osascript", ["-e", script], job: progress.job)
        guard FileManager.default.fileExists(atPath: destination.path) else {
            throw FacetError("Pages didn't save the document.")
        }
    }

    /// .pages files are packages that carry a full-size PDF preview; use it for reading.
    static func previewPDF(of pages: URL) throws -> Data {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: pages.path, isDirectory: &isDir)
        if isDir.boolValue {
            let pdf = pages.appendingPathComponent("QuickLook/Preview.pdf")
            if let d = try? Data(contentsOf: pdf) { return d }
        } else if let zip = try? ZipReader(url: pages), zip.contains("QuickLook/Preview.pdf") {
            return try zip.data(for: "QuickLook/Preview.pdf")
        }
        throw FacetError("This Pages file has no preview. Open it in Pages and export it instead.")
    }

    private static func quoted(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
