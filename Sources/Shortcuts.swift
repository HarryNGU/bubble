// Global shortcuts. Every action has one shortcut, changed by clicking it anywhere it's shown
// and pressing new keys. A shortcut is either a key combination (a Carbon hot key, which needs
// no permission) or, for dictation, a double-tap of a modifier such as ⌥ (noticed by the
// dictation monitor, which needs Accessibility to see it in other apps).

import AppKit
import Carbon.HIToolbox

enum ShortcutAction: String, CaseIterable, Identifiable {
    case record, area, dictate, assist, assistVoice, assistAsk
    var id: String { rawValue }
    var hotKeyID: UInt32 { switch self { case .record: 1; case .area: 2; case .dictate: 3; case .assist: 4; case .assistAsk: 5; case .assistVoice: 6 } }
    /// Only active while Ask Bubble is on screen (the panel registers it itself).
    var panelOnly: Bool { self == .assistAsk }
    var title: String {
        switch self {
        case .record: "Start / finish recording"
        case .area: "Record an area"
        case .dictate: "Dictate"
        case .assist: "Show / hide Ask Bubble"
        case .assistAsk: "Ask about the screen"
        case .assistVoice: "Talk to Ask Bubble"
        }
    }
    /// Double-tapping a modifier needs the Accessibility-backed monitor, which only dictation has.
    var allowsDoubleTap: Bool { self == .dictate }
}

struct Shortcut: Codable, Equatable {
    var keyCode: UInt32 = 0
    var mods: UInt32 = 0          // Carbon modifier mask
    var tapModifier: UInt = 0     // NSEvent.ModifierFlags raw value; non-zero = double-tap this key
    var label: String

    var isDoubleTap: Bool { tapModifier != 0 }
    var tapFlags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: tapModifier) }
    /// The key to tap once to finish, e.g. "⌥".
    var tapSymbol: String { ShortcutCenter.symbol(tapFlags) }

    static func standard(_ a: ShortcutAction) -> Shortcut {
        switch a {
        case .record:
            // Carry over the shortcut chosen before shortcuts were stored this way.
            Shortcut(keyCode: Settings.hotKeyCode, mods: Settings.hotKeyMods, label: Settings.hotKeyLabel)
        case .area: Shortcut(keyCode: UInt32(kVK_ANSI_A), mods: UInt32(optionKey | shiftKey), label: "⌥⇧A")
        case .dictate: Shortcut(tapModifier: NSEvent.ModifierFlags.option.rawValue, label: "⌥ ⌥")
        case .assist: Shortcut(keyCode: UInt32(kVK_ANSI_Backslash), mods: UInt32(optionKey), label: "⌥\\")
        case .assistAsk: Shortcut(keyCode: UInt32(kVK_Return), mods: UInt32(cmdKey), label: "⌘↩")
        case .assistVoice: Shortcut(keyCode: UInt32(kVK_ANSI_Backslash), mods: UInt32(optionKey | shiftKey), label: "⌥⇧\\")
        }
    }

    func clashes(with o: Shortcut) -> Bool {
        isDoubleTap || o.isDoubleTap ? tapModifier == o.tapModifier : (keyCode == o.keyCode && mods == o.mods)
    }
}

final class ShortcutCenter: ObservableObject {
    static let shared = ShortcutCenter()

    @Published private(set) var shortcuts: [ShortcutAction: Shortcut] = [:]
    @Published private(set) var capturing: ShortcutAction?
    var onTrigger: ((ShortcutAction) -> Void)?
    var onChange: (() -> Void)?

    private var refs: [ShortcutAction: EventHotKeyRef] = [:]
    private var escapeRef: EventHotKeyRef?
    private var tempRefs: [UInt32: EventHotKeyRef] = [:]
    private var tempHandlers: [UInt32: () -> Void] = [:]
    private var onEscape: (() -> Void)?
    private static let escapeID: UInt32 = 9
    private var captureMonitor: Any?
    private var tapDown: (flags: NSEvent.ModifierFlags, at: Date)?
    private var lastTap: (flags: NSEvent.ModifierFlags, at: Date)?
    private static let modifiers: [NSEvent.ModifierFlags] = [.option, .command, .control, .shift, .function]

    private init() {
        for a in ShortcutAction.allCases {
            if let data = Settings.d.data(forKey: "shortcut." + a.rawValue), let s = try? JSONDecoder().decode(Shortcut.self, from: data) {
                shortcuts[a] = s
            } else {
                shortcuts[a] = .standard(a)
            }
        }
    }

    subscript(a: ShortcutAction) -> Shortcut { shortcuts[a] ?? .standard(a) }
    func label(_ a: ShortcutAction) -> String { self[a].label }

    func install() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let id = hk.id
            log("hotkey \(id) pressed")
            DispatchQueue.main.async {
                if id == ShortcutCenter.escapeID { ShortcutCenter.shared.escapePressed(); return }
                if let h = ShortcutCenter.shared.tempHandlers[id] { h(); return }
                guard let a = ShortcutAction.allCases.first(where: { $0.hotKeyID == id }) else { return }
                ShortcutCenter.shared.onTrigger?(a)
            }
            return noErr
        }, 1, &spec, nil, nil)
        ShortcutAction.allCases.forEach { register($0) }
    }

    @discardableResult
    private func register(_ a: ShortcutAction) -> Bool {
        unregister(a)
        let s = self[a]
        guard !s.isDoubleTap, !a.panelOnly else { return true }
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(s.keyCode, s.mods, EventHotKeyID(signature: OSType(0x4255_424C), id: a.hotKeyID),
                                         GetApplicationEventTarget(), 0, &ref)
        if status == noErr { refs[a] = ref }
        log("hotkey \(a.rawValue) (\(s.label)) registered = \(status == noErr)")
        return status == noErr
    }

    private func unregister(_ a: ShortcutAction) {
        if let r = refs[a] { UnregisterEventHotKey(r) }
        refs[a] = nil
    }

    // MARK: Keys that only exist while a panel is up

    /// Registers global keys (ids 20 and up) until `releaseTemporary` is called with the same ids.
    func holdTemporary(_ keys: [(id: UInt32, keyCode: Int, mods: Int, handler: () -> Void)]) {
        for k in keys where tempRefs[k.id] == nil {
            var ref: EventHotKeyRef?
            if RegisterEventHotKey(UInt32(k.keyCode), UInt32(k.mods), EventHotKeyID(signature: OSType(0x4255_424C), id: k.id),
                                   GetApplicationEventTarget(), 0, &ref) == noErr, let ref {
                tempRefs[k.id] = ref
                tempHandlers[k.id] = k.handler
            }
        }
    }

    func releaseTemporary(_ ids: [UInt32]) {
        for id in ids {
            if let r = tempRefs[id] { UnregisterEventHotKey(r) }
            tempRefs[id] = nil
            tempHandlers[id] = nil
        }
    }

    // MARK: Esc while an overlay is up

    /// While `handler` is set, Esc anywhere calls it, even when another app has focus (the
    /// picker, area selector and countdown open on top of whatever you were using). Pass nil to
    /// give Esc back to other apps.
    func escapeCancels(_ handler: (() -> Void)?) {
        onEscape = handler
        if handler != nil, escapeRef == nil {
            var ref: EventHotKeyRef?
            if RegisterEventHotKey(UInt32(kVK_Escape), 0, EventHotKeyID(signature: OSType(0x4255_424C), id: Self.escapeID),
                                   GetApplicationEventTarget(), 0, &ref) == noErr { escapeRef = ref }
        } else if handler == nil, let r = escapeRef {
            UnregisterEventHotKey(r)
            escapeRef = nil
        }
    }

    private func escapePressed() {
        let h = onEscape
        escapeCancels(nil)
        h?()
    }

    // MARK: Changing a shortcut

    /// Starts listening for new keys for `a`. Esc (or clicking it again) cancels.
    func capture(_ a: ShortcutAction) {
        if capturing == a { endCapture(); return }
        endCapture()
        capturing = a
        unregister(a)  // so pressing the current keys records them instead of running the action
        tapDown = nil
        lastTap = nil
        captureMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] e in
            guard let self, let a = self.capturing else { return e }
            if e.type == .keyDown {
                if e.keyCode == 53 { self.endCapture(); return nil }  // Esc
                let flags = e.modifierFlags.intersection([.command, .option, .control, .shift])
                guard !flags.subtracting(.shift).isEmpty else { NSSound.beep(); return nil }  // needs ⌘, ⌥ or ⌃
                var carbon: UInt32 = 0
                if flags.contains(.command) { carbon |= UInt32(cmdKey) }
                if flags.contains(.option) { carbon |= UInt32(optionKey) }
                if flags.contains(.control) { carbon |= UInt32(controlKey) }
                if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
                self.set(Shortcut(keyCode: UInt32(e.keyCode), mods: carbon, label: Self.label(flags: flags, event: e)), for: a)
                return nil
            }
            guard a.allowsDoubleTap else { return e }
            // A modifier pressed and released on its own, twice in quick succession.
            let flags = e.modifierFlags.intersection([.command, .option, .control, .shift, .function])
            let now = Date()
            if Self.modifiers.contains(flags) {
                self.tapDown = (flags, now)
            } else if flags.isEmpty, let down = self.tapDown, now.timeIntervalSince(down.at) < 0.4 {
                self.tapDown = nil
                if let last = self.lastTap, last.flags == down.flags, now.timeIntervalSince(last.at) < 0.5 {
                    let sym = Self.symbol(down.flags)
                    self.set(Shortcut(tapModifier: down.flags.rawValue, label: "\(sym) \(sym)"), for: a)
                } else {
                    self.lastTap = (down.flags, now)
                }
            } else {
                self.tapDown = nil
            }
            return e
        }
    }

    func resetToDefault(_ a: ShortcutAction) {
        endCapture()
        Settings.d.removeObject(forKey: "shortcut." + a.rawValue)
        shortcuts[a] = a == .record ? Shortcut(keyCode: 15, mods: UInt32(optionKey | shiftKey), label: "⌥⇧R") : .standard(a)
        register(a)
        onChange?()
    }

    private func set(_ s: Shortcut, for a: ShortcutAction) {
        if let other = ShortcutAction.allCases.first(where: { $0 != a && self[$0].clashes(with: s) }) {
            NSSound.beep()
            log("shortcut \(s.label) already used for \(other.rawValue)")
            return  // keep listening
        }
        let old = self[a]
        shortcuts[a] = s
        if register(a) {
            if let data = try? JSONEncoder().encode(s) { Settings.d.set(data, forKey: "shortcut." + a.rawValue) }
        } else {
            NSSound.beep()  // taken by another app
            shortcuts[a] = old
        }
        endCapture()
        onChange?()
    }

    func endCapture() {
        if let m = captureMonitor { NSEvent.removeMonitor(m) }
        captureMonitor = nil
        if let a = capturing, refs[a] == nil { register(a) }
        capturing = nil
    }

    static func symbol(_ f: NSEvent.ModifierFlags) -> String {
        switch f {
        case .command: "⌘"
        case .control: "⌃"
        case .shift: "⇧"
        case .function: "fn"
        default: "⌥"
        }
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
        return s + (e.charactersIgnoringModifiers?.uppercased() ?? "?")
    }
}
