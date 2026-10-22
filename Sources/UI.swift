// SwiftUI interface: the main window (Home) and the floating recording pill.
// AppDelegate owns the behaviour; these views read and write `UIModel`.

import AppKit
import AVFoundation
import SwiftUI

// MARK: - Shared state

final class UIModel: ObservableObject {
    @Published var camera = Settings.camera { didSet { Settings.camera = camera; onCamera?(camera) } }
    @Published var background = Settings.background { didSet { onBackground?(background) } }
    @Published var bubbleSize = Settings.bubbleSize { didSet { onSize?(bubbleSize) } }
    @Published var mic = Settings.mic { didSet { Settings.mic = mic } }
    @Published var micDevice = Settings.micDevice { didSet { Settings.micDevice = micDevice } }
    @Published var micDevices: [(String, String)] = MicCapture.devices()
    @Published var noise = Settings.noiseSuppression { didSet { Settings.noiseSuppression = noise } }
    @Published var systemAudio = Settings.systemAudio { didSet { Settings.systemAudio = systemAudio } }
    @Published var countdown = Settings.countdown { didSet { Settings.countdown = countdown } }
    @Published var sounds = Settings.sounds { didSet { Settings.sounds = sounds } }
    @Published var autoName = Settings.autoName { didSet { Settings.autoName = autoName } }
    @Published var nameFromSpeech = Settings.nameFromSpeech { didSet { Settings.nameFromSpeech = nameFromSpeech } }
    @Published var micLevel: Float = 0      // 0...1 while recording
    @Published var micSilent = false        // nothing heard for a few seconds

    @Published var screenAllowed = CGPreflightScreenCaptureAccess()
    @Published var recents: [RecentRecording] = []
    /// The recording open in the reel editor, if any.
    @Published var editing: URL?

    // Recording pill
    @Published var paused = false
    @Published var elapsed: TimeInterval = 0
    @Published var saving = false

    var onCamera: ((Bool) -> Void)?
    var onBackground: ((CameraBackground) -> Void)?
    var onSize: ((CGFloat) -> Void)?
    var onStart: (() -> Void)?
    var onOpenFolder: (() -> Void)?
    var onPause: (() -> Void)?
    var onRestart: (() -> Void)?
    var onDiscard: (() -> Void)?
    var onDone: (() -> Void)?
    var onDragPill: ((Bool) -> Void)?  // true = drag ended
    var onDictate: (() -> Void)?
    var onAssist: (() -> Void)?
    var onAssistKeysChanged: (() -> Void)?
    var onAllowAccessibility: (() -> Void)?

    var elapsedText: String {
        let s = Int(elapsed)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%02d:%02d", s / 60, s % 60)
    }

    func refreshRecents() {
        let fm = FileManager.default
        func videos(in dir: URL) -> [URL] {
            ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey])) ?? [])
                .filter { $0.pathExtension == "mp4" && !$0.lastPathComponent.hasPrefix(".") }
        }
        let files = videos(in: Settings.folder) + videos(in: Settings.reelsFolder)
        let dated = files.map { ($0, (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast) }
            .sorted { $0.1 > $1.1 }
        recents = dated.map { RecentRecording(url: $0.0, date: $0.1) }
        for item in recents { item.load() }
    }
}

final class RecentRecording: ObservableObject, Identifiable {
    let url: URL
    let date: Date
    @Published var thumbnail: NSImage?
    @Published var duration: String = ""
    var id: URL { url }

    init(url: URL, date: Date) { self.url = url; self.date = date }

    /// Made by the reel editor (saved in Bubble Recordings/Reels).
    var isReel: Bool { url.deletingLastPathComponent().standardizedFileURL == Settings.reelsFolder.standardizedFileURL }

    func load() {
        Task {
            let asset = AVURLAsset(url: url)
            if let d = try? await asset.load(.duration), d.seconds.isFinite {
                let s = Int(d.seconds.rounded())
                let text = String(format: "%d:%02d", s / 60, s % 60)
                await MainActor.run { self.duration = text }
            }
            let gen = AVAssetImageGenerator(asset: asset)
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: 240, height: 160)
            if let (cg, _) = try? await gen.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)) {
                let img = NSImage(cgImage: cg, size: .zero)
                await MainActor.run { self.thumbnail = img }
            }
        }
    }
}

// MARK: - Look

struct BubbleTheme: Identifiable, Equatable {
    let id: String
    let name: String
    let start: NSColor   // gradient start (top-left)
    let end: NSColor     // gradient end (bottom-right)

    static func rgb(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    static let all: [BubbleTheme] = [
        BubbleTheme(id: "electric", name: "Electric Blue", start: rgb(0x1F5BFF), end: rgb(0x00B8FF)),
        BubbleTheme(id: "cobalt", name: "Cobalt", start: rgb(0x2433FF), end: rgb(0x7A5CFF)),
        BubbleTheme(id: "aqua", name: "Aqua", start: rgb(0x0091FF), end: rgb(0x00D9C0)),
        BubbleTheme(id: "violet", name: "Violet", start: rgb(0x7B3FFF), end: rgb(0xD04BFF)),
        BubbleTheme(id: "coral", name: "Coral", start: rgb(0xFF5C5C), end: rgb(0xED388C)),
        BubbleTheme(id: "graphite", name: "Graphite", start: rgb(0x2E3440), end: rgb(0x667085)),
    ]
}

/// The chosen colour theme, shared by every window. Default: a sharp electric blue.
final class ThemeStore: ObservableObject {
    static let shared = ThemeStore()
    @Published var current: BubbleTheme {
        didSet { UserDefaults.standard.set(current.id, forKey: "theme") }
    }
    private init() {
        let id = UserDefaults.standard.string(forKey: "theme") ?? "electric"
        current = BubbleTheme.all.first { $0.id == id } ?? BubbleTheme.all[0]
    }
}

enum Theme {
    static var brand: LinearGradient {
        LinearGradient(colors: [Color(nsColor: ThemeStore.shared.current.start), Color(nsColor: ThemeStore.shared.current.end)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    static var accent: Color { Color(nsColor: nsAccent) }
    /// The midpoint of the gradient, for strokes, rings and highlights.
    static var nsAccent: NSColor {
        ThemeStore.shared.current.start.blended(withFraction: 0.35, of: ThemeStore.shared.current.end) ?? ThemeStore.shared.current.start
    }
    static let card = Color.primary.opacity(0.045)
    static let stroke = Color.primary.opacity(0.08)
}

struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blending: NSVisualEffectView.BlendingMode = .behindWindow
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blending
        v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) { v.material = material }
}

/// Lets clicks land on the first try in panels that aren't the key window.
final class FirstClickHostingView<V: View>: NSHostingView<V> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

struct BackgroundTile: View {
    let kind: CameraBackground
    let selected: Bool
    let action: () -> Void

    private var name: String {
        switch kind { case .off: return "None"; case .blur: return "Blur"; case .grey: return "Grey"; case .clear: return "Cut-out" }
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    swatch
                    Image(systemName: "person.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(kind == .grey ? Color.white.opacity(0.9) : Color.black.opacity(0.55))
                        .offset(y: 6)
                }
                .frame(height: 46)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(selected ? Theme.accent : Theme.stroke, lineWidth: selected ? 2 : 1))
                Text(name).font(.system(size: 10.5, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Theme.accent : .secondary)
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var swatch: some View {
        switch kind {
        case .off:
            RoomScene()
        case .blur:
            RoomScene().blur(radius: 4)
        case .grey:
            Color(red: 0.17, green: 0.17, blue: 0.19)
        case .clear:
            Checkerboard()
        }
    }
}

/// A tiny "room" (window, shelf, plant) so None and Blur look clearly different.
struct RoomScene: View {
    var body: some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: [Color(red: 0.86, green: 0.82, blue: 0.74), Color(red: 0.74, green: 0.68, blue: 0.6)],
                           startPoint: .top, endPoint: .bottom)
            RoundedRectangle(cornerRadius: 2).fill(Color(red: 0.62, green: 0.8, blue: 0.95))
                .frame(width: 22, height: 16).offset(x: 8, y: 7)
            Rectangle().fill(Color(red: 0.45, green: 0.32, blue: 0.22)).frame(width: 30, height: 3).offset(x: 52, y: 14)
            Circle().fill(Color(red: 0.3, green: 0.6, blue: 0.35)).frame(width: 12, height: 12).offset(x: 62, y: 26)
        }
    }
}

struct Checkerboard: View {
    var body: some View {
        Canvas { ctx, size in
            let s: CGFloat = 6
            for y in stride(from: 0, to: size.height, by: s) {
                for x in stride(from: 0, to: size.width, by: s) where (Int(x / s) + Int(y / s)) % 2 == 0 {
                    ctx.fill(Path(CGRect(x: x, y: y, width: s, height: s)), with: .color(.gray.opacity(0.25)))
                }
            }
        }
        .background(Color.white.opacity(0.6))
    }
}

// MARK: - Recording pill

struct RecordingPill: View {
    @ObservedObject var model: UIModel
    @ObservedObject private var themes = ThemeStore.shared
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 4) {
            // Drag handle + status
            HStack(spacing: 9) {
                ZStack {
                    Circle().fill(model.paused ? Color.orange : Color.red).frame(width: 10, height: 10)
                    if !model.paused {
                        Circle().stroke(Color.red.opacity(0.6), lineWidth: 2)
                            .frame(width: 10, height: 10)
                            .scaleEffect(pulse ? 2.2 : 1).opacity(pulse ? 0 : 1)
                    }
                }
                Text(model.saving ? "Saving…" : model.paused ? "Paused" : model.elapsedText)
                    .font(.system(size: 14, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(model.paused ? Color.orange : .white)
                    .frame(width: 62, alignment: .leading)
                if model.mic { MicMeter(level: model.micLevel, silent: model.micSilent) }
            }
            .padding(.leading, 14).padding(.trailing, 6)
            .frame(height: 44)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 1)
                .onChanged { _ in model.onDragPill?(false) }
                .onEnded { _ in model.onDragPill?(true) })
            .help("Drag to move")

            Rectangle().fill(.white.opacity(0.14)).frame(width: 1, height: 22)

            PillIcon(icon: model.paused ? "play.fill" : "pause.fill", tip: model.paused ? "Resume" : "Pause") { model.onPause?() }
            PillIcon(icon: "arrow.counterclockwise", tip: "Restart (discard and start again)") { model.onRestart?() }
            PillIcon(icon: "trash", tip: "Discard recording") { model.onDiscard?() }

            Button { model.onDone?() } label: {
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2.5).fill(.white).frame(width: 9, height: 9)
                    Text("Done").font(.system(size: 13, weight: .semibold, design: .rounded))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 14).frame(height: 32)
                .background(Capsule().fill(Theme.brand))
            }
            .buttonStyle(.plain)
            .help("Finish and open the video")
            .padding(.leading, 4).padding(.trailing, 6)
        }
        .disabled(model.saving)
        .background(
            ZStack {
                VisualEffect(material: .hudWindow)
                Color.black.opacity(0.35)
            }
            .clipShape(Capsule())
        )
        .overlay(Capsule().stroke(.white.opacity(0.12)))
        .environment(\.colorScheme, .dark)
        .fixedSize()
        .id(themes.current.id)
        .onAppear { withAnimation(.easeOut(duration: 1.2).repeatForever(autoreverses: false)) { pulse = true } }
    }
}

/// Four little bars that bounce with your voice; turns into an amber warning if the mic is silent.
struct MicMeter: View {
    let level: Float
    let silent: Bool

    var body: some View {
        Group {
            if silent {
                Image(systemName: "mic.slash.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.orange)
                    .help("Your microphone isn't picking up any sound. Check the Mic setting.")
            } else {
                HStack(alignment: .center, spacing: 2) {
                    ForEach(0..<4) { i in
                        let weights: [Float] = [0.55, 1, 0.8, 0.45]
                        let h = 4 + 14 * CGFloat(min(1, level * weights[i] * 1.4))
                        Capsule().fill(Theme.accent.opacity(0.95)).frame(width: 3, height: h)
                    }
                }
                .frame(height: 18)
                .animation(.easeOut(duration: 0.12), value: level)
                .help("Microphone level")
            }
        }
        .frame(width: 20)
    }
}

struct PillIcon: View {
    let icon: String
    let tip: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(hover ? 1 : 0.85))
                .frame(width: 32, height: 32)
                .background(Circle().fill(.white.opacity(hover ? 0.16 : 0)))
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
        .help(tip)
    }
}
