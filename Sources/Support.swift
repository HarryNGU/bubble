// Shared bits: settings, logging, small UI helpers, coordinate conversion.

import AppKit

enum CameraBackground: String, CaseIterable {
    case off, blur, grey, clear
    var title: String {
        switch self {
        case .off: return "Off (real background)"
        case .blur: return "Blur"
        case .grey: return "Dark grey"
        case .clear: return "Clear (just you, no circle)"
        }
    }
}

enum Settings {
    static let d = UserDefaults.standard
    private static func bool(_ k: String, _ def: Bool) -> Bool { d.object(forKey: k) as? Bool ?? def }

    static var camera: Bool { get { bool("camera", true) } set { d.set(newValue, forKey: "camera") } }
    static var mic: Bool { get { bool("mic", true) } set { d.set(newValue, forKey: "mic") } }
    static var noiseSuppression: Bool { get { bool("noiseSuppression", true) } set { d.set(newValue, forKey: "noiseSuppression") } }
    static var systemAudio: Bool { get { bool("systemAudio", false) } set { d.set(newValue, forKey: "systemAudio") } }
    /// Chosen microphone's unique ID; empty = the Mac's current default input.
    static var micDevice: String { get { d.string(forKey: "micDevice") ?? "" } set { d.set(newValue, forKey: "micDevice") } }
    /// Name each recording from the page/window title (and, if allowed, what you said).
    static var autoName: Bool { get { bool("autoName", true) } set { d.set(newValue, forKey: "autoName") } }
    static var nameFromSpeech: Bool { get { bool("nameFromSpeech", true) } set { d.set(newValue, forKey: "nameFromSpeech") } }
    static var sounds: Bool { get { bool("sounds", true) } set { d.set(newValue, forKey: "sounds") } }
    /// Global start/stop shortcut: Carbon key code + Carbon modifier mask, and how to show it.
    /// Defaults to Option-Shift-R (kVK_ANSI_R = 15, optionKey|shiftKey = 0x0A00).
    static var hotKeyCode: UInt32 { get { UInt32(d.object(forKey: "hotKeyCode") as? Int ?? 15) } set { d.set(Int(newValue), forKey: "hotKeyCode") } }
    static var hotKeyMods: UInt32 { get { UInt32(d.object(forKey: "hotKeyMods") as? Int ?? 0x0A00) } set { d.set(Int(newValue), forKey: "hotKeyMods") } }
    static var hotKeyLabel: String { get { d.string(forKey: "hotKeyLabel") ?? "⌥⇧R" } set { d.set(newValue, forKey: "hotKeyLabel") } }
    static var countdown: Bool { get { bool("countdown", true) } set { d.set(newValue, forKey: "countdown") } }
    static var bubbleSize: CGFloat { get { d.object(forKey: "bubbleSize") as? CGFloat ?? 200 } set { d.set(newValue, forKey: "bubbleSize") } }
    static var background: CameraBackground {
        get { CameraBackground(rawValue: d.string(forKey: "background") ?? "") ?? .off }
        set { d.set(newValue.rawValue, forKey: "background") }
    }

    /// Edited reels, inside the recordings folder so they're easy to find and upload.
    static var reelsFolder: URL {
        let url = folder.appendingPathComponent("Reels", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// ~/Desktop/Bubble Recordings. Anything left in the old ~/Movies folder is moved over once.
    static var folder: URL {
        let fm = FileManager.default
        let url = fm.homeDirectoryForCurrentUser.appendingPathComponent("Desktop/Bubble Recordings", isDirectory: true)
        try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        let old = fm.homeDirectoryForCurrentUser.appendingPathComponent("Movies/Bubble Recordings", isDirectory: true)
        if let items = try? fm.contentsOfDirectory(at: old, includingPropertiesForKeys: nil) {
            for f in items where f.pathExtension == "mp4" {
                try? fm.moveItem(at: f, to: url.appendingPathComponent(f.lastPathComponent))
            }
            if (try? fm.contentsOfDirectory(atPath: old.path))?.allSatisfy({ $0.hasPrefix(".") }) ?? false {
                try? fm.removeItem(at: old)
            }
        }
        return url
    }
}

/// Appends a line to ~/Library/Logs/Bubble.log so problems can be traced.
let logQueue = DispatchQueue(label: "bubble.log")
func log(_ msg: String) {
    let line = "\(Date()) \(msg)\n"
    logQueue.async {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Bubble.log")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let h = try? FileHandle(forWritingTo: url) else { return }
        h.seekToEndOfFile()
        h.write(line.data(using: .utf8)!)
        try? h.close()
    }
}

func alert(_ text: String) {
    NSApp.activate(ignoringOtherApps: true)
    let a = NSAlert()
    a.messageText = "Bubble"
    a.informativeText = text
    a.runModal()
}

final class DragView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
}

final class BlockButton: NSButton {
    private var block: () -> Void = {}
    convenience init(title: String, action: @escaping () -> Void) {
        self.init(frame: .zero)
        self.title = title
        bezelStyle = .rounded
        block = action
        target = self
        self.action = #selector(fire)
    }
    @objc private func fire() { block() }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? CGMainDisplayID()
    }
    static func with(displayID id: CGDirectDisplayID) -> NSScreen? { screens.first { $0.displayID == id } }
    static var underMouse: NSScreen {
        let p = NSEvent.mouseLocation
        return screens.first { $0.frame.contains(p) } ?? main ?? screens[0]
    }
}

/// ScreenCaptureKit uses top-left-origin global coordinates; AppKit uses bottom-left.
func appKitRect(fromGlobalTopLeft r: CGRect) -> NSRect {
    let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
    return NSRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
}
