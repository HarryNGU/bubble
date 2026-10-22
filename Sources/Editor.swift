// The reel editor: one recording in, up to four videos out (Original, 1:1, 9:16, 16:9). Bubble cuts the pauses
// straight away; captions follow once the words are transcribed. Change anything with the
// controls, or ask Claude in the chat ("cut the part about pricing", "faster", "zoom in on the
// left"). Saving writes the reels to Bubble Recordings/Reels.

import AppKit
import AVFoundation
import AVKit
import SwiftUI

struct ChatLine: Codable, Identifiable, Equatable {
    var id = UUID()
    var fromUser: Bool
    var text: String
}

@MainActor
final class ReelEditor: ObservableObject {
    let url: URL
    @Published var plan: EditPlan { didSet { if plan != oldValue { savePlan(); scheduleRebuild() } } }
    @Published var size: ReelSize = .vertical { didSet { if size != oldValue { scheduleRebuild() } } }
    @Published var aspect: CGFloat = 9.0 / 16.0
    /// Which shapes "Save" writes.
    @Published var toSave: Set<ReelSize> = Set(ReelSize.allCases)
    @Published var analysis: Analysis?
    @Published var status: String? = "Finding the pauses…"
    @Published var transcribing: Double?
    @Published var editedLength: Double = 0
    @Published var cutCount = 0
    @Published var chat: [ChatLine] = []
    @Published var thinking = false
    @Published var exporting: (size: ReelSize, progress: Double)?
    @Published var saved: [URL] = []
    @Published var error: String?
    @Published var replaceOriginal = false
    let player = AVPlayer()
    private var rebuildTask: Task<Void, Never>?
    private var undo: [EditPlan] = []

    init(url: URL) {
        self.url = url
        plan = Analyzer.load(EditPlan.self, Analyzer.cacheURL(for: url, "plan")) ?? EditPlan(title: Namer.displayTitle(of: url))
        chat = Analyzer.load([ChatLine].self, Analyzer.cacheURL(for: url, "chat")) ?? []
    }

    var canUndo: Bool { !undo.isEmpty }

    func start() {
        Task {
            var a: Analysis
            if let cached = Analyzer.load(Analysis.self, Analyzer.cacheURL(for: url, "analysis")) {
                a = cached
            } else {
                do { a = try await Analyzer.levels(of: url) } catch {
                    self.error = "Couldn't read this recording: \(error.localizedDescription)"; status = nil; return
                }
                Analyzer.save(a, Analyzer.cacheURL(for: url, "analysis"))
            }
            analysis = a
            status = nil
            rebuild()
            if a.words == nil || (a.engine != "whisper" && Whisper.ready) { await transcribe() }
        }
    }

    // MARK: Captions

    @Published var whisperReady = Whisper.ready
    @Published var modelDownload: Double?

    /// Whisper when it's set up (accurate), otherwise Apple's on-device recognition.
    func transcribe() async {
        guard var a = analysis, transcribing == nil else { return }
        transcribing = 0
        let url = self.url
        let report: @Sendable (Double) -> Void = { p in Task { @MainActor in self.transcribing = p } }
        if Whisper.ready {
            do {
                a.words = try await Whisper.transcribe(url, voiced: Cutter.voiced(a), progress: report)
                a.engine = "whisper"
            } catch {
                log("whisper: \(error.localizedDescription)")
                self.error = "Whisper couldn't transcribe this one, so captions use Apple's recognition."
            }
        }
        if a.engine != "whisper" {
            let snapshot = a
            a.words = await Task.detached { await Analyzer.words(of: url, analysis: snapshot, progress: report) }.value
            a.engine = "apple"
        }
        analysis = a
        Analyzer.save(a, Analyzer.cacheURL(for: url, "analysis"))
        transcribing = nil
        rebuild()
    }

    func downloadModel() {
        guard modelDownload == nil else { return }
        modelDownload = 0
        Task {
            do {
                try await Whisper.downloadModel { p in Task { @MainActor in self.modelDownload = p } }
                whisperReady = Whisper.ready
                modelDownload = nil
                if whisperReady { await transcribe() }
            } catch {
                modelDownload = nil
                self.error = "Couldn't download the Whisper model: \(error.localizedDescription)"
            }
        }
    }

    func checkWhisper() {
        whisperReady = Whisper.ready
        if whisperReady, analysis?.engine != "whisper" { Task { await transcribe() } }
    }

    var originalLength: Double { analysis?.duration ?? 0 }
    var spans: [TimeSpan] { analysis.map { Cutter.spans($0, plan) } ?? [] }

    private func scheduleRebuild() {
        rebuildTask?.cancel()
        rebuildTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            self?.rebuild()
        }
    }

    func rebuild() {
        guard let a = analysis else { return }
        let spans = Cutter.spans(a, plan)
        cutCount = max(0, spans.count - 1)
        let plan = self.plan, size = self.size, url = self.url
        let wasAt = player.currentTime(), playing = player.rate > 0
        Task {
            do {
                let b = try await ReelBuilder.build(url: url, spans: spans, plan: plan, size: size, words: a.words)
                let item = AVPlayerItem(asset: b.composition)
                item.videoComposition = b.video
                item.audioTimePitchAlgorithm = .spectral
                self.player.replaceCurrentItem(with: item)
                self.editedLength = b.duration
                self.aspect = b.renderSize.width / b.renderSize.height
                if wasAt.seconds < b.duration { await self.player.seek(to: wasAt, toleranceBefore: .zero, toleranceAfter: .zero) }
                if playing { self.player.play() }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    func change(_ f: (inout EditPlan) -> Void) {
        undo.append(plan)
        f(&plan)
    }

    func undoLast() {
        guard let p = undo.popLast() else { return }
        plan = p
    }

    private func savePlan() { Analyzer.save(plan, Analyzer.cacheURL(for: url, "plan")) }

    // MARK: Chat

    func send(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !thinking, let a = analysis else { return }
        chat.append(ChatLine(fromUser: true, text: t))
        thinking = true
        Task {
            do {
                let (newPlan, reply) = try await ReelAssistant.ask(t, history: Array(chat.dropLast().suffix(12)), plan: plan, analysis: a,
                                                                    spans: spans, editedLength: editedLength)
                if newPlan != plan { change { $0 = newPlan } }
                chat.append(ChatLine(fromUser: false, text: reply))
            } catch {
                chat.append(ChatLine(fromUser: false, text: error.localizedDescription))
            }
            thinking = false
            Analyzer.save(chat, Analyzer.cacheURL(for: url, "chat"))
        }
    }

    func clearChat() {
        chat = []
        Analyzer.save(chat, Analyzer.cacheURL(for: url, "chat"))
    }

    // MARK: Saving

    /// Writes all three sizes to Bubble Recordings/Reels, then (if asked) moves the original to the Bin.
    func save() {
        guard exporting == nil, let a = analysis else { return }
        player.pause()
        saved = []
        error = nil
        let spans = Cutter.spans(a, plan), plan = self.plan, url = self.url
        let safe = plan.title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: " -")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            let sizes = ReelSize.allCases.filter { toSave.contains($0) }
            for size in sizes {
                exporting = (size, 0)
                let out = Settings.reelsFolder.appendingPathComponent("\(safe.isEmpty ? "Reel" : safe) · \(size.fileTag).mp4")
                do {
                    let b = try await ReelBuilder.build(url: url, spans: spans, plan: plan, size: size, words: a.words)
                    try await ReelBuilder.export(b, to: out) { p in Task { @MainActor in self.exporting = (size, p) } }
                    saved.append(out)
                    log("reel saved: \(out.lastPathComponent)")
                } catch {
                    self.error = "Couldn't save the \(size.ratio) reel: \(error.localizedDescription)"
                    log("reel export failed: \(error)")
                    break
                }
            }
            exporting = nil
            if saved.count == sizes.count {
                Sounds.stop()
                if replaceOriginal { NSWorkspace.shared.recycle([url]) { _, _ in } }
            }
        }
    }
}

// MARK: - Claude

enum ReelAssistant {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private static let tool: [String: Any] = [
        "name": "update_edit",
        "description": "Apply the edit. Leave out any field that should stay as it is.",
        "input_schema": [
            "type": "object",
            "properties": [
                "reply": ["type": "string", "description": "One or two short sentences to the user saying what you changed, in plain words."],
                "max_pause": ["type": "number", "description": "Seconds of silence left between phrases (0.1 very tight, 0.25 sharp, 0.5 relaxed). 0 keeps every pause uncut."],
                "removed": ["type": "array", "description": "The full list of parts of the ORIGINAL video to cut, in seconds. Include the existing ones you want to keep cut.",
                            "items": ["type": "object", "properties": ["start": ["type": "number"], "end": ["type": "number"]], "required": ["start", "end"]]],
                "kept": ["type": "array", "description": "The full list of parts of the ORIGINAL video to keep even if silent (e.g. a demo without talking).",
                         "items": ["type": "object", "properties": ["start": ["type": "number"], "end": ["type": "number"]], "required": ["start", "end"]]],
                "speed": ["type": "number", "description": "Playback speed, 0.75 to 2."],
                "captions": ["type": "boolean"],
                "caption_position": ["type": "string", "enum": ["top", "middle", "bottom"]],
                "zoom": ["type": "number", "description": "1 shows the whole recording; up to 4 crops in towards the focus point."],
                "focus_x": ["type": "number", "description": "Where to crop towards, 0 left to 1 right."],
                "focus_y": ["type": "number", "description": "Where to crop towards, 0 top to 1 bottom."],
                "title": ["type": "string", "description": "File name for the reels."],
            ],
            "required": ["reply"],
        ] as [String: Any],
    ]

    static func ask(_ message: String, history: [ChatLine], plan: EditPlan, analysis a: Analysis,
                    spans: [TimeSpan], editedLength: Double) async throws -> (EditPlan, String) {
        guard let key = Keychain.apiKey, !key.isEmpty else { throw Failure(message: "Add your Anthropic API key below to chat.") }
        let system = """
        You edit screen recordings into short social media reels inside Bubble, a Mac app. The user tells you what \
        they want; you change the edit with the update_edit tool. Bubble already cuts silences automatically using \
        max_pause, lays the recording out as Original, 1:1, 9:16 and 16:9 over a blurred background, and adds captions. Times \
        are always seconds in the ORIGINAL recording. Use the transcript to find the parts the user means. To shorten \
        a video, cut repeated takes, false starts, tangents and dead air, and keep the core message. Never invent \
        content. If the request can't be done with these settings, say so in the reply and change nothing.
        """
        var transcript = ""
        if let words = a.words, !words.isEmpty {
            var line = "", lineStart = words[0].start
            for w in words {
                if line.isEmpty { lineStart = w.start }
                line += (line.isEmpty ? "" : " ") + w.text
                if line.count > 90 || w.text.last.map({ ".!?".contains($0) }) == true {
                    transcript += String(format: "[%.1f] %@\n", lineStart, line); line = ""
                }
            }
            if !line.isEmpty { transcript += String(format: "[%.1f] %@\n", lineStart, line) }
        } else {
            transcript = "(Not transcribed yet, or no speech.)"
        }
        let current: [String: Any] = [
            "max_pause": plan.maxPause ?? 0, "speed": plan.speed, "captions": plan.captions,
            "caption_position": plan.captionPosition, "zoom": plan.zoom, "focus_x": plan.focusX, "focus_y": plan.focusY,
            "title": plan.title, "removed": plan.removed.map { ["start": $0.start, "end": $0.end] },
            "kept": plan.kept.map { ["start": $0.start, "end": $0.end] },
        ]
        let currentJSON = (try? JSONSerialization.data(withJSONObject: current, options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let earlier = history.map { ($0.fromUser ? "User: " : "You: ") + $0.text }.joined(separator: "\n")
        let user = """
        <video>
        Original length: \(String(format: "%.1f", a.duration)) s. Current edit: \(String(format: "%.1f", editedLength)) s in \(spans.count) pieces.
        Current settings: \(currentJSON)
        </video>
        <transcript>
        \(transcript)</transcript>
        \(earlier.isEmpty ? "" : "<earlier_chat>\n\(earlier)\n</earlier_chat>\n")
        User's request: \(message)
        """
        let body: [String: Any] = [
            "model": "claude-opus-5-5",
            "max_tokens": 8000,
            "output_config": ["effort": "medium"],
            "fallbacks": "default",
            "system": system,
            "tools": [tool],
            "tool_choice": ["type": "tool", "name": "update_edit"],
            "messages": [["role": "user", "content": user]],
        ]
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 90
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            let msg = (json["error"] as? [String: Any])?["message"] as? String ?? "HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)"
            log("reel chat: \(msg)")
            throw Failure(message: "Claude couldn't answer: \(msg)")
        }
        if json["stop_reason"] as? String == "refusal" { throw Failure(message: "Claude declined that request.") }
        guard let input = (json["content"] as? [[String: Any]])?.first(where: { $0["type"] as? String == "tool_use" })?["input"] as? [String: Any] else {
            throw Failure(message: "Claude didn't return an edit. Try rephrasing.")
        }
        return (apply(input, to: plan, duration: a.duration), input["reply"] as? String ?? "Done.")
    }

    private static func apply(_ i: [String: Any], to plan: EditPlan, duration: Double) -> EditPlan {
        var p = plan
        func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { min(hi, max(lo, v)) }
        func spans(_ v: Any?) -> [TimeSpan]? {
            (v as? [[String: Any]])?.compactMap { d in
                guard let s = (d["start"] as? NSNumber)?.doubleValue, let e = (d["end"] as? NSNumber)?.doubleValue, e > s else { return nil }
                return TimeSpan(start: clamp(s, 0, duration), end: clamp(e, 0, duration))
            }
        }
        if let v = i["max_pause"] as? NSNumber { p.maxPause = v.doubleValue <= 0 ? nil : clamp(v.doubleValue, 0.05, 2) }
        if let r = spans(i["removed"]) { p.removed = r }
        if let k = spans(i["kept"]) { p.kept = k }
        if let v = i["speed"] as? NSNumber { p.speed = clamp(v.doubleValue, 0.75, 2) }
        if let v = i["captions"] as? Bool { p.captions = v }
        if let v = i["caption_position"] as? String, ["top", "middle", "bottom"].contains(v) { p.captionPosition = v }
        if let v = i["zoom"] as? NSNumber { p.zoom = clamp(v.doubleValue, 1, 4) }
        if let v = i["focus_x"] as? NSNumber { p.focusX = clamp(v.doubleValue, 0, 1) }
        if let v = i["focus_y"] as? NSNumber { p.focusY = clamp(v.doubleValue, 0, 1) }
        if let v = i["title"] as? String, !v.trimmingCharacters(in: .whitespaces).isEmpty { p.title = v }
        return p
    }
}

// MARK: - View

struct EditorPage: View {
    let url: URL
    let onClose: () -> Void
    @StateObject private var ed: ReelEditor
    @State private var message = ""
    @State private var apiKey = ""
    @State private var hasKey = Keychain.hasKey

    init(url: URL, onClose: @escaping () -> Void) {
        self.url = url
        self.onClose = onClose
        _ed = StateObject(wrappedValue: ReelEditor(url: url))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            header
            if let e = ed.error {
                Label(e, systemImage: "exclamationmark.triangle.fill").font(.system(size: 13)).foregroundStyle(.orange)
            }
            HStack(alignment: .top, spacing: 28) {
                preview.frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: 18) {
                    summary
                    controls
                    if !ed.whisperReady { whisperCard }
                    chatBox
                    savedNote
                }
                .frame(width: 380)
            }
        }
        .onAppear { ed.start(); hasKey = Keychain.hasKey }
        .onDisappear { ed.player.pause() }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            Button(action: onClose) {
                Image(systemName: "chevron.left").font(.system(size: 13, weight: .semibold))
                    .frame(width: 30, height: 30).background(Circle().fill(Palette.card))
            }
            .buttonStyle(.plain).help("Back to recordings")
            VStack(alignment: .leading, spacing: 2) {
                TextField("Title", text: Binding(get: { ed.plan.title }, set: { v in ed.change { $0.title = v } }))
                    .textFieldStyle(.plain).font(.system(size: 24, weight: .semibold))
                Text("Reels are saved in Bubble Recordings › Reels, ready to upload.").font(.system(size: 13)).foregroundStyle(Palette.subtle)
            }
            Spacer()
            if ed.canUndo { SecondaryButton(title: "Undo", icon: "arrow.uturn.backward") { ed.undoLast() } }
            PrimaryButton(title: ed.exporting == nil ? "Save \(ed.toSave.count) video\(ed.toSave.count == 1 ? "" : "s")" : "Saving…", icon: "square.and.arrow.down") { ed.save() }
                .disabled(ed.analysis == nil || ed.exporting != nil || ed.toSave.isEmpty)
        }
    }

    private var preview: some View {
        VStack(spacing: 14) {
            HStack(spacing: 8) {
                ForEach(ReelSize.allCases) { s in SizeChip(size: s, selected: ed.size == s) { ed.size = s } }
            }
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.black)
                if ed.analysis != nil {
                    PlayerView(player: ed.player)
                } else {
                    VStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(ed.status ?? "").font(.system(size: 13)).foregroundStyle(.white.opacity(0.7))
                    }
                }
            }
            .aspectRatio(ed.aspect, contentMode: .fit)
            .frame(maxHeight: 720)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            if let p = ed.transcribing {
                HStack(spacing: 8) {
                    ProgressView(value: p).frame(width: 140)
                    Text("\(ed.whisperReady ? "Writing captions with Whisper" : "Writing captions")… \(Int(p * 100))%").font(.system(size: 12)).foregroundStyle(Palette.subtle)
                }
            }
        }
    }

    private var summary: some View {
        HStack(spacing: 0) {
            stat("Original", time(ed.originalLength))
            Rectangle().fill(Palette.border).frame(width: 1, height: 34)
            stat("Edited", time(ed.editedLength))
            Rectangle().fill(Palette.border).frame(width: 1, height: 34)
            stat("Pauses cut", "\(ed.cutCount)")
        }
        .padding(.vertical, 14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Palette.card))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.border))
        .overlay(alignment: .bottom) {
            if let ex = ed.exporting {
                ProgressView(value: (Double(ReelSize.allCases.filter { ed.toSave.contains($0) }.firstIndex(of: ex.size) ?? 0) + ex.progress) / Double(max(1, ed.toSave.count)))
                    .padding(.horizontal, 12).offset(y: 14)
            }
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(spacing: 3) {
            Text(value).font(.system(size: 18, weight: .semibold, design: .rounded)).monospacedDigit()
            Text(label).font(.system(size: 11.5)).foregroundStyle(Palette.subtle)
        }
        .frame(maxWidth: .infinity)
    }

    private var controls: some View {
        VStack(spacing: 0) {
            SettingRow(title: "Pauses") {
                SwiftUI.Picker("", selection: Binding(get: { ed.plan.maxPause.map { $0 <= 0.15 ? 1 : $0 <= 0.3 ? 2 : 3 } ?? 0 },
                                                      set: { v in ed.change { $0.maxPause = [nil, 0.12, 0.25, 0.5][v] } })) {
                    Text("Keep").tag(0); Text("Tight").tag(1); Text("Sharp").tag(2); Text("Relaxed").tag(3)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 220)
            }
            SettingRow(title: "Speed") {
                SwiftUI.Picker("", selection: Binding(get: { ed.plan.speed }, set: { v in ed.change { $0.speed = v } })) {
                    Text("1×").tag(1.0); Text("1.1×").tag(1.1); Text("1.25×").tag(1.25); Text("1.5×").tag(1.5)
                    if ![1.0, 1.1, 1.25, 1.5].contains(ed.plan.speed) { Text(String(format: "%.2g×", ed.plan.speed)).tag(ed.plan.speed) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 220)
            }
            SettingRow(title: "Captions") {
                HStack(spacing: 10) {
                    SwiftUI.Picker("", selection: Binding(get: { ed.plan.captionPosition }, set: { v in ed.change { $0.captionPosition = v } })) {
                        Text("Top").tag("top"); Text("Middle").tag("middle"); Text("Bottom").tag("bottom")
                    }
                    .labelsHidden().frame(width: 100).disabled(!ed.plan.captions)
                    Toggle("", isOn: Binding(get: { ed.plan.captions }, set: { v in ed.change { $0.captions = v } }))
                        .toggleStyle(.switch).controlSize(.small).labelsHidden().tint(Theme.accent)
                }
            }
            SettingRow(title: "Zoom", divider: ed.plan.zoom > 1.01) {
                Slider(value: Binding(get: { ed.plan.zoom }, set: { v in ed.plan.zoom = v }), in: 1...3,
                       onEditingChanged: { began in if began { ed.change { _ in } } })
                    .frame(width: 220).tint(Theme.accent)
            }
            if ed.plan.zoom > 1.01 {
                SettingRow(title: "Focus", subtitle: "Where to zoom in.", divider: false) {
                    VStack(spacing: 4) {
                        Slider(value: Binding(get: { ed.plan.focusX }, set: { ed.plan.focusX = $0 }), in: 0...1) { Text("↔") }
                        Slider(value: Binding(get: { 1 - ed.plan.focusY }, set: { ed.plan.focusY = 1 - $0 }), in: 0...1) { Text("↕") }
                    }
                    .frame(width: 220).tint(Theme.accent)
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 12).fill(Palette.card))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.border))
    }

    /// Sets up accurate captions: the whisper-cli tool, then the model.
    private var whisperCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Make captions accurate", systemImage: "captions.bubble").font(.system(size: 13, weight: .semibold))
            Text("Captions now use Apple's basic recognition, which gets a lot wrong. Whisper is free, far more accurate and runs on your Mac.")
                .font(.system(size: 12)).foregroundStyle(Palette.subtle).fixedSize(horizontal: false, vertical: true)
            if Whisper.binary == nil {
                HStack(spacing: 8) {
                    Text("1. In Terminal: brew install whisper-cpp").font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                    Spacer()
                    SecondaryButton(title: "Copy") { copy("brew install whisper-cpp") }
                }
            }
            HStack(spacing: 8) {
                if let p = ed.modelDownload {
                    ProgressView(value: p).frame(maxWidth: .infinity)
                    Text("\(Int(p * 100))%").font(.system(size: 12)).monospacedDigit().foregroundStyle(Palette.subtle)
                } else if !Whisper.hasModel {
                    Text("\(Whisper.binary == nil ? "2." : "1.") Get the model (\(Whisper.modelSize))").font(.system(size: 12))
                    Spacer()
                    SecondaryButton(title: "Download") { ed.downloadModel() }
                } else {
                    Text("Model downloaded.").font(.system(size: 12)).foregroundStyle(Palette.subtle)
                    Spacer()
                    SecondaryButton(title: "Check again") { ed.checkWhisper() }
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Palette.card))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.border))
    }

    private var chatBox: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Ask Claude to edit", systemImage: "sparkles").font(.system(size: 13, weight: .semibold))
                Spacer()
                if !ed.chat.isEmpty {
                    Button("Clear") { ed.clearChat() }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Palette.subtle)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 11)
            Rectangle().fill(Palette.border).frame(height: 1)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if ed.chat.isEmpty {
                            Text("Try “make it under 60 seconds”, “cut the bit where I restart”, “captions at the top” or “zoom in on the left”.")
                                .font(.system(size: 12.5)).foregroundStyle(Palette.subtle)
                        }
                        ForEach(ed.chat) { line in
                            Text(line.text).font(.system(size: 13)).textSelection(.enabled)
                                .padding(.horizontal, 11).padding(.vertical, 8)
                                .foregroundStyle(line.fromUser ? Palette.onInk : Palette.ink)
                                .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(line.fromUser ? Palette.ink : Palette.canvas))
                                .frame(maxWidth: .infinity, alignment: line.fromUser ? .trailing : .leading)
                                .id(line.id)
                        }
                        if ed.thinking {
                            HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("Editing…").font(.system(size: 12)).foregroundStyle(Palette.subtle) }
                                .id("thinking")
                        }
                    }
                    .padding(14)
                }
                .frame(minHeight: 150, maxHeight: 280)
                .onChange(of: ed.chat.count) { if let last = ed.chat.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } } }
            }
            Rectangle().fill(Palette.border).frame(height: 1)
            if hasKey {
                HStack(spacing: 8) {
                    TextField("Describe a change…", text: $message, axis: .vertical)
                        .textFieldStyle(.plain).font(.system(size: 13)).lineLimit(1...4)
                        .onSubmit(send)
                    Button(action: send) {
                        Image(systemName: "arrow.up").font(.system(size: 12, weight: .bold)).foregroundStyle(Palette.onInk)
                            .frame(width: 26, height: 26).background(Circle().fill(Palette.ink))
                    }
                    .buttonStyle(.plain)
                    .disabled(message.trimmingCharacters(in: .whitespaces).isEmpty || ed.thinking || ed.analysis == nil)
                }
                .padding(12)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("The chat uses Claude with your own Anthropic API key (from console.anthropic.com). It's kept in your Mac's Keychain and also powers AI polish for dictation. Only the transcript and settings are sent, never the video.")
                        .font(.system(size: 12)).foregroundStyle(Palette.subtle).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        SecureField("sk-ant-…", text: $apiKey).textFieldStyle(.roundedBorder)
                        PrimaryButton(title: "Save") {
                            Keychain.setAPIKey(apiKey.trimmingCharacters(in: .whitespacesAndNewlines))
                            apiKey = ""
                            hasKey = Keychain.hasKey
                        }
                        .disabled(apiKey.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                .padding(12)
            }
        }
        .background(RoundedRectangle(cornerRadius: 12).fill(Palette.card))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.border))
    }

    @ViewBuilder private var savedNote: some View {
        if !ed.saved.isEmpty && ed.exporting == nil {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("\(ed.saved.count) video\(ed.saved.count == 1 ? "" : "s") saved").font(.system(size: 13, weight: .medium))
                Spacer()
                SecondaryButton(title: "Show in Finder", icon: "folder") { NSWorkspace.shared.activateFileViewerSelecting(ed.saved) }
            }
        } else if ed.exporting == nil {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 14) {
                    Text("Save").font(.system(size: 12.5, weight: .medium))
                    ForEach(ReelSize.allCases) { s in
                        Toggle(s.ratio, isOn: Binding(get: { ed.toSave.contains(s) },
                                                      set: { on in if on { ed.toSave.insert(s) } else { ed.toSave.remove(s) } }))
                            .toggleStyle(.checkbox).font(.system(size: 12.5))
                    }
                }
                Toggle("Move the original to the Bin after saving", isOn: $ed.replaceOriginal)
                    .toggleStyle(.checkbox).font(.system(size: 12.5)).foregroundStyle(Palette.subtle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func send() {
        let t = message
        message = ""
        ed.send(t)
    }

    private func time(_ s: Double) -> String {
        guard s.isFinite, s > 0 else { return "–" }
        let i = Int(s.rounded())
        return i >= 3600 ? String(format: "%d:%02d:%02d", i / 3600, i / 60 % 60, i % 60) : String(format: "%d:%02d", i / 60, i % 60)
    }
}

struct PlayerView: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.player = player
        v.controlsStyle = .floating
        v.videoGravity = .resizeAspect
        return v
    }
    func updateNSView(_ v: AVPlayerView, context: Context) { if v.player !== player { v.player = player } }
}

/// A shape choice drawn like Instagram's crop menu: the ratio and a little outline of it.
struct SizeChip: View {
    let size: ReelSize
    let selected: Bool
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: size.icon).font(.system(size: 13, weight: .medium))
                VStack(alignment: .leading, spacing: 0) {
                    Text(size.ratio).font(.system(size: 13, weight: .semibold))
                    Text(size.use).font(.system(size: 10.5)).foregroundStyle(selected ? Palette.onInk.opacity(0.7) : Palette.subtle)
                }
            }
            .foregroundStyle(selected ? Palette.onInk : Palette.ink)
            .padding(.horizontal, 12).frame(height: 42)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(selected ? Palette.ink : (hover ? Palette.selected : Palette.card)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Palette.border))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}
