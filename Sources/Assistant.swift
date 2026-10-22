// Ask Bubble: a translucent panel you open with a shortcut, anywhere. It can see your screen
// (a screenshot each time you ask) and hear what's playing and what you say (live, on-device
// transcription), and Claude answers in real time with your own API key.
//
// It is deliberately honest: the panel shows up in screen shares and recordings like any other
// window, and a red dot shows whenever it's listening.

import AppKit
import AVFoundation
import Carbon.HIToolbox
import ScreenCaptureKit
import Speech
import SwiftUI
import WebKit

// MARK: - When Bubble hides its Dock icon

/// macOS only shows a regular (Dock) app's windows on that app's own desktops. While the pill
/// follows you or the assistant is open, Bubble runs as a menu-bar app so its panels can appear
/// over other apps' full-screen spaces too.
enum AppPresence {
    private static var reasons = Set<String>()
    static func need(_ reason: String, _ on: Bool) {
        if on { reasons.insert(reason) } else { reasons.remove(reason) }
        let want: NSApplication.ActivationPolicy = reasons.isEmpty ? .regular : .accessory
        if NSApp.activationPolicy() != want { NSApp.setActivationPolicy(want) }
    }
}

// MARK: - Settings

enum AssistantModelChoice: String, CaseIterable, Identifiable {
    case fast, balanced, smart
    var id: String { rawValue }
    var title: String { switch self { case .fast: "Fast"; case .balanced: "Balanced"; case .smart: "Smartest" } }
    var detail: String { switch self { case .fast: "Haiku 5.5"; case .balanced: "Sonnet 5.5"; case .smart: "Opus 5.5" } }
    var modelID: String { switch self { case .fast: "claude-haiku-5-5"; case .balanced: "claude-sonnet-5-5"; case .smart: "claude-opus-5-5" } }
}

extension Settings {
    static var assistantModel: AssistantModelChoice {
        get { AssistantModelChoice(rawValue: d.string(forKey: "assistantModel") ?? "") ?? .balanced }
        set { d.set(newValue.rawValue, forKey: "assistantModel") }
    }
    static var assistantHearsMac: Bool { get { d.object(forKey: "assistantHearsMac") as? Bool ?? true } set { d.set(newValue, forKey: "assistantHearsMac") } }
    static var assistantHearsMic: Bool { get { d.object(forKey: "assistantHearsMic") as? Bool ?? true } set { d.set(newValue, forKey: "assistantHearsMic") } }
}

// MARK: - Live listening

/// Mac audio and your microphone, mixed and transcribed on this Mac as they happen.
final class LiveListener: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    struct Line: Identifiable { let id = UUID(); let text: String; let at: Date }

    var onChange: (() -> Void)?
    private(set) var lines: [Line] = []
    private(set) var live = ""
    private(set) var level: Float = 0

    private var stream: SCStream?
    private let queue = DispatchQueue(label: "bubble.listener")
    private let lock = NSLock()
    private var macQ: [Float] = [], micQ: [Float] = []
    private var lastMac = Date.distantPast, lastMic = Date.distantPast
    private var converters: [String: AVAudioConverter] = [:]
    private let out16k = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private var pump: DispatchSourceTimer?
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var taskStarted = Date()
    private var running = false

    func start(mac: Bool, mic: Bool) async throws {
        guard !running else { return }
        let status: SFSpeechRecognizerAuthorizationStatus = await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) } }
        guard status == .authorized else { throw Failure("Allow Speech Recognition for Bubble in System Settings → Privacy & Security.") }
        recognizer = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        guard recognizer?.supportsOnDeviceRecognition == true else { throw Failure("Turn on Dictation once in System Settings → Keyboard so macOS downloads on-device speech.") }

        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw Failure("No display found.") }
        let cfg = SCStreamConfiguration()
        cfg.width = 2; cfg.height = 2                      // audio only; the picture is ignored
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        cfg.capturesAudio = mac
        cfg.excludesCurrentProcessAudio = true
        cfg.captureMicrophone = mic
        let s = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if mac { try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue) }
        if mic { try s.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue) }
        try await s.startCapture()
        stream = s
        running = true
        queue.sync { newTask() }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.1, repeating: 0.1)
        t.setEventHandler { [weak self] in self?.mixAndFeed() }
        t.resume()
        pump = t
        log("assistant: listening (mac \(mac), mic \(mic))")
    }

    func stop() {
        guard running else { return }
        running = false
        pump?.cancel(); pump = nil
        let s = stream
        stream = nil
        Task { try? await s?.stopCapture() }
        queue.async { [self] in
            request?.endAudio()
            task?.cancel()
            commit()
            request = nil; task = nil
            lock.lock(); macQ = []; micQ = []; lock.unlock()
            level = 0
            notify()
        }
        log("assistant: stopped listening")
    }

    var isRunning: Bool { running }

    /// What was said in the last few minutes, oldest first.
    func recent(minutes: Double = 4) -> String {
        lock.lock(); defer { lock.unlock() }
        let since = Date().addingTimeInterval(-minutes * 60)
        let said = lines.filter { $0.at >= since }.map(\.text) + (live.isEmpty ? [] : [live])
        return said.joined(separator: "\n")
    }

    func clear() {
        lock.lock(); lines = []; live = ""; lock.unlock()
        notify()
    }

    // MARK: Audio in

    func stream(_ s: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type != .screen, sb.isValid, let samples = to16k(sb, key: type == .audio ? "mac" : "mic") else { return }
        lock.lock()
        if type == .audio { macQ += samples; lastMac = Date(); if macQ.count > 32_000 { macQ.removeFirst(macQ.count - 32_000) } }
        else { micQ += samples; lastMic = Date(); if micQ.count > 32_000 { micQ.removeFirst(micQ.count - 32_000) } }
        lock.unlock()
    }

    func stream(_ s: SCStream, didStopWithError error: Error) {
        log("assistant: listening stopped: \(error.localizedDescription)")
        running = false
        notify()
    }

    private func to16k(_ sb: CMSampleBuffer, key: String) -> [Float]? {
        guard let fd = CMSampleBufferGetFormatDescription(sb) else { return nil }
        let inFormat = AVAudioFormat(cmAudioFormatDescription: fd)
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sb))
        guard frames > 0, let inBuf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: frames) else { return nil }
        inBuf.frameLength = frames
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sb, at: 0, frameCount: Int32(frames), into: inBuf.mutableAudioBufferList) == noErr else { return nil }
        let ck = key + "\(inFormat.sampleRate)-\(inFormat.channelCount)-\(inFormat.commonFormat.rawValue)-\(inFormat.isInterleaved)"
        if converters[ck] == nil { converters[ck] = AVAudioConverter(from: inFormat, to: out16k) }
        guard let conv = converters[ck] else { return nil }
        let cap = AVAudioFrameCount(Double(frames) * 16_000 / inFormat.sampleRate) + 32
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: out16k, frameCapacity: cap) else { return nil }
        var fed = false
        var err: NSError?
        conv.convert(to: outBuf, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return inBuf
        }
        guard err == nil, let p = outBuf.floatChannelData?[0] else { return nil }
        return Array(UnsafeBufferPointer(start: p, count: Int(outBuf.frameLength)))
    }

    /// Every 100 ms: mix what each source has, and hand it to the recognizer.
    private func mixAndFeed() {
        let n = 1600
        lock.lock()
        let now = Date()
        let macOn = now.timeIntervalSince(lastMac) < 0.5, micOn = now.timeIntervalSince(lastMic) < 0.5
        // A source that has stopped sending (nothing playing) counts as silence.
        guard (macOn && macQ.count >= n) || (micOn && micQ.count >= n) else { lock.unlock(); return }
        var mix = [Float](repeating: 0, count: n)
        for q in [0, 1] {
            let on = q == 0 ? macOn : micOn
            guard on else { continue }
            let take = min(n, q == 0 ? macQ.count : micQ.count)
            for i in 0..<take { mix[i] += q == 0 ? macQ[i] : micQ[i] }
            if q == 0 { macQ.removeFirst(take) } else { micQ.removeFirst(take) }
        }
        lock.unlock()
        var peak: Float = 0
        for i in 0..<n { mix[i] = max(-1, min(1, mix[i])); peak = max(peak, abs(mix[i])) }
        level = peak
        guard let buf = AVAudioPCMBuffer(pcmFormat: out16k, frameCapacity: AVAudioFrameCount(n)) else { return }
        buf.frameLength = AVAudioFrameCount(n)
        mix.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress!, count: n) }
        request?.append(buf)
        // Start a fresh recognition every 50 s so no single request grows too long.
        if Date().timeIntervalSince(taskStarted) > 50 {
            request?.endAudio()
            newTask()
        }
    }

    // MARK: Recognition (runs on `queue`)

    private func newTask() {
        guard running, let recognizer else { return }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.requiresOnDeviceRecognition = true
        req.shouldReportPartialResults = true
        req.addsPunctuation = true
        request = req
        taskStarted = Date()
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            self.queue.async {
                if let r = result {
                    self.update(r.bestTranscription.formattedString)
                    if r.isFinal { self.commit() }
                }
                if error != nil, self.request === req {
                    self.commit()
                    self.queue.asyncAfter(deadline: .now() + 0.3) { if self.request === req { self.newTask() } }
                }
            }
        }
    }

    /// On-device recognition starts over after a pause; keep what was said before it.
    private func update(_ text: String) {
        lock.lock()
        let cur = live
        if !cur.isEmpty, text.count < cur.count / 2, !cur.lowercased().hasPrefix(text.lowercased().prefix(4)) {
            lines.append(Line(text: cur, at: Date()))
        }
        live = text
        lock.unlock()
        notify()
    }

    private func commit() {
        lock.lock()
        if !live.trimmingCharacters(in: .whitespaces).isEmpty { lines.append(Line(text: live, at: Date())) }
        live = ""
        if lines.count > 400 { lines.removeFirst(lines.count - 400) }
        lock.unlock()
        notify()
    }

    private func notify() { DispatchQueue.main.async { self.onChange?() } }

    struct Failure: LocalizedError { let m: String; init(_ m: String) { self.m = m }; var errorDescription: String? { m } }
}

// MARK: - Seeing the screen

enum ScreenGrab {
    /// A JPEG of the display under the mouse, without Bubble's own panels.
    static func jpeg(excluding windowNumbers: [Int]) async -> Data? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let screen = NSScreen.underMouse
            guard let display = content.displays.first(where: { $0.displayID == screen.displayID }) ?? content.displays.first else { return nil }
            let hide = content.windows.filter { windowNumbers.contains(Int($0.windowID)) }
            let cfg = SCStreamConfiguration()
            let scale = min(1, 1568 / CGFloat(max(display.width, display.height)))
            // About 1568 px on the long side: sharp enough to read, small enough to send quickly.
            cfg.width = Int(CGFloat(display.width) * scale)
            cfg.height = Int(CGFloat(display.height) * scale)
            cfg.showsCursor = true
            let img = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: display, excludingWindows: hide), configuration: cfg)
            return NSBitmapImageRep(cgImage: img).representation(using: .jpeg, properties: [.compressionFactor: 0.72])
        } catch {
            log("assistant: screenshot failed: \(error.localizedDescription)")
            return nil
        }
    }
}

// MARK: - Claude

/// How Claude asks Bubble to show pictures (shared by both brains).
let pictureRules = """
Pictures: Bubble can show pictures for you. Put [[images: search words]] on its own line and Bubble shows \
several matching pictures from Wikimedia Commons (diagrams, anatomy, maps, places, plants, artworks, \
apparatus). For any chemical compound or molecule, always put [[molecule: compound name]] on its own line \
(for example [[molecule: caffeine]]) and Bubble shows its 2D and 3D structure from PubChem. Use these \
whenever a picture would help someone learn or decide. Prefer them to markdown image links; you don't need \
to search the web for pictures yourself.
"""

enum AssistantClient {
    struct Turn { var question: String; var answer: String }

    static var system: String { systemText }
    private static let systemText = """
    You are Bubble's on-screen assistant on the user's Mac. The panel looks like a chat with a friend: reply as \
    a few short messages separated by blank lines, each one thought, most useful first, keeping all the detail. Each message can include a screenshot of their \
    screen and a live transcript of what they and others said recently (Mac audio and their microphone, \
    mixed, transcribed on-device, so expect mistakes and no speaker names). Help in real time: lead with the \
    answer or the exact words to say, then at most a few short bullets. Be specific to what is on screen and \
    in the conversation. If the question is unclear, give your best useful guess rather than asking.

    You can search the web. Show things, not just tell, when it helps: put code in fenced blocks with the \
    language; give links as markdown links; for a video, put a YouTube watch link on its own line. \
    \(pictureRules) Use **bold** and bullets; no tables.
    """

    /// Streams Claude's answer, calling `onText` with each new piece.
    static func ask(_ question: String, history: [Turn], screenshot: Data?, transcript: String,
                    onText: @escaping @MainActor (String) -> Void) async throws {
        guard let key = Keychain.apiKey, !key.isEmpty else {
            throw LiveListener.Failure("Add your Anthropic API key in Bubble → Assistant to start asking.")
        }
        var messages: [[String: Any]] = []
        for t in history.suffix(8) {
            messages.append(["role": "user", "content": t.question])
            messages.append(["role": "assistant", "content": t.answer.isEmpty ? "(no answer)" : t.answer])
        }
        var content: [[String: Any]] = []
        if let s = screenshot {
            content.append(["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": s.base64EncodedString()]])
        }
        var text = ""
        if !transcript.isEmpty { text += "<recent_conversation>\n\(transcript)\n</recent_conversation>\n\n" }
        text += question
        content.append(["type": "text", "text": text])
        messages.append(["role": "user", "content": content])

        let model = Settings.assistantModel
        let body: [String: Any] = [
            "model": model.modelID,
            "max_tokens": 4096,
            "stream": true,
            "system": system,
            "messages": messages,
            // Web search runs on Anthropic's side; results come back as links Claude can cite and show.
            "tools": [["type": model == .fast ? "web_search_20250305" : "web_search_20260209", "name": "web_search", "max_uses": 3]],
        ]
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, resp) = try await URLSession.shared.bytes(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            var raw = Data()
            for try await b in bytes { raw.append(b); if raw.count > 20_000 { break } }
            let json = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any]
            let msg = (json?["error"] as? [String: Any])?["message"] as? String ?? "HTTP \(status)"
            log("assistant: \(msg)")
            throw LiveListener.Failure(status == 401 ? "That API key isn't working. Check it in Bubble → Assistant." : "Claude couldn't answer: \(msg)")
        }
        for try await line in bytes.lines {
            guard line.hasPrefix("data: "), let d = line.dropFirst(6).data(using: .utf8),
                  let ev = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { continue }
            switch ev["type"] as? String {
            case "content_block_delta":
                if let delta = ev["delta"] as? [String: Any], delta["type"] as? String == "text_delta", let t = delta["text"] as? String {
                    await onText(t)
                }
            case "message_delta":
                if (ev["delta"] as? [String: Any])?["stop_reason"] as? String == "refusal" { await onText("\n\n(Claude declined to answer this.)") }
            case "error":
                let msg = (ev["error"] as? [String: Any])?["message"] as? String ?? "stream error"
                throw LiveListener.Failure("Claude stopped: \(msg)")
            default:
                break
            }
        }
    }
}

// MARK: - The panel

/// Which brain answers: the Claude Code you already use (your memory, apps and subscription), or
/// the plain API with an API key.
enum AssistantBrain: String, CaseIterable, Identifiable {
    case claudeCode, api
    var id: String { rawValue }
    var title: String { switch self { case .claudeCode: "Claude Code (your context)"; case .api: "API key only" } }
}

extension Settings {
    static var assistantBrain: AssistantBrain {
        get { AssistantBrain(rawValue: d.string(forKey: "assistantBrain") ?? "") ?? (ClaudeCodeSession.binary != nil ? .claudeCode : .api) }
        set { d.set(newValue.rawValue, forKey: "assistantBrain") }
    }
}

@MainActor
final class AssistantModel: ObservableObject {
    struct Exchange: Identifiable { let id = UUID(); var question: String; var answer: String; var withScreen: Bool; var activity: String? }

    @Published var exchanges: [Exchange] = []
    @Published var input = ""
    @Published var thinking = false
    @Published var error: String?
    @Published var listening = false
    @Published var lines: [String] = []
    @Published var live = ""
    @Published var level: Float = 0
    @Published var seeScreen = true
    @Published var cardOpen = true
    @Published var focusRequest = 0
    @Published var approval: ClaudeCodeSession.Approval?
    @Published var talking = false
    private var speech: SpeechSession?
    private var silence: Timer?

    static let sayPrompt = "Based on the conversation and my screen, what should I say next? Give me the exact words."
    static let screenPrompt = "Help me with what's on my screen right now: what is it, and what should I do or know?"

    let listener = LiveListener()
    let session = ClaudeCodeSession()
    var panelNumber: () -> [Int] = { [] }
    private var current: Task<Void, Never>?

    init() {
        listener.onChange = { [weak self] in
            guard let self else { return }
            self.lines = self.listener.lines.suffix(30).map(\.text)
            self.live = self.listener.live
            self.level = self.listener.level
            if self.listening && !self.listener.isRunning { self.listening = false }
        }
        session.onEvent = { [weak self] e in self?.handle(e) }
    }

    /// Opening the panel starts Claude Code in the background, so the first answer is quicker.
    func warmUp() {
        if Settings.assistantBrain == .claudeCode { session.warmUp() }
    }

    func toggleListening() {
        if listening {
            listener.stop()
            listening = false
        } else {
            listening = true
            error = nil
            Task {
                do { try await listener.start(mac: Settings.assistantHearsMac, mic: Settings.assistantHearsMic) }
                catch { self.listening = false; self.error = error.localizedDescription }
            }
        }
    }

    func ask(_ preset: String? = nil) {
        let q = (preset ?? input).trimmingCharacters(in: .whitespacesAndNewlines)
        if approval != nil, preset == nil, !q.isEmpty {
            input = ""
            spokenOrTyped(q)
            return
        }
        guard !q.isEmpty, !thinking else { return }
        if preset == nil { input = "" }
        error = nil
        thinking = true
        let history = exchanges.map { AssistantClient.Turn(question: $0.question, answer: $0.answer) }
        exchanges.append(Exchange(question: q, answer: "", withScreen: seeScreen, activity: seeScreen ? "Looking at your screen…" : "Thinking…"))
        let index = exchanges.count - 1
        let transcript = listener.recent()
        let screen = seeScreen
        current = Task {
            let shot = screen ? await ScreenGrab.jpeg(excluding: panelNumber()) : nil
            if Settings.assistantBrain == .claudeCode {
                var text = ""
                if !transcript.isEmpty { text += "<recent_conversation>\n\(transcript)\n</recent_conversation>\n\n" }
                if let shot, let file = Self.saveShot(shot) {
                    text += "(The image is a screenshot of my screen right now. It's also saved at \(file.path) if you need to attach or upload it.)\n\n"
                }
                session.ask(text + q, screenshot: shot)
                return  // the answer arrives through handle(_:)
            }
            do {
                try await AssistantClient.ask(q, history: history, screenshot: shot, transcript: transcript) { piece in
                    if index < self.exchanges.count { self.exchanges[index].answer += piece; self.exchanges[index].activity = nil }
                }
            } catch is CancellationError {
            } catch {
                self.error = error.localizedDescription
                if index < self.exchanges.count, self.exchanges[index].answer.isEmpty { self.exchanges.remove(at: index) }
            }
            self.thinking = false
        }
    }

    private func handle(_ e: ClaudeCodeSession.Event) {
        guard !exchanges.isEmpty else { return }
        let i = exchanges.count - 1
        switch e {
        case .text(let t):
            exchanges[i].answer += t
            exchanges[i].activity = nil
        case .activity(let a):
            exchanges[i].activity = a
            if !exchanges[i].answer.isEmpty && !exchanges[i].answer.hasSuffix("\n\n") { exchanges[i].answer += "\n\n" }
        case .approval(let a):
            approval = a
            cardOpen = true
        case .done(let err):
            thinking = false
            approval = nil
            exchanges[i].activity = nil
            if let err {
                error = err
                if exchanges[i].answer.isEmpty { exchanges.remove(at: i) }
            }
        }
    }

    // MARK: Talking to it

    /// Say what you want; when you stop talking (or press the key again) it's asked, or, if
    /// Claude is waiting for your OK, "yes" / "no" answers that.
    func toggleTalk() { talking ? finishTalk() : startTalk() }

    func startTalk() {
        guard !talking else { return }
        cardOpen = true
        Task {
            if let problem = await SpeechSession.checkAvailability() { self.error = problem; return }
            let s = SpeechSession()
            s.onPartial = { [weak self] t in
                guard let self, self.talking else { return }
                self.input = t
                self.armSilence(heardSomething: !t.isEmpty)
            }
            do { try s.start(hints: ["yes", "send it", "go ahead", "no", "cancel"] + SnippetStore.shared.triggers) }
            catch { self.error = error.localizedDescription; return }
            self.speech = s
            self.talking = true
            self.input = ""
            self.error = nil
            Sounds.listen()
            self.armSilence(heardSomething: false)
        }
    }

    /// Stops after a short pause once you've said something (or after a while if you say nothing).
    private func armSilence(heardSomething: Bool) {
        silence?.invalidate()
        silence = Timer.scheduledTimer(withTimeInterval: heardSomething ? 1.6 : 7, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.finishTalk() }
        }
    }

    func finishTalk() {
        guard talking, let s = speech else { return }
        talking = false
        silence?.invalidate()
        speech = nil
        Sounds.heard()
        s.stop { [weak self] raw in
            Task { @MainActor in
                let text = await s.bestTranscript(apple: raw, hints: ["yes", "send it"] + SnippetStore.shared.triggers)
                self?.spoken(text)
            }
        }
    }

    func cancelTalk() {
        silence?.invalidate()
        speech?.cancel()
        speech = nil
        talking = false
        input = ""
    }

    private static let yesWords = ["yes", "yeah", "yep", "yup", "sure", "ok", "okay", "send", "send it", "go ahead", "do it", "confirm", "approve", "allow"]
    private static let noWords = ["no", "nope", "don't", "do not", "stop", "cancel", "deny", "wait", "hold on"]

    private func spoken(_ raw: String) {
        input = ""
        spokenOrTyped(Cleaner.clean(raw))
    }

    private func spokenOrTyped(_ raw: String) {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        if approval != nil {
            let w = t.lowercased().trimmingCharacters(in: .punctuationCharacters)
            if Self.noWords.contains(where: { w == $0 || w.hasPrefix($0 + " ") }) { decide(allow: false); return }
            if Self.yesWords.contains(where: { w == $0 || w.hasPrefix($0 + " ") || w.hasPrefix($0 + ",") }) { decide(allow: true); return }
            return  // waiting on a yes or no; ignore anything else
        }
        ask(t)
    }

    /// The latest screenshot, kept on disk so Claude can attach it to an email or upload it.
    private static func saveShot(_ data: Data) -> URL? {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Bubble/Assistant", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("screen.jpg")
        guard (try? data.write(to: url, options: [.atomic, .completeFileProtection])) != nil else { return nil }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)  // only you can read it
        return url
    }

    func decide(allow: Bool, always: Bool = false) {
        guard let a = approval else { return }
        session.answer(a, allow: allow, always: always)
        approval = nil
    }

    func stopAnswer() {
        current?.cancel()
        if Settings.assistantBrain == .claudeCode && thinking { session.interrupt() }
        if let a = approval { session.answer(a, allow: false); approval = nil }
        thinking = false
    }

    func clear() {
        stopAnswer()
        exchanges = []
        listener.clear()
        session.reset()
    }
}

final class AssistantPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    var onEscape: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

/// The bar and its answer card float at the top of the screen, see-through, like Cluely.
/// While they're up: ⌘ + arrows move them, ⌘⏎ asks about the screen, Esc hides.
@MainActor
final class AssistantController: NSObject, NSWindowDelegate {
    let model = AssistantModel()
    private var panel: AssistantPanel?
    private var top: CGFloat = 0          // the bar stays put while the card grows below it
    private static let keyIDs: [UInt32] = [20, 21, 22, 23, 24]

    var isShown: Bool { panel?.isVisible == true }

    /// Dictation (⌥⌥) while you're typing in the panel goes straight into its text box.
    func takeDictation(_ text: String) -> Bool {
        guard let p = panel, p.isVisible, p.isKeyWindow else { return false }
        let cur = model.input.trimmingCharacters(in: .whitespaces)
        model.input = cur.isEmpty ? text : cur + " " + text
        model.focusRequest += 1
        return true
    }

    func toggle() { isShown ? hide() : show() }

    func show() {
        let p = panel ?? makePanel()
        panel = p
        AppPresence.need("assistant", true)
        model.cardOpen = true
        if !p.isVisible {
            // Size to the content first, then pin the bar to the top centre of this screen.
            if let v = p.contentViewController?.view {
                v.layoutSubtreeIfNeeded()
                p.setContentSize(v.fittingSize)
            }
            let f = NSScreen.underMouse.visibleFrame
            top = f.maxY - 10
            p.setFrameOrigin(NSPoint(x: f.midX - p.frame.width / 2, y: top - p.frame.height))
        }
        p.orderFrontRegardless()
        p.makeKey()
        model.focusRequest += 1
        model.warmUp()
        holdKeys()
        log("assistant: shown")
    }

    func hide() {
        panel?.orderOut(nil)
        ShortcutCenter.shared.releaseTemporary(Self.keyIDs)
        AppPresence.need("assistant", false)
    }

    /// Re-registers the panel's keys (after you change them in settings).
    func refreshKeys() {
        guard isShown else { return }
        ShortcutCenter.shared.releaseTemporary(Self.keyIDs)
        holdKeys()
    }

    private func holdKeys() {
        let m = Settings.assistantMoveMods
        let ask = ShortcutCenter.shared[.assistAsk]
        ShortcutCenter.shared.holdTemporary([
            (20, kVK_LeftArrow, m, { [weak self] in self?.nudge(dx: -1, dy: 0) }),
            (21, kVK_RightArrow, m, { [weak self] in self?.nudge(dx: 1, dy: 0) }),
            (22, kVK_UpArrow, m, { [weak self] in self?.nudge(dx: 0, dy: 1) }),
            (23, kVK_DownArrow, m, { [weak self] in self?.nudge(dx: 0, dy: -1) }),
            (24, Int(ask.keyCode), Int(ask.mods), { [weak self] in self?.quickAsk() }),
        ])
    }

    private func nudge(dx: CGFloat, dy: CGFloat) {
        guard let p = panel else { return }
        let step: CGFloat = 80
        let screen = p.screen ?? NSScreen.underMouse
        let f = screen.visibleFrame
        var o = p.frame.origin
        o.x = min(f.maxX - p.frame.width, max(f.minX, o.x + dx * step))
        top = min(f.maxY, max(f.minY + 60, top + dy * step))
        o.y = top - p.frame.height
        p.setFrameOrigin(o)
    }

    /// ⌘⏎: ask about what's typed, or, with nothing typed, help with the screen right now.
    private func quickAsk() {
        let typed = model.input.trimmingCharacters(in: .whitespacesAndNewlines)
        model.cardOpen = true
        model.ask(typed.isEmpty ? (model.listening ? AssistantModel.sayPrompt : AssistantModel.screenPrompt) : nil)
    }

    func windowDidResize(_ n: Notification) {
        guard let p = panel, top > 0 else { return }
        p.setFrameOrigin(NSPoint(x: p.frame.minX, y: top - p.frame.height))
    }

    /// Dragging the bar moves the anchor with it.
    func windowDidMove(_ n: Notification) {
        guard let p = panel, p.isVisible, top > 0 else { return }
        top = p.frame.maxY
    }

    private func makePanel() -> AssistantPanel {
        let p = AssistantPanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 60),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.level = .floating
        p.hasShadow = false
        p.hidesOnDeactivate = false
        p.isMovableByWindowBackground = true
        p.becomesKeyOnlyIfNeeded = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.onEscape = { [weak self] in
            guard let self else { return }
            if self.model.talking { self.model.cancelTalk() } else { self.hide() }
        }
        p.delegate = self
        let host = NSHostingController(rootView: AssistantView(model: model, onClose: { [weak self] in self?.hide() }))
        host.sizingOptions = [.preferredContentSize]
        p.contentViewController = host
        model.panelNumber = { [weak p] in p.map { [$0.windowNumber] } ?? [] }
        return p
    }
}

enum MoveKeys: Int, CaseIterable, Identifiable {
    case option, command, control, optionCommand
    var id: Int { rawValue }
    var label: String { switch self { case .option: "⌥"; case .command: "⌘"; case .control: "⌃"; case .optionCommand: "⌥⌘" } }
    var carbon: Int {
        switch self {
        case .option: optionKey
        case .command: cmdKey
        case .control: controlKey
        case .optionCommand: optionKey | cmdKey
        }
    }
}

extension Settings {
    /// Modifier held with the arrow keys to move Ask Bubble. Default ⌥.
    static var assistantMove: MoveKeys {
        get { MoveKeys(rawValue: d.integer(forKey: "assistantMove")) ?? .option }
        set { d.set(newValue.rawValue, forKey: "assistantMove") }
    }
    static var assistantMoveMods: Int { assistantMove.carbon }

    /// How dark the assistant's glass is: 0.25 (very see-through) to 0.85 (solid).
    static var assistantDarkness: Double {
        get { d.object(forKey: "assistantDarkness") as? Double ?? 0.62 }
        set { d.set(newValue, forKey: "assistantDarkness") }
    }
}

struct AssistantView: View {
    @ObservedObject var model: AssistantModel
    let onClose: () -> Void
    @ObservedObject private var keys = ShortcutCenter.shared
    @AppStorage("assistantDarkness") private var darkness = 0.62
    @AppStorage("chatMyColor") private var myColor = ChatStyle.defaultMine
    @AppStorage("chatTheirColor") private var theirColor = ChatStyle.defaultTheirs
    @AppStorage("chatTextSize") private var textSize = 14.0
    @AppStorage("chatName") private var name = "Bubble"
    @AppStorage("chatAvatar") private var avatar = ""
    @FocusState private var focused: Bool
    @State private var showTranscript = false
    @State private var showLook = false

    private let chips: [(String, String)] = [
        ("What should I say?", AssistantModel.sayPrompt),
        ("Explain this", "Explain what's on my screen right now, simply."),
        ("Summarise", "Summarise the conversation so far in a few bullets, with any decisions and to-dos."),
        ("Next step", "What's the best next step for what I'm doing on screen?"),
    ]

    private var glass: Color { Color.black.opacity(darkness) }

    var body: some View {
        VStack(spacing: 8) {
            bar
            if model.cardOpen { card.transition(.opacity.combined(with: .move(edge: .top))) }
        }
        .frame(width: 640)
        .padding(.bottom, 4)
        .environment(\.colorScheme, .dark)
        .animation(.easeOut(duration: 0.15), value: model.cardOpen)
        .onChange(of: model.focusRequest) { focused = true }
    }

    // MARK: Bar

    private var bar: some View {
        HStack(spacing: 4) {
            Image(systemName: "circle.fill").font(.system(size: 13)).foregroundStyle(Theme.accent)
                .padding(.leading, 14).padding(.trailing, 6)
            barButton(model.listening ? "Listening" : "Listen", dot: model.listening ? .red : .white.opacity(0.35)) { model.toggleListening() }
            divider
            barButton(model.talking ? "Done" : "Talk", keys: keys.label(.assistVoice), dot: model.talking ? .red : nil) { model.toggleTalk() }
            divider
            barButton("Ask", keys: keys.label(.assistAsk)) { model.cardOpen = true; model.focusRequest += 1 }
            divider
            barButton(model.cardOpen ? "Collapse" : "Expand", keys: nil) { model.cardOpen.toggle() }
            divider
            barButton("Hide", keys: keys.label(.assist)) { onClose() }
            Spacer(minLength: 4)
            Button { model.seeScreen.toggle() } label: {
                Image(systemName: model.seeScreen ? "eye" : "eye.slash").font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(model.seeScreen ? 0.9 : 0.45)).frame(width: 28, height: 28)
            }
            .buttonStyle(.plain).help(model.seeScreen ? "Sees your screen when you ask" : "Not looking at your screen")
            Menu {
                Button("Clear conversation") { model.clear() }
                Divider()
                Text("Move: \(Settings.assistantMove.label) + arrow keys")
            } label: { Image(systemName: "ellipsis").foregroundStyle(.white.opacity(0.8)).frame(width: 26, height: 28) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .padding(.trailing, 8)
        }
        .frame(height: 42)
        // The bar is small, so it's always dark enough to read over anything, with a light blur.
        .background(
            ZStack {
                VisualEffect(material: .hudWindow).opacity(0.85)
                Color.black.opacity(max(darkness, 0.6))
            }
            .clipShape(Capsule())
        )
        .shadow(color: .black.opacity(0.35), radius: 1)
        .overlay(Capsule().stroke(.white.opacity(0.16)))
        .foregroundStyle(.white)
    }

    private var divider: some View { Rectangle().fill(.white.opacity(0.14)).frame(width: 1, height: 18) }

    private func barButton(_ title: String, keys: String? = nil, dot: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let dot { Circle().fill(dot).frame(width: 7, height: 7) }
                Text(title).font(.system(size: 12.5, weight: .medium))
                if let keys {
                    Text(keys).font(.system(size: 11, weight: .medium, design: .rounded)).foregroundStyle(.white.opacity(0.55))
                        .padding(.horizontal, 5).frame(height: 18)
                        .background(RoundedRectangle(cornerRadius: 4).fill(.white.opacity(0.1)))
                }
            }
            .padding(.horizontal, 10).frame(height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Card

    private var style: ChatStyle { ChatStyle.current(mine: myColor, theirs: theirColor, size: textSize) }

    /// Colours, see-through and text size, changed right from the chat.
    private var lookPicker: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Chat look").font(.system(size: 13, weight: .semibold))
            VStack(alignment: .leading, spacing: 6) {
                Text("Your bubbles").font(.system(size: 11.5)).foregroundStyle(.secondary)
                HStack(spacing: 9) {
                    ForEach(ChatStyle.mineChoices, id: \.0) { hex, label in
                        Button { myColor = hex } label: {
                            Circle().fill(ChatStyle.color(hex) ?? .blue).frame(width: 22, height: 22)
                                .overlay(Circle().stroke(Color.primary.opacity(myColor == hex ? 0.9 : 0), lineWidth: 2).padding(-3))
                        }
                        .buttonStyle(.plain).help(label)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Their bubbles").font(.system(size: 11.5)).foregroundStyle(.secondary)
                SwiftUI.Picker("", selection: $theirColor) { ForEach(ChatStyle.theirsChoices, id: \.0) { Text($0.1).tag($0.0) } }
                    .pickerStyle(.segmented).labelsHidden()
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("See-through").font(.system(size: 11.5)).foregroundStyle(.secondary)
                Slider(value: Binding(get: { 1 - darkness }, set: { darkness = 1 - $0 }), in: 0.15...0.75)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Text size").font(.system(size: 11.5)).foregroundStyle(.secondary)
                SwiftUI.Picker("", selection: $textSize) { Text("S").tag(13.0); Text("M").tag(14.0); Text("L").tag(16.0) }
                    .pickerStyle(.segmented).labelsHidden()
            }
        }
        .padding(16)
        .frame(width: 270)
    }

    /// Who you're talking to, like the top of a chat.
    private var chatHeader: some View {
        HStack(spacing: 9) {
            Avatar(emoji: avatar, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(name.isEmpty ? "Bubble" : name).font(.system(size: 13, weight: .semibold))
                HStack(spacing: 4) {
                    Circle().fill(model.thinking ? Color.orange : Color.green).frame(width: 6, height: 6)
                    Text(model.thinking ? "typing…" : "here for you").font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
                }
            }
            Spacer()
            Button { showLook.toggle() } label: {
                Image(systemName: "paintpalette").font(.system(size: 13)).foregroundStyle(.white.opacity(0.85))
                    .frame(width: 28, height: 28).background(Circle().fill(.white.opacity(showLook ? 0.18 : 0.08)))
            }
            .buttonStyle(.plain).help("Change the chat's look")
            .popover(isPresented: $showLook, arrowEdge: .bottom) { lookPicker }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .overlay(alignment: .bottom) { Rectangle().fill(.white.opacity(0.08)).frame(height: 1) }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            chatHeader
            if model.listening || !model.lines.isEmpty { transcriptStrip }
            if !model.exchanges.isEmpty || model.error != nil {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(model.exchanges) { ex in exchange(ex).id(ex.id) }
                            if let a = model.approval { ChatRow(mine: false, style: style) { approvalCard(a) } }
                            if let e = model.error {
                                Label(e, systemImage: "exclamationmark.triangle.fill").font(.system(size: 12.5)).foregroundStyle(.orange)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Color.clear.frame(height: 1).id("end")
                        }
                        .padding(16)
                    }
                    .frame(maxHeight: 460)
                    .fixedSize(horizontal: false, vertical: true)
                    .onChange(of: model.exchanges.last?.answer) { proxy.scrollTo("end", anchor: .bottom) }
                }
            }
            if model.exchanges.isEmpty { chipRow }
            inputBar
        }
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(glass))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(.white.opacity(0.16)))
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.5), radius: 0.5)  // keeps text readable over busy backgrounds
    }

    private var transcriptStrip: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { showTranscript.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "waveform").font(.system(size: 11))
                    Text("Live transcript").font(.system(size: 11, weight: .semibold))
                    Spacer()
                    Image(systemName: showTranscript ? "chevron.up" : "chevron.down").font(.system(size: 9, weight: .bold))
                }
                .foregroundStyle(.white.opacity(0.6)).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            let all = model.lines + (model.live.isEmpty ? [] : [model.live])
            if all.isEmpty {
                Text("Waiting for speech…").font(.system(size: 12)).foregroundStyle(.white.opacity(0.4))
            } else {
                Text((showTranscript ? all.suffix(12) : all.suffix(2)).joined(separator: " "))
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.8))
                    .lineLimit(showTranscript ? 14 : 2).truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .overlay(alignment: .bottom) { Rectangle().fill(.white.opacity(0.08)).frame(height: 1) }
    }

    /// Splits a reply into separate texts at blank lines, keeping code blocks and lists whole.
    static func messages(_ text: String) -> [String] {
        var out: [String] = []
        var cur: [String] = []
        var inCode = false
        for line in text.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { inCode.toggle() }
            if !inCode, line.trimmingCharacters(in: .whitespaces).isEmpty {
                if !cur.isEmpty { out.append(cur.joined(separator: "\n")); cur = [] }
            } else {
                cur.append(line)
            }
        }
        if !cur.isEmpty { out.append(cur.joined(separator: "\n")) }
        // A list of longer points becomes one text per point, like a friend sending them one by one.
        out = out.flatMap { chunk -> [String] in
            let lines = chunk.components(separatedBy: "\n")
            let bullet = #"^\s*([-*•]|\d+[.)])\s+"#
            let isList = lines.count > 1 && lines.allSatisfy { $0.range(of: bullet, options: .regularExpression) != nil }
            guard isList, lines.contains(where: { $0.count > 70 }) else { return [chunk] }
            return lines.map { $0.replacingOccurrences(of: bullet, with: "", options: .regularExpression) }
        }
        // A heading or label like "Here's what I found:" reads better with the message after it.
        var merged: [String] = []
        for m in out {
            if let last = merged.last, last.count < 40, last.hasSuffix(":") { merged[merged.count - 1] = last + "\n" + m } else { merged.append(m) }
        }
        return merged.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private func exchange(_ ex: AssistantModel.Exchange) -> some View {
        let live = model.thinking && ex.id == model.exchanges.last?.id
        return VStack(spacing: 4) {
            ChatRow(mine: true, style: style) {
                VStack(alignment: .trailing, spacing: 3) {
                    Text(ex.question).textSelection(.enabled)
                    if ex.withScreen {
                        Label("saw your screen", systemImage: "eye").font(.system(size: 10.5)).opacity(0.7)
                    }
                }
            }
            // Like texts from a friend: each short message is its own bubble; the avatar sits by the last.
            let parts = Self.messages(ex.answer)
            ForEach(Array(parts.enumerated()), id: \.offset) { i, part in
                ChatRow(mine: false, style: style, showAvatar: i == parts.count - 1 && !(live && ex.activity != nil)) {
                    RichAnswer(text: part, size: style.textSize)
                }
                .contextMenu {
                    Button("Copy this message") { copy(part) }
                    Button("Copy whole reply") { copy(ex.answer) }
                }
            }
            if let act = ex.activity, live {
                ChatRow(mine: false, style: style, compact: true, showAvatar: true) { TypingDots(label: act) }
            }
        }
    }

    /// Claude wants to do something that changes things: you decide.
    private func approvalCard(_ a: ClaudeCodeSession.Approval) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Claude wants to: \(a.appName)", systemImage: "hand.raised.fill").font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.yellow)
            if !a.summary.isEmpty {
                Text(a.summary).font(.system(size: 12, design: .monospaced)).foregroundStyle(.white.opacity(0.85))
                    .lineLimit(8).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10).background(RoundedRectangle(cornerRadius: 8).fill(.black.opacity(0.4)))
            }
            HStack(spacing: 8) {
                Button("Deny") { model.decide(allow: false) }.buttonStyle(.plain)
                    .padding(.horizontal, 12).frame(height: 28).background(Capsule().fill(.white.opacity(0.12)))
                Spacer()
                Button("Always allow") { model.decide(allow: true, always: true) }.buttonStyle(.plain)
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.6)).help("Don't ask again for \(a.appName)")
                Button("Allow once") { model.decide(allow: true) }.buttonStyle(.plain)
                    .foregroundStyle(.black).padding(.horizontal, 14).frame(height: 28).background(Capsule().fill(.white))
            }
            .font(.system(size: 12.5, weight: .medium))
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(.yellow.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.yellow.opacity(0.35)))
    }

    private var chipRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(chips, id: \.0) { c in
                    Button { model.ask(c.1) } label: {
                        Text(c.0).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.9))
                            .padding(.horizontal, 10).frame(height: 26)
                            .background(Capsule().fill(.white.opacity(0.1)))
                    }
                    .buttonStyle(.plain).disabled(model.thinking)
                }
            }
            .padding(.horizontal, 12)
        }
        .padding(.top, 10)
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            if model.talking {
                Image(systemName: "mic.fill").foregroundStyle(.red).symbolEffect(.pulse)
            }
            TextField(model.talking ? "Listening… say what you want" : (model.approval != nil ? "Say or type yes / no…" : "Ask, or press \(keys.label(.assistVoice)) and say it…"),
                      text: $model.input, axis: .vertical)
                .textFieldStyle(.plain).font(.system(size: 13.5)).lineLimit(1...4)
                .focused($focused)
                .onSubmit { model.ask() }
            if model.thinking {
                Button(action: model.stopAnswer) {
                    Image(systemName: "stop.fill").font(.system(size: 10, weight: .bold)).foregroundStyle(.black)
                        .frame(width: 26, height: 26).background(Circle().fill(.white))
                }
                .buttonStyle(.plain).help("Stop")
            } else {
                Button { model.ask() } label: {
                    Image(systemName: "arrow.up").font(.system(size: 12, weight: .bold)).foregroundStyle(.black)
                        .frame(width: 26, height: 26).background(Circle().fill(.white))
                }
                .buttonStyle(.plain)
                .disabled(model.input.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(.white.opacity(0.1)))
        .padding(12)
    }
}

// MARK: - Rich answers

/// Claude's answer as text, code blocks with a copy button, pictures and video links.
struct RichAnswer: View {
    let text: String
    var size: Double = 14

    enum Block: Hashable {
        case prose(String)
        case code(lang: String, body: String)
        case image(URL)
        case video(URL, thumb: URL)
        case imageSearch(String)
        case molecule(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(Self.blocks(text).enumerated()), id: \.offset) { _, b in
                switch b {
                case .prose(let s):
                    Text(Self.inline(s)).font(.system(size: size)).lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        .tint(Color(red: 0.55, green: 0.75, blue: 1))
                case .code(let lang, let body):
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            Text(lang.isEmpty ? "code" : lang).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.5))
                            Spacer()
                            Button { copy(body) } label: { Label("Copy", systemImage: "doc.on.doc").font(.system(size: 11)) }
                                .buttonStyle(.plain).foregroundStyle(.white.opacity(0.7))
                        }
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        ScrollView(.horizontal, showsIndicators: false) {
                            Text(body).font(.system(size: 12.5, design: .monospaced)).textSelection(.enabled)
                                .padding(.horizontal, 12).padding(.bottom, 10)
                        }
                    }
                    .background(RoundedRectangle(cornerRadius: 10).fill(.black.opacity(0.45)))
                case .image(let url):
                    LinkedPicture(url: url)
                case .imageSearch(let q):
                    ImageSearchStrip(query: q)
                case .molecule(let name):
                    MoleculeCard(name: name)
                case .video(let url, let thumb):
                    VideoBlock(url: url, thumb: thumb)
                }
            }
        }
    }

    static func blocks(_ s: String) -> [Block] {
        var out: [Block] = []
        var prose: [String] = []
        var code: [String]? = nil
        var lang = ""
        func flush() {
            let p = prose.joined(separator: "\n").trimmingCharacters(in: .newlines)
            if !p.isEmpty { out.append(.prose(p)) }
            prose = []
        }
        for raw in s.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if let c = code { out.append(.code(lang: lang, body: c.joined(separator: "\n"))); code = nil }
                else { flush(); lang = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces); code = [] }
                continue
            }
            if code != nil { code!.append(raw); continue }
            if let q = Self.capture(#"^\[\[\s*images?\s*:\s*(.+?)\s*\]\]$"#, in: line) {
                flush(); out.append(.imageSearch(q)); continue
            }
            if let q = Self.capture(#"^\[\[\s*molecule\s*:\s*(.+?)\s*\]\]$"#, in: line) {
                flush(); out.append(.molecule(q)); continue
            }
            if let u = Self.capture(#"^!\[[^\]]*\]\((https?://[^)\s]+)\)$"#, in: line).flatMap(URL.init(string:)) {
                flush(); out.append(.image(u)); continue
            }
            prose.append(line.hasPrefix("#") ? "**" + line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces) + "**" : raw)
            // A YouTube link gets a playable thumbnail under its line.
            if let id = Self.capture(#"(?:youtube\.com/watch\?v=|youtu\.be/)([A-Za-z0-9_-]{11})"#, in: raw),
               let thumb = URL(string: "https://img.youtube.com/vi/\(id)/hqdefault.jpg"),
               let url = URL(string: "https://www.youtube.com/watch?v=\(id)") {
                flush(); out.append(.video(url, thumb: thumb))
            }
        }
        if let c = code { out.append(.code(lang: lang, body: c.joined(separator: "\n"))) }
        flush()
        return out
    }

    /// The first capture group of `pattern` in `s`.
    private static func capture(_ pattern: String, in s: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)), m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: s) else { return nil }
        return String(s[r])
    }

    static func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}

// MARK: - Pictures Bubble finds itself

enum PictureFetch {
    static let agent = "Bubble/1.0 (https://github.com/HarryNGU/bubble)"

    static func image(_ url: URL) async -> NSImage? {
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        req.setValue(agent, forHTTPHeaderField: "User-Agent")
        guard let (d, r) = try? await URLSession.shared.data(for: req), (r as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return NSImage(data: d)
    }

    /// Up to six pictures for `query` from Wikimedia Commons (free, no account): (thumbnail, page).
    /// Long searches often match nothing, so it retries with fewer words.
    static func commons(_ query: String) async -> [(URL, URL)] {
        let words = query.split(separator: " ")
        for n in [words.count, min(words.count, 3), min(words.count, 2), 1] where n > 0 {
            let found = await commonsOnce(words.prefix(n).joined(separator: " "))
            if !found.isEmpty { return found }
        }
        return []
    }

    private static func commonsOnce(_ query: String) async -> [(URL, URL)] {
        var c = URLComponents(string: "https://commons.wikimedia.org/w/api.php")!
        c.queryItems = [
            .init(name: "action", value: "query"), .init(name: "format", value: "json"),
            .init(name: "generator", value: "search"), .init(name: "gsrnamespace", value: "6"),
            .init(name: "gsrlimit", value: "10"), .init(name: "gsrsearch", value: query + " filetype:bitmap|drawing"),
            .init(name: "prop", value: "imageinfo"), .init(name: "iiprop", value: "url|mime"), .init(name: "iiurlwidth", value: "420"),
        ]
        var req = URLRequest(url: c.url!)
        req.setValue(agent, forHTTPHeaderField: "User-Agent")
        guard let (d, _) = try? await URLSession.shared.data(for: req),
              let json = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let pages = (json["query"] as? [String: Any])?["pages"] as? [String: [String: Any]] else { return [] }
        let ordered = pages.values.sorted { ($0["index"] as? Int ?? 0) < ($1["index"] as? Int ?? 0) }
        return ordered.compactMap { p in
            guard let info = (p["imageinfo"] as? [[String: Any]])?.first,
                  let mime = info["mime"] as? String, mime.hasPrefix("image/"),
                  let thumb = (info["thumburl"] as? String).flatMap(URL.init(string:)),
                  let page = (info["descriptionurl"] as? String).flatMap(URL.init(string:)) else { return nil }
            return (thumb, page)
        }
        .prefix(6).map { $0 }
    }
}

/// A row of pictures for a search, from Wikimedia Commons. Click one to open its page.
struct ImageSearchStrip: View {
    let query: String
    @State private var items: [(NSImage, URL)] = []
    @State private var done = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(query, systemImage: "photo.on.rectangle").font(.system(size: 11, weight: .medium)).opacity(0.6)
            if items.isEmpty {
                RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.06)).frame(height: 110)
                    .overlay { if done { Text("No pictures found").font(.system(size: 12)).opacity(0.6) } else { ProgressView().controlSize(.small) } }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(items.enumerated()), id: \.offset) { _, it in
                            Image(nsImage: it.0).resizable().scaledToFill()
                                .frame(width: 150, height: 120).background(Color.white).clipped()
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                .onTapGesture { NSWorkspace.shared.open(it.1) }
                                .help("Open on Wikimedia Commons")
                        }
                    }
                }
            }
        }
        .task(id: query) {
            let found = await PictureFetch.commons(query)
            var loaded: [(NSImage, URL)] = []
            for (thumb, page) in found { if let img = await PictureFetch.image(thumb) { loaded.append((img, page)); items = loaded } }
            done = true
        }
    }
}

/// A compound's 2D and 3D structure from PubChem.
struct MoleculeCard: View {
    let name: String
    @State private var flat: NSImage?
    @State private var solid: NSImage?
    @State private var done = false

    private func url(_ threeD: Bool) -> URL? {
        let n = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        // PubChem only draws 3D models at its fixed "large" size.
        return URL(string: "https://pubchem.ncbi.nlm.nih.gov/rest/pug/compound/name/\(n)/PNG?" + (threeD ? "record_type=3d&image_size=large" : "image_size=400x400"))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(name.capitalized, systemImage: "atom").font(.system(size: 11, weight: .medium)).opacity(0.6)
            HStack(spacing: 8) {
                tile(flat, "2D")
                tile(solid, "3D")
            }
            .onTapGesture {
                let q = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? name
                if let u = URL(string: "https://pubchem.ncbi.nlm.nih.gov/#query=\(q)") { NSWorkspace.shared.open(u) }
            }
            .help("Open on PubChem")
        }
        .task(id: name) {
            if let u = url(false) { flat = await PictureFetch.image(u) }
            if let u = url(true) { solid = await PictureFetch.image(u) }
            done = true
        }
    }

    private func tile(_ img: NSImage?, _ label: String) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 10).fill(.white)
            if let img { Image(nsImage: img).resizable().scaledToFit().padding(6) }
            else if done { Text("Not found").font(.system(size: 11)).foregroundStyle(.gray).frame(maxWidth: .infinity, maxHeight: .infinity) }
            else { ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity) }
            Text(label).font(.system(size: 10, weight: .bold)).foregroundStyle(.black.opacity(0.5)).padding(6)
        }
        .frame(width: 170, height: 150)
    }
}

/// A picture from a link in the answer, loaded with a polite user agent (some sites refuse
/// requests without one). Shows a note instead of spinning forever if it can't load.
struct LinkedPicture: View {
    let url: URL
    @State private var img: NSImage?
    @State private var failed = false
    var body: some View {
        Group {
            if let img {
                Image(nsImage: img).resizable().scaledToFit().frame(maxHeight: 240)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            } else if failed {
                Label("Couldn't load this picture. Click to open it.", systemImage: "photo").font(.system(size: 12))
                    .opacity(0.65)
            } else {
                RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.06)).frame(height: 120).overlay(ProgressView().controlSize(.small))
            }
        }
        .onTapGesture { NSWorkspace.shared.open(url) }
        .task(id: url) {
            img = await PictureFetch.image(url)
            failed = img == nil
        }
    }
}

// MARK: - Videos that play in the panel

/// A YouTube video: a thumbnail until you click it, then it plays right here.
struct VideoBlock: View {
    let url: URL
    let thumb: URL
    @State private var playing = false
    @State private var img: NSImage?

    private var videoID: String? { URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "v" }?.value }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if playing, let id = videoID {
                YouTubePlayer(id: id).frame(width: 560, height: 315).clipShape(RoundedRectangle(cornerRadius: 10))
            } else {
                Button { playing = true } label: {
                    ZStack {
                        if let img { Image(nsImage: img).resizable().scaledToFill() } else { Color.white.opacity(0.06) }
                        Image(systemName: "play.circle.fill").font(.system(size: 44)).foregroundStyle(.white.opacity(0.92)).shadow(radius: 4)
                    }
                    .frame(width: 320, height: 180).clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain).help("Play here")
            }
            Button { NSWorkspace.shared.open(url) } label: {
                Label("Open on YouTube", systemImage: "arrow.up.right").font(.system(size: 11))
            }
            .buttonStyle(.plain).opacity(0.6)
        }
        .task(id: thumb) { img = await PictureFetch.image(thumb) }
    }
}

/// YouTube's own embedded player. It needs a real web origin, so the page is given one.
struct YouTubePlayer: NSViewRepresentable {
    let id: String
    func makeNSView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.mediaTypesRequiringUserActionForPlayback = []
        let v = WKWebView(frame: .zero, configuration: cfg)
        v.setValue(false, forKey: "drawsBackground")
        let html = """
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
        <style>html,body{margin:0;height:100%;background:#000}iframe{border:0;width:100%;height:100%}</style></head>
        <body><iframe src="https://www.youtube-nocookie.com/embed/\(id)?autoplay=1&playsinline=1&rel=0"
        allow="autoplay; encrypted-media; picture-in-picture; fullscreen" allowfullscreen
        referrerpolicy="strict-origin-when-cross-origin"></iframe></body></html>
        """
        v.loadHTMLString(html, baseURL: URL(string: "https://bubble.localhost/"))
        return v
    }
    func updateNSView(_ v: WKWebView, context: Context) {}
}

// MARK: - Chat look

/// Colours and size for the Ask Bubble chat, chosen in Assistant settings.
struct ChatStyle {
    let mine: Color, mineText: Color, theirs: Color, theirsText: Color
    let textSize: Double

    static let defaultMine = "0A84FF"
    static let defaultTheirs = "glass"
    /// Your bubble colours.
    static let mineChoices: [(String, String)] = [("0A84FF", "Blue"), ("7C5CFF", "Violet"), ("30B85A", "Green"), ("FF375F", "Pink"), ("FF8A00", "Orange"), ("3A3A3C", "Graphite")]
    /// Their bubble styles.
    static let theirsChoices: [(String, String)] = [("glass", "Glass"), ("2C2C2E", "Graphite"), ("1C1C1E", "Ink"), ("E9E9EB", "Light")]

    static func current(mine: String, theirs: String, size: Double) -> ChatStyle {
        let m = color(mine) ?? Color(red: 0.04, green: 0.52, blue: 1)
        let t: Color = theirs == "glass" ? .white.opacity(0.14) : (color(theirs) ?? .white.opacity(0.14))
        let light = theirs == "E9E9EB"
        return ChatStyle(mine: m, mineText: .white, theirs: t, theirsText: light ? .black : .white, textSize: size)
    }

    static func color(_ hex: String) -> Color? {
        guard hex.count == 6, let v = UInt32(hex, radix: 16) else { return nil }
        return Color(red: Double(v >> 16 & 0xFF) / 255, green: Double(v >> 8 & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}

/// One message: yours on the right, theirs on the left with their avatar, like a DM.
struct ChatRow<Content: View>: View {
    let mine: Bool
    let style: ChatStyle
    var compact = false
    var showAvatar = true
    @ViewBuilder let content: Content
    @AppStorage("chatAvatar") private var avatar = ""

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if mine { Spacer(minLength: 70) }
            else if showAvatar { Avatar(emoji: avatar, size: 24) }
            else { Color.clear.frame(width: 24, height: 1) }
            content
                .font(.system(size: style.textSize))
                .foregroundStyle(mine ? style.mineText : style.theirsText)
                .padding(.horizontal, compact ? 12 : 13).padding(.vertical, compact ? 8 : 9)
                .background(
                    UnevenRoundedRectangle(topLeadingRadius: 18, bottomLeadingRadius: mine ? 18 : 5,
                                           bottomTrailingRadius: mine ? 5 : 18, topTrailingRadius: 18, style: .continuous)
                        .fill(mine ? style.mine : style.theirs)
                )
                .fixedSize(horizontal: false, vertical: true)
            if !mine { Spacer(minLength: 40) }
        }
        .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
    }
}

/// Bubble's blue circle logo, or an emoji if you chose one.
struct Avatar: View {
    let emoji: String
    let size: CGFloat
    var body: some View {
        let e = emoji.trimmingCharacters(in: .whitespaces)
        if e.isEmpty || e == "🫧" {
            ZStack {
                Circle().fill(Theme.accent)
                Circle().fill(.white).frame(width: size * 0.36, height: size * 0.36)
            }
            .frame(width: size, height: size)
        } else {
            Text(String(e.prefix(2)))
                .font(.system(size: size * 0.58))
                .frame(width: size, height: size)
                .background(Circle().fill(.white.opacity(0.16)))
        }
    }
}

/// "…" while it's working, with what it's doing underneath.
struct TypingDots: View {
    let label: String
    @State private var phase = 0
    private let tick = Timer.publish(every: 0.35, on: .main, in: .common).autoconnect()
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                ForEach(0..<3) { i in
                    Circle().frame(width: 6, height: 6).opacity(phase == i ? 0.95 : 0.35)
                }
            }
            if !label.isEmpty && label != "Thinking…" {
                Text(label).font(.system(size: 11)).opacity(0.6)
            }
        }
        .onReceive(tick) { _ in phase = (phase + 1) % 3 }
    }
}
