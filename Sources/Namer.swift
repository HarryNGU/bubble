// Names recordings automatically, entirely on the Mac:
//   1. Right away, from what was recorded: the Chrome page title, the window title, or the
//      app you were in.
//   2. A few seconds later, from what you said: Apple's on-device speech recognition makes a
//      transcript, and the most-used topic words are added to the name.
// Nothing is sent anywhere; if on-device recognition isn't available, step 2 is skipped.

import AppKit
import NaturalLanguage
import Speech

enum Namer {
    // MARK: Context (captured when recording starts)

    /// What was recorded: `title` is a real page/window title (strong), `app` is just the
    /// app's name, used only when nothing better is known.
    static func context(for source: CaptureSource) -> (title: String?, app: String?) {
        switch source {
        case .window(let id, _), .croppedWindow(let id, _, _):
            guard let w = windowInfo(id) else { return (nil, nil) }
            return (clean(w.title, app: w.app), w.app)
        case .app(_, let name):
            return (nil, name)
        case .screenUnderMouse, .display, .area:
            // The app you were working in (the picker never takes focus from it).
            guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid() else { return (nil, nil) }
            let name = app.localizedName
            return (frontWindow(of: app.processIdentifier).flatMap { clean($0, app: name ?? "") }, name)
        }
    }

    private static func windowInfo(_ id: CGWindowID) -> (title: String, app: String)? {
        guard let w = (CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]])?.first else { return nil }
        return (w[kCGWindowName as String] as? String ?? "", w[kCGWindowOwnerName as String] as? String ?? "")
    }

    private static func frontWindow(of pid: pid_t) -> String? {
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return info.first { ($0[kCGWindowOwnerPID as String] as? pid_t) == pid && ($0[kCGWindowLayer as String] as? Int) == 0
                            && !(($0[kCGWindowName as String] as? String) ?? "").isEmpty }?[kCGWindowName as String] as? String
    }

    /// "Getting Started with SwiftUI - Tutorials - Example Docs - Google Chrome"
    ///   → "Getting Started with SwiftUI"
    static func clean(_ raw: String, app: String) -> String? {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for suffix in [" - Google Chrome", " — Google Chrome", " - Safari", " — Mozilla Firefox", " - Microsoft Edge",
                       " - \(app)", " — \(app)", " | \(app)"] where t.hasSuffix(suffix) {
            t = String(t.dropLast(suffix.count))
        }
        // Never put an email address in a file name.
        t = t.replacingOccurrences(of: #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, with: "", options: .regularExpression)
        // Drop notification counts like "(3) Inbox".
        if let r = t.range(of: #"^\(\d+\)\s*"#, options: .regularExpression) { t.removeSubrange(r) }
        // Titles are usually "Page - Section - Site": keep the first meaningful part.
        let parts = t.components(separatedBy: " - ").flatMap { $0.components(separatedBy: " | ") }
            .flatMap { $0.components(separatedBy: " — ") }.flatMap { $0.components(separatedBy: " – ") }
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if let first = parts.first { t = first }
        // "Lesson Plan.docx" → "Lesson Plan"; "#exams-folder" → "exams-folder"
        if let r = t.range(of: #"\.(docx?|xlsx?|pptx?|pdf|key|pages|numbers|txt|md|swift|py|js|ts|html?)$"#,
                           options: [.regularExpression, .caseInsensitive]) { t.removeSubrange(r) }
        if t.hasPrefix("#") { t.removeFirst() }
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.count > 60 { t = shorten(t, to: 60) }
        let generic = ["new tab", "untitled", "home", "start page", "google", app.lowercased()]
        return t.count < 3 || generic.contains(t.lowercased()) ? nil : t
    }

    // MARK: Topics from speech

    /// On-device transcript of the recording's audio, or nil (no permission, no speech,
    /// or on-device recognition isn't available for your language).
    static func transcribe(_ url: URL) async -> String? {
        guard await authorized() else { log("naming: speech recognition not allowed"); return nil }
        guard let recognizer = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
            log("naming: on-device speech recognition not available")
            return nil
        }
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true  // never send audio to a server
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        return await withCheckedContinuation { (done: CheckedContinuation<String?, Never>) in
            var finished = false
            recognizer.recognitionTask(with: request) { result, error in
                guard !finished else { return }
                if let result, result.isFinal {
                    finished = true
                    done.resume(returning: result.bestTranscription.formattedString)
                } else if error != nil {
                    finished = true
                    done.resume(returning: nil)
                }
            }
        }
    }

    private static func authorized() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return true
        case .notDetermined:
            return await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) } }
        default: return false
        }
    }

    private static let filler: Set<String> = [
        "thing", "things", "way", "lot", "bit", "video", "today", "time", "something", "anything", "everything",
        "guy", "guys", "kind", "sort", "stuff", "people", "one", "ones", "okay", "yeah", "right", "part", "look",
        "screen", "recording", "minute", "second", "question", "example", "case", "point", "idea", "start", "end",
    ]

    /// The 1–3 topic words you used most, e.g. ["layout", "buttons"]. Proper nouns count double.
    static func keywords(from text: String) -> [String] {
        let tagger = NLTagger(tagSchemes: [.lexicalClass, .lemma, .nameType])
        tagger.string = text
        var score: [String: Double] = [:]
        var firstSeen: [String: Int] = [:]
        var display: [String: String] = [:]
        var index = 0
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .lexicalClass,
                             options: [.omitWhitespace, .omitPunctuation, .omitOther]) { tag, range in
            index += 1
            guard tag == .noun else { return true }
            let word = String(text[range])
            let lemma = (tagger.tag(at: range.lowerBound, unit: .word, scheme: .lemma).0?.rawValue ?? word).lowercased()
            guard lemma.count >= 3, !filler.contains(lemma) else { return true }
            let isName = tagger.tag(at: range.lowerBound, unit: .word, scheme: .nameType).0 != nil
            score[lemma, default: 0] += isName ? 2 : 1
            if firstSeen[lemma] == nil { firstSeen[lemma] = index; display[lemma] = isName ? word : lemma }
            return true
        }
        let words = text.split(whereSeparator: { $0.isWhitespace }).count
        let minScore: Double = words > 40 ? 2 : 1
        return score.filter { $0.value >= minScore }
            .sorted { $0.value != $1.value ? $0.value > $1.value : firstSeen[$0.key]! < firstSeen[$1.key]! }
            .prefix(3).map { display[$0.key]! }
    }

    // MARK: Title and file name

    static func title(context: String?, keywords: [String], app: String? = nil) -> String {
        let ctx = context?.trimmingCharacters(in: .whitespaces)
        let lowerCtx = ctx?.lowercased() ?? ""
        let fresh = keywords.filter { !lowerCtx.contains($0.lowercased()) }.map(capitalised)
        switch (ctx, fresh.isEmpty) {
        case let (c?, true): return c
        case let (c?, false): return shorten("\(c) – \(fresh.prefix(2).joined(separator: ", "))", to: 80)
        case (nil, false): return fresh.prefix(3).joined(separator: ", ")
        case (nil, true): return app.map { "\($0) recording" } ?? "Screen recording"
        }
    }

    /// Renames to "Title · 20 Oct 18.14.mp4" (adding " 2", " 3"… if taken). Returns the new URL.
    static func rename(_ url: URL, to title: String, recordedAt date: Date) -> URL? {
        let fmt = DateFormatter()
        fmt.dateFormat = "d MMM HH.mm"
        let safe = title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: " -")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        let base = "\(safe) · \(fmt.string(from: date))"
        let dir = url.deletingLastPathComponent()
        var target = dir.appendingPathComponent(base).appendingPathExtension("mp4")
        var n = 2
        while FileManager.default.fileExists(atPath: target.path), target != url {
            target = dir.appendingPathComponent("\(base) \(n)").appendingPathExtension("mp4")
            n += 1
        }
        if target == url { return url }
        do {
            try FileManager.default.moveItem(at: url, to: target)
            log("named: \(target.lastPathComponent)")
            return target
        } catch {
            log("naming: rename failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// The title part of a Bubble file name, for display.
    static func displayTitle(of url: URL) -> String {
        let name = url.deletingPathExtension().lastPathComponent
        if let r = name.range(of: " · ", options: .backwards) { return String(name[..<r.lowerBound]) }
        return name
    }

    private static func capitalised(_ s: String) -> String {
        s.first.map { String($0).uppercased() + s.dropFirst() } ?? s
    }

    private static func shorten(_ s: String, to max: Int) -> String {
        guard s.count > max else { return s }
        let cut = String(s.prefix(max))
        return (cut.range(of: " ", options: .backwards).map { String(cut[..<$0.lowerBound]) } ?? cut) + "…"
    }
}
