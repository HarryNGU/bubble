// Accurate captions with Whisper (whisper.cpp), run on this Mac. Optional: Bubble falls back to
// Apple's speech recognition when it isn't set up. Needs the `whisper-cli` tool
// (`brew install whisper-cpp`) and a model file, which Bubble downloads into
// ~/Library/Application Support/Bubble/Models when you ask it to.

import AVFoundation
import Foundation

enum Whisper {
    static let modelName = "ggml-large-v3-turbo-q5_0.bin"
    static let modelSize = "574 MB"
    private static let modelSource = URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin")!

    static var modelURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Bubble/Models", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(modelName)
    }

    static var binary: URL? {
        ["/opt/homebrew/bin/whisper-cli", "/usr/local/bin/whisper-cli"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    static var hasModel: Bool {
        ((try? modelURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 100_000_000
    }

    static var ready: Bool { binary != nil && hasModel }

    // MARK: Model download

    static func downloadModel(progress: @escaping @Sendable (Double) -> Void) async throws {
        let tmp = try await Downloader(progress: progress).download(modelSource)
        try? FileManager.default.removeItem(at: modelURL)
        try FileManager.default.moveItem(at: tmp, to: modelURL)
        log("whisper: model downloaded")
    }

    private final class Downloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        let progress: @Sendable (Double) -> Void
        private var cont: CheckedContinuation<URL, Error>?
        init(progress: @escaping @Sendable (Double) -> Void) { self.progress = progress }

        func download(_ url: URL) async throws -> URL {
            try await withCheckedThrowingContinuation { c in
                cont = c
                let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
                session.downloadTask(with: url).resume()
            }
        }

        func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64, totalBytesWritten w: Int64, totalBytesExpectedToWrite t: Int64) {
            if t > 0 { progress(Double(w) / Double(t)) }
        }

        func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            // The file is deleted when this returns, so move it first.
            let keep = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            do {
                if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
                    throw NSError(domain: "Bubble", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "Download failed (HTTP \(http.statusCode))."])
                }
                try FileManager.default.moveItem(at: location, to: keep)
                cont?.resume(returning: keep)
            } catch {
                cont?.resume(throwing: error)
            }
            cont = nil
            s.finishTasksAndInvalidate()
        }

        func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error { cont?.resume(throwing: error); cont = nil }
            s.finishTasksAndInvalidate()
        }
    }

    // MARK: Transcribing

    /// Words with timings for the whole recording. `voiced` drops anything Whisper "hears" in
    /// long silences (it sometimes invents text there).
    static func transcribe(_ url: URL, voiced: [TimeSpan], progress: @escaping @Sendable (Double) -> Void) async throws -> [Word] {
        guard let bin = binary, hasModel else { throw NSError(domain: "Bubble", code: 3, userInfo: [NSLocalizedDescriptionKey: "Whisper isn't set up."]) }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bubble-whisper-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav = dir.appendingPathComponent("audio.wav")
        try await writeWAV(from: url, to: wav)

        let lang = Locale.current.language.languageCode?.identifier ?? "auto"
        let p = Process()
        p.executableURL = bin
        // One word per segment (-ml 1 -sow), no context carried between windows (-mc 0, which stops
        // Whisper repeating itself in silences), and DTW word timings (-dtw, needs -nfa).
        p.arguments = ["-m", modelURL.path, "-f", wav.path, "-ojf", "-of", dir.appendingPathComponent("out").path,
                       "-ml", "1", "-sow", "-mc", "0", "-nfa", "-dtw", "large.v3.turbo", "-l", lang, "-t", "\(max(4, ProcessInfo.processInfo.activeProcessorCount - 2))", "-pp"]
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        err.fileHandleForReading.readabilityHandler = { h in
            let s = String(decoding: h.availableData, as: UTF8.self)
            // "whisper_print_progress_callback: progress =  45%"
            if let r = s.range(of: #"progress\s*=\s*(\d+)%"#, options: .regularExpression),
               let n = Double(s[r].filter(\.isNumber)) { progress(n / 100) }
        }
        let started = Date()
        try p.run()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            p.terminationHandler = { _ in c.resume() }
        }
        err.fileHandleForReading.readabilityHandler = nil
        guard p.terminationStatus == 0 else {
            throw NSError(domain: "Bubble", code: Int(p.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "Whisper stopped with an error."])
        }

        struct Out: Decodable {
            struct Seg: Decodable {
                struct Off: Decodable { let from: Int; let to: Int }
                struct Token: Decodable { let text: String; let t_dtw: Int? }
                let offsets: Off
                let text: String
                let tokens: [Token]?
            }
            let transcription: [Seg]
        }
        let data = try Data(contentsOf: dir.appendingPathComponent("out.json"))
        let out = try JSONDecoder().decode(Out.self, from: data)
        var words: [Word] = []
        for seg in out.transcription {
            var t = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if t == "i" || t.hasPrefix("i'") { t = "I" + t.dropFirst() }
            guard !t.isEmpty, !t.hasPrefix("["), !t.hasPrefix("(") else { continue }
            // DTW time (centiseconds) of the word's first real token; segment offsets as a fallback.
            let dtw = seg.tokens?.first(where: { !$0.text.hasPrefix("[_") && ($0.t_dtw ?? -1) >= 0 })?.t_dtw
            let start = dtw.map { Double($0) / 100 } ?? Double(seg.offsets.from) / 1000
            words.append(Word(text: t, start: start, end: start + 0.3))
        }
        words.sort { $0.start < $1.start }
        // Each word lasts until the next one starts (at most a second).
        for i in words.indices {
            let next = i + 1 < words.count ? words[i + 1].start : words[i].start + 0.4
            words[i].end = max(words[i].start + 0.08, min(next, words[i].start + 1))
        }
        // Drop anything "heard" in long silences.
        let padded = voiced.map { TimeSpan(start: $0.start - 0.5, end: $0.end + 0.5) }
        if !padded.isEmpty { words = words.filter { w in padded.contains { w.start < $0.end && w.end > $0.start } } }
        log("whisper: \(words.count) words in \(Int(Date().timeIntervalSince(started)))s")
        return mergePunctuation(words)
    }

    /// Whisper sometimes gives punctuation as its own "word"; attach it to the word before.
    private static func mergePunctuation(_ ws: [Word]) -> [Word] {
        var out: [Word] = []
        for w in ws {
            if let last = out.last, w.text.allSatisfy({ $0.isPunctuation }) {
                out[out.count - 1] = Word(text: last.text + w.text, start: last.start, end: max(last.end, w.end))
            } else {
                out.append(w)
            }
        }
        return out
    }

    /// 16 kHz mono 16-bit WAV of the first audio track, which is what whisper.cpp reads.
    private static func writeWAV(from url: URL, to wav: URL) async throws {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw NSError(domain: "Bubble", code: 4, userInfo: [NSLocalizedDescriptionKey: "This recording has no sound."])
        }
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
        ])
        reader.add(out)
        reader.startReading()
        FileManager.default.createFile(atPath: wav.path, contents: Data(count: 44))
        let h = try FileHandle(forWritingTo: wav)
        try h.seekToEnd()
        var bytes: UInt32 = 0
        while let buf = out.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buf) else { continue }
            let len = CMBlockBufferGetDataLength(block)
            var d = Data(count: len)
            d.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: len, destination: $0.baseAddress!) }
            try h.write(contentsOf: d)
            bytes += UInt32(len)
        }
        // Header, now that the length is known.
        var hdr = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; hdr.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; hdr.append(Data(bytes: &x, count: 2)) }
        hdr.append("RIFF".data(using: .ascii)!); u32(36 + bytes)
        hdr.append("WAVEfmt ".data(using: .ascii)!); u32(16); u16(1); u16(1); u32(16_000); u32(32_000); u16(2); u16(16)
        hdr.append("data".data(using: .ascii)!); u32(bytes)
        try h.seek(toOffset: 0)
        try h.write(contentsOf: hdr)
        try h.close()
    }
}

// MARK: - Whisper for voice (dictation and Talk)

/// Keeps whisper.cpp's small server running on this Mac (127.0.0.1 only) once you've used voice,
/// so each dictation is transcribed in about a second without reloading the model.
final class WhisperServer: @unchecked Sendable {
    static let shared = WhisperServer()
    private var process: Process?
    private var port: Int = 0
    private var idle: Timer?

    private var serverBinary: URL? {
        Whisper.binary.map { $0.deletingLastPathComponent().appendingPathComponent("whisper-server") }
            .flatMap { FileManager.default.isExecutableFile(atPath: $0.path) ? $0 : nil }
    }

    var available: Bool { serverBinary != nil && Whisper.hasModel }

    /// Starts loading the model in the background (call when you start talking).
    func warmUp() {
        guard available, process?.isRunning != true, let bin = serverBinary else { return }
        port = Int.random(in: 52_000...59_000)
        let p = Process()
        p.executableURL = bin
        let lang = Locale.current.language.languageCode?.identifier ?? "en"
        p.arguments = ["-m", Whisper.modelURL.path, "--host", "127.0.0.1", "--port", "\(port)",
                       "-t", "\(max(4, ProcessInfo.processInfo.activeProcessorCount - 2))", "-l", lang, "-nt"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run(); process = p; log("whisper: voice server starting"); scheduleIdleStop() } catch { log("whisper: server failed: \(error.localizedDescription)") }
    }

    /// Text for a 16 kHz mono 16-bit recording, or nil (then Apple's text is used).
    func transcribe(pcm16: Data, prompt: String) async -> String? {
        guard available, pcm16.count > 16_000 else { return nil }  // under half a second: nothing said
        warmUp()
        defer { scheduleIdleStop() }
        let wav = Self.wav(pcm16)
        let boundary = "bubble-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("response_format", "json")
        field("temperature", "0")
        if !prompt.isEmpty { field("prompt", prompt) }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"voice.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        body.append(wav)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        // The server may still be loading the model: try for up to ~20 seconds.
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/inference")!)
            req.httpMethod = "POST"
            req.timeoutInterval = 6
            req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            req.httpBody = body
            if let (d, r) = try? await URLSession.shared.data(for: req), (r as? HTTPURLResponse)?.statusCode == 200,
               let json = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any], let text = json["text"] as? String {
                // Drop sound labels like *music* or [laughs], then common phrases Whisper "hears" in silence.
                let t = text.replacingOccurrences(of: #"\*[^*]*\*|\[[^\]]*\]|\([^)]*\)"#, with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let ghosts = ["thank you.", "thanks for watching!", "you", "thank you for watching.", "[blank_audio]", "bye."]
                return t.isEmpty || ghosts.contains(t.lowercased()) ? nil : t
            }
            try? await Task.sleep(for: .milliseconds(300))
        }
        log("whisper: voice server didn't answer in time")
        return nil
    }

    /// Frees the memory after 30 minutes without voice.
    private func scheduleIdleStop() {
        DispatchQueue.main.async {
            self.idle?.invalidate()
            self.idle = Timer.scheduledTimer(withTimeInterval: 1800, repeats: false) { [weak self] _ in self?.stop() }
        }
    }

    func stop() {
        process?.terminate()
        process = nil
    }

    private static func wav(_ pcm: Data) -> Data {
        var h = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; h.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; h.append(Data(bytes: &x, count: 2)) }
        h.append(Data("RIFF".utf8)); u32(36 + UInt32(pcm.count))
        h.append(Data("WAVEfmt ".utf8)); u32(16); u16(1); u16(1); u32(16_000); u32(32_000); u16(2); u16(16)
        h.append(Data("data".utf8)); u32(UInt32(pcm.count))
        return h + pcm
    }
}
