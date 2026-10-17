import AVFoundation
import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Video on AVFoundation (hardware encoders, passthrough remux when possible).
/// ffmpeg is used only for MKV / WebM / MP3 and for sources AVFoundation can't open.
enum VideoEngine {
    static func convert(_ url: URL, to f: Format, progress: ProgressSlice) throws -> URL {
        let out = Output.url(for: url, ext: f.ext)
        do {
            if Category.needsFFmpegToRead(url) || [.mkv, .webm, .mp3].contains(f) {
                try ffmpegConvert(url, to: out, format: f, progress: progress)
            } else {
                let asset = AVURLAsset(url: url)
                switch f {
                case .mp4, .mov:
                    let type: AVFileType = f == .mp4 ? .mp4 : .mov
                    do {
                        // Remux without re-encoding when the codecs fit the container.
                        try export(asset, preset: AVAssetExportPresetPassthrough, to: out, type: type, progress: progress)
                    } catch is CancelledError {
                        throw CancelledError()
                    } catch {
                        try? FileManager.default.removeItem(at: out)
                        try export(asset, preset: AVAssetExportPresetHighestQuality, to: out, type: type, progress: progress)
                    }
                case .m4a:
                    try export(asset, preset: AVAssetExportPresetAppleM4A, to: out, type: .m4a, progress: progress)
                case .gif:
                    try makeGIF(asset, to: out, progress: progress)
                default:
                    throw FacetError("Can't convert video to \(f.label).")
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: out)
            throw error
        }
        return out
    }

    // MARK: AVFoundation helpers

    static func fileType(for url: URL) -> AVFileType {
        switch url.pathExtension.lowercased() {
        case "mov": return .mov
        case "m4v": return .m4v
        default: return .mp4
        }
    }

    /// Runs an export session synchronously (we're already on a background queue).
    static func export(_ asset: AVAsset, preset: String, to out: URL, type: AVFileType,
                       videoComposition: AVVideoComposition? = nil, timeRange: CMTimeRange? = nil,
                       stripMetadata: Bool = false, progress: ProgressSlice) throws {
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw FacetError("This video can't be exported.")
        }
        guard session.supportedFileTypes.contains(type) else {
            throw FacetError("This video can't be saved as \(out.pathExtension.uppercased()).")
        }
        session.outputURL = out
        session.outputFileType = type
        session.shouldOptimizeForNetworkUse = true
        session.audioTimePitchAlgorithm = .spectral
        if let videoComposition { session.videoComposition = videoComposition }
        if let timeRange { session.timeRange = timeRange }
        if stripMetadata {
            session.metadata = []
            session.metadataItemFilter = AVMetadataItemFilter.forSharing()
        }

        let done = DispatchSemaphore(value: 0)
        session.exportAsynchronously { done.signal() }
        while done.wait(timeout: .now() + 0.1) == .timedOut {
            progress.report(Double(session.progress))
            if progress.isCancelled { session.cancelExport() }
        }
        switch session.status {
        case .completed:
            progress.report(1)
        case .cancelled:
            try? FileManager.default.removeItem(at: out)
            throw CancelledError()
        default:
            try? FileManager.default.removeItem(at: out)
            throw FacetError(session.error?.localizedDescription ?? "Export failed.")
        }
    }

    /// Display size of the first video track (rotation applied).
    static func displaySize(_ asset: AVAsset) -> CGSize {
        guard let track = asset.tracks(withMediaType: .video).first else { return .zero }
        let r = CGRect(origin: .zero, size: track.naturalSize).applying(track.preferredTransform)
        return CGSize(width: abs(r.width), height: abs(r.height))
    }

    /// A composition with the asset's tracks over `range`, optionally without audio and
    /// with time scaled by `speed`.
    static func composition(_ asset: AVAsset, range: CMTimeRange? = nil, audio: Bool = true, speed: Double = 1) throws -> AVMutableComposition {
        let comp = AVMutableComposition()
        let full = CMTimeRange(start: .zero, duration: asset.duration)
        let r = range ?? full
        for track in asset.tracks(withMediaType: .video) {
            guard let t = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            try t.insertTimeRange(r, of: track, at: .zero)
            t.preferredTransform = track.preferredTransform
        }
        if audio {
            for track in asset.tracks(withMediaType: .audio) {
                guard let t = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
                try t.insertTimeRange(r, of: track, at: .zero)
            }
        }
        if speed != 1 {
            let span = CMTimeRange(start: .zero, duration: r.duration)
            comp.scaleTimeRange(span, toDuration: CMTimeMultiplyByFloat64(r.duration, multiplier: 1 / speed))
        }
        return comp
    }

    // MARK: GIF

    static func makeGIF(_ asset: AVAsset, to out: URL, progress: ProgressSlice) throws {
        let duration = asset.duration.seconds
        guard duration.isFinite, duration > 0 else { throw FacetError("This video has no frames.") }
        let fps: Double = duration > 30 ? 8 : 12
        let count = max(1, min(Int(duration * fps), 1200))

        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 640, height: 640)
        let tol = CMTime(value: 1, timescale: CMTimeScale(fps * 2))
        gen.requestedTimeToleranceBefore = tol
        gen.requestedTimeToleranceAfter = tol

        guard let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.gif.identifier as CFString, count, nil) else {
            throw FacetError("Couldn't create the GIF.")
        }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let frameProps = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / fps]] as CFDictionary
        for i in 0..<count {
            try progress.check()
            let t = CMTime(seconds: Double(i) / fps, preferredTimescale: 600)
            if let img = try? gen.copyCGImage(at: t, actualTime: nil) {
                CGImageDestinationAddImage(dest, img, frameProps)
            }
            progress.report(Double(i + 1) / Double(count))
        }
        guard CGImageDestinationFinalize(dest) else { throw FacetError("Couldn't write the GIF.") }
    }

    // MARK: ffmpeg

    private static func ffmpegConvert(_ url: URL, to out: URL, format f: Format, progress: ProgressSlice) throws {
        let duration: Double? = Category.needsFFmpegToRead(url) ? nil : AVURLAsset(url: url).duration.seconds
        let input = ["-i", url.path]
        let h264 = ["-c:v", "h264_videotoolbox", "-q:v", "62", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "160k"]
        switch f {
        case .mkv:
            do {
                try FFmpeg.run(input + ["-map", "0", "-c", "copy", out.path], duration: duration, progress: progress)
            } catch is CancelledError {
                throw CancelledError()
            } catch {
                try FFmpeg.run(input + h264 + [out.path], duration: duration, progress: progress)
            }
        case .webm:
            try FFmpeg.run(input + ["-c:v", "libvpx-vp9", "-crf", "33", "-b:v", "0", "-row-mt", "1",
                                    "-deadline", "good", "-cpu-used", "4", "-c:a", "libopus", "-b:a", "128k", out.path],
                           duration: duration, progress: progress)
        case .mp3:
            try FFmpeg.run(input + ["-vn", "-c:a", "libmp3lame", "-q:a", "2", out.path], duration: duration, progress: progress)
        case .m4a:
            try FFmpeg.run(input + ["-vn", "-c:a", "aac", "-b:a", "192k", out.path], duration: duration, progress: progress)
        case .mp4, .mov:
            let flags = f == .mp4 ? ["-movflags", "+faststart"] : []
            try FFmpeg.run(input + h264 + flags + [out.path], duration: duration, progress: progress)
        case .gif:
            let filter = "fps=12,scale='min(640,iw)':-2:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=sierra2_4a"
            try FFmpeg.run(input + ["-vf", filter, "-loop", "0", out.path], duration: duration, progress: progress)
        default:
            throw FacetError("Can't convert video to \(f.label).")
        }
    }
}

// MARK: - Tools

enum VideoTools {
    /// HEVC at a bitrate that keeps quality while usually cutting size by half or more.
    static func compress(_ url: URL, progress: ProgressSlice) throws -> URL {
        if Category.needsFFmpegToRead(url) {
            let out = Output.url(for: url, ext: "mp4", suffix: "Compressed")
            try FFmpeg.run(["-i", url.path, "-c:v", "hevc_videotoolbox", "-q:v", "50", "-tag:v", "hvc1",
                            "-c:a", "aac", "-b:a", "128k", "-movflags", "+faststart", out.path], progress: progress)
            return try ImageTools.keepIfSmaller(out, than: url)
        }
        let out = Output.url(for: url, ext: url.pathExtension.lowercased() == "mov" ? "mov" : "mp4", suffix: "Compressed")
        do {
            try Transcoder.compress(AVURLAsset(url: url), to: out, type: VideoEngine.fileType(for: out), progress: progress)
        } catch {
            try? FileManager.default.removeItem(at: out)
            throw error
        }
        return try ImageTools.keepIfSmaller(out, than: url)
    }

    static func stripMetadata(_ url: URL, progress: ProgressSlice) throws -> URL {
        let out = Output.url(for: url, ext: url.pathExtension, suffix: "Clean")
        if Category.needsFFmpegToRead(url) {
            try FFmpeg.run(["-i", url.path, "-map", "0", "-map_metadata", "-1", "-c", "copy", out.path], progress: progress)
            return out
        }
        let asset = AVURLAsset(url: url)
        let comp = try VideoEngine.composition(asset)
        try VideoEngine.export(comp, preset: AVAssetExportPresetPassthrough, to: out,
                               type: VideoEngine.fileType(for: out), stripMetadata: true, progress: progress)
        return out
    }

    static func mute(_ url: URL, progress: ProgressSlice) throws -> URL {
        let out = Output.url(for: url, ext: url.pathExtension, suffix: "Muted")
        if Category.needsFFmpegToRead(url) {
            try FFmpeg.run(["-i", url.path, "-map", "0", "-an", "-c", "copy", out.path], progress: progress)
            return out
        }
        let comp = try VideoEngine.composition(AVURLAsset(url: url), audio: false)
        try VideoEngine.export(comp, preset: AVAssetExportPresetPassthrough, to: out,
                               type: VideoEngine.fileType(for: out), progress: progress)
        return out
    }

    static func trim(_ url: URL, range: CMTimeRange, progress: ProgressSlice) throws -> URL {
        let out = Output.url(for: url, ext: url.pathExtension, suffix: "Trimmed")
        let comp = try VideoEngine.composition(AVURLAsset(url: url), range: range)
        try VideoEngine.export(comp, preset: AVAssetExportPresetPassthrough, to: out,
                               type: VideoEngine.fileType(for: out), progress: progress)
        return out
    }

    static func split(_ url: URL, at time: CMTime, progress: ProgressSlice) throws -> [URL] {
        let asset = AVURLAsset(url: url)
        let parts = [CMTimeRange(start: .zero, end: time), CMTimeRange(start: time, end: asset.duration)]
        var outs: [URL] = []
        for (i, r) in parts.enumerated() {
            let out = Output.url(for: url, ext: url.pathExtension, suffix: "Part \(i + 1)")
            let comp = try VideoEngine.composition(asset, range: r)
            let slice = ProgressSlice(job: progress.job, index: i, count: parts.count)
            try VideoEngine.export(comp, preset: AVAssetExportPresetPassthrough, to: out,
                                   type: VideoEngine.fileType(for: out), progress: slice)
            outs.append(out)
        }
        return outs
    }

    static func speed(_ url: URL, factor: Double, progress: ProgressSlice) throws -> URL {
        let label = factor < 1 ? String(format: "%.2gx", factor) : String(format: "%gx", factor)
        let out = Output.url(for: url, ext: url.pathExtension, suffix: label)
        let comp = try VideoEngine.composition(AVURLAsset(url: url), speed: factor)
        try VideoEngine.export(comp, preset: AVAssetExportPresetHighestQuality, to: out,
                               type: VideoEngine.fileType(for: out), progress: progress)
        return out
    }

    /// `rect` is in display pixels with a top-left origin.
    static func crop(_ url: URL, rect: CGRect, progress: ProgressSlice) throws -> URL {
        let asset = AVURLAsset(url: url)
        guard let source = asset.tracks(withMediaType: .video).first else { throw FacetError("No video track.") }
        let comp = try VideoEngine.composition(asset)
        guard let track = comp.tracks(withMediaType: .video).first else { throw FacetError("No video track.") }

        // Encoders want even dimensions.
        let w = max(2, (Int(rect.width) / 2) * 2), h = max(2, (Int(rect.height) / 2) * 2)
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        let transform = source.preferredTransform.concatenating(CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
        layer.setTransform(transform, at: .zero)
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: comp.duration)
        instruction.layerInstructions = [layer]
        let video = AVMutableVideoComposition()
        video.renderSize = CGSize(width: w, height: h)
        let fps = source.nominalFrameRate > 0 ? source.nominalFrameRate : 30
        video.frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps.rounded()))
        video.instructions = [instruction]

        let out = Output.url(for: url, ext: url.pathExtension, suffix: "Cropped")
        try VideoEngine.export(comp, preset: AVAssetExportPresetHighestQuality, to: out,
                               type: VideoEngine.fileType(for: out), videoComposition: video, progress: progress)
        return out
    }

    static func snapshot(_ url: URL, at time: CMTime) throws -> URL {
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        let image = try gen.copyCGImage(at: time, actualTime: nil)
        let secs = max(0, time.seconds)
        let stamp = String(format: "%02d-%02d", Int(secs) / 60, Int(secs) % 60)
        let out = Output.url(for: url, ext: "png", suffix: stamp)
        try ImageEngine.write(image, to: out, type: UTType.png.identifier)
        return out
    }
}

/// AVAssetReader → AVAssetWriter pipeline with explicit bitrate control (used by Compress).
enum Transcoder {
    static func compress(_ asset: AVAsset, to out: URL, type: AVFileType, progress: ProgressSlice) throws {
        guard let vTrack = asset.tracks(withMediaType: .video).first else { throw FacetError("No video track.") }
        let natural = vTrack.naturalSize
        let longSide = max(natural.width, natural.height)
        let scale = longSide > 1920 ? 1920 / longSide : 1
        let width = Int((natural.width * scale / 2).rounded()) * 2
        let height = Int((natural.height * scale / 2).rounded()) * 2
        let fps = Double(vTrack.nominalFrameRate > 0 ? vTrack.nominalFrameRate : 30)

        // ~0.075 bits per pixel per frame is visually clean for HEVC; never exceed half the source rate.
        let pixelBudget = Double(width * height) * min(fps, 60) * 0.075
        let sourceRate = Double(vTrack.estimatedDataRate)
        var bitrate = sourceRate > 0 ? min(pixelBudget, sourceRate * 0.5) : pixelBudget
        bitrate = max(bitrate, 500_000)

        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: out, fileType: type)
        writer.shouldOptimizeForNetworkUse = true

        let vOut = AVAssetReaderTrackOutput(track: vTrack, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ])
        vOut.alwaysCopiesSampleData = false
        reader.add(vOut)
        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoScalingModeKey: AVVideoScalingModeResizeAspect,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: Int(bitrate),
                AVVideoExpectedSourceFrameRateKey: Int(fps.rounded()),
                AVVideoMaxKeyFrameIntervalDurationKey: 2,
            ] as [String: Any],
        ])
        vIn.transform = vTrack.preferredTransform
        vIn.expectsMediaDataInRealTime = false
        writer.add(vIn)

        var pairs: [(AVAssetReaderOutput, AVAssetWriterInput)] = [(vOut as AVAssetReaderOutput, vIn)]
        let audioTracks = asset.tracks(withMediaType: .audio)
        if !audioTracks.isEmpty {
            let aOut = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ])
            reader.add(aOut)
            var layout = AudioChannelLayout()
            layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
            let aIn = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 128_000,
                AVChannelLayoutKey: Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size),
            ])
            aIn.expectsMediaDataInRealTime = false
            writer.add(aIn)
            pairs.append((aOut as AVAssetReaderOutput, aIn))
        }

        guard reader.startReading() else { throw FacetError(reader.error?.localizedDescription ?? "Can't read the video.") }
        guard writer.startWriting() else { throw FacetError(writer.error?.localizedDescription ?? "Can't write the video.") }
        writer.startSession(atSourceTime: .zero)

        let duration = asset.duration.seconds
        let group = DispatchGroup()
        for (i, pair) in pairs.enumerated() {
            let (output, input) = pair
            let queue = DispatchQueue(label: "facet.transcode.\(i)")
            let finished = Flag()
            group.enter()
            input.requestMediaDataWhenReady(on: queue) {
                while input.isReadyForMoreMediaData && !finished.value {
                    if progress.isCancelled { reader.cancelReading() }
                    guard let sample = output.copyNextSampleBuffer() else {
                        input.markAsFinished()
                        finished.value = true
                        group.leave()
                        return
                    }
                    if i == 0, duration > 0 {
                        progress.report(CMSampleBufferGetPresentationTimeStamp(sample).seconds / duration)
                    }
                    if !input.append(sample) {
                        reader.cancelReading()
                    }
                }
            }
        }
        group.wait()

        if progress.isCancelled {
            writer.cancelWriting()
            throw CancelledError()
        }
        if reader.status == .failed || writer.status == .failed {
            writer.cancelWriting()
            throw FacetError((writer.error ?? reader.error)?.localizedDescription ?? "Compression failed.")
        }
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        guard writer.status == .completed else {
            throw FacetError(writer.error?.localizedDescription ?? "Compression failed.")
        }
    }

    private final class Flag {
        var value = false
    }
}
