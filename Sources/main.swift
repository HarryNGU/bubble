// Bubble: a free, local Loom-style screen recorder for macOS 15+.
// Choose a screen, window, app or custom area; record with a camera bubble (optional
// background blur / grey / cut-out) and a noise-suppressed microphone, straight to MP4.

import AppKit
import AVFoundation
import Carbon.HIToolbox
import SwiftUI
import Combine
import ScreenCaptureKit

/// A recordable window or app, read synchronously from the window server.
struct WindowChoice {
    let id: CGWindowID
    let pid: pid_t
    let app: String
    let title: String
}

func listWindows() -> [WindowChoice] {
    let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let info = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else { return [] }
    let me = getpid()
    let all: [(WindowChoice, Bool)] = info.compactMap { w in
        guard (w[kCGWindowLayer as String] as? Int) == 0,
              let id = w[kCGWindowNumber as String] as? CGWindowID,
              let pid = w[kCGWindowOwnerPID as String] as? pid_t, pid != me,
              let boundsDict = w[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: boundsDict),
              bounds.width >= 240, bounds.height >= 160 else { return nil }  // skip toolbars and helper strips
        let app = w[kCGWindowOwnerName as String] as? String ?? "App"
        let name = (w[kCGWindowName as String] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return (WindowChoice(id: id, pid: pid, app: app, title: name ?? app), name != nil)
    }
    // Untitled windows are usually overlays (e.g. Chrome's full-screen toolbar); hide them
    // when the same app also has a titled window.
    let appsWithTitles = Set(all.filter { $0.1 }.map { $0.0.pid })
    return all.filter { $0.1 || !appsWithTitles.contains($0.0.pid) }.map { $0.0 }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem!
    private let bubble = CameraBubble()
    private let recorder = Recorder()
    private let dictation = DictationController()
    private lazy var assistant = AssistantController()
    private var controls: ControlBar!
    private var recording = false { didSet { if oldValue != recording { buildMainMenu() } } }
    private var busy = false
    private var titleTimer: Timer?
    private var lastHeard = Date()
    private var themeWatch: Any?

    private var source: CaptureSource = .screenUnderMouse
    private var launcher: NSWindow!
    private let model = UIModel()
    private var activeSince: Date?          // nil while paused
    private var accumulated: TimeInterval = 0
    private var restarting = false
    private var quitting = false
    private var recordingContext: (title: String?, app: String?) = (nil, nil)  // captured at start, for naming
    private var recordingStartedAt = Date()
    private var selftestSeconds: Double?
    private var selftestRestarted = false

    func applicationDidFinishLaunching(_ n: Notification) {
        let args = CommandLine.arguments
        // Only one Bubble at a time: a second copy hands over to the first and quits.
        // (Test runs pass "--" options and are allowed alongside.)
        if !args.contains(where: { $0.hasPrefix("--") }),
           let other = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .first(where: { $0 != NSRunningApplication.current }), let url = other.bundleURL {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            log("another Bubble is already running; handing over")
            NSApp.terminate(nil)
            return
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.autosaveName = "BubbleStatusItem"
        setIcon()
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        wireModel()
        Sounds.preload()
        controls = ControlBar(model: model)
        recorder.onMicLevel = { [weak self] level in
            guard let self else { return }
            self.model.micLevel = level
            if level > 0.12 { self.lastHeard = Date() }  // above about -53 dB
        }
        themeWatch = ThemeStore.shared.$current.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.bubble.refreshStyle() }
        }
        recorder.onFinish = { [weak self] url in self?.finished(url) }
        recorder.onError = { [weak self] err in self?.failed(err) }

        buildMainMenu()
        buildLauncher()
        let keys = ShortcutCenter.shared
        keys.onTrigger = { [weak self] a in
            guard let self else { return }
            switch a {
            case .record: self.toggle()
            case .area: self.pickAreaAndRecord()
            case .dictate: self.dictation.toggle()
            case .assist: self.assistant.toggle()
            case .assistAsk: break  // handled by the panel while it is open
            case .assistVoice:
                if !self.assistant.isShown { self.assistant.show() }
                self.assistant.model.toggleTalk()
            }
        }
        keys.onChange = { [weak self] in self?.dictation.applyShortcut(); self?.assistant.refreshKeys(); self?.buildMainMenu() }
        keys.install()
        BubbleToolServer.shared.start()
        if !args.contains(where: { $0.hasPrefix("--") }) {
            Updates.checkIfDue { [weak self] in self?.buildMainMenu() }
        }
        dictation.ownTextTarget = { [weak self] text in self?.assistant.takeDictation(text) ?? false }
        dictation.start()
        // Load Whisper now, so the first dictation is as accurate as the rest.
        if Settings.wantsDictate || Settings.wantsAssist { WhisperServer.shared.warmUp() }
        log("launched; screen access = \(CGPreflightScreenCaptureAccess())")
        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
            // A real ScreenCaptureKit query is what puts Bubble in the Screen Recording list.
            Task {
                do { _ = try await SCShareableContent.current; log("screen capture query ok") }
                catch { log("screen capture query: \(error.localizedDescription)") }
            }
        }
        if Settings.mic { AVCaptureDevice.requestAccess(for: .audio) { ok in log("mic access = \(ok)") } }
        if Settings.camera { bubble.show(on: NSScreen.underMouse) }

        if args.contains("--countdowntest") {  // plays the countdown only (for screenshots)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { runCountdown(on: NSScreen.underMouse, region: args.contains("chrome") ? Picker.chromeSourceForTesting().flatMap { AppDelegate.region(of: $0, screen: NSScreen.underMouse) } : nil) { log("countdown done") } }
            return
        }
        if args.contains("--pickertest") {  // opens the picker on launch (for screenshots)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.startPicker() }
            return
        }
        // Testing: `--selftest N [area|window]` records N seconds without countdown.
        if let i = args.firstIndex(of: "--selftest"), i + 1 < args.count, let secs = Double(args[i + 1]) {
            let mode = i + 2 < args.count ? args[i + 2] : "screen"
            if mode == "area" {
                let s = NSScreen.underMouse
                source = .area(s.displayID, CGRect(x: 100, y: 120, width: 800, height: 500))
            } else if mode == "chrome", let s = Picker.chromeSourceForTesting() {
                source = s
            } else if mode == "window", let w = listWindows().first {
                source = .window(w.id, "\(w.app): \(w.title)")
            }
            selftestSeconds = secs
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.start() }
        } else {
            if !launchedAtLogin || !Settings.onboarded { showLauncher() } else { log("started at login") }
            // Testing: `--dicttest` dictates for 8 seconds (say something), then delivers.
            if args.contains("--dicttest") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.dictation.toggle() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 11) { self.dictation.toggle() }
            }
            // Testing: `--assisttest` opens the assistant and starts listening.
            if args.contains("--assisttest") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.assistant.show() }
                if let i = args.firstIndex(of: "--assisttest"), i + 1 < args.count {
                    let q = args[i + 1]
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.assistant.model.seeScreen = false; self.assistant.model.ask(q) }
                }
            }
            // Testing: `--edit <file name>` opens that recording in the reel editor.
            if let i = args.firstIndex(of: "--edit"), i + 1 < args.count {
                model.editing = Settings.folder.appendingPathComponent(args[i + 1])
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !recording { showLauncher() }
        return true
    }

    // MARK: Launcher window

    /// The standard Mac menu bar: Bubble, File, Edit, View, Window and Help. Items for Bubble's own
    /// shortcuts show the keys you chose, and the menus are rebuilt when you change them.
    private func buildMainMenu() {
        let main = NSMenu()
        func menu(_ title: String, _ items: [NSMenuItem]) -> NSMenu {
            let m = NSMenu(title: title)
            items.forEach(m.addItem)
            let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            holder.submenu = m
            main.addItem(holder)
            return m
        }
        func std(_ title: String, _ action: Selector?, _ key: String = "", _ mods: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            return i
        }
        func mine(_ title: String, _ sel: Selector, shortcut: ShortcutAction? = nil, key: String = "", mods: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
            let i = item(title, sel, key: key, mods: mods)
            if let a = shortcut, let (k, m) = Self.keyEquivalent(ShortcutCenter.shared[a]) { i.keyEquivalent = k; i.keyEquivalentModifierMask = m }
            return i
        }

        // Bubble
        let update = Updates.available.map { mine("Update to Bubble \($0.version)…", #selector(openUpdate)) }
        let services = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        services.submenu = NSMenu(title: "Services")
        NSApp.servicesMenu = services.submenu
        _ = menu("Bubble", [
            mine("About Bubble", #selector(showAbout)),
            update ?? mine("Check for Updates…", #selector(checkForUpdates)),
            .separator(),
            mine("Settings…", #selector(showSettings), key: ","),
            .separator(),
            services,
            .separator(),
            std("Hide Bubble", #selector(NSApplication.hide(_:)), "h"),
            std("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            std("Show All", #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            mine("Quit Bubble", #selector(quit), key: "q"),
        ])

        // File
        _ = menu("File", [
            mine(recording ? "Finish Recording" : "New Recording…", #selector(toggleClicked), shortcut: .record),
            mine("Record an Area…", #selector(pickAreaAndRecord), shortcut: .area),
            mine("Record Entire Screen", #selector(recordScreen)),
            .separator(),
            mine("Open Recordings Folder", #selector(openFolder), key: "o", mods: [.command, .shift]),
            .separator(),
            std("Close Window", #selector(NSWindow.performClose(_:)), "w"),
        ])

        // Edit (⌘C / ⌘V / ⌘A in text fields come from here; macOS adds Dictation and Emoji itself)
        let redo = std("Redo", Selector(("redo:")), "z", [.command, .shift])
        _ = menu("Edit", [
            std("Undo", Selector(("undo:")), "z"), redo, .separator(),
            std("Cut", #selector(NSText.cut(_:)), "x"),
            std("Copy", #selector(NSText.copy(_:)), "c"),
            std("Paste", #selector(NSText.paste(_:)), "v"),
            std("Paste and Match Style", #selector(NSTextView.pasteAsPlainText(_:)), "v", [.command, .option, .shift]),
            std("Delete", #selector(NSText.delete(_:))),
            std("Select All", #selector(NSText.selectAll(_:)), "a"),
            .separator(),
            mine("Copy Last Dictation", #selector(copyLastDictation)),
        ])

        // View: the pages of Bubble's window, then the floating helpers.
        var pages: [NSMenuItem] = []
        for (n, page) in [Page.home, .recordings, .assistant, .dictation, .snippets, .style].enumerated() {
            let i = mine(page.title, #selector(showPage(_:)), key: "\(n + 1)")
            i.representedObject = page.rawValue
            pages.append(i)
        }
        _ = menu("View", pages + [
            .separator(),
            mine("Ask Bubble", #selector(assistClicked), shortcut: .assist),
            mine("Camera Bubble", #selector(toggleCamera)),
            .separator(),
            std("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
        ])

        // Window
        let win = menu("Window", [
            std("Minimise", #selector(NSWindow.performMiniaturize(_:)), "m"),
            std("Zoom", #selector(NSWindow.performZoom(_:))),
            .separator(),
            mine("Bubble", #selector(showLauncherClicked), key: "0"),
            .separator(),
            std("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))),
        ])
        NSApp.windowsMenu = win

        // Help (macOS adds its search field)
        let help = menu("Help", [
            mine("Bubble Help", #selector(openHelp), key: "?"),
            mine("Keyboard Shortcuts", #selector(openShortcutsHelp)),
            mine("Testing Guide", #selector(openTestingGuide)),
            .separator(),
            mine("Report a Problem…", #selector(reportProblem)),
            mine("Privacy Policy", #selector(openPrivacy)),
            mine("Bubble on GitHub", #selector(openGitHub)),
        ])
        NSApp.helpMenu = help
        NSApp.mainMenu = main
    }

    /// The menu key for one of Bubble's shortcuts, when it's an ordinary key combination.
    /// (Bubble's global shortcut fires first, so the menu item is only there to show the keys.)
    static func keyEquivalent(_ s: Shortcut) -> (String, NSEvent.ModifierFlags)? {
        guard !s.isDoubleTap else { return nil }
        var mods: NSEvent.ModifierFlags = []
        var rest = Substring(s.label)
        let symbols: [(Character, NSEvent.ModifierFlags)] = [("⌃", .control), ("⌥", .option), ("⇧", .shift), ("⌘", .command)]
        while let c = rest.first, let m = symbols.first(where: { $0.0 == c }) { mods.insert(m.1); rest = rest.dropFirst() }
        let key = rest.trimmingCharacters(in: .whitespaces)
        guard !mods.isEmpty else { return nil }
        if key == "↩" { return ("\r", mods) }
        guard key.count == 1 else { return nil }
        return (key.lowercased(), mods)
    }

    @objc func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        let credits = NSMutableAttributedString(string: "Your personal assistant, living on your Mac.\nFree and open source. No account, no tracking.\n\n",
                                                attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
        credits.append(NSAttributedString(string: "harryngu.github.io/bubble", attributes: [.link: URL(string: "https://harryngu.github.io/bubble/")!, .font: NSFont.systemFont(ofSize: 11)]))
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        credits.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: credits.length))
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits, .applicationName: "Bubble"])
    }

    @objc func showSettings() { showPageNamed(Page.settings.rawValue) }
    @objc func showPage(_ sender: NSMenuItem) { if let p = sender.representedObject as? String { showPageNamed(p) } }
    private func showPageNamed(_ p: String) {
        UserDefaults.standard.set(p, forKey: "page")
        showLauncher()
    }

    @objc func checkForUpdates() { Updates.check(manual: true) { [weak self] in self?.buildMainMenu() } }
    @objc func openUpdate() { if let u = Updates.available { NSWorkspace.shared.open(u.page) } }

    private func web(_ path: String) { NSWorkspace.shared.open(URL(string: "https://harryngu.github.io/bubble/" + path)!) }
    @objc func openHelp() { web("get-started.html") }
    @objc func openShortcutsHelp() { web("get-started.html#shortcuts") }
    @objc func openPrivacy() { web("privacy.html") }
    @objc func openTestingGuide() { NSWorkspace.shared.open(URL(string: "https://github.com/HarryNGU/bubble/blob/main/TESTING.md")!) }
    @objc func openGitHub() { NSWorkspace.shared.open(URL(string: "https://github.com/HarryNGU/bubble")!) }
    @objc func reportProblem() {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        let body = "What happened:\n\nWhat you expected:\n\nSteps to try it:\n\n---\nBubble \(v), macOS \(os)"
        var c = URLComponents(string: "https://github.com/HarryNGU/bubble/issues/new")!
        c.queryItems = [URLQueryItem(name: "body", value: body)]
        if let u = c.url { NSWorkspace.shared.open(u) }
    }

    /// Connects the SwiftUI views to the app's behaviour.
    private func wireModel() {
        model.onCamera = { [weak self] on in
            guard let self else { return }
            on ? self.bubble.show(on: NSScreen.underMouse) : self.bubble.hide()
        }
        model.onBackground = { [weak self] bg in self?.bubble.setBackground(bg) }
        model.onSize = { [weak self] size in self?.bubble.setSize(size) }
        model.onStart = { [weak self] in self?.startPicker() }
        model.onOpenFolder = { [weak self] in self?.openFolder() }
        model.onPause = { [weak self] in self?.togglePause() }
        model.onRestart = { [weak self] in self?.restart() }
        model.onDiscard = { [weak self] in self?.stop(discard: true) }
        model.onDone = { [weak self] in self?.stop(discard: false) }
        model.onDictate = { [weak self] in self?.dictation.toggle() }
        model.onAssist = { [weak self] in self?.assistant.show() }
        model.onAssistKeysChanged = { [weak self] in self?.assistant.refreshKeys() }
        model.onAllowAccessibility = {
            Inserter.requestTrust()
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        }
    }

    private func buildLauncher() {
        let host = NSHostingView(rootView: MainView(model: model, dictation: dictation.model))
        launcher = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 740),
                            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                            backing: .buffered, defer: false)
        launcher.titlebarAppearsTransparent = true
        launcher.titleVisibility = .hidden
        launcher.title = "Bubble"
        launcher.isReleasedWhenClosed = false
        launcher.collectionBehavior = [.fullScreenPrimary]
        launcher.minSize = NSSize(width: 860, height: 560)
        launcher.contentView = host
        launcher.delegate = self
        launcher.setFrameAutosaveName("BubbleMainWindow")
        if !launcher.setFrameUsingName("BubbleMainWindow") { launcher.center() }
    }

    private func showLauncher() {
        model.screenAllowed = CGPreflightScreenCaptureAccess()
        model.micDevices = MicCapture.devices()
        model.refreshRecents()
        AppPresence.mainWindow(true)
        NSApp.activate(ignoringOtherApps: true)
        launcher.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        if (notification.object as? NSWindow) === launcher { AppPresence.mainWindow(false) }
    }

    /// Started by "Open Bubble when you log in": stay quietly in the menu bar.
    private var launchedAtLogin: Bool {
        guard let e = NSAppleEventManager.shared().currentAppleEvent, e.eventID == kAEOpenApplication else { return false }
        return e.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    private func pickArea(then done: @escaping (Bool) -> Void) {
        launcher.orderOut(nil)
        let screen = NSScreen.underMouse
        ShortcutCenter.shared.escapeCancels { AreaSelector.cancelActive() }
        AreaSelector.pick(on: screen) { [weak self] rect in
            guard let self else { return }
            ShortcutCenter.shared.escapeCancels(nil)
            if let rect {
                self.source = .area(screen.displayID, rect)
                log("source: \(self.source.label)")
            }
            done(rect != nil)
        }
    }

    // MARK: Menu bar menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if recording {
            menu.addItem(item("Done  (\(model.elapsedText))   \(ShortcutCenter.shared.label(.record))", #selector(toggleClicked)))
            menu.addItem(item(model.paused ? "Resume" : "Pause", #selector(pauseClicked)))
            menu.addItem(item("Restart", #selector(restartClicked)))
            menu.addItem(item("Discard Recording", #selector(discardClicked)))
        } else {
            menu.addItem(item("Start Recording…   \(ShortcutCenter.shared.label(.record))", #selector(toggleClicked)))
            menu.addItem(.separator())
            menu.addItem(item("Record Entire Screen", #selector(recordScreen)))
            menu.addItem(item("Record Custom Area…   \(ShortcutCenter.shared.label(.area))", #selector(pickAreaAndRecord)))
            let winMenu = NSMenu(), appMenu = NSMenu()
            var seen = Set<pid_t>()
            for w in listWindows().prefix(40) {
                let t = w.title == w.app ? w.app : "\(w.app): \(w.title)"
                let i = item(String(t.prefix(70)), #selector(recordChosen(_:)))
                i.representedObject = Box(.window(w.id, t))
                winMenu.addItem(i)
                if seen.insert(w.pid).inserted {
                    let a = item(w.app, #selector(recordChosen(_:)))
                    a.representedObject = Box(.app(w.pid, w.app))
                    appMenu.addItem(a)
                }
            }
            let wi = NSMenuItem(title: "Record a Window", action: nil, keyEquivalent: "")
            wi.submenu = winMenu
            menu.addItem(wi)
            let ai = NSMenuItem(title: "Record an App", action: nil, keyEquivalent: "")
            ai.submenu = appMenu
            menu.addItem(ai)
        }
        menu.addItem(.separator())
        let dk = ShortcutCenter.shared.label(.dictate)
        menu.addItem(item(dictation.model.phase == .listening ? "Finish Dictation   \(dk)" : "Dictate   \(dk)", #selector(dictateClicked)))
        menu.addItem(item("Copy Last Dictation", #selector(copyLastDictation), enabled: !dictation.model.last.isEmpty))
        menu.addItem(.separator())
        menu.addItem(item("Ask Bubble   \(ShortcutCenter.shared.label(.assist))", #selector(assistClicked)))
        if assistant.model.listening { menu.addItem(item("Stop Listening", #selector(stopListeningClicked))) }
        menu.addItem(.separator())
        menu.addItem(item("Camera Bubble", #selector(toggleCamera), on: Settings.camera))
        let bgMenu = NSMenu()
        for bg in CameraBackground.allCases {
            let i = item(bg.title, #selector(menuBackground(_:)), on: Settings.background == bg)
            i.representedObject = bg.rawValue
            bgMenu.addItem(i)
        }
        let bgItem = NSMenuItem(title: "Camera Background", action: nil, keyEquivalent: "")
        bgItem.submenu = bgMenu
        menu.addItem(bgItem)
        menu.addItem(item("Microphone", #selector(toggleMic), on: Settings.mic, enabled: !recording))
        menu.addItem(item("Noise Suppression", #selector(toggleNoise), on: Settings.noiseSuppression, enabled: !recording))
        menu.addItem(.separator())
        menu.addItem(item("Show Bubble Window", #selector(showLauncherClicked)))
        menu.addItem(item("Open Recordings Folder", #selector(openFolder)))
        menu.addItem(item("Quit Bubble", #selector(quit), key: "q"))
    }

    private final class Box: NSObject {
        let source: CaptureSource
        init(_ s: CaptureSource) { source = s }
    }

    private func item(_ title: String, _ sel: Selector, key: String = "", mods: NSEvent.ModifierFlags = [.command],
                      on: Bool? = nil, enabled: Bool = true) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: enabled ? sel : nil, keyEquivalent: key)
        i.keyEquivalentModifierMask = mods
        i.target = self
        if let on { i.state = on ? .on : .off }
        return i
    }

    private func setIcon() {
        guard let button = statusItem.button else { return }
        if recording {
            statusItem.length = NSStatusItem.variableLength
            let img = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: "Bubble recording")
            button.image = img?.withSymbolConfiguration(.init(paletteColors: [.white, .systemRed]))
            button.title = " " + (model.paused ? "Paused" : model.elapsedText)
        } else {
            statusItem.length = NSStatusItem.squareLength
            let img = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "Bubble")
            img?.isTemplate = true
            button.image = img
            button.title = ""
        }
        button.imagePosition = .imageLeading
    }

    // MARK: Recording flow

    @objc func toggleClicked() { toggle() }
    @objc func discardClicked() { stop(discard: true) }
    @objc func pauseClicked() { togglePause() }
    @objc func dictateClicked() { dictation.toggle() }
    @objc func assistClicked() { assistant.show() }
    @objc func stopListeningClicked() { if assistant.model.listening { assistant.model.toggleListening() } }
    @objc func copyLastDictation() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(dictation.model.last, forType: .string)
    }
    @objc func restartClicked() { restart() }
    @objc func showLauncherClicked() { showLauncher() }
    @objc func recordScreen() { source = .screenUnderMouse; start() }
    @objc func recordChosen(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? Box else { return }
        source = box.source
        start()
    }
    @objc func pickAreaAndRecord() {
        guard !recording, !busy else { return }
        pickArea { [weak self] ok in if ok { self?.start() } }
    }

    func toggle() { recording ? stop(discard: false) : startPicker() }

    /// Loom-style: hover what you want, click "Record this".
    func startPicker() {
        guard !recording, !busy else { return }
        launcher.orderOut(nil)
        ShortcutCenter.shared.escapeCancels { Picker.cancelActive() }
        Picker.run { [weak self] picked in
            guard let self else { return }
            ShortcutCenter.shared.escapeCancels(nil)
            guard let picked else { self.showLauncher(); return }
            self.source = picked
            self.start()
        }
    }

    private func start() {
        log("start requested: \(source.label) (recording=\(recording), busy=\(busy))")
        guard !recording, !busy else { return }
        busy = true
        launcher.orderOut(nil)
        let screen: NSScreen
        switch source {
        case .display(let id), .area(let id, _): screen = NSScreen.with(displayID: id) ?? NSScreen.underMouse
        default: screen = NSScreen.underMouse  // the picker leaves the mouse over the chosen window
        }
        if Settings.camera { bubble.moveOnto(screen) }
        let go = { (target: CaptureSource) in
            if Settings.countdown && !CommandLine.arguments.contains("--selftest") {
                // Esc during the 3-2-1 cancels before anything is recorded.
                let cancel = runCountdown(on: screen, region: Self.region(of: target, screen: screen)) {
                    ShortcutCenter.shared.escapeCancels(nil)
                    self.beginCapture(on: screen, target: target)
                }
                ShortcutCenter.shared.escapeCancels { [weak self] in
                    cancel()
                    self?.busy = false
                    log("countdown cancelled")
                }
            } else {
                self.beginCapture(on: screen, target: target)
            }
        }
        go(source)
    }

    /// Where the source sits on screen (AppKit coordinates), so the countdown can tint exactly
    /// what will be recorded: a Chrome tab without its toolbar, a window, an area or a screen.
    static func region(of source: CaptureSource, screen: NSScreen) -> NSRect? {
        func windowFrame(_ id: CGWindowID) -> CGRect? {
            guard let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]],
                  let bd = info.first?[kCGWindowBounds as String] as? NSDictionary else { return nil }
            return CGRect(dictionaryRepresentation: bd)
        }
        switch source {
        case .screenUnderMouse:
            return screen.frame
        case .display(let id):
            return NSScreen.with(displayID: id)?.frame ?? screen.frame
        case .area(let id, let r):
            let s = NSScreen.with(displayID: id) ?? screen
            return NSRect(x: s.frame.minX + r.minX, y: s.frame.maxY - r.maxY, width: r.width, height: r.height)
        case .window(let id, _):
            return windowFrame(id).map(appKitRect(fromGlobalTopLeft:))
        case .croppedWindow(let id, let inset, _):
            guard var f = windowFrame(id) else { return nil }
            f.origin.y += inset
            f.size.height -= inset
            return appKitRect(fromGlobalTopLeft: f)
        case .app:
            return screen.frame
        }
    }

    private func beginCapture(on screen: NSScreen, target: CaptureSource) {
        Sounds.start()  // finishes before the first frame is written, so it isn't in the video
        recordingContext = Namer.context(for: target)
        recordingStartedAt = Date()
        lastHeard = Date()
        model.micSilent = false
        model.micLevel = 0
        // The control bar must be on screen before ScreenCaptureKit is asked to exclude it.
        controls.show(on: screen, follow: target.isWholeScreen)
        let exclude = [controls.panel.windowNumber]
        let bubbleWindows = Settings.camera ? [bubble.panel.windowNumber] : []
        Task { @MainActor in
            do {
                try await recorder.start(source: target, excluding: exclude, bubble: bubbleWindows,
                                         mic: Settings.mic, noiseSuppression: Settings.noiseSuppression,
                                         systemAudio: Settings.systemAudio)
                if Settings.camera, let r = recorder.recordedRect { bubble.keepInside(r) }
                recording = true
                busy = false
                accumulated = 0
                activeSince = Date()
                model.elapsed = 0
                model.paused = false
                model.saving = false
                controls.show(on: screen, follow: target.isWholeScreen)
                setIcon()
                titleTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
                if CommandLine.arguments.contains("restart"), selftestSeconds != nil, !selftestRestarted {  // restart once, 2s in
                    selftestRestarted = true
                    selftestSeconds = 4
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.restart() }
                } else if let secs = selftestSeconds {
                    DispatchQueue.main.asyncAfter(deadline: .now() + secs) { self.stop(discard: false) }
                    if CommandLine.arguments.contains("pause") {  // pause 2s in, for 3s
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.togglePause() }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { self.togglePause() }
                    }
                }
            } catch {
                busy = false
                controls.hide()
                failed(error)
            }
        }
    }

    private func tick() {
        model.elapsed = accumulated + (activeSince.map { Date().timeIntervalSince($0) } ?? 0)
        let silent = Settings.mic && !model.paused && Date().timeIntervalSince(lastHeard) > 3
        if silent != model.micSilent { model.micSilent = silent; if silent { log("mic: silent for 3 s") } }
        setIcon()
    }

    private func togglePause() {
        guard recording else { return }
        if let since = activeSince {
            accumulated += Date().timeIntervalSince(since)
            activeSince = nil
            model.paused = true
        } else {
            activeSince = Date()
            model.paused = false
        }
        recorder.setPaused(model.paused)
        tick()
    }

    /// Throw away this take and start again on the same tab/window/area.
    private func restart() {
        guard recording else { return }
        log("restart")
        restarting = true
        stop(discard: true)
    }

    private func stop(discard: Bool) {
        guard recording else { return }
        if !discard { DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { Sounds.stop() } }
        recording = false
        titleTimer?.invalidate()
        controls.hide()
        setIcon()
        Task { await recorder.stop(discarding: discard) }
    }

    private func finished(_ url: URL?) {
        log("finished: \(url?.path ?? "discarded")")
        if quitting {
            quitting = false
            NSApp.reply(toApplicationShouldTerminate: true)
            return
        }
        model.refreshRecents()
        if restarting {
            restarting = false
            start()
            return
        }
        guard var url else { showLauncher(); return }
        let testing = CommandLine.arguments.contains("--selftest")

        // 1. Instantly: name it after what was recorded.
        let context = recordingContext
        if Settings.autoName, let named = Namer.rename(url, to: Namer.title(context: context.title, keywords: [], app: context.app),
                                                       recordedAt: recordingStartedAt) {
            url = named
        }
        if !testing {
            copyToClipboard(url)
            showSavedToast(on: NSScreen.underMouse, url: url)
            revealInFinder(url)
        } else {
            // A test run records once and quits, so it can't be left running in test mode
            // (no countdown, recordings that stop by themselves).
            log("selftest finished; quitting")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { NSApp.terminate(nil) }
            return
        }
        model.refreshRecents()

        // 2. A few seconds later: add the topics you talked about (on-device speech recognition).
        guard Settings.autoName, Settings.nameFromSpeech, Settings.mic else { return }
        let started = recordingStartedAt
        Task { @MainActor in
            guard let transcript = await Namer.transcribe(url) else { return }
            let words = Namer.keywords(from: transcript)
            log("naming: \(transcript.split(separator: " ").count) words heard, topics \(words)")
            guard !words.isEmpty else { return }
            let better = Namer.title(context: context.title, keywords: words, app: context.app)
            guard better != Namer.displayTitle(of: url), let renamed = Namer.rename(url, to: better, recordedAt: started) else { return }
            if !testing { copyToClipboard(renamed) }
            model.refreshRecents()
        }
    }

    private func copyToClipboard(_ url: URL) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([url as NSURL])
    }

    /// Opens Bubble Recordings in Finder with the new video selected, and brings Finder to
    /// the front even if you were in a full-screen app (which is its own Space).
    private func revealInFinder(_ url: URL) {
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        if let finder = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.finder") {
            NSWorkspace.shared.open([url.deletingLastPathComponent()], withApplicationAt: finder, configuration: cfg) { _, _ in
                DispatchQueue.main.async { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    private func failed(_ error: Error) {
        log("failed: \(error)")
        restarting = false
        recording = false
        titleTimer?.invalidate()
        controls.hide()
        setIcon()
        guard !CommandLine.arguments.contains("--selftest") else { return }
        showLauncher()
        let ns = error as NSError
        if ns.domain == "com.apple.ScreenCaptureKit.SCStreamErrorDomain" && ns.code == -3801 {
            alert("Bubble needs Screen Recording permission.\n\nIn System Settings → Privacy & Security → Screen & System Audio Recording, turn on Bubble (remove any old Bubble entry first), then quit and reopen Bubble.")
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        } else {
            alert("Recording stopped: \(error.localizedDescription)")
        }
    }

    // MARK: Settings actions

    @objc func toggleCamera() { model.camera.toggle() }
    @objc func menuBackground(_ sender: NSMenuItem) {
        model.background = CameraBackground(rawValue: sender.representedObject as? String ?? "off") ?? .off
    }
    @objc func toggleMic() { model.mic.toggle() }
    @objc func toggleNoise() { model.noise.toggle() }
    @objc func openFolder() { NSWorkspace.shared.open(Settings.folder) }
    @objc func quit() { NSApp.terminate(nil) }

    /// Background helpers (Whisper's voice server, Claude Code) stop with Bubble.
    func applicationWillTerminate(_ n: Notification) {
        WhisperServer.shared.stop()
        assistant.model.session.shutdown()
    }

    /// However Bubble is asked to quit (menu, ⌘Q, logging out, another app), a recording in
    /// progress is finished and saved first; Bubble quits once the file is complete.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard recording else { return .terminateNow }
        log("quit requested while recording: saving first")
        quitting = true
        stop(discard: false)
        // Never hang the logout: give up after 30 seconds.
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard self?.quitting == true else { return }
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

// Top-level code runs on the main thread.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)  // the window shows the Dock icon while it's open
    app.run()
}
