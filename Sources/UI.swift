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
    @Published var shortcutLabel = Settings.hotKeyLabel
    @Published var capturingShortcut = false
    @Published var micLevel: Float = 0      // 0...1 while recording
    @Published var micSilent = false        // nothing heard for a few seconds

    @Published var screenAllowed = CGPreflightScreenCaptureAccess()
    @Published var recents: [RecentRecording] = []

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
    var onCaptureShortcut: (() -> Void)?

    var elapsedText: String {
        let s = Int(elapsed)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%02d:%02d", s / 60, s % 60)
    }

    func refreshRecents() {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: Settings.folder, includingPropertiesForKeys: [.creationDateKey]))?
            .filter { $0.pathExtension == "mp4" && !$0.lastPathComponent.hasPrefix(".") } ?? []
        let dated = files.map { ($0, (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast) }
            .sorted { $0.1 > $1.1 }.prefix(4)
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

// MARK: - Home window

struct HomeView: View {
    @ObservedObject var model: UIModel
    @ObservedObject private var themes = ThemeStore.shared

    var body: some View {
        ZStack {
            VisualEffect(material: .sidebar).ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(spacing: 14) {
                    header
                    if !model.screenAllowed { permissionBanner }
                    RecordButton(shortcut: model.shortcutLabel) { model.onStart?() }
                    cameraCard
                    soundCard
                    styleCard
                    recentsSection
                }
                .id(themes.current.id)  // repaint everything when the theme changes
                .padding(.horizontal, 18)
                .padding(.top, 34)
                .padding(.bottom, 18)
            }
        }
        .frame(width: 380)
        .frame(minHeight: 640)
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(Theme.brand).frame(width: 30, height: 30)
                Circle().fill(.white).frame(width: 11, height: 11)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("Bubble").font(.system(size: 17, weight: .bold, design: .rounded))
                Text("Screen, camera and voice. Free.").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Button { model.onOpenFolder?() } label: {
                Image(systemName: "folder").font(.system(size: 13, weight: .medium))
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Theme.card))
            }
            .buttonStyle(.plain)
            .help("Open Bubble Recordings on your Desktop")
        }
    }

    private var permissionBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 6) {
                Text("Screen Recording is off").font(.system(size: 12.5, weight: .semibold))
                Text("Turn Bubble on in System Settings, then quit and reopen Bubble.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Open Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                }
                .controlSize(.small)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.orange.opacity(0.12)))
    }

    private var cameraCard: some View {
        Card(icon: "video.fill", title: "Camera", isOn: $model.camera) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Background").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    ForEach(CameraBackground.allCases, id: \.self) { bg in
                        BackgroundTile(kind: bg, selected: model.background == bg) { model.background = bg }
                    }
                }
                HStack {
                    Text("Bubble size").font(.system(size: 12.5))
                    Spacer()
                    SwiftUI.Picker("", selection: $model.bubbleSize) {
                        Text("S").tag(CGFloat(140))
                        Text("M").tag(CGFloat(200))
                        Text("L").tag(CGFloat(280))
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 120)
                }
            }
            .disabled(!model.camera)
            .opacity(model.camera ? 1 : 0.45)
        }
    }

    private var soundCard: some View {
        Card(icon: "waveform", title: "Sound", isOn: nil) {
            VStack(spacing: 10) {
                ToggleRow(title: "Microphone", subtitle: nil, isOn: $model.mic)
                HStack {
                    Text("Mic").font(.system(size: 12.5)).foregroundStyle(.secondary)
                    Spacer()
                    SwiftUI.Picker("", selection: $model.micDevice) {
                        Text("Mac default").tag("")
                        ForEach(model.micDevices, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 210)
                }
                .disabled(!model.mic).opacity(model.mic ? 1 : 0.45)
                ToggleRow(title: "Noise suppression", subtitle: "Keeps voices, removes background noise", isOn: $model.noise)
                    .disabled(!model.mic).opacity(model.mic ? 1 : 0.45)
                ToggleRow(title: "Mac audio", subtitle: "Include sound playing on your Mac", isOn: $model.systemAudio)
                Divider().opacity(0.5)
                ToggleRow(title: "3-2-1 countdown", subtitle: nil, isOn: $model.countdown)
            }
        }
    }

    private var styleCard: some View {
        Card(icon: "paintpalette.fill", title: "Shortcut & style", isOn: nil) {
            VStack(spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Start / finish shortcut").font(.system(size: 12.5))
                        Text("Works from any app").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { model.onCaptureShortcut?() } label: {
                        Text(model.capturingShortcut ? "Press keys…" : model.shortcutLabel)
                            .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                            .foregroundStyle(model.capturingShortcut ? Theme.accent : .primary)
                            .frame(minWidth: 86).padding(.vertical, 6).padding(.horizontal, 10)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.07)))
                            .overlay(RoundedRectangle(cornerRadius: 8)
                                .stroke(model.capturingShortcut ? Theme.accent : Theme.stroke, lineWidth: model.capturingShortcut ? 1.5 : 1))
                    }
                    .buttonStyle(.plain)
                    .help("Click, then press the keys you want (Esc to cancel)")
                }
                HStack {
                    Text("Colour").font(.system(size: 12.5))
                    Spacer()
                    HStack(spacing: 8) {
                        ForEach(BubbleTheme.all) { t in
                            Button { withAnimation(.easeOut(duration: 0.2)) { themes.current = t } } label: {
                                Circle()
                                    .fill(LinearGradient(colors: [Color(nsColor: t.start), Color(nsColor: t.end)],
                                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                                    .frame(width: 20, height: 20)
                                    .overlay(Circle().stroke(Color.primary.opacity(themes.current == t ? 0.85 : 0), lineWidth: 2).padding(-3))
                            }
                            .buttonStyle(.plain)
                            .help(t.name)
                        }
                    }
                }
                ToggleRow(title: "Sound effects", subtitle: "A soft pop when recording starts and ends", isOn: $model.sounds)
                Divider().opacity(0.5)
                ToggleRow(title: "Name videos automatically", subtitle: "From the page or window you recorded", isOn: $model.autoName)
                ToggleRow(title: "Use what you said", subtitle: "Adds the topics you talked about. Runs on your Mac.", isOn: $model.nameFromSpeech)
                    .disabled(!model.autoName).opacity(model.autoName ? 1 : 0.45)
            }
        }
    }

    @ViewBuilder private var recentsSection: some View {
        if !model.recents.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Recent").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Button("Show all") { model.onOpenFolder?() }
                        .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.accent)
                }
                VStack(spacing: 6) {
                    ForEach(model.recents) { RecentRow(item: $0) }
                }
            }
            .padding(.top, 4)
        }
    }
}

struct RecordButton: View {
    var shortcut: String = Settings.hotKeyLabel
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                ZStack {
                    Circle().fill(.white.opacity(0.25)).frame(width: 40, height: 40)
                    Circle().fill(.white).frame(width: 16, height: 16)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Start recording").font(.system(size: 16, weight: .bold, design: .rounded))
                    Text("Tab, window, area or screen").font(.system(size: 11.5)).opacity(0.85)
                }
                Spacer()
                Text(shortcut)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 7).padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.22)))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16).padding(.vertical, 14)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.brand))
            .shadow(color: Theme.accent.opacity(hover ? 0.45 : 0.25), radius: hover ? 14 : 8, y: 4)
            .scaleEffect(hover ? 1.012 : 1)
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.defaultAction)
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hover = h } }
    }
}

struct Card<Content: View>: View {
    let icon: String
    let title: String
    let isOn: Binding<Bool>?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.brand))
                Text(title).font(.system(size: 13, weight: .semibold))
                Spacer()
                if let isOn { Toggle("", isOn: isOn).toggleStyle(.switch).controlSize(.small).labelsHidden().tint(Theme.accent) }
            }
            content
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.stroke))
    }
}

struct ToggleRow: View {
    let title: String
    let subtitle: String?
    @Binding var isOn: Bool
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12.5))
                if let subtitle { Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary) }
            }
            Spacer()
            Toggle("", isOn: $isOn).toggleStyle(.switch).controlSize(.mini).labelsHidden().tint(Theme.accent)
        }
    }
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

struct RecentRow: View {
    @ObservedObject var item: RecentRecording
    @State private var hover = false

    var body: some View {
        Button { NSWorkspace.shared.activateFileViewerSelecting([item.url]) } label: {
            HStack(spacing: 10) {
                Group {
                    if let t = item.thumbnail { Image(nsImage: t).resizable().aspectRatio(contentMode: .fill) }
                    else { Rectangle().fill(Theme.card).overlay(Image(systemName: "film").foregroundStyle(.secondary)) }
                }
                .frame(width: 64, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(Namer.displayTitle(of: item.url)).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Text([item.date.formatted(date: .abbreviated, time: .shortened), item.duration].filter { !$0.isEmpty }.joined(separator: "  ·  "))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "arrow.up.forward.square").foregroundStyle(.secondary).opacity(hover ? 1 : 0)
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 10).fill(hover ? Theme.card : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help("Show in Finder")
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
