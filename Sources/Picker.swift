// Loom-style picker: hover over a window, Chrome tab or the desktop to highlight it, then
// click "Record this". Drag anywhere to draw a custom area instead. Esc cancels.

import AppKit

final class Picker {
    private struct Target {
        let source: CaptureSource
        let rect: NSRect      // AppKit global coordinates
        let label: String
        /// Over Chrome's tab strip / address bar: let clicks reach Chrome so you can switch tabs.
        var passThrough = false
    }

    private struct Win {
        let id: CGWindowID
        let pid: pid_t
        let app: String
        let frame: CGRect     // top-left global coordinates
    }

    private var overlays: [PickerWindow] = []
    private var windows: [Win] = []
    private var lastRefresh = Date.distantPast
    private var current: Target?
    private var locked = false  // true after dragging out an area
    private var completion: ((CaptureSource?) -> Void)?
    private var poll: Timer?
    private static var active: Picker?

    static func run(completion: @escaping (CaptureSource?) -> Void) {
        active?.finish(nil)
        let p = Picker()
        p.completion = completion
        active = p
        p.show()
    }

    private func show() {
        for screen in NSScreen.screens {
            let w = PickerWindow(screen: screen, picker: self)
            overlays.append(w)
            w.orderFrontRegardless()
        }
        // Don't activate Bubble: that would pull you off a full-screen app's Space.
        let mouseScreen = NSScreen.underMouse
        (overlays.first { $0.screen == mouseScreen } ?? overlays.first)?.makeKey()
        update(at: NSEvent.mouseLocation)
        // Poll the pointer too: while clicks pass through to Chrome the overlay gets no mouse events.
        poll = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            self?.update(at: NSEvent.mouseLocation)
        }
    }

    fileprivate func finish(_ source: CaptureSource?) {
        poll?.invalidate()
        poll = nil
        overlays.forEach { $0.orderOut(nil) }
        overlays = []
        Picker.active = nil
        let c = completion
        completion = nil
        c?(source)
    }

    fileprivate func confirm() {
        guard let current else { return }
        log("picked: \(current.label)")
        finish(current.source)
    }

    fileprivate func cancel() { finish(nil) }

    // MARK: Hover

    private func refreshWindows() {
        guard Date().timeIntervalSince(lastRefresh) > 0.25 else { return }
        lastRefresh = Date()
        let me = getpid()
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        windows = info.compactMap { w in
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  let id = w[kCGWindowNumber as String] as? CGWindowID,
                  let pid = w[kCGWindowOwnerPID as String] as? pid_t, pid != me,
                  (w[kCGWindowAlpha as String] as? Double ?? 1) > 0.05,
                  let bd = w[kCGWindowBounds as String] as? NSDictionary,
                  let b = CGRect(dictionaryRepresentation: bd), b.width >= 60, b.height >= 30 else { return nil }
            return Win(id: id, pid: pid, app: w[kCGWindowOwnerName as String] as? String ?? "App", frame: b)
        }
    }

    fileprivate func update(at point: NSPoint) {
        guard !locked else { return }
        refreshWindows()
        let target = target(at: point)
        let through = target?.passThrough ?? false
        for o in overlays where o.ignoresMouseEvents != through { o.ignoresMouseEvents = through }
        if target?.rect != current?.rect || target?.label != current?.label {
            current = target
            overlays.forEach { $0.show(highlight: target?.rect, label: target?.label) }
        }
    }

    private func target(at p: NSPoint) -> Target? {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let cg = CGPoint(x: p.x, y: primaryHeight - p.y)
        guard let hit = windows.first(where: { $0.frame.contains(cg) }) else {
            let s = NSScreen.screens.first { $0.frame.contains(p) } ?? NSScreen.underMouse
            return Target(source: .display(s.displayID), rect: s.frame, label: "Record this screen")
        }
        if let chromePID = Chrome.pid, hit.pid == chromePID { return chromeTarget(hit, pointer: cg) }
        return Target(source: .window(hit.id, hit.app), rect: appKitRect(fromGlobalTopLeft: hit.frame),
                      label: "Record this window")
    }

    /// Chrome: highlight just the page. In full screen, the toolbar lives in separate small
    /// windows above the page window, so pick the big one and crop nothing.
    private func chromeTarget(_ hit: Win, pointer: CGPoint? = nil) -> Target {
        let chromeWins = windows.filter { $0.pid == hit.pid }
        let page = chromeWins
            .filter { $0.frame.height >= 160 && $0.frame.intersects(hit.frame.insetBy(dx: 0, dy: -400)) }
            .max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height } ?? hit
        let fullScreen = chromeWins.contains { $0.id != page.id && $0.frame.maxY <= page.frame.minY + 2 && $0.frame.height < 200
                                              && abs($0.frame.width - page.frame.width) < 4 }
        let inset = fullScreen ? 0 : Chrome.toolbarHeight()
        var content = page.frame
        content.origin.y += inset
        content.size.height -= inset
        // The pointer is on Chrome's own controls (toolbar strip windows in full screen, or the
        // top band of a normal window): pass clicks through so a tab click switches tabs.
        let onControls = pointer.map { hit.id != page.id || $0.y < content.minY } ?? false
        return Target(source: .croppedWindow(page.id, inset, "Chrome tab"), rect: appKitRect(fromGlobalTopLeft: content),
                      label: "Record this tab", passThrough: onControls)
    }

    /// For `--selftest N chrome`: the biggest Chrome window, as the picker would choose it.
    static func chromeSourceForTesting() -> CaptureSource? {
        let p = Picker()
        p.refreshWindows()
        guard let pid = Chrome.pid,
              let big = p.windows.filter({ $0.pid == pid }).max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height })
        else { return nil }
        return p.chromeTarget(big).source
    }

    // MARK: Drag a custom area

    fileprivate func dragged(from a: NSPoint, to b: NSPoint, done: Bool) {
        let r = NSRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y)).integral
        let screen = NSScreen.screens.first { $0.frame.contains(a) } ?? NSScreen.underMouse
        let clipped = r.intersection(screen.frame)
        locked = true
        if done && (clipped.width < 40 || clipped.height < 40) {
            locked = false
            update(at: b)
            return
        }
        // Display-local, top-left origin.
        let local = CGRect(x: clipped.minX - screen.frame.minX, y: screen.frame.maxY - clipped.maxY,
                           width: clipped.width, height: clipped.height)
        current = Target(source: .area(screen.displayID, local), rect: clipped, label: "Record this area")
        let scale = screen.backingScaleFactor
        overlays.forEach {
            $0.show(highlight: clipped, label: done ? "Record this area" : nil,
                    sizeText: "\(Int(clipped.width * scale)) × \(Int(clipped.height * scale))")
        }
    }

    fileprivate func clickedOutsideLockedArea() {
        locked = false
        update(at: NSEvent.mouseLocation)
    }

    fileprivate var isLocked: Bool { locked }
    fileprivate var currentRect: NSRect? { current?.rect }
}

// MARK: - Overlay window, one per screen

private final class PickerWindow: NSPanel {
    weak var picker: Picker?
    private let view: PickerView
    override var canBecomeKey: Bool { true }

    init(screen: NSScreen, picker: Picker) {
        self.picker = picker
        view = PickerView(frame: NSRect(origin: .zero, size: screen.frame.size))
        // A non-activating panel can float over full-screen apps and take keys (Esc)
        // without switching Spaces.
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        isOpaque = false
        backgroundColor = .clear
        level = .screenSaver
        ignoresMouseEvents = false  // also catch clicks on the see-through parts
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        view.picker = picker
        contentView = view
        setFrame(screen.frame, display: false)
    }

    func show(highlight global: NSRect?, label: String?, sizeText: String? = nil) {
        view.highlight = global.map { NSRect(x: $0.minX - frame.minX, y: $0.minY - frame.minY, width: $0.width, height: $0.height) }
            .flatMap { $0.intersects(view.bounds) ? $0 : nil }
        view.label = label
        view.sizeText = sizeText
        view.layoutButton()
        view.needsDisplay = true
    }
}

private final class PickerView: NSView {
    weak var picker: Picker?
    var highlight: NSRect?
    var label: String?
    var sizeText: String?
    private var downAt: NSPoint?
    private var dragging = false
    private lazy var button: BlockButton = {
        let b = BlockButton(title: "") { [weak self] in self?.picker?.confirm() }
        b.isBordered = false
        b.wantsLayer = true
        b.layer?.backgroundColor = Theme.nsAccent.cgColor
        b.layer?.cornerRadius = 22
        b.isHidden = true
        addSubview(b)
        return b
    }()

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    func layoutButton() {
        guard let h = highlight, let label else { button.isHidden = true; return }
        button.attributedTitle = NSAttributedString(string: "●  " + label, attributes: [
            .foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 16, weight: .semibold)])
        let w = button.attributedTitle.size().width + 44
        button.frame = NSRect(x: h.midX - w / 2, y: h.midY - 22, width: w, height: 44)
        button.isHidden = false
    }

    override func mouseMoved(with event: NSEvent) {
        picker?.update(at: NSEvent.mouseLocation)
    }

    override func mouseDown(with event: NSEvent) {
        downAt = NSEvent.mouseLocation
        dragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let downAt else { return }
        let p = NSEvent.mouseLocation
        if !dragging && hypot(p.x - downAt.x, p.y - downAt.y) < 6 { return }
        dragging = true
        picker?.dragged(from: downAt, to: p, done: false)
    }

    override func mouseUp(with event: NSEvent) {
        defer { downAt = nil; dragging = false }
        if dragging, let downAt {
            picker?.dragged(from: downAt, to: NSEvent.mouseLocation, done: true)
            return
        }
        // A plain click inside the highlight records it; outside a drawn area resets it.
        if let picker, picker.isLocked, let r = picker.currentRect, !r.contains(NSEvent.mouseLocation) {
            picker.clickedOutsideLockedArea()
        } else {
            picker?.confirm()
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { picker?.cancel() }           // Esc
        else if event.keyCode == 36 { picker?.confirm() }     // Return
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0, alpha: 0.28).setFill()
        bounds.fill()
        if let h = highlight {
            Theme.nsAccent.withAlphaComponent(0.12).setFill()
            h.fill(using: .copy)
            Theme.nsAccent.setStroke()
            let path = NSBezierPath(rect: h.insetBy(dx: 2, dy: 2))
            path.lineWidth = 4
            path.stroke()
            if let sizeText {
                let a = NSAttributedString(string: sizeText, attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.white])
                a.draw(at: NSPoint(x: h.minX + 8, y: h.maxY - 22))
            }
        }
        // Instructions pill near the top of the screen.
        let text = NSAttributedString(
            string: "Hover a window or the desktop and click Record.  In Chrome, click the tab you want first.  Drag for an area.  Esc cancels.",
            attributes: [.font: NSFont.systemFont(ofSize: 14, weight: .medium), .foregroundColor: NSColor.white])
        let sz = text.size()
        let pill = NSRect(x: bounds.midX - sz.width / 2 - 18, y: bounds.maxY - 90, width: sz.width + 36, height: sz.height + 16)
        NSColor(white: 0.1, alpha: 0.9).setFill()
        NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
        text.draw(at: NSPoint(x: pill.minX + 18, y: pill.minY + 8))
    }
}
