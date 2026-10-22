// Ask Bubble's brain: the Claude Code you already use, running in the background. It starts in
// your home folder, so it has your memory notes, your CLAUDE.md files and your connected apps,
// and it uses your Claude subscription (no API key). One session stays open while you use the
// panel, so only the first question pays the start-up time.
//
// It only ever acts with your say-so: reading and searching run freely, but anything that
// changes something (sending, writing, running commands) waits for Approve in the panel.

import AppKit
import Foundation

final class ClaudeCodeSession: @unchecked Sendable {
    struct Approval: Identifiable {
        let id: String          // the request id Claude Code is waiting on
        let tool: String
        let input: [String: Any]
        var summary: String { ClaudeCodeSession.describe(tool, input) }
        var appName: String { ClaudeCodeSession.friendlyTool(tool) }
    }

    enum Event {
        case text(String)
        case activity(String)            // "Searching Gmail…"
        case approval(Approval)
        case done(error: String?)
    }

    static var binary: URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [home + "/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude", home + "/.claude/local/claude"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    var onEvent: ((Event) -> Void)?
    private var process: Process?
    private var stdin: FileHandle?
    private var buffer = Data()
    private var sessionID: String? = Settings.d.string(forKey: "assistantSessionID")
    private var busy = false
    private let lock = NSLock()

    /// Tools you said "Always allow" for.
    private var alwaysAllowed: Set<String> {
        get { Set(Settings.d.stringArray(forKey: "assistantAlwaysAllow") ?? []) }
        set { Settings.d.set(Array(newValue).sorted(), forKey: "assistantAlwaysAllow") }
    }

    var isRunning: Bool { process?.isRunning == true }

    private static var overlayPrompt: String { overlayText + "\n\n" + pictureRules + "\n\n" + actionRules }

    private static let actionRules = """
    Doing things: when the user asks you to do something ("email Alex this", "find me…", "book…"), do it with \
    your tools and connected apps rather than explaining how. For anything that reaches other people (emails, \
    messages, posts, invites): prepare it first, show exactly what will be sent and to whom, and end with a short \
    question like "Send it?". Only send after they say yes; Bubble also shows them an approval card. If they ask \
    to attach or upload what's on their screen, use the screenshot file path given in their message. On a Mac \
    you can use AppleScript (osascript) for Mail, Calendar, Reminders, Notes and opening apps or links.

    Messaging: for email use the Gmail connector (write a draft, show it, send only after they say yes). For \
    Messenger, Instagram, WhatsApp or Apple Messages use Bubble's prepare_message tool: it opens the chat and \
    types the message but never sends, so tell the user to check it and press Enter. Connected apps (Gmail, \
    Calendar, Notion, Drive and others) load a few seconds after you start and may be deferred: search for them \
    with ToolSearch before ever saying you have no connection to something.
    """

    private static let overlayText = """
    You are answering inside Bubble, a small see-through panel on the user's Mac screen that they open \
    for quick help while they work. Messages may include a screenshot of their screen and a live, \
    on-device transcript of the sound recently playing on their Mac (people on a call or meeting, or a video; \
    never the user's own voice), with mistakes and no speaker names. It looks like a chat with a friend, so text like one: send your reply as a few short \
    messages separated by a blank line, each one thought (one to three sentences), the most useful one first. \
    Keep all the detail that matters; just split it up. A list or code block can be its own message. Use what \
    you know about the user from memory and their connected apps when it helps, and talk to them warmly by name. \
    Show things when useful: code in fenced blocks, markdown links, YouTube watch links on their own line. No \
    tables. Only take actions the user asked for; Bubble asks them to approve anything that changes something.

    Reactions: like a friend in a chat, you can react to the user's message with an emoji by starting your reply \
    with [react: ❤️] (one or two emoji, for example 😂 at a joke, ❤️ at good news or thanks, 👍 at a plan, 🙏 when \
    they help you, 😮 at a surprise). Do it now and then when it fits, not every time, and never mention it. If \
    they tell you they reacted to one of your messages, take it as a friend would.
    """

    // MARK: Starting

    /// Starts the background session if it isn't running (the first answer then comes quicker).
    func warmUp() { _ = try? ensureRunning() }

    private func ensureRunning() throws {
        if isRunning { return }
        guard let bin = Self.binary else {
            throw Failure("Claude Code isn't installed. Install it from claude.com/claude-code, then sign in.")
        }
        let p = Process()
        p.executableURL = bin
        var args = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                    "--include-partial-messages", "--permission-prompt-tool", "stdio",
                    "--model", Settings.assistantModel.alias,
                    // Things that need Claude Code's own window, or would run on after the panel closes.
                    "--disallowedTools", "AskUserQuestion,EnterPlanMode,ExitPlanMode,EnterWorktree,ExitWorktree,CronCreate,CronDelete,ScheduleWakeup,Monitor,RemoteTrigger",
                    "--append-system-prompt", Self.overlayPrompt]
        if let id = sessionID { args += ["--resume", id] }
        if let cfg = BubbleToolServer.shared.mcpConfig { args += ["--mcp-config", cfg] }  // Bubble's own tools
        p.arguments = args
        p.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser  // where your memory lives
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = [bin.deletingLastPathComponent().path, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", env["PATH"] ?? ""].joined(separator: ":")
        p.environment = env
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = errPipe
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in self?.received(h.availableData) }
        errPipe.fileHandleForReading.readabilityHandler = { h in
            let s = String(decoding: h.availableData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if !s.isEmpty { log("claude code: \(s.prefix(300))") }
        }
        p.terminationHandler = { [weak self] proc in
            log("claude code: session ended (\(proc.terminationStatus))")
            guard let self else { return }
            self.lock.lock()
            let wasBusy = self.busy
            self.busy = false
            self.process = nil
            self.lock.unlock()
            if wasBusy { self.emit(.done(error: "Claude Code stopped unexpectedly. Try again.")) }
        }
        try p.run()
        process = p
        stdin = inPipe.fileHandleForWriting
        log("claude code: session started\(sessionID == nil ? "" : " (resumed)")")
    }

    // MARK: Asking

    func ask(_ text: String, screenshot: Data?) {
        do { try ensureRunning() } catch { emit(.done(error: error.localizedDescription)); return }
        var content: [[String: Any]] = []
        if let s = screenshot {
            content.append(["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": s.base64EncodedString()]])
        }
        content.append(["type": "text", "text": text])
        lock.lock(); busy = true; lock.unlock()
        send(["type": "user", "message": ["role": "user", "content": content]])
    }

    /// Stops the current answer (the session stays open for the next question).
    func interrupt() {
        send(["type": "control_request", "request_id": UUID().uuidString, "request": ["subtype": "interrupt"]])
    }

    /// Stops the background process but keeps the conversation for next time.
    func shutdown() { process?.terminate(); process = nil }

    /// Forget this conversation and start a new one next time.
    func reset() {
        process?.terminate()
        process = nil
        sessionID = nil
        Settings.d.removeObject(forKey: "assistantSessionID")
    }

    func answer(_ a: Approval, allow: Bool, always: Bool = false) {
        if allow && always { alwaysAllowed.insert(a.tool) }
        let response: [String: Any] = allow
            ? ["behavior": "allow", "updatedInput": a.input]
            : ["behavior": "deny", "message": "The user said no to this action. Don't try it again; tell them what you would have done instead."]
        send(["type": "control_response", "response": ["subtype": "success", "request_id": a.id, "response": response]])
    }

    private func send(_ obj: [String: Any]) {
        guard let h = stdin, var d = try? JSONSerialization.data(withJSONObject: obj) else { log("claude code: nothing to send to"); return }
        if CommandLine.arguments.contains("--assisttest") { log("claude code → \(obj["type"] as? String ?? "?")") }
        d.append(0x0A)
        do { try h.write(contentsOf: d) } catch { log("claude code: write failed: \(error.localizedDescription)") }
    }

    // MARK: Reading what Claude Code says

    private func received(_ data: Data) {
        guard !data.isEmpty else { return }
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
            handle(obj)
        }
    }

    private func handle(_ m: [String: Any]) {
        if ProcessInfo.processInfo.environment["BUBBLE_DEBUG"] != nil || CommandLine.arguments.contains("--assisttest") {
            log("claude code ← \(m["type"] as? String ?? "?") \(m["subtype"] as? String ?? "")")
        }
        switch m["type"] as? String {
        case "system":
            if m["subtype"] as? String == "init", let id = m["session_id"] as? String {
                sessionID = id
                Settings.d.set(id, forKey: "assistantSessionID")
            }
        case "stream_event":
            if let ev = m["event"] as? [String: Any], ev["type"] as? String == "content_block_delta",
               let delta = ev["delta"] as? [String: Any], delta["type"] as? String == "text_delta", let t = delta["text"] as? String {
                emit(.text(t))
            }
        case "assistant":
            let blocks = (m["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            for b in blocks where b["type"] as? String == "tool_use" {
                emit(.activity(Self.activity(b["name"] as? String ?? "", b["input"] as? [String: Any] ?? [:])))
            }
        case "control_request":
            guard let id = m["request_id"] as? String, let req = m["request"] as? [String: Any],
                  req["subtype"] as? String == "can_use_tool", let tool = req["tool_name"] as? String else { return }
            let input = req["input"] as? [String: Any] ?? [:]
            let a = Approval(id: id, tool: tool, input: input)
            if Self.isSafe(tool, input) && (Self.isReadOnly(tool) || alwaysAllowed.contains(tool)) {
                answer(a, allow: true)
            } else {
                emit(.approval(a))
            }
        case "result":
            lock.lock(); busy = false; lock.unlock()
            let isError = m["is_error"] as? Bool ?? false
            let text = m["result"] as? String ?? ""
            if isError, text.localizedCaseInsensitiveContains("no conversation found") {
                // The saved conversation is gone: start a new one next time.
                sessionID = nil
                Settings.d.removeObject(forKey: "assistantSessionID")
                process?.terminate()
                emit(.done(error: "Started a fresh conversation. Ask again."))
            } else if isError, text.contains("Not logged in") || text.contains("/login") {
                // Nothing was said yet, so don't try to resume this session later.
                sessionID = nil
                Settings.d.removeObject(forKey: "assistantSessionID")
                emit(.done(error: "Claude Code isn't signed in on this Mac yet. Open Terminal, run `claude`, type /login and sign in with your Claude account, then ask again."))
            } else {
                emit(.done(error: isError ? (text.isEmpty ? "Claude Code hit an error." : text) : nil))
            }
        default:
            break
        }
    }

    private func emit(_ e: Event) { DispatchQueue.main.async { self.onEvent?(e) } }

    // MARK: Which tools run without asking

    /// Places that hold keys, passwords and private history. Reading them, or searching inside
    /// them, always asks first, even for tools you've "always allowed".
    private static let privatePaths = ["/.ssh", "/.aws", "/.gnupg", "/.config/gh", "/.netrc", "/.docker", "/.kube",
                                       "/Library/Keychains", "/Library/Cookies", "/Library/Messages", "/Library/Mail",
                                       "/Library/Application Support/Google/Chrome", "/Library/Safari",
                                       "/.zsh_history", "/.bash_history", "/.claude.json", "/.claude/.credentials",
                                       "/Library/Application Support/Bubble/snippets.json", "/Library/Application Support/Bubble/about-me.md"]

    /// Guards against a web page, email or file tricking Claude into leaking something private:
    /// no reading secret files without asking, and no sending data out inside a web address.
    static func isSafe(_ tool: String, _ input: [String: Any]) -> Bool {
        let paths = ["file_path", "path", "notebook_path"].compactMap { input[$0] as? String }
        for p in paths {
            let full = (p as NSString).expandingTildeInPath
            if privatePaths.contains(where: { full.contains($0) }) { return false }
            let name = (full as NSString).lastPathComponent.lowercased()
            if name.hasPrefix(".env") || name.hasSuffix(".pem") || name.hasSuffix(".key") || name.contains("credential") || name.contains("secret") { return false }
        }
        if tool == "Grep" || tool == "Glob", (input["path"] as? String) == nil || (input["path"] as? String) == "~" || (input["path"] as? String) == NSHomeDirectory() {
            // Searching your whole home folder can sweep up secrets: ask.
            return false
        }
        if tool == "WebFetch", let u = input["url"] as? String {
            // Plain pages are fine; a long address or one carrying data in ?query=… asks first.
            guard let c = URLComponents(string: u), c.scheme == "https", (c.query ?? "").isEmpty, u.count <= 160 else { return false }
        }
        return true
    }

    /// Looking things up is fine; changing things needs your OK.
    static func isReadOnly(_ tool: String) -> Bool {
        if ["Read", "Glob", "Grep", "WebSearch", "WebFetch", "TodoWrite", "ToolSearch", "ListMcpResourcesTool", "ReadMcpResourceTool"].contains(tool) { return true }
        // Bubble's prepare_message only fills in the box; you still press send.
        if tool == "mcp__bubble__prepare_message" { return true }
        guard tool.hasPrefix("mcp__") else { return false }
        let action = tool.components(separatedBy: "__").last?.lowercased() ?? tool.lowercased()
        // A draft isn't sent; sending it later still asks.
        if action.contains("draft"), !["send", "delete", "remove", "trash"].contains(where: { action.contains($0) }) { return true }
        let readVerbs = ["get", "list", "search", "read", "fetch", "query", "find", "view", "show", "describe", "lookup", "retrieve"]
        let writeWords = ["send", "create", "delete", "update", "trash", "remove", "post", "publish", "share", "write", "edit", "move", "cancel", "reply", "forward", "pay", "transfer"]
        if writeWords.contains(where: { action.contains($0) }) { return false }
        return readVerbs.contains(where: { action.hasPrefix($0) || action.contains("-" + $0) || action.contains("_" + $0) })
    }

    static func friendlyTool(_ tool: String) -> String {
        if tool == "Bash" { return "Run a command" }
        if tool == "Write" || tool == "Edit" || tool == "NotebookEdit" { return "Change a file" }
        if tool.hasPrefix("mcp__") {
            let parts = tool.components(separatedBy: "__")
            return (parts.last ?? tool).replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ").capitalized
        }
        return tool
    }

    static func describe(_ tool: String, _ input: [String: Any]) -> String {
        if tool == "Bash" { return input["command"] as? String ?? "" }
        if let path = input["file_path"] as? String { return path.replacingOccurrences(of: NSHomeDirectory(), with: "~") }
        let pairs = input.prefix(4).map { k, v in "\(k): \(String(describing: v).prefix(120))" }
        return pairs.joined(separator: "\n")
    }

    static func activity(_ tool: String, _ input: [String: Any]) -> String {
        switch tool {
        case "WebSearch": return "Searching the web…"
        case "WebFetch": return "Reading a web page…"
        case "Read": return "Reading \(((input["file_path"] as? String) ?? "a file").split(separator: "/").last ?? "a file")…"
        case "Glob", "Grep": return "Looking through files…"
        case "Bash": return "Running a command…"
        default:
            if tool.hasPrefix("mcp__") { return friendlyTool(tool) + "…" }
            return "Working…"
        }
    }

    struct Failure: LocalizedError { let m: String; init(_ m: String) { self.m = m }; var errorDescription: String? { m } }
}

extension AssistantModelChoice {
    /// Claude Code's model names.
    var alias: String { switch self { case .fast: "haiku"; case .balanced: "sonnet"; case .smart: "opus" } }
}
