import AVFoundation
import SwiftUI

/// Trim, split, snapshot and speed for a video, sharing one player and filmstrip.
struct TimelineEditor: View {
    let url: URL
    @State var mode: TimelineMode
    let close: () -> Void

    @StateObject private var playback = Playback()
    @State private var frames: [CGImage] = []
    @State private var inPoint: Double = 0
    @State private var outPoint: Double = 1
    @State private var speed: Double = 2

    private let speeds: [Double] = [0.25, 0.5, 0.75, 1.25, 1.5, 2, 3, 4]

    init(url: URL, mode: TimelineMode, close: @escaping () -> Void) {
        self.url = url
        self._mode = State(initialValue: mode)
        self.close = close
    }

    var body: some View {
        EditorChrome(title: url.lastPathComponent, close: close) {
            VStack(spacing: 12) {
                Picker("", selection: $mode) {
                    ForEach(TimelineMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 300)

                PlayerView(player: playback.player)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .frame(minHeight: 220)

                HStack(spacing: 10) {
                    GlassIconButton(symbol: playback.isPlaying ? "pause.fill" : "play.fill", size: 30) {
                        playback.toggle(loop: mode == .trim ? (inPoint, outPoint) : nil)
                    }
                    .keyboardShortcut(.space, modifiers: [])
                    Text(timecode(playback.time))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(rangeLabel)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                Filmstrip(frames: frames, duration: playback.duration, time: playback.time,
                          showsRange: mode == .trim, inPoint: $inPoint, outPoint: $outPoint) { t in
                    playback.seek(to: t)
                }
                .frame(height: 54)

                if mode == .speed {
                    HStack(spacing: 6) {
                        ForEach(speeds, id: \.self) { s in
                            Button { speed = s; playback.player.rate = playback.isPlaying ? Float(s) : 0 } label: {
                                Text(speedLabel(s))
                                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                                    .frame(width: 44, height: 26)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .facetSurface(Capsule(), tint: speed == s ? Tint.selection : nil, interactive: true)
                        }
                    }
                }
            }
        } footer: {
            Text(footerHint)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            PrimaryButton(title: actionTitle, disabled: playback.duration <= 0) { apply() }
        }
        .onAppear {
            playback.load(url)
            loadFrames()
        }
        .onDisappear { playback.player.pause() }
    }

    private var actionTitle: String {
        switch mode {
        case .trim: return "Trim"
        case .split: return "Split Here"
        case .snapshot: return "Save Frame"
        case .speed: return "Apply \(speedLabel(speed))"
        }
    }

    private var footerHint: String {
        switch mode {
        case .trim: return "Drag the handles to keep a range."
        case .split: return "Splits into two files at the playhead."
        case .snapshot: return "Saves the current frame as PNG."
        case .speed: return "Pitch is preserved."
        }
    }

    private var rangeLabel: String {
        let d = playback.duration
        switch mode {
        case .trim: return "\(timecode(inPoint * d)) – \(timecode(outPoint * d))"
        default: return timecode(d)
        }
    }

    private func speedLabel(_ s: Double) -> String {
        s == s.rounded() ? "\(Int(s))×" : String(format: "%g×", s)
    }

    private func timecode(_ t: Double) -> String {
        guard t.isFinite else { return "0:00.00" }
        return String(format: "%d:%05.2f", Int(t) / 60, t.truncatingRemainder(dividingBy: 60))
    }

    private func loadFrames() {
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 160, height: 160)
        let duration = asset.duration.seconds
        guard duration.isFinite, duration > 0 else { return }
        let count = 12
        let times = (0..<count).map { NSValue(time: CMTime(seconds: duration * (Double($0) + 0.5) / Double(count), preferredTimescale: 600)) }
        let collected = FrameCollector()
        gen.generateCGImagesAsynchronously(forTimes: times) { requested, image, _, _, _ in
            _ = gen // keep the generator alive until every frame has arrived
            guard let image else { return }
            let i = times.firstIndex(of: NSValue(time: requested)) ?? 0
            let ordered = collected.add(image, at: i)
            DispatchQueue.main.async { frames = ordered }
        }
    }

    private func apply() {
        let d = playback.duration
        let url = self.url
        let time = CMTime(seconds: playback.time, preferredTimescale: 600)
        playback.player.pause()
        switch mode {
        case .trim:
            let range = CMTimeRange(start: CMTime(seconds: inPoint * d, preferredTimescale: 600),
                                    end: CMTime(seconds: outPoint * d, preferredTimescale: 600))
            close()
            JobCenter.shared.run("Trimming video", subtitle: url.lastPathComponent) { job in
                [try VideoTools.trim(url, range: range, progress: ProgressSlice(job: job))]
            }
        case .split:
            guard playback.time > 0.05, playback.time < d - 0.05 else { return }
            close()
            JobCenter.shared.run("Splitting video", subtitle: url.lastPathComponent) { job in
                try VideoTools.split(url, at: time, progress: ProgressSlice(job: job))
            }
        case .snapshot:
            JobCenter.shared.run("Saving frame", subtitle: url.lastPathComponent) { _ in
                [try VideoTools.snapshot(url, at: time)]
            }
        case .speed:
            let factor = speed
            close()
            JobCenter.shared.run("Changing speed", subtitle: url.lastPathComponent) { job in
                [try VideoTools.speed(url, factor: factor, progress: ProgressSlice(job: job))]
            }
        }
    }
}

/// Thread-safe store for filmstrip frames arriving out of order.
private final class FrameCollector {
    private let lock = NSLock()
    private var frames: [Int: CGImage] = [:]

    func add(_ image: CGImage, at index: Int) -> [CGImage] {
        lock.lock(); defer { lock.unlock() }
        frames[index] = image
        return frames.keys.sorted().compactMap { frames[$0] }
    }
}

/// AVPlayer wrapper that publishes time and play state.
final class Playback: ObservableObject {
    let player = AVPlayer()
    @Published var time: Double = 0
    @Published var duration: Double = 0
    @Published var isPlaying = false
    private var observer: Any?
    private var loop: (Double, Double)?

    func load(_ url: URL) {
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        player.actionAtItemEnd = .pause
        duration = max(0, AVURLAsset(url: url).duration.seconds)
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] t in
            guard let self else { return }
            self.time = t.seconds
            self.isPlaying = self.player.rate != 0
            if let loop = self.loop, self.duration > 0, self.time >= loop.1 * self.duration {
                self.seek(to: loop.0 * self.duration)
            }
        }
    }

    func toggle(loop range: (Double, Double)?) {
        loop = range
        if player.rate != 0 {
            player.pause()
        } else {
            if let r = range, time < r.0 * duration || time >= r.1 * duration - 0.05 {
                seek(to: r.0 * duration)
            } else if time >= duration - 0.05 {
                seek(to: 0)
            }
            player.play()
        }
        isPlaying = player.rate != 0
    }

    func seek(to t: Double) {
        time = t
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    deinit {
        if let observer { player.removeTimeObserver(observer) }
    }
}

struct PlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspect
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        view.layer?.addSublayer(layer)
        layer.frame = view.bounds
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.layer?.sublayers?.first?.frame = nsView.bounds
    }
}

/// Thumbnails with a playhead and, for trimming, in/out handles.
struct Filmstrip: View {
    let frames: [CGImage]
    let duration: Double
    let time: Double
    let showsRange: Bool
    @Binding var inPoint: Double
    @Binding var outPoint: Double
    let seek: (Double) -> Void

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack(alignment: .leading) {
                HStack(spacing: 0) {
                    ForEach(frames.indices, id: \.self) { i in
                        Image(decorative: frames[i], scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: w / CGFloat(max(frames.count, 1)), height: h)
                            .clipped()
                    }
                }
                .frame(width: w, height: h)
                .background(Color.primary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                    seek(min(max(v.location.x / w, 0), 1) * duration)
                })

                if showsRange {
                    // Dim the parts that will be removed.
                    Rectangle().fill(Color.black.opacity(0.5))
                        .frame(width: max(0, inPoint * w), height: h)
                        .allowsHitTesting(false)
                    Rectangle().fill(Color.black.opacity(0.5))
                        .frame(width: max(0, (1 - outPoint) * w), height: h)
                        .offset(x: outPoint * w)
                        .allowsHitTesting(false)
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(0.9), lineWidth: 2.5)
                        .frame(width: max(8, (outPoint - inPoint) * w), height: h)
                        .offset(x: inPoint * w)
                        .allowsHitTesting(false)
                    handle(h).offset(x: inPoint * w - 7)
                        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("strip")).onChanged { v in
                            inPoint = min(max(v.location.x / w, 0), outPoint - 0.02)
                            seek(inPoint * duration)
                        })
                    handle(h).offset(x: outPoint * w - 7)
                        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("strip")).onChanged { v in
                            outPoint = max(min(v.location.x / w, 1), inPoint + 0.02)
                            seek(outPoint * duration)
                        })
                }

                // Playhead.
                Capsule()
                    .fill(Color.white)
                    .frame(width: 3, height: h + 8)
                    .shadow(color: .black.opacity(0.4), radius: 2)
                    .offset(x: (duration > 0 ? time / duration : 0) * w - 1.5)
                    .allowsHitTesting(false)
            }
            .coordinateSpace(name: "strip")
        }
    }

    private func handle(_ h: CGFloat) -> some View {
        Capsule()
            .fill(Color.accentColor)
            .frame(width: 14, height: h + 6)
            .overlay(Capsule().fill(Color.white.opacity(0.85)).frame(width: 2, height: h * 0.4))
            .contentShape(Rectangle())
    }
}
