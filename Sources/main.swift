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

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let bubble = CameraBubble()
    private let recorder = Recorder()
    private var controls: ControlBar!
    private var recording = false
    private var busy = false
    private var titleTimer: Timer?
    private var mainHotKey: EventHotKeyRef?
    private var areaHotKey: EventHotKeyRef?
    private var shortcutMonitor: Any?
    private var lastHeard = Date()
    private var themeWatch: Any?

    private var source: CaptureSource = .screenUnderMouse
    private var launcher: NSWindow!
    private let model = UIModel()
    private var activeSince: Date?          // nil while paused
    private var accumulated: TimeInterval = 0
    private var restarting = false
    private var selftestSeconds: Double?
    private var selftestRestarted = false

    func applicationDidFinishLaunching(_ n: Notification) {
        let args = CommandLine.arguments
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
        registerHotKeys()
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
            showLauncher()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !recording { showLauncher() }
        return true
    }

    // MARK: Launcher window

    private func buildMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(item("Start / Finish Recording…", #selector(toggleClicked)))
        appMenu.addItem(item("Record Custom Area…", #selector(pickAreaAndRecord), key: "a", mods: [.option, .shift]))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Hide Bubble", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        appMenu.addItem(NSMenuItem(title: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        appMenu.addItem(item("Quit Bubble", #selector(quit), key: "q"))
        appItem.submenu = appMenu
        NSApp.mainMenu = main
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
        model.onCaptureShortcut = { [weak self] in self?.captureShortcut() }
    }

    private func buildLauncher() {
        let host = NSHostingView(rootView: HomeView(model: model))
        launcher = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 800),
                            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                            backing: .buffered, defer: false)
        launcher.titlebarAppearsTransparent = true
        launcher.titleVisibility = .hidden
        launcher.isMovableByWindowBackground = true
        launcher.isReleasedWhenClosed = false
        launcher.contentView = host
        launcher.setContentSize(NSSize(width: 380, height: 800))
        launcher.center()
    }

    private func showLauncher() {
        model.screenAllowed = CGPreflightScreenCaptureAccess()
        model.micDevices = MicCapture.devices()
        model.refreshRecents()
        NSApp.activate(ignoringOtherApps: true)
        launcher.makeKeyAndOrderFront(nil)
    }

    private func pickArea(then done: @escaping (Bool) -> Void) {
        launcher.orderOut(nil)
        let screen = NSScreen.underMouse
        AreaSelector.pick(on: screen) { [weak self] rect in
            guard let self else { return }
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
            menu.addItem(item("Done  (\(model.elapsedText))   \(model.shortcutLabel)", #selector(toggleClicked)))
            menu.addItem(item(model.paused ? "Resume" : "Pause", #selector(pauseClicked)))
            menu.addItem(item("Restart", #selector(restartClicked)))
            menu.addItem(item("Discard Recording", #selector(discardClicked)))
        } else {
            menu.addItem(item("Start Recording…   \(model.shortcutLabel)", #selector(toggleClicked)))
            menu.addItem(.separator())
            menu.addItem(item("Record Entire Screen", #selector(recordScreen)))
            menu.addItem(item("Record Custom Area…", #selector(pickAreaAndRecord), key: "a", mods: [.option, .shift]))
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
        Picker.run { [weak self] picked in
            guard let self else { return }
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
                runCountdown(on: screen, region: Self.region(of: target, screen: screen)) { self.beginCapture(on: screen, target: target) }
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
        lastHeard = Date()
        model.micSilent = false
        model.micLevel = 0
        // The control bar must be on screen before ScreenCaptureKit is asked to exclude it.
        controls.show(on: screen)
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
                controls.show(on: screen)
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
        model.refreshRecents()
        if restarting {
            restarting = false
            start()
            return
        }
        guard let url else { showLauncher(); return }
        guard !CommandLine.arguments.contains("--selftest") else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([url as NSURL])
        showSavedToast(on: NSScreen.underMouse, url: url)
        revealInFinder(url)
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
    @objc func quit() {
        if recording {
            stop(discard: false)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { NSApp.terminate(nil) }
        } else {
            NSApp.terminate(nil)
        }
    }

    // MARK: Global shortcuts (Carbon hot keys need no extra permission)
    //   main (default Option-Shift-R): picker / finish     Option-Shift-A: draw an area, then record

    private func registerHotKeys() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            log("hotkey \(hk.id) pressed")
            let id = hk.id
            DispatchQueue.main.async {
                guard let d = NSApp.delegate as? AppDelegate else { return }
                if id == 1 { d.toggle() } else { d.pickAreaAndRecord() }
            }
            return noErr
        }, 1, &spec, nil, nil)
        _ = registerMainHotKey()
        let status = RegisterEventHotKey(UInt32(kVK_ANSI_A), UInt32(optionKey | shiftKey),
                                         EventHotKeyID(signature: OSType(0x4255_424C), id: 2),
                                         GetApplicationEventTarget(), 0, &areaHotKey)
        log("hotkey 2 registered = \(status == noErr)")
    }

    private func registerMainHotKey() -> Bool {
        if let mainHotKey { UnregisterEventHotKey(mainHotKey) }
        mainHotKey = nil
        let status = RegisterEventHotKey(Settings.hotKeyCode, Settings.hotKeyMods,
                                         EventHotKeyID(signature: OSType(0x4255_424C), id: 1),
                                         GetApplicationEventTarget(), 0, &mainHotKey)
        log("hotkey 1 (\(Settings.hotKeyLabel)) registered = \(status == noErr)")
        return status == noErr
    }

    /// Click the shortcut in settings, then press a new combination (Esc cancels).
    private func captureShortcut() {
        guard shortcutMonitor == nil else { return }
        model.capturingShortcut = true
        if let mainHotKey { UnregisterEventHotKey(mainHotKey); self.mainHotKey = nil }
        shortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self else { return e }
            if e.keyCode == 53 { self.endShortcutCapture(); return nil }  // Esc
            let flags = e.modifierFlags.intersection([.command, .option, .control, .shift])
            guard !flags.subtracting(.shift).isEmpty else { NSSound.beep(); return nil }  // needs ⌘, ⌥ or ⌃
            let old = (Settings.hotKeyCode, Settings.hotKeyMods, Settings.hotKeyLabel)
            var carbon: UInt32 = 0
            if flags.contains(.command) { carbon |= UInt32(cmdKey) }
            if flags.contains(.option) { carbon |= UInt32(optionKey) }
            if flags.contains(.control) { carbon |= UInt32(controlKey) }
            if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
            Settings.hotKeyCode = UInt32(e.keyCode)
            Settings.hotKeyMods = carbon
            Settings.hotKeyLabel = Self.label(flags: flags, event: e)
            if !self.registerMainHotKey() {
                (Settings.hotKeyCode, Settings.hotKeyMods, Settings.hotKeyLabel) = old
                NSSound.beep()
                log("shortcut taken by another app; kept \(old.2)")
            }
            self.model.shortcutLabel = Settings.hotKeyLabel
            self.endShortcutCapture()
            return nil
        }
    }

    private func endShortcutCapture() {
        if let m = shortcutMonitor { NSEvent.removeMonitor(m) }
        shortcutMonitor = nil
        model.capturingShortcut = false
        if mainHotKey == nil { _ = registerMainHotKey() }
    }

    private static func label(flags: NSEvent.ModifierFlags, event e: NSEvent) -> String {
        var s = ""
        if flags.contains(.control) { s += "⌃" }
        if flags.contains(.option) { s += "⌥" }
        if flags.contains(.shift) { s += "⇧" }
        if flags.contains(.command) { s += "⌘" }
        let special: [UInt16: String] = [49: "Space", 36: "↩", 48: "⇥", 51: "⌫", 117: "⌦", 123: "←", 124: "→", 125: "↓", 126: "↑",
                                         122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
                                         101: "F9", 109: "F10", 103: "F11", 111: "F12"]
        if let name = special[e.keyCode] { return s + name }
        // Use the unshifted key so ⌥ symbols (like ® for ⌥R) show as the plain letter.
        let key = e.charactersIgnoringModifiers?.uppercased() ?? "?"
        return s + key
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
