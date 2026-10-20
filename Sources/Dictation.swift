// Voice typing. Double-tap Option anywhere: Bubble listens (Apple's on-device speech
// recognition), tidies what you said, expands snippets, then types it into the text box
// you're in. If no text box is focused, the text goes to "Last dictation" in Bubble's window
// and onto the clipboard. Double-tap Option again to finish; Esc cancels.
//
// Needs Accessibility access (to notice Option taps in other apps and to type into them).

import AppKit
import ApplicationServices
import AVFoundation
import Speech
import SwiftUI

// MARK: - Double-tap Option

final class DoubleOptionMonitor {
    var onDoubleTap: (() -> Void)?
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
            if flags == .option {
                optionDownAt = Date()
                otherInput = false
            } else if flags.isEmpty, let down = optionDownAt {
                optionDownAt = nil
                guard !otherInput, Date().timeIntervalSince(down) < 0.35 else { lastTap = nil; return }
                if let last = lastTap, Date().timeIntervalSince(last) < 0.45 {
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
    private var session: AVCaptureSession?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let queue = DispatchQueue(label: "bubble.dictation")
    private var latest = ""
    private var finished: ((String) -> Void)?
    private var lastLevel = Date.distantPast

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
        DispatchQueue.main.async { self.onLevel?(level) }
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
    @Published var hasAPIKey = Keychain.apiKey != nil
}

final class DictationController {
    let model = DictationModel()
    private let monitor = DoubleOptionMonitor()
    private var speech: SpeechSession?
    private var hud: NSPanel?
    private var targetApp: String?
    private var trustTimer: Timer?

    func start() {
        monitor.onDoubleTap = { [weak self] in self?.toggle() }
        monitor.onEscape = { [weak self] in self?.cancel() }
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
            Sounds.tick()
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
        Sounds.tick()
        s.stop { [weak self] raw in
            guard let self else { return }
            self.speech = nil
            Task { @MainActor in await self.deliver(raw) }
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
        case .listening: return model.partial.isEmpty ? "Double-tap ⌥ to finish · Esc to cancel" : model.partial
        case .done: return model.last
        default: return nil
        }
    }
}
