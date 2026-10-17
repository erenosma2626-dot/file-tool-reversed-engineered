import AppKit

/// Routes a wheel choice to the engine, editor or file action that handles it.
enum Actions {
    static func perform(_ item: WheelItem, urls: [URL], category: Category, at point: NSPoint) {
        guard !urls.isEmpty else { return }
        switch item {
        case .convert(let format):
            convert(urls, to: format, category: category, at: point)
        case .tool(let tool):
            run(tool, urls: urls, category: category, at: point)
        case .action(let action):
            perform(action, urls: urls, at: point)
        }
    }

    // MARK: Conversion

    static func convert(_ urls: [URL], to format: Format, category: Category, at point: NSPoint) {
        let subtitle = urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) files"
        JobCenter.shared.run("Converting to \(format.label)", subtitle: subtitle, at: point) { job in
            var outputs: [URL] = []
            for (i, url) in urls.enumerated() {
                try job.checkCancelled()
                if urls.count > 1 { job.setSubtitle("\(url.lastPathComponent) · \(i + 1) of \(urls.count)") }
                let slice = ProgressSlice(job: job, index: i, count: urls.count)
                let out = try convertOne(url, to: format, category: category, progress: slice)
                outputs.append(out)
            }
            Output.finish(sources: urls)
            return outputs
        }
    }

    private static func convertOne(_ url: URL, to format: Format, category: Category, progress: ProgressSlice) throws -> URL {
        switch category {
        case .image: return try ImageEngine.convert(url, to: format, progress: progress)
        case .video: return try VideoEngine.convert(url, to: format, progress: progress)
        case .pdf: return try PDFEngine.convert(url, to: format, progress: progress)
        case .document, .ebook: return try DocumentEngine.convert(url, to: format, progress: progress)
        case .spreadsheet: return try SpreadsheetEngine.convert(url, to: format, progress: progress)
        }
    }

    // MARK: Tools

    static func run(_ tool: Tool, urls: [URL], category: Category, at point: NSPoint) {
        switch tool {
        // Tools that need a decision from the user open an editor.
        case .crop:
            if category == .video { EditorWindow.open(.videoCrop(urls[0])) } else { EditorWindow.open(.imageCrop(urls[0])) }
        case .adjust: EditorWindow.open(.imageAdjust(urls[0]))
        case .annotate: EditorWindow.open(.annotate(urls[0]))
        case .trim: EditorWindow.open(.videoTimeline(urls[0], .trim))
        case .split: EditorWindow.open(.videoTimeline(urls[0], .split))
        case .snapshot: EditorWindow.open(.videoTimeline(urls[0], .snapshot))
        case .speed: EditorWindow.open(.videoTimeline(urls[0], .speed))
        case .organize: EditorWindow.open(.organize(urls[0]))

        // One-shot tools run straight away.
        case .compress, .metadata, .removeBackground, .redact, .mute, .splitPDF:
            batch(tool, urls: urls, category: category, at: point)
        case .combinePDF:
            JobCenter.shared.run("Creating PDF", subtitle: "\(urls.count) images", at: point) { job in
                [try ImageTools.combineToPDF(urls, progress: ProgressSlice(job: job))]
            }
        case .merge:
            JobCenter.shared.run("Merging PDFs", subtitle: "\(urls.count) files", at: point) { job in
                [try PDFTools.merge(urls, progress: ProgressSlice(job: job))]
            }
        }
    }

    private static func batch(_ tool: Tool, urls: [URL], category: Category, at point: NSPoint) {
        let verb: String
        switch tool {
        case .compress: verb = "Compressing"
        case .metadata: verb = "Removing metadata"
        case .removeBackground: verb = "Removing background"
        case .redact: verb = "Redacting"
        case .mute: verb = "Muting"
        case .splitPDF: verb = "Splitting"
        default: verb = tool.title
        }
        let subtitle = urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) files"
        JobCenter.shared.run(verb, subtitle: subtitle, at: point) { job in
            var outputs: [URL] = []
            for (i, url) in urls.enumerated() {
                try job.checkCancelled()
                let p = ProgressSlice(job: job, index: i, count: urls.count)
                switch (category, tool) {
                case (.image, .compress): outputs.append(try ImageTools.compress(url, progress: p))
                case (.image, .metadata): outputs.append(try ImageTools.stripMetadata(url))
                case (.image, .removeBackground): outputs.append(try ImageTools.removeBackground(url))
                case (.image, .redact): outputs.append(try ImageTools.redact(url))
                case (.video, .compress): outputs.append(try VideoTools.compress(url, progress: p))
                case (.video, .metadata): outputs.append(try VideoTools.stripMetadata(url, progress: p))
                case (.video, .mute): outputs.append(try VideoTools.mute(url, progress: p))
                case (.pdf, .compress): outputs.append(try PDFTools.compress(url, progress: p))
                case (.pdf, .metadata): outputs.append(try PDFTools.stripMetadata(url))
                case (.pdf, .splitPDF): outputs.append(try PDFTools.splitPages(url, progress: p))
                default: throw FacetError("\(tool.title) isn't available for this file.")
                }
            }
            return outputs
        }
    }

    // MARK: File actions

    static func perform(_ action: FileAction, urls: [URL], at point: NSPoint) {
        switch action {
        case .airdrop:
            guard let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: urls) else {
                JobCenter.shared.toast("AirDrop unavailable", detail: "Turn on Wi-Fi and Bluetooth", at: point)
                return
            }
            NSApp.activate(ignoringOtherApps: true)
            service.perform(withItems: urls)
        case .float:
            ShelfManager.shared.float(urls, at: point)
        case .copyPath:
            let text = urls.map(\.path).joined(separator: "\n")
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            JobCenter.shared.toast(urls.count == 1 ? "Path copied" : "\(urls.count) paths copied",
                                   detail: urls.count == 1 ? urls[0].path : urls[0].deletingLastPathComponent().path,
                                   at: point)
        }
    }
}

/// Maps a sub-task's 0…1 progress into its share of the whole job.
struct ProgressSlice {
    let job: Job
    var index = 0
    var count = 1

    func report(_ fraction: Double) {
        job.report((Double(index) + min(max(fraction, 0), 1)) / Double(max(count, 1)))
    }

    var isCancelled: Bool { job.isCancelled }
    func check() throws { try job.checkCancelled() }
}
