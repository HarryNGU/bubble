// Bubble's main window: a resizable, full-screen-capable library with a sidebar, in a calm,
// neutral style (white canvas, warm sidebar, hairline borders, black primary buttons). The
// theme colour is used only as an accent.

import AppKit
import AVFoundation
import Speech
import SwiftUI

// MARK: - Design system

enum Palette {
    private static func dyn(_ light: NSColor, _ dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light })
    }
    private static func hex(_ v: UInt32, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat(v >> 16 & 0xFF) / 255, green: CGFloat(v >> 8 & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: a)
    }
    static let sidebar = dyn(hex(0xF4F3EF), hex(0x161618))
    static let canvas = dyn(hex(0xFFFFFF), hex(0x1E1E21))
    static let card = dyn(hex(0xF7F6F3), hex(0x27272A))
    static let selected = dyn(hex(0xE9E7E2), hex(0x2C2C30))
    static let border = dyn(NSColor.black.withAlphaComponent(0.08), NSColor.white.withAlphaComponent(0.08))
    static let ink = dyn(hex(0x111111), hex(0xF2F2F2))
    static let onInk = dyn(hex(0xFFFFFF), hex(0x111111))
    static let subtle = dyn(hex(0x6B6B6B), hex(0x9A9A9F))
}

struct PrimaryButton: View {
    let title: String
    var icon: String?
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if let icon { Image(systemName: icon).font(.system(size: 12, weight: .semibold)) }
                Text(title).font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(Palette.onInk)
            .padding(.horizontal, 16).frame(height: 34)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Palette.ink.opacity(hover ? 0.85 : 1)))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

struct SecondaryButton: View {
    let title: String
    var icon: String?
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon { Image(systemName: icon).font(.system(size: 12, weight: .medium)) }
                Text(title).font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 14).frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(hover ? Palette.card : Palette.canvas))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(Palette.border))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

struct KeyCap: View {
    let keys: String
    var body: some View {
        Text(keys)
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .foregroundStyle(Palette.subtle)
            .padding(.horizontal, 8).frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 6).fill(Palette.canvas))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Palette.border))
    }
}

/// A shortcut you can change by clicking it, then pressing new keys (Esc cancels).
struct ShortcutField: View {
    let action: ShortcutAction
    @ObservedObject private var keys = ShortcutCenter.shared
    @State private var hover = false

    init(_ action: ShortcutAction) { self.action = action }

    private var capturing: Bool { keys.capturing == action }

    var body: some View {
        Button { keys.capture(action) } label: {
            HStack(spacing: 6) {
                Text(capturing ? (action.allowsDoubleTap ? "Press keys or double-tap ⌥ ⌘ ⌃" : "Press new keys…") : keys.label(action))
                    .font(.system(size: 12.5, weight: .medium, design: .rounded))
                    .foregroundStyle(capturing ? Theme.accent : .primary.opacity(0.85))
                if hover && !capturing {
                    Image(systemName: "pencil").font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.subtle)
                }
            }
            .padding(.horizontal, 10).frame(minWidth: 64).frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 7).fill(hover || capturing ? Palette.selected : Palette.canvas))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(capturing ? Theme.accent : Palette.border, lineWidth: capturing ? 1.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(capturing ? "Esc to cancel" : "Click to change")
        .contextMenu { Button("Reset to default") { keys.resetToDefault(action) } }
        .animation(.easeOut(duration: 0.12), value: capturing)
    }
}

/// A titled group of settings rows, like System Settings.
struct SettingsGroup<Content: View>: View {
    let title: String
    var footer: String?
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.system(size: 11, weight: .semibold)).tracking(0.6).foregroundStyle(Palette.subtle)
            VStack(spacing: 0) { content }
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.card))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Palette.border))
            if let footer {
                Text(footer).font(.system(size: 11.5)).foregroundStyle(Palette.subtle).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct SettingRow<Control: View>: View {
    let title: String
    var subtitle: String?
    var divider = true
    @ViewBuilder let control: Control
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13.5))
                    if let subtitle { Text(subtitle).font(.system(size: 12)).foregroundStyle(Palette.subtle).fixedSize(horizontal: false, vertical: true) }
                }
                Spacer(minLength: 12)
                control
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            if divider { Rectangle().fill(Palette.border).frame(height: 1).padding(.leading, 16) }
        }
    }
}

struct SwitchRow: View {
    let title: String
    var subtitle: String?
    @Binding var isOn: Bool
    var divider = true
    var body: some View {
        SettingRow(title: title, subtitle: subtitle, divider: divider) {
            Toggle("", isOn: $isOn).toggleStyle(.switch).controlSize(.small).labelsHidden().tint(Theme.accent)
        }
    }
}

struct PageHeader<Trailing: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder let trailing: Trailing
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 28, weight: .semibold))
                if let subtitle { Text(subtitle).font(.system(size: 14)).foregroundStyle(Palette.subtle) }
            }
            Spacer()
            HStack(spacing: 10) { trailing }
        }
    }
}

extension PageHeader where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil) { self.init(title: title, subtitle: subtitle) { EmptyView() } }
}

// MARK: - Permissions

final class Permissions: ObservableObject {
    @Published var screen = false
    @Published var camera = false
    @Published var mic = false
    @Published var speech = false
    @Published var accessibility = false

    func refresh() {
        screen = CGPreflightScreenCaptureAccess()
        camera = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
        mic = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        speech = SFSpeechRecognizer.authorizationStatus() == .authorized
        accessibility = AXIsProcessTrusted()
    }

    var allGood: Bool { screen && camera && mic && speech && accessibility }

    static func open(_ pane: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
    }
}

// MARK: - Window

enum Page: String, CaseIterable, Identifiable {
    case home, recordings, recorder, assistant, dictation, snippets, style, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .home: return "Home"
        case .recordings: return "Recordings"
        case .recorder: return "Screen recorder"
        case .assistant: return "Assistant"
        case .dictation: return "Dictation"
        case .snippets: return "Snippets"
        case .style: return "Style"
        case .settings: return "Settings"
        }
    }
    /// Bubble's own symbol for its main features.
    var glyph: BubbleGlyph.Kind? {
        switch self {
        case .recorder: return .record
        case .assistant: return .assist
        case .dictation: return .dictate
        default: return nil
        }
    }

    var icon: String {
        switch self {
        case .home: return "house"
        case .recordings: return "film.stack"
        case .recorder: return "record.circle"
        case .assistant: return "sparkles"
        case .dictation: return "mic"
        case .snippets: return "text.badge.plus"
        case .style: return "textformat"
        case .settings: return "gearshape"
        }
    }
}

struct MainView: View {
    @ObservedObject var model: UIModel
    @ObservedObject var dictation: DictationModel
    @ObservedObject private var themes = ThemeStore.shared
    @StateObject private var permissions = Permissions()
    @AppStorage("page") private var page: Page = .home
    @AppStorage("onboarded") private var onboarded = false
    private let tick = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        if !onboarded || CommandLine.arguments.contains("--onboard") {
            OnboardingView(permissions: permissions) { onboarded = true; page = .home }
                .frame(minWidth: 860, minHeight: 560)
                .ignoresSafeArea()
                .onReceive(tick) { _ in permissions.refresh() }
        } else {
            library
        }
    }

    private var library: some View {
        HStack(spacing: 0) {
            sidebar
            ScrollView {
                Group {
                    if let url = model.editing {
                        EditorPage(url: url, onClose: { model.editing = nil; model.refreshRecents() }).id(url)
                    } else {
                        switch page {
                        case .home: HomePage(model: model, dictation: dictation, permissions: permissions, page: $page)
                        case .recordings: RecordingsPage(model: model)
                        case .recorder: RecorderPage(model: model)
                        case .assistant: AssistantPage(model: model)
                        case .dictation: DictationPage(model: model, dictation: dictation, permissions: permissions)
                        case .snippets: SnippetsPage()
                        case .style: StylePage(dictation: dictation)
                        case .settings: SettingsPage(model: model, permissions: permissions)
                        }
                    }
                }
                // Galleries and the editor use the whole width in full screen; settings pages stay readable.
                .frame(maxWidth: contentWidth, alignment: .leading)
                .padding(.horizontal, 44).padding(.top, 48).padding(.bottom, 40)
                .frame(maxWidth: .infinity)
            }
            .background(Palette.canvas)
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: 14, bottomLeadingRadius: 14, style: .continuous))
            .overlay(UnevenRoundedRectangle(topLeadingRadius: 14, bottomLeadingRadius: 14, style: .continuous).stroke(Palette.border))
            .padding(.vertical, 8)
        }
        .background(Palette.sidebar)
        .ignoresSafeArea()
        .frame(minWidth: 860, minHeight: 560)
        .id(themes.current.id)
        .onAppear { permissions.refresh(); model.refreshRecents() }
        .onReceive(tick) { _ in permissions.refresh() }
    }

    private var contentWidth: CGFloat {
        if model.editing != nil { return 1600 }
        switch page {
        case .home, .recordings: return 1400
        default: return 980
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 9) {
                ZStack {
                    Circle().fill(Theme.accent).frame(width: 22, height: 22)
                    Circle().fill(.white).frame(width: 8, height: 8)
                }
                Text("Bubble").font(.system(size: 19, weight: .bold))
            }
            .padding(.leading, 10).padding(.top, 52).padding(.bottom, 22)

            ForEach([Page.home, .recordings, .recorder, .assistant]) { item($0) }
            Text("VOICE").font(.system(size: 10.5, weight: .semibold)).tracking(0.6).foregroundStyle(Palette.subtle)
                .padding(.leading, 12).padding(.top, 18).padding(.bottom, 4)
            ForEach([Page.dictation, .snippets, .style]) { item($0) }
            Spacer()
            if !permissions.allGood {
                Button { page = .settings } label: {
                    HStack(spacing: 8) {
                        Circle().fill(Color.orange).frame(width: 7, height: 7)
                        Text("Finish setup").font(.system(size: 12.5, weight: .medium))
                        Spacer()
                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.subtle)
                    }
                    .padding(.horizontal, 12).frame(height: 34)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Palette.canvas))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(Palette.border))
                }
                .buttonStyle(.plain)
                .padding(.bottom, 8)
            }
            item(.settings)
        }
        .padding(.horizontal, 12).padding(.bottom, 16)
        .frame(width: 228)
    }

    private func item(_ p: Page) -> some View {
        let on = model.editing == nil ? page == p : p == .recordings
        return Button { page = p; model.editing = nil } label: {
            HStack(spacing: 11) {
                if let g = p.glyph {
                    BubbleGlyph(kind: g, tinted: false, lineWidth: 1.7).frame(width: 17, height: 17).frame(width: 20)
                } else {
                    Image(systemName: p.icon).font(.system(size: 14, weight: .regular)).frame(width: 20)
                }
                Text(p.title).font(.system(size: 14, weight: on ? .semibold : .regular))
                Spacer()
            }
            .foregroundStyle(on ? Color.primary : Color.primary.opacity(0.8))
            .padding(.horizontal, 10).frame(height: 36)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(on ? Palette.selected : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Home

struct HomePage: View {
    @ObservedObject var model: UIModel
    @ObservedObject var dictation: DictationModel
    @ObservedObject var permissions: Permissions
    @Binding var page: Page

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        let hello = h < 12 ? "Good morning" : h < 18 ? "Good afternoon" : "Good evening"
        return Settings.userName.isEmpty ? hello : "\(hello), \(Settings.userName)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 32) {
            PageHeader(title: greeting, subtitle: "Your ultimate personal assistant on this Mac. Ask, talk or record, and I'll help.")
            HStack(alignment: .top, spacing: 16) {
                ActionCard(glyph: .record, title: "Record your screen", detail: "Hover a tab, window or screen, or drag an area.",
                           shortcut: .record, button: "Start recording") { model.onStart?() }
                ActionCard(glyph: .dictate, title: "Dictate", detail: "Talk anywhere. Bubble types a tidy version where your cursor is.",
                           shortcut: .dictate, button: dictation.phase == .listening ? "Finish" : "Start dictating") { model.onDictate?() }
                ActionCard(glyph: .assist, title: "Ask Bubble", detail: "Claude sees your screen and hears your call, and helps in real time.",
                           shortcut: .assist, button: "Open") { model.onAssist?() }
            }
            if !permissions.allGood {
                SettingsGroup(title: "Finish setup") { PermissionRows(permissions: permissions, onlyMissing: true) }
            }
            if !model.recents.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Recent recordings").font(.system(size: 16, weight: .semibold))
                        Spacer()
                        Button("View all") { page = .recordings }.buttonStyle(.plain).font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.subtle)
                    }
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16), count: 4), spacing: 16) {
                        ForEach(model.recents.prefix(4)) { VideoTile(item: $0, compact: true, onChange: { model.refreshRecents() }, onEdit: { model.editing = $0 }) }
                    }
                }
            }
            if !dictation.last.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Last dictation").font(.system(size: 16, weight: .semibold))
                        Spacer()
                        SecondaryButton(title: "Copy", icon: "doc.on.doc") { copy(dictation.last) }
                    }
                    Text(dictation.last).font(.system(size: 13.5)).lineLimit(4).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Palette.card))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.border))
                }
            }
        }
    }
}

struct ActionCard: View {
    let glyph: BubbleGlyph.Kind
    let title: String, detail: String, shortcut: ShortcutAction, button: String
    let action: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                BubbleGlyph(kind: glyph).frame(width: 27, height: 27)
                    .frame(width: 42, height: 42)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Theme.accent.opacity(0.12)))
                Spacer()
                ShortcutField(shortcut)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 16, weight: .semibold))
                Text(detail).font(.system(size: 13)).foregroundStyle(Palette.subtle).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            PrimaryButton(title: button, action: action)
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 210, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.card))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Palette.border))
    }
}

// MARK: - Recordings

struct RecordingsPage: View {
    @ObservedObject var model: UIModel
    @State private var search = ""
    @AppStorage("recordingsFilter") private var filter = 0  // 0 all, 1 recordings, 2 reels

    private var items: [RecentRecording] {
        let q = search.lowercased().trimmingCharacters(in: .whitespaces)
        return model.recents.filter { r in
            (filter == 0 || (filter == 1) != r.isReel) && (q.isEmpty || Namer.displayTitle(of: r.url).lowercased().contains(q))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            PageHeader(title: "Recordings", subtitle: "\(model.recents.count) video\(model.recents.count == 1 ? "" : "s") in Bubble Recordings on your Desktop") {
                SecondaryButton(title: "Open folder", icon: "folder") { model.onOpenFolder?() }
                PrimaryButton(title: "New recording", icon: "record.circle") { model.onStart?() }
            }
            if model.recents.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "film").font(.system(size: 28)).foregroundStyle(Palette.subtle)
                    Text("No recordings yet").font(.system(size: 15, weight: .medium))
                    Text("They'll appear here as soon as you press Done.").font(.system(size: 13)).foregroundStyle(Palette.subtle)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 60)
                .background(RoundedRectangle(cornerRadius: 14).fill(Palette.card))
            } else {
                HStack {
                    SwiftUI.Picker("", selection: $filter) { Text("All").tag(0); Text("Recordings").tag(1); Text("Reels").tag(2) }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 260)
                    Spacer()
                    TextField("Search", text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 240)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 18)], spacing: 20) {
                    ForEach(items) { VideoTile(item: $0, compact: false, onChange: { model.refreshRecents() }, onEdit: { model.editing = $0 }) }
                }
            }
        }
        .onAppear { model.refreshRecents() }
    }
}

struct VideoTile: View {
    @ObservedObject var item: RecentRecording
    let compact: Bool
    let onChange: () -> Void
    var onEdit: ((URL) -> Void)?
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                // A fixed 16:10 frame; the thumbnail fills it without changing the layout.
                Color.clear
                    .aspectRatio(16 / 10, contentMode: .fit)
                    .overlay {
                        if let t = item.thumbnail { Image(nsImage: t).resizable().aspectRatio(contentMode: .fill) }
                        else { Rectangle().fill(Palette.card).overlay(Image(systemName: "film").foregroundStyle(Palette.subtle)) }
                    }
                    .clipped()
                if !item.duration.isEmpty {
                    Text(item.duration).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(.black.opacity(0.6))).padding(8)
                }
                if hover {
                    Image(systemName: "play.fill").font(.system(size: 18)).foregroundStyle(.white)
                        .frame(width: 44, height: 44).background(Circle().fill(.black.opacity(0.55)))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .overlay(alignment: .topLeading) {
                if item.isReel {
                    Text("REEL").font(.system(size: 10, weight: .bold)).tracking(0.5).foregroundStyle(.white)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Capsule().fill(Theme.accent)).padding(8)
                } else if hover, let onEdit {
                    Button { onEdit(item.url) } label: {
                        Label("Make reels", systemImage: "wand.and.stars").font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Palette.ink)
                            .padding(.horizontal, 10).frame(height: 28)
                            .background(Capsule().fill(Palette.canvas))
                            .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
                    }
                    .buttonStyle(.plain).padding(8)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Palette.border))
            .onTapGesture { NSWorkspace.shared.open(item.url) }

            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(Namer.displayTitle(of: item.url)).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Text(item.date.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 11.5)).foregroundStyle(Palette.subtle)
                }
                Spacer()
                if !compact {
                    Menu {
                        Button("Play") { NSWorkspace.shared.open(item.url) }
                        if !item.isReel, let onEdit { Button("Make reels…") { onEdit(item.url) } }
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                        Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects([item.url as NSURL]) }
                        Divider()
                        Button("Move to Trash") { NSWorkspace.shared.recycle([item.url]) { _, _ in DispatchQueue.main.async(execute: onChange) } }
                    } label: { Image(systemName: "ellipsis").frame(width: 24, height: 20) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                }
            }
        }
        .onHover { hover = $0 }
    }
}

// MARK: - Screen recorder settings

struct RecorderPage: View {
    @ObservedObject var model: UIModel

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            PageHeader(title: "Screen recorder", subtitle: "How your recordings look and sound.") {
                PrimaryButton(title: "Start recording", icon: "record.circle") { model.onStart?() }
            }
            SettingsGroup(title: "Camera") {
                SwitchRow(title: "Show camera bubble", subtitle: "A round, draggable view of you on top of the recording.", isOn: $model.camera)
                SettingRow(title: "Background", subtitle: "Runs on your Mac.") {
                    HStack(spacing: 8) {
                        ForEach(CameraBackground.allCases, id: \.self) { bg in
                            BackgroundTile(kind: bg, selected: model.background == bg) { model.background = bg }.frame(width: 64)
                        }
                    }
                }
                .disabled(!model.camera).opacity(model.camera ? 1 : 0.5)
                SettingRow(title: "Size", divider: false) {
                    SwiftUI.Picker("", selection: $model.bubbleSize) {
                        Text("Small").tag(CGFloat(140)); Text("Medium").tag(CGFloat(200)); Text("Large").tag(CGFloat(280))
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 220)
                }
                .disabled(!model.camera).opacity(model.camera ? 1 : 0.5)
            }
            SettingsGroup(title: "Audio") {
                SwitchRow(title: "Microphone", isOn: $model.mic)
                SettingRow(title: "Input") {
                    SwiftUI.Picker("", selection: $model.micDevice) {
                        Text("Mac default").tag("")
                        ForEach(model.micDevices, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    .labelsHidden().frame(width: 220)
                }
                SwitchRow(title: "Noise suppression", subtitle: "Removes fans, hum and hiss. Keeps voices.", isOn: $model.noise)
                SwitchRow(title: "Mac audio", subtitle: "Include sound playing on your Mac.", isOn: $model.systemAudio, divider: false)
            }
            SettingsGroup(title: "Recording") {
                SwitchRow(title: "3-2-1 countdown", isOn: $model.countdown)
                SettingRow(title: "Start / finish shortcut", subtitle: "Works from any app. Click to change.") { ShortcutField(.record) }
                SettingRow(title: "Record an area", subtitle: "Draw the area, then recording starts.", divider: false) { ShortcutField(.area) }
            }
            SettingsGroup(title: "Naming", footer: "Videos are saved to Bubble Recordings on your Desktop.") {
                SwitchRow(title: "Name videos automatically", subtitle: "After the page or window you recorded.", isOn: $model.autoName)
                SwitchRow(title: "Use what you said", subtitle: "Adds the topics you talked about. On-device speech recognition.", isOn: $model.nameFromSpeech, divider: false)
                    .disabled(!model.autoName).opacity(model.autoName ? 1 : 0.5)
            }
        }
        .onAppear { model.micDevices = MicCapture.devices() }
    }
}

// MARK: - Dictation

struct DictationPage: View {
    @ObservedObject var model: UIModel
    @ObservedObject private var keys = ShortcutCenter.shared
    @ObservedObject var dictation: DictationModel
    @ObservedObject var permissions: Permissions

    private var shortcut: Shortcut { keys[.dictate] }
    private var howTo: String {
        shortcut.isDoubleTap ? "Double-tap \(shortcut.tapSymbol) anywhere, talk, then tap \(shortcut.tapSymbol) once to finish."
                             : "Press \(shortcut.label) anywhere, talk, then press it again to finish."
    }
    private var finishHint: String {
        shortcut.isDoubleTap ? "Double-tap \(shortcut.tapSymbol) to start, tap once to finish." : "Press once to start, again to finish."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            PageHeader(title: "Dictation", subtitle: howTo) {
                PrimaryButton(title: dictation.phase == .listening ? "Finish" : "Start dictating", icon: "mic") { model.onDictate?() }
            }
            if !(permissions.accessibility && permissions.speech && permissions.mic) {
                SettingsGroup(title: "Before you start", footer: "Accessibility lets Bubble notice your shortcut in other apps and type for you. Until it's on, dictations are copied for you to paste.") {
                    PermissionRows(permissions: permissions, onlyMissing: true, kinds: [.mic, .speech, .accessibility])
                }
            }
            SettingsGroup(title: "Sound", footer: "Plays when Bubble starts and stops listening. Turn all sounds off in Settings.") {
                SettingRow(title: "Start and stop sound", divider: false) {
                    HStack(spacing: 8) {
                        SwiftUI.Picker("", selection: Binding(get: { Sounds.voiceStyle }, set: { Sounds.voiceStyle = $0; Sounds.listen() })) {
                            ForEach(Sounds.VoiceStyle.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 240)
                        SecondaryButton(title: "Play", icon: "speaker.wave.2") {
                            Sounds.listen()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { Sounds.heard() }
                        }
                    }
                }
            }
            SettingsGroup(title: "How it works") {
                SettingRow(title: "Shortcut", subtitle: finishHint + " Esc cancels. Click to change.") { ShortcutField(.dictate) }
                SwitchRow(title: "Finish when I stop talking", subtitle: "Bubble types it after a short pause. You can still finish early yourself.", isOn: $dictation.autoStop)
                SettingRow(title: "In a text box", subtitle: "Bubble types a tidy version where your cursor is.") { Image(systemName: "text.cursor").foregroundStyle(Palette.subtle) }
                SettingRow(title: "Anywhere else", subtitle: "It lands in the Scratchpad below and on your clipboard.", divider: false) { Image(systemName: "doc.on.clipboard").foregroundStyle(Palette.subtle) }
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("SCRATCHPAD").font(.system(size: 11, weight: .semibold)).tracking(0.6).foregroundStyle(Palette.subtle)
                    Spacer()
                    Button("Clear") { dictation.last = "" }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Palette.subtle).disabled(dictation.last.isEmpty)
                    SecondaryButton(title: "Copy", icon: "doc.on.doc") { copy(dictation.last) }.disabled(dictation.last.isEmpty)
                }
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $dictation.last).font(.system(size: 14)).scrollContentBackground(.hidden).padding(10)
                    if dictation.last.isEmpty {
                        Text("Your last dictation appears here, ready to edit and paste.")
                            .font(.system(size: 14)).foregroundStyle(Palette.subtle).padding(.horizontal, 15).padding(.vertical, 10).allowsHitTesting(false)
                    }
                }
                .frame(minHeight: 140)
                .background(RoundedRectangle(cornerRadius: 12).fill(Palette.card))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.border))
            }
            if dictation.history.count > 1 {
                SettingsGroup(title: "Earlier today") {
                    ForEach(Array(dictation.history.dropFirst().enumerated()), id: \.offset) { i, text in
                        SettingRow(title: text, divider: i < dictation.history.count - 2) {
                            Button { copy(text) } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.plain).foregroundStyle(Palette.subtle).help("Copy")
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Snippets

struct SnippetsPage: View {
    @ObservedObject private var store = SnippetStore.shared
    @State private var adding = false
    @State private var trigger = ""
    @State private var text = ""
    @State private var search = ""
    @State private var editing: Snippet?

    private var filtered: [Snippet] {
        let q = search.lowercased().trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? store.snippets : store.snippets.filter { $0.trigger.lowercased().contains(q) || $0.text.lowercased().contains(q) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            PageHeader(title: "Snippets", subtitle: "Say a phrase, and Bubble types the text you saved. Stored only on this Mac.") {
                PrimaryButton(title: "Add new", icon: "plus") { adding = true }
            }
            if adding { editor(title: "New snippet", trigger: $trigger, text: $text, save: {
                store.add(trigger: trigger, text: text); trigger = ""; text = ""; adding = false
            }, cancel: { adding = false; trigger = ""; text = "" }) }
            if store.snippets.count > 6 {
                TextField("Search snippets", text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 280)
            }
            if store.snippets.isEmpty {
                Text("No snippets yet. Add one, like \"my email\" → your address.").font(.system(size: 13)).foregroundStyle(Palette.subtle)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(filtered.enumerated()), id: \.element.id) { i, s in
                        if editing?.id == s.id {
                            editor(title: nil,
                                   trigger: Binding(get: { editing?.trigger ?? "" }, set: { editing?.trigger = $0 }),
                                   text: Binding(get: { editing?.text ?? "" }, set: { editing?.text = $0 }),
                                   save: { if let e = editing { store.update(e) }; editing = nil }, cancel: { editing = nil })
                                .padding(12)
                        } else {
                            SnippetLine(snippet: s, onEdit: { editing = s }, onDelete: { store.delete(s) })
                        }
                        if i < filtered.count - 1 { Rectangle().fill(Palette.border).frame(height: 1).padding(.leading, 16) }
                    }
                }
                .background(RoundedRectangle(cornerRadius: 12).fill(Palette.card))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.border))
            }
        }
    }

    private func editor(title: String?, trigger: Binding<String>, text: Binding<String>, save: @escaping () -> Void, cancel: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title { Text(title).font(.system(size: 13, weight: .semibold)) }
            HStack(spacing: 10) {
                TextField("When I say…", text: trigger).textFieldStyle(.roundedBorder).frame(maxWidth: 200)
                Image(systemName: "arrow.right").foregroundStyle(Palette.subtle)
                TextField("Type this", text: text).textFieldStyle(.roundedBorder)
            }
            HStack {
                Spacer()
                SecondaryButton(title: "Cancel", action: cancel)
                PrimaryButton(title: "Save", action: save)
                    .disabled(trigger.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty || text.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(title == nil ? 0 : 16)
        .background { if title != nil { RoundedRectangle(cornerRadius: 12).fill(Palette.card) } }
        .overlay { if title != nil { RoundedRectangle(cornerRadius: 12).stroke(Palette.border) } }
    }
}

struct SnippetLine: View {
    let snippet: Snippet
    let onEdit: () -> Void
    let onDelete: () -> Void
    @State private var hover = false
    var body: some View {
        HStack(spacing: 10) {
            Text(snippet.trigger).font(.system(size: 13.5))
            Image(systemName: "arrow.right").font(.system(size: 11)).foregroundStyle(Palette.subtle)
            Text(snippet.text).font(.system(size: 13.5)).foregroundStyle(.primary.opacity(0.85)).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            Spacer(minLength: 8)
            HStack(spacing: 14) {
                Button(action: onEdit) { Image(systemName: "pencil") }.buttonStyle(.plain).help("Edit")
                Button(action: onDelete) { Image(systemName: "trash") }.buttonStyle(.plain).help("Delete")
            }
            .foregroundStyle(Palette.subtle)
            .opacity(hover ? 1 : 0.35)
        }
        .padding(.horizontal, 16).frame(height: 48)
        .background(hover ? Palette.selected.opacity(0.5) : .clear)
        .onHover { hover = $0 }
    }
}

// MARK: - Style

struct StylePage: View {
    @ObservedObject var dictation: DictationModel
    @State private var apiKey = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            PageHeader(title: "Style", subtitle: "How Bubble tidies what you say.")
            SettingsGroup(title: "Clean-up", footer: "Punctuation, capitals, stutters (\"I I think\") and \"new line\" / \"new paragraph\" are always handled.") {
                SwitchRow(title: "Remove filler words", subtitle: "um, uh, ah, \"you know,\"", isOn: $dictation.removeFillers)
                SwitchRow(title: "Fix self-corrections", subtitle: "\"at 5, no wait, 6\" becomes \"at 6\". \"Scratch that\" deletes the last sentence.",
                          isOn: $dictation.fixCorrections, divider: false)
            }
            SettingsGroup(title: "AI polish", footer: "Off by default. When on, the dictated text (never audio, never snippet values) is sent to Anthropic's API with your key. If anything fails, Bubble uses its on-device clean-up instead.") {
                SwitchRow(title: "Polish with Claude", subtitle: "Smarter rewrites of very messy speech.", isOn: $dictation.aiPolish, divider: false)
                    .disabled(!dictation.hasAPIKey).opacity(dictation.hasAPIKey ? 1 : 0.5)
            }
            SettingsGroup(title: "Claude API key", footer: "One key for everything in Bubble: AI polish here and the chat in the reel editor. It stays in your Mac's Keychain.") {
                if dictation.hasAPIKey {
                    SettingRow(title: "API key", subtitle: "Saved in your Keychain.", divider: false) {
                        SecondaryButton(title: "Remove") { Keychain.setAPIKey(nil); dictation.hasAPIKey = false; dictation.aiPolish = false }
                    }
                } else {
                    SettingRow(title: "API key", subtitle: "From console.anthropic.com", divider: false) {
                        HStack(spacing: 8) {
                            SecureField("sk-ant-…", text: $apiKey).textFieldStyle(.roundedBorder).frame(width: 220)
                            PrimaryButton(title: "Save") {
                                Keychain.setAPIKey(apiKey.trimmingCharacters(in: .whitespacesAndNewlines))
                                apiKey = ""
                                dictation.hasAPIKey = Keychain.hasKey
                            }
                            .disabled(apiKey.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                }
            }
        }
        .onAppear { dictation.hasAPIKey = Keychain.hasKey }
    }
}

// MARK: - Assistant

struct AssistantPage: View {
    @ObservedObject var model: UIModel
    @AppStorage("assistantDarkness") private var darkness = 0.62
    @AppStorage("chatMyColor") private var myColor = ChatStyle.defaultMine
    @AppStorage("chatTheirColor") private var theirColor = ChatStyle.defaultTheirs
    @AppStorage("chatTextSize") private var textSize = 14.0
    @AppStorage("chatName") private var chatName = "Bubble"
    @AppStorage("chatAvatar") private var chatAvatar = ""
    @State private var brain = Settings.assistantBrain
    @State private var move = Settings.assistantMove
    @State private var choice = Settings.assistantModel
    @State private var hasKey = Keychain.hasKey
    @State private var apiKey = ""
    @State private var keepDays = Settings.chatKeepDays
    @State private var aboutMe = AboutMe.load()
    @State private var aboutSaved = false
    @ObservedObject private var keys = ShortcutCenter.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            PageHeader(title: "Assistant", subtitle: "Press \(keys.label(.assist)) anywhere. Bubble sees your screen, can hear your call, and Claude helps as it happens.") {
                PrimaryButton(title: "Open", icon: "sparkles") { model.onAssist?() }
            }
            SettingsGroup(title: "Brain", footer: brain == .claudeCode
                ? "Uses the Claude Code on this Mac: your memory notes, CLAUDE.md files and connected apps (Gmail, Calendar, Notion and more), on your Claude subscription. It reads and searches freely; anything that sends, changes or runs something waits for you to approve it in the panel."
                : "Uses Claude directly with an API key. Faster to start, but it doesn't know your memory or connected apps and can't take actions.") {
                SettingRow(title: "Answer with", divider: brain == .claudeCode) {
                    SwiftUI.Picker("", selection: $brain) { ForEach(AssistantBrain.allCases) { Text($0.title).tag($0) } }
                        .labelsHidden().frame(width: 230)
                        .onChange(of: brain) { Settings.assistantBrain = brain }
                }
                if brain == .claudeCode {
                    if ClaudeCodeSession.binary == nil {
                        SettingRow(title: "Claude Code isn't installed", subtitle: "Install it from claude.com/claude-code.", divider: false) {
                            SecondaryButton(title: "Open", icon: "arrow.up.right") { NSWorkspace.shared.open(URL(string: "https://claude.com/claude-code")!) }
                        }
                    } else {
                        SettingRow(title: "Sign in once", subtitle: "In Terminal run claude, type /login and sign in with your Claude account. Bubble then uses that sign-in.", divider: false) {
                            HStack(spacing: 8) {
                                SecondaryButton(title: "Copy command", icon: "doc.on.doc") { copy("claude") }
                                SecondaryButton(title: "Terminal", icon: "terminal") {
                                    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"))
                                }
                            }
                        }
                    }
                }
            }
            SettingsGroup(title: "Claude", footer: brain == .claudeCode ? "The API key is only needed for the reel editor chat, AI polish, and the API-key-only brain." : "One API key for everything in Bubble (assistant, reel editor, AI polish). It stays in your Mac's Keychain. Usage is billed to your Anthropic account, separately from a Claude.ai subscription.") {
                SettingRow(title: "Model", subtitle: choice.detail + (choice == .fast ? ", quickest replies" : choice == .smart ? ", best for hard problems" : ", quick and capable")) {
                    SwiftUI.Picker("", selection: $choice) { ForEach(AssistantModelChoice.allCases) { Text($0.title).tag($0) } }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 260)
                        .onChange(of: choice) { Settings.assistantModel = choice }
                }
                if hasKey {
                    SettingRow(title: "API key", subtitle: "Saved in your Keychain.", divider: false) {
                        SecondaryButton(title: "Remove") { Keychain.setAPIKey(nil); hasKey = false }
                    }
                } else {
                    SettingRow(title: "API key", subtitle: "Create one at console.anthropic.com → API Keys.", divider: false) {
                        HStack(spacing: 8) {
                            SecureField("sk-ant-…", text: $apiKey).textFieldStyle(.roundedBorder).frame(width: 220)
                            PrimaryButton(title: "Save") {
                                Keychain.setAPIKey(apiKey.trimmingCharacters(in: .whitespacesAndNewlines))
                                apiKey = ""
                                hasKey = Keychain.hasKey
                            }
                            .disabled(apiKey.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                }
            }
            SettingsGroup(title: "Keys", footer: "Move and ask keys only work while the panel is open. Esc hides it, and you can drag the bar too. Click a shortcut to change it.") {
                SettingRow(title: "Show or hide") { ShortcutField(.assist) }
                SettingRow(title: "Talk to it", subtitle: "Opens it and listens. Stop talking and it asks. Say yes or no to approve.") { ShortcutField(.assistVoice) }
                SettingRow(title: "Ask about the screen", subtitle: "With nothing typed, it helps with what's on screen.") { ShortcutField(.assistAsk) }
                SettingRow(title: "Move", subtitle: "Hold this with the arrow keys.") {
                    SwiftUI.Picker("", selection: $move) { ForEach(MoveKeys.allCases) { Text($0.label + " + arrows").tag($0) } }
                        .labelsHidden().frame(width: 140)
                        .onChange(of: move) { Settings.assistantMove = move; model.onAssistKeysChanged?() }
                }
                SettingRow(title: "See-through", subtitle: "How much of what's behind shows through.", divider: false) {
                    Slider(value: Binding(get: { 1 - darkness }, set: { darkness = 1 - $0 }), in: 0.15...0.75).frame(width: 220).tint(Theme.accent)
                }
            }
            SettingsGroup(title: "Chat look", footer: "Like texting a friend: your messages on the right, theirs on the left.") {
                SettingRow(title: "Their name and picture", subtitle: "Leave the picture empty for Bubble's logo, or type an emoji.") {
                    HStack(spacing: 8) {
                        TextField("", text: $chatAvatar).textFieldStyle(.roundedBorder).frame(width: 44).multilineTextAlignment(.center)
                        TextField("Bubble", text: $chatName).textFieldStyle(.roundedBorder).frame(width: 150)
                    }
                }
                SettingRow(title: "Your bubbles") {
                    HStack(spacing: 9) {
                        ForEach(ChatStyle.mineChoices, id: \.0) { hex, label in
                            Button { myColor = hex } label: {
                                Circle().fill(ChatStyle.color(hex) ?? .blue).frame(width: 20, height: 20)
                                    .overlay(Circle().stroke(Color.primary.opacity(myColor == hex ? 0.8 : 0), lineWidth: 2).padding(-3))
                            }
                            .buttonStyle(.plain).help(label)
                        }
                    }
                }
                SettingRow(title: "Their bubbles") {
                    SwiftUI.Picker("", selection: $theirColor) { ForEach(ChatStyle.theirsChoices, id: \.0) { Text($0.1).tag($0.0) } }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 260)
                }
                SettingRow(title: "Text size") {
                    SwiftUI.Picker("", selection: $textSize) { Text("Small").tag(13.0); Text("Medium").tag(14.0); Text("Large").tag(16.0) }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 220)
                }
                // Preview, on a dark background like the panel.
                VStack(spacing: 8) {
                    let st = ChatStyle.current(mine: myColor, theirs: theirColor, size: textSize)
                    ChatRow(mine: true, style: st) { Text("Can you message Sam that I'm running late?") }
                    ChatRow(mine: false, style: st, showAvatar: false) { Text("Done, it's typed in Messenger.") }
                    ChatRow(mine: false, style: st) { Text("Check it and press Enter to send.") }
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.78)))
                .environment(\.colorScheme, .dark)
                .padding(.horizontal, 16).padding(.bottom, 14)
            }
            SettingsGroup(title: "Chat history", footer: "Chats are saved only on this Mac, readable by your account alone, so Bubble picks up where you left off. Screenshots are never saved. After six hours away, Bubble starts a fresh chat and offers to continue the last one.") {
                SettingRow(title: "Keep chats") {
                    SwiftUI.Picker("", selection: $keepDays) {
                        Text("Forever").tag(-1); Text("30 days").tag(30); Text("7 days").tag(7); Text("Don't keep").tag(0)
                    }
                    .labelsHidden().frame(width: 130)
                    .onChange(of: keepDays) { Settings.chatKeepDays = keepDays; ChatStore.prune() }
                }
                SettingRow(title: "Delete all chats", subtitle: "Removes every saved chat from this Mac. Can't be undone.", divider: false) {
                    SecondaryButton(title: "Delete…") {
                        let a = NSAlert()
                        a.messageText = "Delete all your Bubble chats?"
                        a.informativeText = "They're removed from this Mac and can't be brought back."
                        a.addButton(withTitle: "Delete All").hasDestructiveAction = true
                        a.addButton(withTitle: "Cancel")
                        if a.runModal() == .alertFirstButtonReturn { ChatStore.deleteAll() }
                    }
                }
            }
            SettingsGroup(title: "What Bubble knows about you", footer: "Using ChatGPT or another assistant? Copy the prompt, paste it there, then paste its answer here. It's saved only on this Mac (readable by your account alone) and sent with your questions so Bubble already knows you. With Claude Code, Bubble also uses your Claude memory.") {
                SettingRow(title: "1. Ask your other assistant", subtitle: "Copies a short prompt to paste into ChatGPT, Gemini or similar.") {
                    SecondaryButton(title: "Copy prompt", icon: "doc.on.doc") { copy(AboutMe.exportPrompt) }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("2. Paste its answer").font(.system(size: 13, weight: .medium))
                    ZStack(alignment: .topLeading) {
                        TextEditor(text: $aboutMe).font(.system(size: 13)).scrollContentBackground(.hidden).padding(6)
                            .frame(minHeight: 110, maxHeight: 220)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Palette.canvas))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.border))
                        if aboutMe.isEmpty {
                            Text("• My name is…\n• I study… / I work as…").font(.system(size: 13)).foregroundStyle(Palette.subtle)
                                .padding(.horizontal, 11).padding(.vertical, 8).allowsHitTesting(false)
                        }
                    }
                    HStack {
                        if aboutSaved { Label("Saved on this Mac", systemImage: "checkmark.circle.fill").font(.system(size: 12)).foregroundStyle(.green) }
                        Spacer()
                        Button("Forget it") { aboutMe = ""; AboutMe.save(""); aboutSaved = false }.buttonStyle(.plain)
                            .font(.system(size: 12.5)).foregroundStyle(Palette.subtle).disabled(aboutMe.isEmpty)
                        PrimaryButton(title: "Save") { AboutMe.save(aboutMe); aboutSaved = true }
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
            }
            SettingsGroup(title: "Listening", footer: "Only when you turn on Listen in the panel, and a red dot shows while it's on. Sound is transcribed on this Mac and never uploaded; only the recent text goes to Claude when you ask.") {
                SettingRow(title: "Listen hears your Mac's sound", subtitle: "The other people on a call or meeting, or a video you're watching. Not your microphone.") { Image(systemName: "speaker.wave.2").foregroundStyle(Palette.subtle) }
                SettingRow(title: "To talk to Bubble yourself", subtitle: "Use Talk (\(ShortcutCenter.shared.label(.assistVoice))) in the panel.", divider: false) { Image(systemName: "mic").foregroundStyle(Palette.subtle) }
            }
            SettingsGroup(title: "Seeing your screen", footer: "Each time you ask, Bubble sends one screenshot of the display you're on (without its own panel). Turn it off with the eye button in the panel. The panel itself shows up in screen shares and recordings, like any window.") {
                SettingRow(title: "Screenshot when you ask", subtitle: "On by default.", divider: false) { Image(systemName: "eye").foregroundStyle(Palette.subtle) }
            }
        }
        .onAppear { hasKey = Keychain.hasKey }
    }
}

// MARK: - Settings

struct SettingsPage: View {
    @ObservedObject var model: UIModel
    @ObservedObject var permissions: Permissions
    @ObservedObject private var themes = ThemeStore.shared
    @State private var atLogin = LoginItem.isOn
    @State private var checkUpdates = Settings.checkUpdates

    private var version: String {
        let i = Bundle.main.infoDictionary
        return "\(i?["CFBundleShortVersionString"] as? String ?? "?") (\(i?["CFBundleVersion"] as? String ?? "?"))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            PageHeader(title: "Settings")
            SettingsGroup(title: "General", footer: LoginItem.needsApproval ? "macOS needs your OK: open System Settings → General → Login Items and turn Bubble on." : "Bubble's shortcuts only work while it's running, so opening it at login keeps them ready. Update checks read one small file from Bubble's website, once a day.") {
                SwitchRow(title: "Open Bubble when you log in", subtitle: "It starts quietly in the menu bar.", isOn: $atLogin)
                    .onChange(of: atLogin) { LoginItem.set(atLogin) }
                SwitchRow(title: "Check for updates automatically", subtitle: "Tells you when a newer Bubble is out. Installing is up to you.", isOn: $checkUpdates)
                    .onChange(of: checkUpdates) { Settings.checkUpdates = checkUpdates }
                SettingRow(title: "Version", subtitle: "Bubble \(version)", divider: false) {
                    SecondaryButton(title: "Check now") { Updates.check(manual: true) {} }
                }
            }
            SettingsGroup(title: "Appearance") {
                SettingRow(title: "Accent colour", subtitle: themes.current.name) {
                    HStack(spacing: 10) {
                        ForEach(BubbleTheme.all) { t in
                            Button { themes.current = t } label: {
                                Circle().fill(Color(nsColor: t.start.blended(withFraction: 0.35, of: t.end) ?? t.start))
                                    .frame(width: 18, height: 18)
                                    .overlay(Circle().stroke(Color.primary.opacity(themes.current == t ? 0.8 : 0), lineWidth: 2).padding(-3))
                            }
                            .buttonStyle(.plain).help(t.name)
                        }
                    }
                }
                SwitchRow(title: "Sound effects", subtitle: "Soft pops when recording or dictation starts and ends.", isOn: $model.sounds, divider: false)
            }
            SettingsGroup(title: "Keyboard shortcuts", footer: "Click a shortcut and press new keys. Right-click to reset.") {
                ForEach(Array(ShortcutAction.allCases.enumerated()), id: \.element) { i, a in
                    SettingRow(title: a.title, divider: i < ShortcutAction.allCases.count - 1) { ShortcutField(a) }
                }
            }
            SettingsGroup(title: "Permissions", footer: "Bubble only uses these on your Mac. After allowing Screen Recording, quit and reopen Bubble.") {
                PermissionRows(permissions: permissions, onlyMissing: false)
            }
            SettingsGroup(title: "Storage") {
                SettingRow(title: "Recordings folder", subtitle: Settings.folder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")) {
                    SecondaryButton(title: "Open", icon: "folder") { model.onOpenFolder?() }
                }
                SettingRow(title: "Snippets", subtitle: "~/Library/Application Support/Bubble, readable only by you.", divider: false) {
                    SecondaryButton(title: "Show") {
                        NSWorkspace.shared.activateFileViewerSelecting([FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                            .appendingPathComponent("Bubble/snippets.json")])
                    }
                }
            }
            SettingsGroup(title: "About") {
                SettingRow(title: "Welcome tour", subtitle: "Meet Bubble again: permissions, connecting your AI and its promises.") {
                    SecondaryButton(title: "Show again") { Settings.onboardScene = 0; Settings.onboarded = false }
                }
                SettingRow(title: "Bubble", subtitle: "Free and open source. No account, no tracking.", divider: false) {
                    SecondaryButton(title: "GitHub", icon: "arrow.up.right") { NSWorkspace.shared.open(URL(string: "https://github.com/HarryNGU/bubble")!) }
                }
            }
        }
    }
}

struct PermissionRows: View {
    enum Kind: CaseIterable { case screen, camera, mic, speech, accessibility }
    @ObservedObject var permissions: Permissions
    var onlyMissing: Bool
    var kinds: [Kind] = Kind.allCases

    private func info(_ k: Kind) -> (String, String, Bool, String) {
        switch k {
        case .screen: return ("Screen Recording", "To record your screen.", permissions.screen, "Privacy_ScreenCapture")
        case .camera: return ("Camera", "For the camera bubble.", permissions.camera, "Privacy_Camera")
        case .mic: return ("Microphone", "For your voice in recordings and dictation.", permissions.mic, "Privacy_Microphone")
        case .speech: return ("Speech Recognition", "On-device, for dictation and naming.", permissions.speech, "Privacy_SpeechRecognition")
        case .accessibility: return ("Accessibility", "To notice your dictation shortcut and type for you.", permissions.accessibility, "Privacy_Accessibility")
        }
    }

    var body: some View {
        let shown = kinds.filter { !onlyMissing || !info($0).2 }
        ForEach(Array(shown.enumerated()), id: \.offset) { i, k in
            let (title, detail, ok, pane) = info(k)
            SettingRow(title: title, subtitle: detail, divider: i < shown.count - 1) {
                if ok {
                    Label("Allowed", systemImage: "checkmark.circle.fill").font(.system(size: 12.5, weight: .medium)).foregroundStyle(.green)
                } else {
                    SecondaryButton(title: "Allow…") { request(k, pane: pane) }
                }
            }
        }
    }

    private func request(_ k: Kind, pane: String) {
        switch k {
        case .camera:
            if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined { AVCaptureDevice.requestAccess(for: .video) { _ in }; return }
        case .mic:
            if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined { AVCaptureDevice.requestAccess(for: .audio) { _ in }; return }
        case .speech:
            if SFSpeechRecognizer.authorizationStatus() == .notDetermined { SFSpeechRecognizer.requestAuthorization { _ in }; return }
        case .accessibility:
            Inserter.requestTrust()
        case .screen:
            CGRequestScreenCaptureAccess()
        }
        Permissions.open(pane)
    }
}

func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}
