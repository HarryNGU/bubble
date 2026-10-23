// First-run welcome, told as a short conversation with Bubble. Bubble introduces itself, asks
// what to call you (optional, kept on this Mac), lets you pick what it helps with, asks for each
// permission one at a time with the reason, offers to use the Claude you already have, and makes
// its promises before Ask Bubble can see or hear anything. You can run it again from Settings.

import AppKit
import AVFoundation
import Speech
import SwiftUI

extension Settings {
    static var onboarded: Bool { get { d.bool(forKey: "onboarded") } set { d.set(newValue, forKey: "onboarded") } }
    /// You agreed to Ask Bubble's ground rules (screenshots on ask, consent when listening to others).
    static var assistantConsent: Bool { get { d.bool(forKey: "assistantConsent") } set { d.set(newValue, forKey: "assistantConsent") } }
    static var wantsRecord: Bool { get { d.object(forKey: "wantsRecord") as? Bool ?? true } set { d.set(newValue, forKey: "wantsRecord") } }
    static var wantsDictate: Bool { get { d.object(forKey: "wantsDictate") as? Bool ?? true } set { d.set(newValue, forKey: "wantsDictate") } }
    static var wantsAssist: Bool { get { d.object(forKey: "wantsAssist") as? Bool ?? true } set { d.set(newValue, forKey: "wantsAssist") } }
    /// What Bubble calls you. Only shown on this Mac; never sent anywhere.
    static var userName: String { get { d.string(forKey: "userName") ?? "" } set { d.set(newValue, forKey: "userName") } }
    /// Where the welcome tour was, so it picks up again if macOS asks you to reopen Bubble.
    static var onboardScene: Int { get { d.integer(forKey: "onboardScene") } set { d.set(newValue, forKey: "onboardScene") } }
}

struct OnboardingView: View {
    @ObservedObject var permissions: Permissions
    let onDone: () -> Void

    enum Scene: Int, CaseIterable { case hello, name, help, permissions, brain, promises, ready }
    enum BrainState { case checking, signedIn, signedOut, missing }

    // Testing: `--onboard N` opens scene N.
    @State private var scene: Scene = {
        let a = CommandLine.arguments
        if let i = a.firstIndex(of: "--onboard"), i + 1 < a.count, let n = Int(a[i + 1]), let s = Scene(rawValue: n) { return s }
        return Scene(rawValue: Settings.onboardScene) ?? .hello
    }()
    @State private var revealed = 0
    @State private var typing = false
    @State private var reply: String?
    @State private var playID = UUID()

    @State private var name = Settings.userName
    @State private var record = Settings.wantsRecord
    @State private var dictate = Settings.wantsDictate
    @State private var assist = Settings.wantsAssist
    @State private var brain = Settings.assistantBrain
    @State private var brainState = BrainState.checking
    @State private var showKeyField = false
    @State private var apiKey = ""
    @State private var hasKey = Keychain.hasKey
    @State private var agreed = Settings.assistantConsent
    @State private var skipped: Set<String> = []
    @State private var alreadyAllowed = false
    @State private var downloading: Double?
    @FocusState private var nameFocused: Bool
    @State private var atLogin = LoginItem.isOn
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            OnboardBackdrop()
            VStack(spacing: 0) {
                topBar
                GeometryReader { geo in
                ScrollViewReader { scroll in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            if scene == .ready { ReadyOrb().frame(maxWidth: .infinity).padding(.bottom, 14) }
                            ForEach(Array(lines.prefix(revealed).enumerated()), id: \.offset) { i, text in
                                BubbleLine(text: text, avatar: i == 0)
                                    .transition(.asymmetric(insertion: .scale(scale: 0.92, anchor: .bottomLeading).combined(with: .opacity), removal: .opacity))
                            }
                            if typing {
                                HStack(alignment: .bottom, spacing: 10) {
                                    Avatar(emoji: "", size: 30).opacity(revealed == 0 ? 1 : 0)
                                    TypingDots(label: "").foregroundStyle(.white)
                                        .padding(.horizontal, 16).padding(.vertical, 14)
                                        .background(glass(20))
                                }
                                .transition(.opacity)
                            }
                            if revealed >= lines.count && !typing && reply == nil {
                                actions
                                    .padding(.top, 16)
                                    .transition(.opacity.combined(with: .offset(y: 14)))
                            }
                            if let reply {
                                HStack { Spacer(minLength: 120); Text(reply).font(.system(size: 15.5)).foregroundStyle(.white)
                                    .padding(.horizontal, 16).padding(.vertical, 11)
                                    .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Theme.brand)) }
                                    .transition(.scale(scale: 0.9, anchor: .bottomTrailing).combined(with: .opacity))
                            }
                            Color.clear.frame(height: 1).id("end")
                        }
                        .frame(maxWidth: 680, alignment: .leading)
                        .padding(.horizontal, 40).padding(.top, max(28, geo.size.height * (scene == .ready ? 0.04 : 0.13))).padding(.bottom, 48)
                        .frame(maxWidth: .infinity)
                    }
                    .scrollIndicators(.never)
                    .onChange(of: revealed) { withAnimation(.easeOut(duration: 0.3)) { scroll.scrollTo("end", anchor: .bottom) } }
                }
                }
            }
        }
        .environment(\.colorScheme, .dark)
        .onAppear { permissions.refresh(); play(animated: true) }
    }

    // MARK: What Bubble says

    private var you: String { name.isEmpty ? "" : ", \(name)" }

    private var lines: [String] {
        switch scene {
        case .hello:
            return ["Hi, I'm Bubble 👋",
                    "I'm a personal assistant that lives on your Mac. Whatever you're working on, I can help: answer questions about what's on your screen, write and reply for you, type what you say, record and edit videos, and get tasks done.",
                    "Let's get to know each other. It takes about two minutes."]
        case .name:
            return ["First, what should I call you?"]
        case .help:
            return ["Lovely to meet you\(you)! Here's what I can do.",
                    "Keep the ones you'd like. You can change this any time."]
        case .permissions:
            if neededKinds.isEmpty { return ["Nothing to allow for what you picked. Easy."] }
            if alreadyAllowed { return ["You've already allowed everything I need. Thank you for trusting me 💙"] }
            return ["To help, I need your OK in macOS for a few things.",
                   "I'll explain each one. Skip anything you're unsure about, and I'll only ask again when you use that feature."]
        case .brain:
            var l = ["Now, my brain. I think with Claude, the AI made by Anthropic."]
            switch brainState {
            case .checking: break
            case .signedIn:
                l += ["Good news: Claude Code is on this Mac and you're signed in.",
                      "If I use it, I'll know your notes and the apps you've connected to it, like Gmail or Calendar, from day one. Anything I do for you still needs your OK."]
            case .signedOut:
                l += ["Claude Code is on this Mac, but it isn't signed in yet.",
                      "Open Terminal, type claude, then /login. Or use an Anthropic API key instead."]
            case .missing:
                l += ["I couldn't find Claude Code on this Mac. It's the best way to share your context with me.",
                      "You can install it, or use an Anthropic API key if you have one."]
            }
            return l
        case .promises:
            return ["Before we start, a few promises from me.",
                    "And one thing I'll ask of you: if I'm listening to a call, let the other people know."]
        case .ready:
            return ["That's it\(you)! I'm ready when you are.",
                    "Here's how to find me. Click a shortcut to change it."]
        }
    }

    // MARK: What you can do

    @ViewBuilder private var actions: some View {
        switch scene {
        case .hello:
            VStack(alignment: .leading, spacing: 14) {
                ReplyChips([("Nice to meet you!", true)]) { _ in say("Nice to meet you!") { go(.name) } }
                Label("Everything stays on this Mac unless you use something that needs the internet. No account, no tracking.", systemImage: "lock.fill")
                    .font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.55))
            }

        case .name:
            VStack(alignment: .trailing, spacing: 12) {
                HStack(spacing: 10) {
                    Spacer(minLength: 0)
                    TextField("", text: $name, prompt: Text("Your first name").foregroundColor(.white.opacity(0.35)))
                        .textFieldStyle(.plain).font(.system(size: 17)).foregroundStyle(.white)
                        .focused($nameFocused)
                        .onSubmit { saveName() }
                        .padding(.horizontal, 16).frame(width: 280, height: 46)
                        .background(glass(14))
                    Chip(title: "That's me", primary: true) { saveName() }
                        .disabled(clean(name).isEmpty).opacity(clean(name).isEmpty ? 0.4 : 1)
                }
                HStack(spacing: 14) {
                    Spacer(minLength: 0)
                    Chip(title: "Skip", primary: false) { name = ""; Settings.userName = ""; say("I'd rather not say") { go(.help) } }
                }
                Text("Only used to greet you. It never leaves this Mac.")
                    .font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.55))
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { nameFocused = true } }

        case .help:
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 12) {
                    FeatureCard(on: $assist, glyph: .assist, title: "Ask me anything", keys: ShortcutCenter.shared.label(.assist),
                                detail: "I see your screen when you ask, answer questions, write emails, find pictures and videos, and do tasks with your OK.",
                                example: "“Reply to this and say I'll be there at 6.”")
                    FeatureCard(on: $dictate, glyph: .dictate, title: "Talk instead of typing", keys: ShortcutCenter.shared.label(.dictate),
                                detail: "Double-tap Option in any app and just speak. I'll type a tidy version where your cursor is.",
                                example: "“Running ten minutes late, sorry!”")
                    FeatureCard(on: $record, glyph: .record, title: "Record and share", keys: ShortcutCenter.shared.label(.record),
                                detail: "Record your screen with your face in a bubble, then turn it into captioned reels in one click.",
                                example: "Tutorials, demos, quick updates")
                }
                let none = !(record || dictate || assist)
                ReplyChips([(none ? "Pick at least one" : "Sounds good", true)]) { _ in
                    say("Sounds good") { go(.permissions) }
                }
                .disabled(none).opacity(none ? 0.4 : 1)
            }

        case .permissions:
            permissionStep

        case .brain:
            brainStep

        case .promises:
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 14) {
                    promise("eye", "I only look at your screen when you ask.", "One screenshot per question. Turn the eye off in the chat for private things, like banking.")
                    promise("waveform", "I only listen when you turn it on.", "A red dot shows whenever I am. Voices are turned into text on this Mac.")
                    promise("paperplane", "I never send anything without your yes.", "Emails wait for your Approve. Messages are typed in, and you press Enter.")
                    promise("lock", "Your private files stay private.", "I ask before opening passwords, keys or history, or links that carry data.")
                    promise("person.2", "I'm never a secret.", "I show up in screen shares like any window. Please don't use me to cheat in exams or interviews.")
                }
                .padding(20)
                .background(glass(20))
                ReplyChips([("Deal 🤝", true), ("Not now, skip Ask Bubble", false)]) { i in
                    agreed = i == 0
                    say(i == 0 ? "Deal 🤝" : "Not now") { go(.ready) }
                }
            }

        case .ready:
            readyStep
        }
    }

    // MARK: Permissions, one at a time

    private struct Ask { let kind: PermissionRows.Kind; let icon: String; let short: String; let title: String; let why: String; let granted: Bool; let pane: String }
    /// Testing: `--pretend-new` shows the permission cards as if nothing were allowed yet.
    private static let pretendNew = CommandLine.arguments.contains("--pretend-new")

    private var asks: [Ask] {
        neededKinds.map { k in
            switch k {
            case .screen: return ask(k, short: "Screen", icon: "macwindow", title: "See your screen", why: "So I can record it, and look at it when you ask me something. Never in the background.", granted: permissions.screen, pane: "Privacy_ScreenCapture")
            case .camera: return ask(k, short: "Camera", icon: "video", title: "Use your camera", why: "For the round camera bubble in your recordings. Only while you record.", granted: permissions.camera, pane: "Privacy_Camera")
            case .mic: return ask(k, short: "Voice", icon: "mic", title: "Hear your voice", why: "So you can talk to me and dictate. Only while you're talking or recording.", granted: permissions.mic, pane: "Privacy_Microphone")
            case .speech: return ask(k, short: "Speech", icon: "waveform", title: "Understand speech", why: "Turns your voice into words, right here on this Mac.", granted: permissions.speech, pane: "Privacy_SpeechRecognition")
            case .accessibility: return ask(k, short: "Typing", icon: "keyboard", title: "Type for you", why: "So I can notice your shortcuts in any app and type where your cursor is.", granted: permissions.accessibility, pane: "Privacy_Accessibility")
            }
        }
    }

    private func ask(_ kind: PermissionRows.Kind, short: String, icon: String, title: String, why: String, granted: Bool, pane: String) -> Ask {
        Ask(kind: kind, icon: icon, short: short, title: title, why: why, granted: granted && !Self.pretendNew, pane: pane)
    }

    @ViewBuilder private var permissionStep: some View {
        let list = asks
        let current = list.first { !$0.granted && !skipped.contains($0.title) }
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                ForEach(list, id: \.title) { a in
                    HStack(spacing: 6) {
                        Image(systemName: a.granted ? "checkmark.circle.fill" : skipped.contains(a.title) ? "minus.circle" : a.icon)
                            .foregroundStyle(a.granted ? Color.green : .white.opacity(current?.title == a.title ? 1 : 0.5))
                        Text(a.short).foregroundStyle(.white.opacity(current?.title == a.title ? 1 : 0.6))
                    }
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 10).frame(height: 28)
                    .background(Capsule().fill(.white.opacity(current?.title == a.title ? 0.16 : 0.06)))
                }
            }
            if let a = current {
                HStack(alignment: .center, spacing: 20) {
                    Image(systemName: a.icon).font(.system(size: 30, weight: .medium)).foregroundStyle(.white)
                        .frame(width: 72, height: 72)
                        .background(Circle().fill(Theme.brand))
                        .shadow(color: Theme.accent.opacity(0.5), radius: 18)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(a.title).font(.system(size: 20, weight: .semibold, design: .rounded)).foregroundStyle(.white)
                        Text(a.why).font(.system(size: 14)).foregroundStyle(.white.opacity(0.7)).fixedSize(horizontal: false, vertical: true)
                        if a.kind == .screen {
                            Text("macOS may ask you to reopen Bubble after this. I'll pick up right here.")
                                .font(.system(size: 12)).foregroundStyle(.white.opacity(0.5)).padding(.top, 2)
                        }
                        HStack(spacing: 10) {
                            Chip(title: "Allow", primary: true) { request(a) }
                            Chip(title: "Not now", primary: false) { withAnimation(.spring(duration: 0.4)) { _ = skipped.insert(a.title) } }
                        }
                        .padding(.top, 8)
                    }
                }
                .padding(22)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(glass(22))
                .id(a.title)
                .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .move(edge: .leading).combined(with: .opacity)))
            } else {
                let allowed = list.allSatisfy(\.granted)
                ReplyChips([(allowed ? "All done, thank you" : "Done for now", true)]) { _ in
                    say(allowed ? "All done!" : "Done for now") { go(.brain) }
                }
            }
        }
        .animation(.spring(duration: 0.45), value: current?.title)
    }

    private func request(_ a: Ask) {
        switch a.kind {
        case .camera where AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { _ in DispatchQueue.main.async { permissions.refresh() } }
        case .mic where AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { _ in DispatchQueue.main.async { permissions.refresh() } }
        case .speech where SFSpeechRecognizer.authorizationStatus() == .notDetermined:
            SFSpeechRecognizer.requestAuthorization { _ in DispatchQueue.main.async { permissions.refresh() } }
        case .accessibility:
            Inserter.requestTrust(); Permissions.open(a.pane)
        case .screen:
            CGRequestScreenCaptureAccess(); Permissions.open(a.pane)
        default:
            Permissions.open(a.pane)
        }
    }

    // MARK: Connecting an AI

    @ViewBuilder private var brainStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            if showKeyField {
                VStack(alignment: .leading, spacing: 10) {
                    if hasKey {
                        Label("Your key is saved in the macOS Keychain.", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.system(size: 14))
                    } else {
                        HStack(spacing: 10) {
                            SecureField("", text: $apiKey, prompt: Text("sk-ant-…").foregroundColor(.white.opacity(0.35)))
                                .textFieldStyle(.plain).font(.system(size: 15, design: .monospaced)).foregroundStyle(.white)
                                .padding(.horizontal, 14).frame(width: 320, height: 42).background(glass(12))
                            Chip(title: "Save", primary: true) {
                                Keychain.setAPIKey(clean(apiKey)); apiKey = ""; hasKey = Keychain.hasKey
                            }
                            .disabled(clean(apiKey).isEmpty).opacity(clean(apiKey).isEmpty ? 0.4 : 1)
                        }
                    }
                    Text("Get one at console.anthropic.com. It's stored in your Keychain, and use is billed to your Anthropic account. With a key I won't know your notes or apps.")
                        .font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.55)).fixedSize(horizontal: false, vertical: true)
                }
                .padding(18).background(glass(18))
                ReplyChips(hasKey ? [("Use my API key", true), ("Back", false)] : [("Back", false)]) { i in
                    if hasKey && i == 0 { brain = .api; say("Use my API key") { go(.promises) } } else { withAnimation { showKeyField = false } }
                }
            } else {
                switch brainState {
                case .checking:
                    EmptyView()
                case .signedIn:
                    ReplyChips([("Use my Claude Code", true), ("Use an API key", false), ("Decide later", false)]) { pickBrain($0) }
                case .signedOut:
                    ReplyChips([("I've signed in, check again", true), ("Use an API key", false), ("Decide later", false)]) { pickBrain($0) }
                case .missing:
                    ReplyChips([("Get Claude Code", true), ("Use an API key", false), ("Decide later", false)]) { pickBrain($0) }
                }
            }
            Text("Use ChatGPT? You can bring over what it knows about you later, in Settings → Assistant.")
                .font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.45))
        }
    }

    private func pickBrain(_ i: Int) {
        switch i {
        case 0:
            switch brainState {
            case .signedIn: brain = .claudeCode; say("Use my Claude Code") { go(.promises) }
            case .missing: NSWorkspace.shared.open(URL(string: "https://claude.com/claude-code")!)
            default: checkBrain(replay: true)
            }
        case 1: withAnimation(.spring(duration: 0.4)) { showKeyField = true }
        default: say("Decide later") { go(.promises) }
        }
    }

    private func checkBrain(replay: Bool) {
        brainState = .checking
        Task {
            let s: BrainState
            if ClaudeCodeSession.binary == nil { s = .missing } else { s = await Self.claudeSignedIn() ? .signedIn : .signedOut }
            brainState = s
            if replay { play(animated: true) }
        }
    }

    // MARK: Ready

    @ViewBuilder private var readyStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                if assist && agreed {
                    shortcutTile(.assist, "Ask me anything", "Show or hide the chat")
                    shortcutTile(.assistVoice, "Just talk to me", "Say what you need")
                }
                if dictate { shortcutTile(.dictate, "Type with your voice", "In any app") }
                if record { shortcutTile(.record, "Record your screen", "Press again to finish") }
            }
            if assist && agreed {
                Label("Try it now: press \(ShortcutCenter.shared.label(.assist)) and ask me what's on your screen.", systemImage: "sparkles")
                    .font(.system(size: 13.5, weight: .medium)).foregroundStyle(.white.opacity(0.85))
            } else if assist {
                Label("Ask Bubble stays off for now. You can turn it on any time in Settings.", systemImage: "info.circle")
                    .font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.55))
            }
            Toggle(isOn: $atLogin) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Open Bubble when I log in").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                    Text("My shortcuts only work while I'm running, so this keeps me ready. You can change it in Settings.")
                        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.55)).fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch).tint(Theme.accent)
            .onChange(of: atLogin) { LoginItem.set(atLogin) }
            .padding(14).background(glass(16))
            if (dictate || record) && !Whisper.hasModel { whisperCard }
            HStack {
                Spacer()
                Button { finish() } label: {
                    HStack(spacing: 8) {
                        Text("Start using Bubble").font(.system(size: 16, weight: .semibold, design: .rounded))
                        Image(systemName: "arrow.right").font(.system(size: 14, weight: .bold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 26).frame(height: 50)
                    .background(Capsule().fill(Theme.brand))
                    .shadow(color: Theme.accent.opacity(0.55), radius: 20, y: 6)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
                Spacer()
            }
            .padding(.top, 10)
        }
    }

    private func shortcutTile(_ a: ShortcutAction, _ t: String, _ d: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(t).font(.system(size: 14.5, weight: .semibold)).foregroundStyle(.white)
                Text(d).font(.system(size: 12)).foregroundStyle(.white.opacity(0.55))
            }
            Spacer()
            ShortcutField(a)
        }
        .padding(14).background(glass(16))
    }

    private var whisperCard: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "ear").font(.system(size: 18)).foregroundStyle(.white).frame(width: 40, height: 40).background(Circle().fill(.white.opacity(0.1)))
            VStack(alignment: .leading, spacing: 2) {
                Text("Optional: sharper ears").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                Text(Whisper.binary == nil
                     ? "Whisper makes dictation and captions much more accurate, on this Mac. Needs Homebrew: brew install whisper-cpp"
                     : "Whisper makes dictation and captions much more accurate, on this Mac. A \(Whisper.modelSize) download, once.")
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.55)).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if Whisper.binary == nil {
                Chip(title: "Copy command", primary: false) { copy("brew install whisper-cpp") }
            } else if let p = downloading {
                ProgressView(value: p).frame(width: 120).tint(.white)
            } else {
                Chip(title: "Download", primary: false) { download() }
            }
        }
        .padding(14).background(glass(16))
    }

    // MARK: Pieces

    private var topBar: some View {
        HStack(spacing: 12) {
            Button { back() } label: {
                Image(systemName: "chevron.left").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.8))
                    .frame(width: 30, height: 30).background(Circle().fill(.white.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .opacity(scene == .hello ? 0 : 1).disabled(scene == .hello)
            Spacer()
            HStack(spacing: 6) {
                ForEach(Scene.allCases, id: \.self) { s in
                    Capsule().fill(s.rawValue <= scene.rawValue ? Color.white : Color.white.opacity(0.18))
                        .frame(width: s == scene ? 22 : 7, height: 7)
                }
            }
            .animation(.spring(duration: 0.4), value: scene)
            Spacer()
            Color.clear.frame(width: 30, height: 30)
        }
        .padding(.horizontal, 28).padding(.top, 40)
    }

    private func promise(_ icon: String, _ t: String, _ d: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon).font(.system(size: 15, weight: .medium)).foregroundStyle(.white)
                .frame(width: 32, height: 32).background(Circle().fill(Theme.brand))
            VStack(alignment: .leading, spacing: 2) {
                Text(t).font(.system(size: 14.5, weight: .semibold)).foregroundStyle(.white)
                Text(d).font(.system(size: 13)).foregroundStyle(.white.opacity(0.6)).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func glass(_ r: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: r, style: .continuous).fill(.white.opacity(0.08))
            .overlay(RoundedRectangle(cornerRadius: r, style: .continuous).stroke(.white.opacity(0.1)))
    }

    private var neededKinds: [PermissionRows.Kind] {
        var k: [PermissionRows.Kind] = []
        if assist { k += [.screen, .mic, .speech, .accessibility] }
        if record { k += [.screen, .camera, .mic] }
        if dictate { k += [.mic, .speech, .accessibility] }
        var seen = Set<String>()
        return k.filter { seen.insert("\($0)").inserted }
    }

    private func clean(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

    // MARK: Flow

    /// Bubble "types" its lines one by one, then shows what you can do.
    private func play(animated: Bool) {
        let id = UUID()
        playID = id
        reply = nil
        showKeyField = false
        alreadyAllowed = asks.allSatisfy(\.granted)
        if scene == .brain && brainState == .checking && animated { checkBrain(replay: true); revealed = 0; return }
        guard animated && !reduceMotion else { revealed = lines.count; typing = false; return }
        revealed = 0
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            for i in lines.indices {
                guard playID == id else { return }
                withAnimation(.easeOut(duration: 0.15)) { typing = true }
                let wait = min(0.35 + Double(lines[i].count) * 0.006, 1.0)
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                guard playID == id else { return }
                withAnimation(.spring(duration: 0.4, bounce: 0.25)) { typing = false; revealed = i + 1 }
                try? await Task.sleep(nanoseconds: 120_000_000)
            }
        }
    }

    /// Shows your reply as a blue message, then moves on.
    private func say(_ text: String, then next: @escaping () -> Void) {
        withAnimation(.spring(duration: 0.35, bounce: 0.3)) { reply = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { next() }
    }

    private func saveName() {
        let n = clean(name)
        guard !n.isEmpty else { return }
        name = String(n.prefix(40))
        Settings.userName = name
        say("Call me \(name)") { go(.help) }
    }

    private func go(_ s: Scene) {
        save()
        withAnimation(.easeInOut(duration: 0.25)) { revealed = 0; reply = nil }
        scene = s
        Settings.onboardScene = s.rawValue
        permissions.refresh()
        play(animated: true)
    }

    private func back() {
        guard let prev = Scene(rawValue: scene.rawValue - 1) else { return }
        save()
        scene = prev
        Settings.onboardScene = prev.rawValue
        play(animated: false)
    }

    private func save() {
        Settings.wantsRecord = record
        Settings.wantsDictate = dictate
        Settings.wantsAssist = assist
        Settings.assistantBrain = brain
        Settings.assistantConsent = agreed
    }

    private func finish() {
        save()
        Settings.onboardScene = 0
        Settings.onboarded = true
        onDone()
    }

    private func download() {
        downloading = 0
        Task {
            do { try await Whisper.downloadModel { p in Task { @MainActor in downloading = p } } } catch { log("onboarding: model download failed") }
            downloading = nil
        }
    }

    /// Whether the Claude Code on this Mac is signed in (asks it; nothing is sent).
    static func claudeSignedIn() async -> Bool {
        guard let bin = ClaudeCodeSession.binary else { return false }
        return await withCheckedContinuation { c in
            let p = Process()
            p.executableURL = bin
            p.arguments = ["auth", "status"]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            p.terminationHandler = { _ in
                let d = out.fileHandleForReading.readDataToEndOfFile()
                let json = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
                c.resume(returning: (json?["loggedIn"] as? Bool) == true)
            }
            do { try p.run() } catch { c.resume(returning: false) }
        }
    }
}

// MARK: - Look

/// A deep blue night with two soft lights drifting slowly behind everything.
private struct OnboardBackdrop: View {
    @State private var drift = false
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.03, green: 0.05, blue: 0.13), Color(red: 0.06, green: 0.08, blue: 0.2)], startPoint: .top, endPoint: .bottom)
            Circle().fill(Theme.accent).frame(width: 560, height: 560).blur(radius: 150).opacity(0.5)
                .offset(x: drift ? -260 : -120, y: drift ? -200 : -80)
            Circle().fill(Color(red: 0.0, green: 0.75, blue: 1.0)).frame(width: 420, height: 420).blur(radius: 140).opacity(0.28)
                .offset(x: drift ? 300 : 180, y: drift ? 260 : 140)
        }
        .ignoresSafeArea()
        .onAppear { withAnimation(.easeInOut(duration: 9).repeatForever(autoreverses: true)) { drift = true } }
    }
}

/// One of Bubble's messages, on the left with its logo on the first one.
private struct BubbleLine: View {
    let text: String
    let avatar: Bool
    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            Avatar(emoji: "", size: 30).opacity(avatar ? 1 : 0)
            Text(text)
                .font(.system(size: avatar ? 17 : 15.5, weight: avatar ? .semibold : .regular, design: avatar ? .rounded : .default))
                .foregroundStyle(.white.opacity(0.95))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16).padding(.vertical, 11)
                .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(.white.opacity(0.1)))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(.white.opacity(0.08)))
            Spacer(minLength: 80)
        }
    }
}

/// Quick replies, like the suggestions under a chat. The first can be the highlighted one.
private struct ReplyChips: View {
    let options: [(String, Bool)]
    let pick: (Int) -> Void
    init(_ options: [(String, Bool)], pick: @escaping (Int) -> Void) { self.options = options; self.pick = pick }
    var body: some View {
        HStack(spacing: 10) {
            Spacer(minLength: 0)
            ForEach(Array(options.enumerated()), id: \.offset) { i, o in
                Chip(title: o.0, primary: o.1) { pick(i) }
                    .modifier(DefaultIf(on: i == 0 && o.1))
            }
        }
    }
}

private struct DefaultIf: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View {
        if on { content.keyboardShortcut(.defaultAction) } else { content }
    }
}

private struct Chip: View {
    let title: String
    let primary: Bool
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 14.5, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 18).frame(height: 40)
                .background(Capsule().fill(primary ? AnyShapeStyle(Theme.brand) : AnyShapeStyle(Color.white.opacity(hover ? 0.16 : 0.09))))
                .overlay(Capsule().stroke(.white.opacity(primary ? 0 : 0.14)))
                .shadow(color: primary ? Theme.accent.opacity(hover ? 0.6 : 0.35) : .clear, radius: 14, y: 4)
                .scaleEffect(hover ? 1.03 : 1)
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hover = h } }
    }
}

/// One thing Bubble can do, to keep or leave out.
private struct FeatureCard: View {
    @Binding var on: Bool
    let glyph: BubbleGlyph.Kind
    let title: String
    let keys: String
    let detail: String
    let example: String
    @State private var hover = false
    var body: some View {
        Button { withAnimation(.spring(duration: 0.3)) { on.toggle() } } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    BubbleGlyph(kind: glyph, tinted: false, lineWidth: 2).foregroundStyle(.white)
                        .frame(width: 24, height: 24).frame(width: 46, height: 46)
                        .background(Circle().fill(on ? AnyShapeStyle(Theme.brand) : AnyShapeStyle(Color.white.opacity(0.1))))
                    Spacer()
                    Image(systemName: on ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 20)).foregroundStyle(on ? Color.white : Color.white.opacity(0.35))
                }
                Text(title).font(.system(size: 15.5, weight: .semibold, design: .rounded)).foregroundStyle(.white)
                Text(detail).font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.65)).lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Text(example).font(.system(size: 12, weight: .medium)).italic().foregroundStyle(.white.opacity(0.8))
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.07)))
                Text(keys).font(.system(size: 11.5, weight: .medium, design: .rounded)).foregroundStyle(.white.opacity(0.5))
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 250, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(.white.opacity(on ? 0.11 : 0.04)))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(on ? Theme.accent.opacity(0.9) : .white.opacity(0.08), lineWidth: on ? 1.5 : 1))
            .shadow(color: on ? Theme.accent.opacity(0.3) : .clear, radius: 18)
            .opacity(on ? 1 : 0.7)
            .scaleEffect(hover ? 1.015 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hover = h } }
    }
}

/// Bubble's logo, glowing, with rings rippling out: the finish line.
private struct ReadyOrb: View {
    @State private var go = false
    var body: some View {
        ZStack {
            ForEach(0..<3) { i in
                Circle().stroke(Theme.accent.opacity(0.5), lineWidth: 1.5)
                    .frame(width: 96, height: 96)
                    .scaleEffect(go ? 2.2 : 1).opacity(go ? 0 : 0.8)
                    .animation(.easeOut(duration: 2.4).repeatForever(autoreverses: false).delay(Double(i) * 0.8), value: go)
            }
            Circle().fill(Theme.brand).frame(width: 96, height: 96).shadow(color: Theme.accent.opacity(0.7), radius: 30)
            Circle().fill(.white).frame(width: 34, height: 34)
        }
        .frame(height: 170)
        .onAppear { go = true }
    }
}
