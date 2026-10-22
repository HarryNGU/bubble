// Voice typing. Double-tap Option anywhere (or the shortcut chosen in settings): Bubble listens
// (Whisper on this Mac, or Apple's on-device speech recognition), tidies what you said, expands
// snippets, then types it into the text box you're in. If no text box is focused, the text goes
// onto the clipboard. It finishes by itself when you stop talking, or tap Option once; Esc cancels.
//
// Needs Accessibility access (to notice Option taps in other apps and to type into them).

import AppKit
import ApplicationServices
import AVFoundation
import Speech
import SwiftUI

// MARK: - Modifier taps

/// Notices a modifier key (⌥ by default) pressed and released on its own. A double tap starts;
/// while `endsOnSingleTap` says so, one tap finishes.
final class ModifierTapMonitor {
    var modifier: NSEvent.ModifierFlags? = .option  // nil = off (dictation uses a key combination)
    var onDoubleTap: (() -> Void)?
    var onSingleTap: (() -> Void)?
    var endsOnSingleTap: () -> Bool = { false }
    var onEscape: (() -> Void)?
    private var monitors: [Any] = []
    private var optionDownAt: Date?
    private var lastTap: Date?
    private var otherInput = false

    func install() {
        uninstall()
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown, .leftMouseDown]
        if let g = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] in self?.handle($0) }) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] e in self?.handle(e); return e }) { monitors.append(l) }
    }

    func uninstall() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
    }

    private func handle(_ e: NSEvent) {
        switch e.type {
        case .keyDown:
            if e.keyCode == 53 { onEscape?() }
            otherInput = true
            lastTap = nil
        case .leftMouseDown:
            lastTap = nil
        case .flagsChanged:
            let flags = e.modifierFlags.intersection([.command, .option, .control, .shift, .function])
            if let m = modifier, flags == m {
                optionDownAt = Date()
                otherInput = false
            } else if flags.isEmpty, let down = optionDownAt {
                optionDownAt = nil
                guard !otherInput, Date().timeIntervalSince(down) < 0.35 else { lastTap = nil; return }
                if endsOnSingleTap() {
                    lastTap = nil
                    onSingleTap?()
                } else if let last = lastTap, Date().timeIntervalSince(last) < 0.45 {
                    lastTap = nil
                    onDoubleTap?()
                } else {
                    lastTap = Date()
                }
            } else {
                optionDownAt = nil  // Option used with another modifier: not a tap
                lastTap = nil
            }
        default:
            break
        }
    }
}

// MARK: - Live speech

final class SpeechSession: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    var onPartial: ((String) -> Void)?
    var onLevel: ((Float) -> Void)?
    /// Called once when you've spoken and then gone quiet for `silenceAfter` seconds (or said
    /// nothing for a while). Judged from the mic level, so it works even when Apple's live text lags.
    var onSilence: (() -> Void)?
    var silenceAfter: TimeInterval = 1.6
    private var noiseFloor: Float = 1
    private var loudFrames = 0
    private var heardSpeech = false
    private var quietSince: Date?
    private var startedAt = Date()
    private var silenceFired = false
    private var session: AVCaptureSession?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let queue = DispatchQueue(label: "bubble.dictation")
    private var latest = ""
    private var finished: ((String) -> Void)?
    private var lastLevel = Date.distantPast
    /// A copy of what you said (16 kHz mono 16-bit), for Whisper to transcribe more accurately.
    private(set) var recorded = Data()
    private var converter: AVAudioConverter?
    private let pcm16 = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!

    static func checkAvailability() async -> String? {
        let status: SFSpeechRecognizerAuthorizationStatus = await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
        }
        guard status == .authorized else { return "Allow Speech Recognition for Bubble in System Settings → Privacy & Security." }
        guard let r = recognizer(), r.supportsOnDeviceRecognition else {
            return "On-device dictation isn't set up for your language. Turn on Dictation in System Settings → Keyboard once so macOS downloads it."
        }
        return nil
    }

    private static func recognizer() -> SFSpeechRecognizer? {
        SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    }

    func start(hints: [String]) throws {
        guard let recognizer = Self.recognizer() else { throw RecordError(message: "Speech recognition isn't available.") }
        WhisperServer.shared.warmUp()
        recorded = Data()
        converter = nil
        noiseFloor = 1; loudFrames = 0; heardSpeech = false; quietSince = nil; silenceFired = false; startedAt = Date()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true  // audio never leaves the Mac
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        request.contextualStrings = Array(hints.prefix(100))
        self.request = request
        latest = ""
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result {
                self.latest = result.bestTranscription.formattedString
                DispatchQueue.main.async { self.onPartial?(self.latest) }
                if result.isFinal { self.finish() }
            } else if error != nil {
                self.finish()
            }
        }

        let session = AVCaptureSession()
        let chosen = Settings.micDevice
        guard let device = (chosen.isEmpty ? nil : AVCaptureDevice(uniqueID: chosen)) ?? AVCaptureDevice.default(for: .audio) else {
            throw RecordError(message: "No microphone found.")
        }
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw RecordError(message: "Can't use the microphone.") }
        session.addInput(input)
        let output = AVCaptureAudioDataOutput()
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { throw RecordError(message: "Can't read the microphone.") }
        session.addOutput(output)
        session.startRunning()
        self.session = session
    }

    /// Stops listening and returns the final transcript (or the latest partial after 2.5 s).
    func stop(_ done: @escaping (String) -> Void) {
        finished = done
        session?.stopRunning()
        session = nil
        request?.endAudio()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in self?.finish() }
    }

    func cancel() {
        finished = nil
        session?.stopRunning()
        session = nil
        task?.cancel()
        task = nil
        request = nil
    }

    private func finish() {
        DispatchQueue.main.async {
            guard let f = self.finished else { return }
            self.finished = nil
            self.task?.cancel()
            self.task = nil
            self.request = nil
            f(self.latest)
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from connection: AVCaptureConnection) {
        request?.appendAudioSampleBuffer(sb)
        keep(sb)
        guard Date().timeIntervalSince(lastLevel) > 0.06, let block = CMSampleBufferGetDataBuffer(sb),
              let desc = CMSampleBufferGetFormatDescription(sb),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee else { return }
        lastLevel = Date()
        var length = 0
        var ptr: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &ptr) == noErr,
              let ptr else { return }
        var sum: Float = 0
        var count = 0
        if asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0 {
            count = length / 4
            ptr.withMemoryRebound(to: Float.self, capacity: count) { f in for i in 0..<count { sum += f[i] * f[i] } }
        } else {
            count = length / 2
            ptr.withMemoryRebound(to: Int16.self, capacity: count) { f in for i in 0..<count { let v = Float(f[i]) / 32768; sum += v * v } }
        }
        guard count > 0 else { return }
        let db = 10 * log10(max(sum / Float(count), 1e-12))
        let level = max(0, min(1, (db + 55) / 50))
        DispatchQueue.main.async { self.onLevel?(level); self.watchSilence(level) }
    }

    /// A simple voice detector: the quietest level seen is the room; well above it is you talking.
    private func watchSilence(_ level: Float) {
        guard onSilence != nil, !silenceFired else { return }
        noiseFloor = level < noiseFloor ? level : noiseFloor + (level - noiseFloor) * 0.005
        let speaking = level > noiseFloor + 0.15 && level > 0.18
        if speaking {
            loudFrames += 1
            if loudFrames >= 3 { heardSpeech = true }
            quietSince = nil
        } else {
            loudFrames = 0
            if heardSpeech {
                let since = quietSince ?? Date()
                quietSince = since
                if Date().timeIntervalSince(since) >= silenceAfter { silenceFired = true; onSilence?() }
            } else if Date().timeIntervalSince(startedAt) > 12 {
                silenceFired = true; onSilence?()  // nothing said at all
            }
        }
    }
}

extension SpeechSession {
    /// Converts a mic buffer to 16 kHz mono and adds it to `recorded` (capped at 3 minutes).
    fileprivate func keep(_ sb: CMSampleBuffer) {
        guard recorded.count < 16_000 * 2 * 180, let fd = CMSampleBufferGetFormatDescription(sb) else { return }
        let inFormat = AVAudioFormat(cmAudioFormatDescription: fd)
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sb))
        guard frames > 0, let inBuf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: frames) else { return }
        inBuf.frameLength = frames
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sb, at: 0, frameCount: Int32(frames), into: inBuf.mutableAudioBufferList) == noErr else { return }
        if converter == nil || converter?.inputFormat != inFormat { converter = AVAudioConverter(from: inFormat, to: pcm16) }
        guard let conv = converter,
              let out = AVAudioPCMBuffer(pcmFormat: pcm16, frameCapacity: AVAudioFrameCount(Double(frames) * 16_000 / inFormat.sampleRate) + 32) else { return }
        var fed = false
        var err: NSError?
        conv.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return inBuf
        }
        guard err == nil, let p = out.int16ChannelData?[0] else { return }
        recorded.append(Data(bytes: p, count: Int(out.frameLength) * 2))
    }

    /// Whisper's transcript of what was said, falling back to Apple's (`apple`) if Whisper isn't
    /// set up or doesn't answer.
    func bestTranscript(apple: String, hints: [String]) async -> String {
        guard WhisperServer.shared.available else { return apple }
        let prompt = hints.prefix(30).joined(separator: ", ")
        if let w = await WhisperServer.shared.transcribe(pcm16: recorded, prompt: prompt) {
            if w.trimmingCharacters(in: .whitespaces).lowercased() != apple.trimmingCharacters(in: .whitespaces).lowercased() {
                log("dictation: whisper used (\(w.split(separator: " ").count) words, apple heard \(apple.split(separator: " ").count))")
            }
            return w
        }
        return apple
    }
}

// MARK: - Typing into other apps

enum Inserter {
    /// Is there an editable text field focused in the app you're using?
    static func focusedTextField() -> (editable: Bool, app: String?) {
        let front = NSWorkspace.shared.frontmostApplication
        guard let front, front.processIdentifier != getpid() else { return (false, nil) }
        // Chrome and Electron apps only build their accessibility tree when asked.
        let appEl = AXUIElementCreateApplication(front.processIdentifier)
        AXUIElementSetAttributeValue(appEl, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(appEl, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)

        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appEl, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let el = focused, CFGetTypeID(el) == AXUIElementGetTypeID() else { return (false, front.localizedName) }
        let element = el as! AXUIElement
        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        let role = roleRef as? String ?? ""
        if ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"].contains(role) { return (true, front.localizedName) }
        // Rich editors in web pages (Gmail, Docs, Notion…) mark an editable ancestor.
        var editable: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, "AXEditableAncestor" as CFString, &editable) == .success, editable != nil {
            return (true, front.localizedName)
        }
        var settable = DarwinBoolean(false)
        if AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable) == .success, settable.boolValue {
            return (true, front.localizedName)
        }
        return (false, front.localizedName)
    }

    /// Pastes `text` at the cursor (works in every app), then restores your clipboard.
    static func paste(_ text: String) {
        let pb = NSPasteboard.general
        let saved: [[(NSPasteboard.PasteboardType, Data)]] = (pb.pasteboardItems ?? []).map { item in
            item.types.compactMap { t in item.data(forType: t).map { (t, $0) } }
        }
        pb.clearContents()
        pb.setString(text, forType: .string)
        let src = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: true)   // V
        let up = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            guard !saved.isEmpty else { return }
            pb.clearContents()
            for entries in saved {
                let item = NSPasteboardItem()
                for (t, d) in entries { item.setData(d, forType: t) }
                pb.writeObjects([item])
            }
        }
    }

    static var trusted: Bool { AXIsProcessTrusted() }

    static func requestTrust() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }
}

// MARK: - Controller

final class DictationModel: ObservableObject {
    enum Phase: Equatable { case idle, listening, tidying, done(String), failed(String) }
    @Published var phase: Phase = .idle
    @Published var partial = ""
    @Published var level: Float = 0
    @Published var last: String = UserDefaults.standard.string(forKey: "lastDictation") ?? "" {
        didSet { UserDefaults.standard.set(last, forKey: "lastDictation") }
    }
    @Published var history: [String] = []          // this session only
    @Published var accessibility = Inserter.trusted
    @Published var removeFillers = Settings.d.object(forKey: "dictFillers") as? Bool ?? true { didSet { Settings.d.set(removeFillers, forKey: "dictFillers") } }
    @Published var fixCorrections = Settings.d.object(forKey: "dictCorrections") as? Bool ?? true { didSet { Settings.d.set(fixCorrections, forKey: "dictCorrections") } }
    @Published var aiPolish = Settings.d.object(forKey: "dictAIPolish") as? Bool ?? false { didSet { Settings.d.set(aiPolish, forKey: "dictAIPolish") } }
    @Published var hasAPIKey = Keychain.hasKey
    /// Finish by itself when you stop talking (a single ⌥ tap still finishes straight away).
    @Published var autoStop = Settings.d.object(forKey: "dictAutoStop") as? Bool ?? true { didSet { Settings.d.set(autoStop, forKey: "dictAutoStop") } }
}

final class DictationController {
    let model = DictationModel()
    /// Returns true if one of Bubble's own text boxes took the dictated text.
    var ownTextTarget: ((String) -> Bool)?
    private let monitor = ModifierTapMonitor()
    private var speech: SpeechSession?
    private var hud: NSPanel?
    private var targetApp: String?
    private var trustTimer: Timer?

    func start() {
        monitor.onDoubleTap = { [weak self] in self?.toggle() }
        monitor.onSingleTap = { [weak self] in self?.finish() }
        monitor.endsOnSingleTap = { [weak self] in self?.model.phase == .listening }
        monitor.onEscape = { [weak self] in self?.cancel() }
        applyShortcut()
        monitor.install()
        // Global key monitoring only works once Accessibility is allowed; re-arm when it is.
        trustTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            let t = Inserter.trusted
            if t != self.model.accessibility {
                self.model.accessibility = t
                if t { self.monitor.install(); log("dictation: accessibility granted") }
            }
        }
        log("dictation: ready (accessibility \(Inserter.trusted))")
    }

    /// Follows the dictation shortcut: a double-tapped modifier, or (via a hot key) a key combination.
    func applyShortcut() {
        let s = ShortcutCenter.shared[.dictate]
        monitor.modifier = s.isDoubleTap ? s.tapFlags : nil
    }

    func toggle() {
        switch model.phase {
        case .listening: finish()
        case .tidying: break
        default: begin()
        }
    }

    func begin() {
        Task { @MainActor in
            if let problem = await SpeechSession.checkAvailability() {
                self.model.phase = .failed(problem)
                self.showHUD()
                self.hideHUD(after: 4)
                return
            }
            let s = SpeechSession()
            s.onPartial = { [weak self] t in self?.model.partial = t }
            s.onLevel = { [weak self] l in self?.model.level = l }
            if self.model.autoStop { s.onSilence = { [weak self] in self?.finish() } }
            do {
                try s.start(hints: SnippetStore.shared.triggers)
            } catch {
                self.model.phase = .failed(error.localizedDescription)
                self.showHUD()
                self.hideHUD(after: 3)
                return
            }
            self.speech = s
            self.targetApp = NSWorkspace.shared.frontmostApplication?.localizedName
            self.model.partial = ""
            self.model.phase = .listening
            Sounds.listen()
            self.showHUD()
            log("dictation: listening")
        }
    }

    func cancel() {
        guard model.phase == .listening else { return }
        speech?.cancel()
        speech = nil
        model.phase = .idle
        hideHUD(after: 0)
        log("dictation: cancelled")
    }

    func finish() {
        guard model.phase == .listening, let s = speech else { return }
        model.phase = .tidying
        Sounds.heard()
        s.stop { [weak self] raw in
            guard let self else { return }
            self.speech = nil
            Task { @MainActor in
                let text = await s.bestTranscript(apple: raw, hints: SnippetStore.shared.triggers)
                await self.deliver(text)
            }
        }
    }

    @MainActor private func deliver(_ raw: String) async {
        let words = raw.split(separator: " ").count
        log("dictation: heard \(words) words")
        guard words > 0 else {
            model.phase = .failed("Didn't catch anything. Check the mic in Bubble's settings.")
            hideHUD(after: 2.5)
            return
        }
        var text: String?
        if model.aiPolish { text = await Cleaner.polish(raw, keep: SnippetStore.shared.triggers) }
        if text == nil {
            text = Cleaner.clean(raw, options: .init(removeFillers: model.removeFillers, fixCorrections: model.fixCorrections))
        }
        let final = SnippetStore.shared.expand(text ?? raw)
        model.last = final
        model.history.insert(final, at: 0)
        if model.history.count > 10 { model.history.removeLast() }

        // Bubble's own panels (Ask Bubble) take the text directly: pasting with ⌘V would go to
        // whichever app is in front, since those panels never make Bubble the active app.
        if let own = ownTextTarget, own(final) {
            model.phase = .done("Typed into Ask Bubble")
            log("dictation: delivered (Bubble panel)")
            hideHUD(after: 1.6)
            return
        }
        let target: (editable: Bool, app: String?) = Inserter.trusted ? Inserter.focusedTextField() : (false, nil)
        if target.editable {
            Inserter.paste(final)
            model.phase = .done("Typed into \(target.app ?? "your app")")
        } else {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(final, forType: .string)
            model.phase = .done(Inserter.trusted ? "No text box selected. Copied, paste anywhere" : "Copied. Allow Accessibility so Bubble can type for you")
        }
        log("dictation: delivered (\(target.editable ? "typed" : "copied"))")
        hideHUD(after: 2.2)
    }

    // MARK: Floating pill

    private func showHUD() {
        if hud == nil {
            let host = FirstClickHostingView(rootView: DictationPill(model: model))
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 90),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isOpaque = false
            p.backgroundColor = .clear
            p.level = .statusBar
            p.hasShadow = false
            p.hidesOnDeactivate = false
            p.ignoresMouseEvents = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            p.contentView = host
            hud = p
        }
        guard let hud else { return }
        let f = NSScreen.underMouse.visibleFrame
        hud.setFrameOrigin(NSPoint(x: f.midX - hud.frame.width / 2, y: f.minY + 28))
        hud.orderFrontRegardless()
    }

    private func hideHUD(after seconds: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self else { return }
            if case .listening = self.model.phase { return }
            if case .tidying = self.model.phase { return }
            self.hud?.orderOut(nil)
            self.model.phase = .idle
        }
    }
}

// MARK: - Pill view

struct DictationPill: View {
    @ObservedObject var model: DictationModel
    @ObservedObject private var themes = ThemeStore.shared

    var body: some View {
        HStack(spacing: 12) {
            icon
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold, design: .rounded))
                if let sub = subtitle {
                    Text(sub).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.7)).lineLimit(1).truncationMode(.head)
                }
            }
            .frame(maxWidth: 340, alignment: .leading)
        }
        .foregroundStyle(.white)
        .padding(.leading, 12).padding(.trailing, 18).padding(.vertical, 10)
        .background(ZStack { VisualEffect(material: .hudWindow); Color.black.opacity(0.4) }.clipShape(Capsule()))
        .overlay(Capsule().stroke(.white.opacity(0.12)))
        .environment(\.colorScheme, .dark)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .opacity(model.phase == .idle ? 0 : 1)
        .animation(.easeOut(duration: 0.2), value: model.phase)
    }

    @ViewBuilder private var icon: some View {
        switch model.phase {
        case .listening:
            HStack(spacing: 2.5) {
                ForEach(0..<5) { i in
                    let w: [Float] = [0.5, 0.8, 1, 0.75, 0.45]
                    Capsule().fill(Theme.accent).frame(width: 3.5, height: 5 + 18 * CGFloat(min(1, model.level * w[i] * 1.3)))
                }
            }
            .frame(width: 30, height: 26)
            .animation(.easeOut(duration: 0.1), value: model.level)
        case .tidying:
            ProgressView().controlSize(.small).frame(width: 30)
        case .done:
            Image(systemName: "checkmark.circle.fill").font(.system(size: 20)).foregroundStyle(Theme.accent).frame(width: 30)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 18)).foregroundStyle(.orange).frame(width: 30)
        case .idle:
            EmptyView()
        }
    }

    private var title: String {
        switch model.phase {
        case .listening: return "Listening…"
        case .tidying: return "Tidying up…"
        case .done(let s): return s
        case .failed(let s): return s
        case .idle: return ""
        }
    }

    private var subtitle: String? {
        switch model.phase {
        case .listening:
            let s = ShortcutCenter.shared[.dictate]
            let finish = model.autoStop ? "Talk, then pause" : (s.isDoubleTap ? "Tap \(s.tapSymbol) to finish" : "\(s.label) to finish")
            return model.partial.isEmpty ? finish + " · Esc to cancel" : model.partial
        case .done: return model.last
        default: return nil
        }
    }
}
