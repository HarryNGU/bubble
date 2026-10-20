// On-screen pieces: the recording control bar, the 3-2-1 countdown and the area selector.

import AppKit
import AVFoundation
import SwiftUI

// MARK: - Recording pill window (never appears in the recording)

final class ControlBar {
    let panel: NSPanel
    private var dragOffset: NSPoint?

    init(model: UIModel) {
        let host = FirstClickHostingView(rootView: RecordingPill(model: model))
        let size = host.fittingSize
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .statusBar
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        host.frame = NSRect(origin: .zero, size: size)
        panel.contentView = host
        model.onDragPill = { [weak self] ended in self?.drag(ended: ended) }
    }

    func show(on screen: NSScreen) {
        let f = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: f.midX - panel.frame.width / 2, y: f.maxY - panel.frame.height - 14))
        panel.orderFrontRegardless()
    }

    func hide() { panel.orderOut(nil) }

    private func drag(ended: Bool) {
        let mouse = NSEvent.mouseLocation
        if ended { dragOffset = nil; return }
        if dragOffset == nil { dragOffset = NSPoint(x: mouse.x - panel.frame.minX, y: mouse.y - panel.frame.minY) }
        if let o = dragOffset { panel.setFrameOrigin(NSPoint(x: mouse.x - o.x, y: mouse.y - o.y)) }
    }
}

// MARK: - Countdown
//
// Only the part that will be recorded takes on a light tint of the theme colour, and a
// small frosted disc in its middle counts 3-2-1. Each new number floats up into the bubble while
// its glow swells and settles; on "go" the bubble pops and the tint clears.

/// `region` is what will be recorded, in AppKit global coordinates (nil = the whole screen).
func runCountdown(on screen: NSScreen, region: NSRect? = nil, then done: @escaping () -> Void) {
    let panel = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.level = .screenSaver
    panel.ignoresMouseEvents = true
    panel.hidesOnDeactivate = false
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    let model = CountdownModel()
    // Region in the panel's own top-left coordinates, for SwiftUI.
    let r = (region ?? screen.frame).intersection(screen.frame)
    let local = CGRect(x: r.minX - screen.frame.minX, y: screen.frame.maxY - r.maxY, width: r.width, height: r.height)
    panel.contentView = NSHostingView(rootView: CountdownView(model: model, region: local))
    panel.setFrame(screen.frame, display: true)
    panel.orderFrontRegardless()

    withAnimation(.easeOut(duration: 0.35)) { model.visible = true }
    model.beat()
    Sounds.tick()

    let t = Timer(timeInterval: 1, repeats: true) { t in
        if model.n > 1 {
            model.n -= 1  // the number changes and the ring loses a third
            model.beat()
            Sounds.tick()
        } else {
            // Last third of the ring drains away, then the disc fades and recording starts
            // (beginCapture plays the start sound).
            t.invalidate()
            model.n = 0
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                withAnimation(.easeIn(duration: 0.2)) { model.popped = true; model.visible = false }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                    panel.orderOut(nil)
                    done()
                }
            }
        }
    }
    RunLoop.main.add(t, forMode: .common)
}

final class CountdownModel: ObservableObject {
    @Published var n = 3
    @Published var visible = false
    @Published var swell = false
    @Published var popped = false
    /// How much of the ring is left: full at 3, two thirds at 2, one third at 1, empty at go.
    var remaining: CGFloat { CGFloat(n) / 3 }

    /// Each new number: the glow brightens a touch.
    func beat() {
        withAnimation(.easeOut(duration: 0.25)) { swell = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            withAnimation(.easeInOut(duration: 0.6)) { self.swell = false }
        }
    }
}

/// A frosted-glass disc with the number and a theme-coloured ring that starts full and loses
/// a third each second, plus a soft glow that brightens gently on every number. The area that will be
/// recorded gets a light tint in the theme colour.
struct CountdownView: View {
    @ObservedObject var model: CountdownModel
    let region: CGRect
    private let theme = ThemeStore.shared.current
    private let size: CGFloat = 150

    var body: some View {
        let accent = Color(nsColor: Theme.nsAccent)
        ZStack(alignment: .topLeading) {
            Color.clear

            // Light tint over just the recorded area, with a thin edge.
            Color(nsColor: theme.start).opacity(0.12)
                .frame(width: region.width, height: region.height)
                .overlay(Rectangle().stroke(accent.opacity(0.8), lineWidth: 2))
                .offset(x: region.minX, y: region.minY)
                .opacity(model.visible ? 1 : 0)

            ZStack {
                // Soft glow
                Circle().fill(accent)
                    .frame(width: size, height: size)
                    .blur(radius: 28)
                    .scaleEffect(model.swell ? 1.25 : 1.0)
                    .opacity(model.swell ? 0.55 : 0.3)

                // Frosted disc
                Circle().fill(.ultraThinMaterial)
                    .overlay(Circle().fill(Color.black.opacity(0.35)))
                    .overlay(Circle().stroke(.white.opacity(0.12), lineWidth: 1))
                    .frame(width: size, height: size)
                    .environment(\.colorScheme, .dark)

                // Ring: a faint full track, and the remaining time drawn over it
                Circle().stroke(.white.opacity(0.12), lineWidth: 4)
                    .frame(width: size - 12, height: size - 12)
                Circle().trim(from: 0, to: model.remaining)
                    .stroke(accent, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: size - 12, height: size - 12)
                    .animation(.easeInOut(duration: 0.45), value: model.n)

                Text("\(max(model.n, 1))")
                    .font(.system(size: 60, weight: .medium, design: .default).monospacedDigit())
                    .foregroundStyle(.white)
                    .contentTransition(.opacity)
                    .animation(.easeOut(duration: 0.15), value: model.n)
            }
            .scaleEffect(model.popped ? 0.85 : 1)
            .opacity(model.popped || !model.visible ? 0 : 1)
            .position(x: region.midX, y: region.midY)
        }
        .ignoresSafeArea()
    }
}

// MARK: - "Saved" toast

/// A small card at the top of the screen confirming the save.
func showSavedToast(on screen: NSScreen, url: URL) {
    let title = Namer.displayTitle(of: url)
    let model = ToastModel()
    let host = NSHostingView(rootView: SavedToast(model: model, name: title))
    let size = host.fittingSize
    let f = screen.visibleFrame
    let panel = NSPanel(contentRect: NSRect(x: f.midX - size.width / 2, y: f.maxY - size.height - 16, width: size.width, height: size.height),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.level = .statusBar
    panel.hasShadow = false
    panel.ignoresMouseEvents = true
    panel.hidesOnDeactivate = false
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    panel.contentView = host
    panel.orderFrontRegardless()
    withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) { model.shown = true }
    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
        withAnimation(.easeIn(duration: 0.25)) { model.shown = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { panel.orderOut(nil) }
    }
}

final class ToastModel: ObservableObject { @Published var shown = false }

struct SavedToast: View {
    @ObservedObject var model: ToastModel
    let name: String
    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(Theme.brand).frame(width: 34, height: 34)
                Image(systemName: "checkmark").font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Saved as “\(name)”").font(.system(size: 13.5, weight: .semibold, design: .rounded)).lineLimit(1)
                    .frame(maxWidth: 380, alignment: .leading)
                Text("Copied to clipboard. Paste it anywhere.").font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.7))
            }
        }
        .foregroundStyle(.white)
        .padding(.leading, 10).padding(.trailing, 20).padding(.vertical, 10)
        .background(ZStack { VisualEffect(material: .hudWindow); Color.black.opacity(0.35) }.clipShape(Capsule()))
        .overlay(Capsule().stroke(.white.opacity(0.12)))
        .environment(\.colorScheme, .dark)
        .padding(12)
        .offset(y: model.shown ? 0 : -30)
        .opacity(model.shown ? 1 : 0)
        .fixedSize()
    }
}

// MARK: - Area selector

/// Dims the screen and lets you drag out the area to record. Esc cancels.
final class AreaSelector: NSWindow {
    private var completion: ((CGRect?) -> Void)?
    private static var current: AreaSelector?

    override var canBecomeKey: Bool { true }

    /// Calls back with the rect in the screen's own points, top-left origin.
    static func pick(on screen: NSScreen, completion: @escaping (CGRect?) -> Void) {
        let w = AreaSelector(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        w.completion = completion
        w.isOpaque = false
        w.backgroundColor = .clear
        w.level = .screenSaver
        w.ignoresMouseEvents = false
        w.acceptsMouseMovedEvents = true
        let view = SelectionView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.onDone = { [weak w] r in w?.finish(r.map { CGRect(x: $0.minX, y: screen.frame.height - $0.maxY, width: $0.width, height: $0.height) }) }
        w.contentView = view
        w.setFrame(screen.frame, display: true)
        current = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        w.makeFirstResponder(view)
        NSCursor.crosshair.push()
    }

    private func finish(_ rect: CGRect?) {
        NSCursor.pop()
        orderOut(nil)
        let c = completion
        completion = nil
        AreaSelector.current = nil
        c?(rect)
    }
}

private final class SelectionView: NSView {
    var onDone: ((NSRect?) -> Void)?
    private var start: NSPoint?
    private var rect: NSRect?

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onDone?(nil) }  // Esc
    }

    override func mouseDown(with event: NSEvent) {
        start = convert(event.locationInWindow, from: nil)
        rect = nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start else { return }
        let p = convert(event.locationInWindow, from: nil)
        rect = NSRect(x: min(start.x, p.x), y: min(start.y, p.y), width: abs(p.x - start.x), height: abs(p.y - start.y)).integral
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if let rect, rect.width >= 40, rect.height >= 40 { onDone?(rect) } else { rect = nil; needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0, alpha: 0.4).setFill()
        bounds.fill()
        let hint = "Drag to choose the area to record  ·  Esc to cancel"
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 16, weight: .medium), .foregroundColor: NSColor.white]
        if let rect {
            NSColor.clear.setFill()
            rect.fill(using: .copy)
            NSColor.white.setStroke()
            let path = NSBezierPath(rect: rect.insetBy(dx: -1, dy: -1))
            path.lineWidth = 2
            path.stroke()
            let scale = window?.screen?.backingScaleFactor ?? 2
            let size = "\(Int(rect.width)) × \(Int(rect.height))  (\(Int(rect.width * scale)) × \(Int(rect.height * scale)) px)"
            let label = NSAttributedString(string: size, attributes: attrs)
            let y = rect.minY > 40 ? rect.minY - 30 : rect.maxY + 8
            label.draw(at: NSPoint(x: rect.minX, y: y))
        } else {
            let s = NSAttributedString(string: hint, attributes: attrs)
            let sz = s.size()
            s.draw(at: NSPoint(x: bounds.midX - sz.width / 2, y: bounds.midY - sz.height / 2))
        }
    }
}
