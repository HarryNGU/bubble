// Turns a recording into short, sharp reels: finds the pauses from the audio level, cuts them
// out, and lays the screen out for Original, 1:1, 9:16 and 16:9 with big captions. Everything here runs
// on the Mac (Apple's on-device speech recognition for captions). The edit is a plan of numbers
// (see EditPlan) that the editor's sliders and the Claude chat both change.

import AppKit
import AVFoundation
import CoreImage
import Speech

// MARK: - The edit

struct TimeSpan: Codable, Equatable {
    var start: Double
    var end: Double
    var length: Double { end - start }
}

/// The same four shapes Instagram offers when you post: the recording's own shape, square,
/// tall (Reels, TikTok, Shorts) and wide (YouTube, LinkedIn, X).
enum ReelSize: String, CaseIterable, Codable, Identifiable {
    case original, square, vertical, landscape
    var id: String { rawValue }
    var ratio: String { switch self { case .original: "Original"; case .square: "1:1"; case .vertical: "9:16"; case .landscape: "16:9" } }
    var icon: String {
        switch self {
        case .original: "photo"
        case .square: "square"
        case .vertical: "rectangle.portrait"
        case .landscape: "rectangle"
        }
    }
    var use: String {
        switch self {
        case .original: "As recorded"
        case .square: "Feed posts"
        case .vertical: "Reels, TikTok, Shorts"
        case .landscape: "YouTube, LinkedIn, X"
        }
    }
    /// Output size in pixels. Original keeps the recording's shape, up to 1920 wide.
    func render(source: CGSize) -> CGSize {
        switch self {
        case .square: return CGSize(width: 1080, height: 1080)
        case .vertical: return CGSize(width: 1080, height: 1920)
        case .landscape: return CGSize(width: 1920, height: 1080)
        case .original:
            guard source.width > 0, source.height > 0 else { return CGSize(width: 1920, height: 1080) }
            let scale = min(1, 1920 / source.width)
            func even(_ v: CGFloat) -> CGFloat { (v * scale / 2).rounded() * 2 }
            return CGSize(width: even(source.width), height: even(source.height))
        }
    }
    var fileTag: String { switch self { case .original: "original"; case .square: "1x1"; case .vertical: "9x16"; case .landscape: "16x9" } }
}

struct EditPlan: Codable, Equatable {
    /// Silence left between phrases, in seconds. Longer silences are cut down to this. nil = keep pauses.
    var maxPause: Double? = 0.25
    /// Parts of the original removed on request (seconds in the original video).
    var removed: [TimeSpan] = []
    /// Parts always kept, even if silent (for example a demo with no talking).
    var kept: [TimeSpan] = []
    var speed: Double = 1.0
    var captions = true
    var captionPosition = "bottom"   // top, middle, bottom
    /// 1 = the whole recording fits the frame; higher crops in towards `focus`.
    var zoom: Double = 1.0
    var focusX: Double = 0.5         // 0 left … 1 right
    var focusY: Double = 0.5         // 0 top … 1 bottom
    var title: String
}

struct Word: Codable, Equatable {
    var text: String
    var start: Double
    var end: Double
}

/// What Bubble learns from a recording once, then keeps: audio loudness every 20 ms and the words.
struct Analysis: Codable {
    var duration: Double
    var hop: Double
    var levels: [Float]       // dBFS per hop; empty when there's no sound
    var words: [Word]?        // nil until transcribed
    var engine: String?       // "whisper" or "apple": who wrote the words
}

// MARK: - Finding what to keep

enum Cutter {
    /// The parts of the original to keep, in order.
    static func spans(_ a: Analysis, _ p: EditPlan) -> [TimeSpan] {
        var keep: [TimeSpan]
        if let maxPause = p.maxPause, !a.levels.isEmpty {
            keep = voiced(a).map { TimeSpan(start: $0.start - maxPause / 2, end: $0.end + maxPause / 2) }
            keep = merge(keep + p.kept)
            if keep.isEmpty { keep = [TimeSpan(start: 0, end: a.duration)] }
        } else {
            keep = [TimeSpan(start: 0, end: a.duration)]
        }
        keep = keep.map { TimeSpan(start: max(0, $0.start), end: min(a.duration, $0.end)) }
        for r in p.removed { keep = keep.flatMap { subtract(r, from: $0) } }
        return keep.filter { $0.length > 0.08 }
    }

    /// Stretches where someone is talking: louder than the room by a margin.
    static func voiced(_ a: Analysis) -> [TimeSpan] {
        let sorted = a.levels.sorted()
        guard !sorted.isEmpty else { return [] }
        let floor = sorted[Int(Double(sorted.count) * 0.15)]
        let loud = sorted[Int(Double(sorted.count - 1) * 0.95)]
        let threshold = min(max(floor + 10, -55), loud - 8)
        var runs: [TimeSpan] = []
        var start: Int?
        for (i, l) in a.levels.enumerated() {
            if l > threshold { if start == nil { start = i } } else if let s = start {
                runs.append(TimeSpan(start: Double(s) * a.hop, end: Double(i) * a.hop)); start = nil
            }
        }
        if let s = start { runs.append(TimeSpan(start: Double(s) * a.hop, end: Double(a.levels.count) * a.hop)) }
        // Join breaths inside a phrase, then drop clicks and bumps.
        var joined: [TimeSpan] = []
        for r in runs {
            if let last = joined.last, r.start - last.end < 0.18 { joined[joined.count - 1].end = r.end } else { joined.append(r) }
        }
        return joined.filter { $0.length >= 0.15 }
    }

    static func merge(_ spans: [TimeSpan]) -> [TimeSpan] {
        var out: [TimeSpan] = []
        for s in spans.sorted(by: { $0.start < $1.start }) {
            if let last = out.last, s.start <= last.end { out[out.count - 1].end = max(last.end, s.end) } else { out.append(s) }
        }
        return out
    }

    private static func subtract(_ r: TimeSpan, from s: TimeSpan) -> [TimeSpan] {
        guard r.end > s.start, r.start < s.end else { return [s] }
        var out: [TimeSpan] = []
        if r.start > s.start { out.append(TimeSpan(start: s.start, end: r.start)) }
        if r.end < s.end { out.append(TimeSpan(start: r.end, end: s.end)) }
        return out
    }

    /// Where an original time lands in the edit (nil if it was cut).
    static func outputTime(_ t: Double, spans: [TimeSpan], speed: Double) -> Double? {
        var offset = 0.0
        for s in spans {
            if t >= s.start && t <= s.end { return (offset + t - s.start) / speed }
            offset += s.length
        }
        return nil
    }
}

// MARK: - Listening to the recording

enum Analyzer {
    static let hop = 0.02
    private static let format: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
        AVLinearPCMIsBigEndianKey: false,
    ]

    /// Loudness every 20 ms, from the first audio track (the microphone).
    static func levels(of url: URL) async throws -> Analysis {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            return Analysis(duration: duration, hop: hop, levels: [], words: [])
        }
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: format)
        reader.add(out)
        reader.startReading()
        let per = Int(16_000 * hop)
        var levels: [Float] = []
        var acc: Double = 0, n = 0
        while let buf = out.copyNextSampleBuffer() {
            for x in samples(buf) {
                acc += Double(x * x); n += 1
                if n == per { levels.append(Float(10 * log10(acc / Double(n) + 1e-10))); acc = 0; n = 0 }
            }
        }
        return Analysis(duration: duration, hop: hop, levels: levels, words: nil)
    }

    /// Words with timings, using on-device speech recognition in chunks of about a minute,
    /// split at quiet moments so no word is cut in half.
    static func words(of url: URL, analysis a: Analysis, progress: @escaping (Double) -> Void) async -> [Word] {
        guard await authorized(),
              let rec = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              rec.supportsOnDeviceRecognition else { return [] }
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first else { return [] }
        // One phrase at a time: the on-device recognizer drops requests that overlap.
        let list = chunks(a)
        var results = [[Word]](repeating: [], count: list.count)
        var next = 0, finished = 0
        await withTaskGroup(of: (Int, [Word]).self) { group in
            func launch() {
                guard next < list.count else { return }
                let i = next
                next += 1
                group.addTask { (i, await phrase(list[i], rec: rec, asset: asset, track: track)) }
            }
            launch()
            for await (i, ws) in group {
                results[i] = ws
                finished += 1
                progress(Double(finished) / Double(list.count))
                launch()
            }
        }
        let words = results.flatMap { $0 }
        log("captions: \(words.count) words in \(list.count) phrases")
        return words
    }

    private static func phrase(_ chunk: TimeSpan, rec: SFSpeechRecognizer, asset: AVURLAsset, track: AVAssetTrack) async -> [Word] {
        guard let reader = try? AVAssetReader(asset: asset) else { return [] }
        reader.timeRange = CMTimeRange(start: CMTime(seconds: chunk.start, preferredTimescale: 600),
                                       end: CMTime(seconds: chunk.end, preferredTimescale: 600))
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: format)
        reader.add(out)
        reader.startReading()
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.requiresOnDeviceRecognition = true
        req.shouldReportPartialResults = false
        req.addsPunctuation = true
        let pcm = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        // One phrase per request: on-device recognition only times the words of its last utterance.
        let box = WordBox()
        let task = rec.recognitionTask(with: req) { result, error in
            if let r = result, r.isFinal {
                box.add(r.bestTranscription.segments.map {
                    Word(text: $0.substring, start: chunk.start + $0.timestamp, end: chunk.start + $0.timestamp + $0.duration)
                })
                box.markDone()
            }
            if error != nil { box.markDone() }
        }
        while let buf = out.copyNextSampleBuffer() {
            let xs = samples(buf)
            guard !xs.isEmpty, let b = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: AVAudioFrameCount(xs.count)) else { continue }
            b.frameLength = AVAudioFrameCount(xs.count)
            xs.withUnsafeBufferPointer { b.floatChannelData![0].update(from: $0.baseAddress!, count: xs.count) }
            req.append(b)
        }
        req.endAudio()
        let deadline = Date().addingTimeInterval(60)  // never hang on one phrase
        while !box.done, Date() < deadline { try? await Task.sleep(for: .milliseconds(40)) }
        if task.state != .completed { task.cancel() }
        return box.words
    }

    /// Spoken phrases: stretches of talking split at pauses, at most 20 seconds each.
    private static func chunks(_ a: Analysis) -> [TimeSpan] {
        let voiced = Cutter.voiced(a)
        guard !voiced.isEmpty else { return a.levels.isEmpty ? [] : [TimeSpan(start: 0, end: a.duration)] }
        var out: [TimeSpan] = []
        for v in voiced {
            if let last = out.last, v.start - last.end < 0.35, v.end - last.start < 20 { out[out.count - 1].end = v.end } else { out.append(v) }
        }
        return out.map { TimeSpan(start: max(0, $0.start - 0.15), end: min(a.duration, $0.end + 0.2)) }
    }

    private static func samples(_ buf: CMSampleBuffer) -> [Float] {
        guard let block = CMSampleBufferGetDataBuffer(buf) else { return [] }
        let len = CMBlockBufferGetDataLength(block)
        var xs = [Float](repeating: 0, count: len / 4)
        xs.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: len, destination: $0.baseAddress!) }
        return xs
    }

    private static func authorized() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return true
        case .notDetermined:
            return await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) } }
        default: return false
        }
    }

    // MARK: Cache (~/Library/Application Support/Bubble/Edits, never next to the videos)

    static func cacheURL(for url: URL, _ kind: String) -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Bubble/Edits", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Name + byte size identifies the recording without reading it.
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let safe = url.deletingPathExtension().lastPathComponent.prefix(40).replacingOccurrences(of: "/", with: "-")
        return dir.appendingPathComponent("\(safe)-\(size)-\(kind).json")
    }

    static func load<T: Decodable>(_ t: T.Type, _ url: URL) -> T? {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    static func save<T: Encodable>(_ v: T, _ url: URL) {
        if let d = try? JSONEncoder().encode(v) { try? d.write(to: url, options: .atomic) }
    }
}

private final class WordBox: @unchecked Sendable {
    private var list: [Word] = []
    private var finished = false
    private let lock = NSLock()
    func add(_ ws: [Word]) {
        lock.lock(); defer { lock.unlock() }
        let last = list.last?.end ?? -1
        list += ws.filter { $0.start >= last - 0.05 }
    }
    func markDone() {
        lock.lock(); defer { lock.unlock() }
        finished = true
    }
    var done: Bool { lock.lock(); defer { lock.unlock() }; return finished }
    var words: [Word] { lock.lock(); defer { lock.unlock() }; return list }
}

private final class Once: @unchecked Sendable {
    private var done = false
    private let lock = NSLock()
    func run(_ f: () -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard !done else { return }
        done = true
        f()
    }
}

// MARK: - Captions

struct Cue {
    var text: String
    var start: Double   // output seconds
    var end: Double
}

enum Captions {
    /// Short bursts of up to three words, timed to the edit.
    static func cues(_ words: [Word], spans: [TimeSpan], speed: Double) -> [Cue] {
        var cues: [Cue] = []
        var group: [(Word, Double, Double)] = []
        func flush() {
            guard let first = group.first, let last = group.last else { return }
            cues.append(Cue(text: group.map { $0.0.text }.joined(separator: " "), start: first.1, end: last.2))
            group = []
        }
        for w in words {
            guard let s = Cutter.outputTime(w.start, spans: spans, speed: speed) else { flush(); continue }
            let e = Cutter.outputTime(w.end, spans: spans, speed: speed) ?? s + (w.end - w.start) / speed
            if let last = group.last, s - last.2 > 0.6 { flush() }
            group.append((w, s, e))
            if group.count == 3 || w.text.last.map({ ".,!?".contains($0) }) == true { flush() }
        }
        flush()
        // Hold each caption until the next one starts (no flicker in short gaps).
        for i in cues.indices.dropLast() where cues[i + 1].start - cues[i].end < 0.5 { cues[i].end = cues[i + 1].start }
        return cues
    }

    /// Bold white text with a dark outline and shadow, drawn once per caption.
    static func image(_ text: String, frame: CGSize) -> CIImage? {
        let short = min(frame.width, frame.height)
        let size = short * 0.068
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineBreakMode = .byWordWrapping
        let font = NSFont.systemFont(ofSize: size, weight: .heavy)
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.55)
        shadow.shadowBlurRadius = size * 0.25
        shadow.shadowOffset = NSSize(width: 0, height: -size * 0.06)
        let fill = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.white, .paragraphStyle: para, .shadow: shadow])
        let stroke = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.clear, .paragraphStyle: para,
                                                                    .strokeColor: NSColor.black, .strokeWidth: 9])
        let maxW = min(frame.width * 0.86, short * 1.15)
        let bounds = fill.boundingRect(with: NSSize(width: maxW, height: 1000), options: [.usesLineFragmentOrigin])
        let w = Int(maxW), h = Int(ceil(bounds.height + size * 0.8))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        let rect = NSRect(x: 0, y: size * 0.4, width: CGFloat(w), height: bounds.height)
        stroke.draw(with: rect, options: [.usesLineFragmentOrigin])
        fill.draw(with: rect, options: [.usesLineFragmentOrigin])
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage().map { CIImage(cgImage: $0) }
    }
}

// MARK: - Building the reel

/// Draws each frame: the recording laid out for the reel size over a blurred copy of itself,
/// plus the caption. Shared with AVFoundation's render threads, so its state is fixed or locked.
final class ReelRenderer: @unchecked Sendable {
    let size: CGSize
    let plan: EditPlan
    let cues: [Cue]
    private var cache: [Int: CIImage] = [:]
    private let lock = NSLock()

    init(size: CGSize, plan: EditPlan, cues: [Cue]) { self.size = size; self.plan = plan; self.cues = cues }

    func frame(_ src: CIImage, at t: Double) -> CIImage {
        let W = size.width, H = size.height
        let e = src.extent
        let out = CGRect(origin: .zero, size: size)
        let fit = min(W / e.width, H / e.height), fill = max(W / e.width, H / e.height)

        // Background: the same frame, filling, blurred and dimmed.
        let small = fill * 0.25
        let bg = src.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY).scaledBy(x: small, y: small))
            .clampedToExtent()
            .applyingGaussianBlur(sigma: 14)
            .transformed(by: CGAffineTransform(scaleX: 4, y: 4))
            .transformed(by: CGAffineTransform(translationX: (W - e.width * fill) / 2, y: (H - e.height * fill) / 2))
            .applyingFilter("CIColorControls", parameters: [kCIInputBrightnessKey: 0.04, kCIInputSaturationKey: 1.25])
            .cropped(to: out)

        // Foreground: fits at zoom 1, crops in towards the focus point above that.
        let s = fit * max(1, plan.zoom)
        let sw = e.width * s, sh = e.height * s
        let x = sw > W ? -(sw - W) * plan.focusX : (W - sw) / 2
        let y = sh > H ? -(sh - H) * (1 - plan.focusY) : (H - sh) / 2
        let fg = src.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
            .transformed(by: CGAffineTransform(scaleX: s, y: s))
            .transformed(by: CGAffineTransform(translationX: x, y: y))
            .cropped(to: out)
        var img = fg.composited(over: bg)

        if plan.captions, let (i, cue) = cues.enumerated().first(where: { t >= $0.element.start && t < $0.element.end }),
           let cap = caption(i, cue.text) {
            let cy: CGFloat
            switch plan.captionPosition {
            case "top": cy = H * 0.80
            case "middle": cy = H * 0.5
            default: cy = H * (H > W * 1.2 ? 0.2 : 0.12)
            }
            img = cap.transformed(by: CGAffineTransform(translationX: (W - cap.extent.width) / 2, y: cy - cap.extent.height / 2))
                .composited(over: img)
        }
        return img.cropped(to: out)
    }

    private func caption(_ i: Int, _ text: String) -> CIImage? {
        lock.lock(); defer { lock.unlock() }
        if let c = cache[i] { return c }
        if cache.count > 24 { cache.removeAll() }
        let c = Captions.image(text, frame: size)
        cache[i] = c
        return c
    }
}

enum ReelBuilder {
    struct Built {
        let composition: AVComposition
        let video: AVVideoComposition
        let duration: Double
        let renderSize: CGSize
    }

    static func build(url: URL, spans: [TimeSpan], plan: EditPlan, size: ReelSize, words: [Word]?) async throws -> Built {
        let asset = AVURLAsset(url: url)
        let comp = AVMutableComposition()
        guard let vSrc = try await asset.loadTracks(withMediaType: .video).first,
              let v = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw NSError(domain: "Bubble", code: 1, userInfo: [NSLocalizedDescriptionKey: "This recording has no video."])
        }
        let aSrcs = try await asset.loadTracks(withMediaType: .audio)
        let aDsts = aSrcs.compactMap { _ in comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) }
        var cursor = CMTime.zero
        for s in spans {
            let r = CMTimeRange(start: CMTime(seconds: s.start, preferredTimescale: 600), end: CMTime(seconds: s.end, preferredTimescale: 600))
            try v.insertTimeRange(r, of: vSrc, at: cursor)
            for (src, dst) in zip(aSrcs, aDsts) { try? dst.insertTimeRange(r, of: src, at: cursor) }
            cursor = cursor + r.duration
        }
        if plan.speed != 1, cursor.seconds > 0 {
            comp.scaleTimeRange(CMTimeRange(start: .zero, duration: cursor),
                                toDuration: CMTime(seconds: cursor.seconds / plan.speed, preferredTimescale: 600))
        }
        let cues = words.map { Captions.cues($0, spans: spans, speed: plan.speed) } ?? []
        let natural = try await vSrc.load(.naturalSize)
        let render = size.render(source: natural)
        // The original shape shows the whole recording, never cropped.
        var p = plan
        if size == .original { p.zoom = 1 }
        let renderer = ReelRenderer(size: render, plan: p, cues: cues)
        let vc = try await AVMutableVideoComposition.videoComposition(with: comp) { req in
            req.finish(with: renderer.frame(req.sourceImage, at: req.compositionTime.seconds), context: nil)
        }
        vc.renderSize = render
        vc.frameDuration = CMTime(value: 1, timescale: 30)
        return Built(composition: comp, video: vc, duration: comp.duration.seconds, renderSize: render)
    }

    static func export(_ b: Built, to url: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        try? FileManager.default.removeItem(at: url)
        guard let session = AVAssetExportSession(asset: b.composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw NSError(domain: "Bubble", code: 2, userInfo: [NSLocalizedDescriptionKey: "Couldn't start the export."])
        }
        session.videoComposition = b.video
        session.audioTimePitchAlgorithm = .spectral
        let watcher = Task {
            for await state in session.states(updateInterval: 0.25) {
                if case .exporting(let p) = state { progress(p.fractionCompleted) }
            }
        }
        defer { watcher.cancel() }
        try await session.export(to: url, as: .mp4)
    }
}
