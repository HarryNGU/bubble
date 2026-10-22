// Tools Bubble lends to Ask Bubble's brain (Claude Code), over a tiny MCP server that only this
// Mac can reach (127.0.0.1, with a secret that changes every launch).
//
// prepare_message opens a chat in Messenger, Instagram, WhatsApp or Messages and puts the message
// in the box, but never sends it: you read it and press Enter yourself. Bubble keeps no
// passwords or tokens for these apps; it uses the browser and apps you're already signed in to.

import AppKit
import ApplicationServices
import Foundation
import Network

final class BubbleToolServer: @unchecked Sendable {
    static let shared = BubbleToolServer()

    private var listener: NWListener?
    private(set) var port: UInt16 = 0
    private let token = UUID().uuidString + UUID().uuidString
    private let queue = DispatchQueue(label: "bubble.tools")

    /// For Claude Code's --mcp-config. nil until the server is listening.
    var mcpConfig: String? {
        guard port > 0 else { return nil }
        let cfg: [String: Any] = ["mcpServers": ["bubble": [
            "type": "http", "url": "http://127.0.0.1:\(port)/mcp",
            "headers": ["Authorization": "Bearer \(token)"],
        ]]]
        return (try? JSONSerialization.data(withJSONObject: cfg)).flatMap { String(data: $0, encoding: .utf8) }
    }

    func start() {
        guard listener == nil else { return }
        do {
            let params = NWParameters.tcp
            params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            let l = try NWListener(using: params)
            l.newConnectionHandler = { [weak self] c in self?.serve(c) }
            l.stateUpdateHandler = { [weak self, weak l] state in
                if case .ready = state, let p = l?.port?.rawValue { self?.port = p; log("tools: listening on 127.0.0.1:\(p)") }
                if case .failed(let e) = state { log("tools: \(e)") }
            }
            l.start(queue: queue)
            listener = l
        } catch {
            log("tools: couldn't start: \(error.localizedDescription)")
        }
    }

    // MARK: HTTP, just enough for MCP

    private func serve(_ c: NWConnection) {
        c.start(queue: queue)
        read(c, Data())
    }

    private func read(_ c: NWConnection, _ soFar: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, err in
            guard let self else { return }
            var buf = soFar
            if let data { buf.append(data) }
            if let req = Self.parse(buf) {
                self.respond(c, req)
            } else if done || err != nil || buf.count > 4 << 20 {
                c.cancel()
            } else {
                self.read(c, buf)
            }
        }
    }

    private struct Request { let method: String; let path: String; let headers: [String: String]; let body: Data }

    private static func parse(_ d: Data) -> Request? {
        guard let end = d.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: d[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let first = head.first?.split(separator: " ") ?? []
        guard first.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in head.dropFirst() {
            guard let i = line.firstIndex(of: ":") else { continue }
            headers[line[..<i].lowercased()] = line[line.index(after: i)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let body = d[end.upperBound...]
        guard body.count >= length else { return nil }
        return Request(method: String(first[0]), path: String(first[1]), headers: headers, body: Data(body.prefix(length)))
    }

    private func send(_ c: NWConnection, status: String, json: Any?) {
        let body = json.flatMap { try? JSONSerialization.data(withJSONObject: $0) } ?? Data()
        var head = "HTTP/1.1 \(status)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
        if json != nil { head += "Content-Type: application/json\r\n" }
        head += "\r\n"
        c.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in c.cancel() })
    }

    private func respond(_ c: NWConnection, _ r: Request) {
        // Only Claude Code, started by Bubble, knows the secret.
        guard r.headers["authorization"] == "Bearer \(token)" else { send(c, status: "401 Unauthorized", json: nil); return }
        guard r.method == "POST" else { send(c, status: "405 Method Not Allowed", json: nil); return }
        guard let msg = (try? JSONSerialization.jsonObject(with: r.body)) as? [String: Any], let method = msg["method"] as? String else {
            send(c, status: "400 Bad Request", json: nil); return
        }
        let id = msg["id"]
        let params = msg["params"] as? [String: Any] ?? [:]
        func reply(_ result: Any) { send(c, status: "200 OK", json: ["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result]) }

        switch method {
        case "initialize":
            reply([
                "protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
                "capabilities": ["tools": [:] as [String: Any]],
                "serverInfo": ["name": "bubble", "version": "1.0"],
                "instructions": "Tools from Bubble, the Mac app the user is talking to you through.",
            ])
        case "tools/list":
            reply(["tools": Self.tools])
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let args = params["arguments"] as? [String: Any] ?? [:]
            Task { @MainActor in
                let (text, isError) = await BubbleTools.call(name, args)
                reply(["content": [["type": "text", "text": text]], "isError": isError])
            }
        case "ping":
            reply([:] as [String: Any])
        default:
            if method.hasPrefix("notifications/") { send(c, status: "202 Accepted", json: nil) }
            else { send(c, status: "200 OK", json: ["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": -32601, "message": "Unknown method"]]) }
        }
    }

    private static let tools: [[String: Any]] = [[
        "name": "prepare_message",
        "description": """
        Opens a chat with someone in Messenger, Instagram, WhatsApp or Apple Messages on the user's Mac and puts \
        the message in the message box. It never sends: the user reads it and presses Enter themselves. Use it \
        whenever the user asks you to message someone on those apps. `to` must be their Messenger username, \
        Instagram handle, WhatsApp phone number with country code, or Messages phone/email. If you don't know it, \
        ask the user (and remember it for next time).
        """,
        "inputSchema": [
            "type": "object",
            "properties": [
                "app": ["type": "string", "enum": ["messenger", "instagram", "whatsapp", "messages"]],
                "to": ["type": "string", "description": "Username, handle, phone number or email of the person."],
                "text": ["type": "string", "description": "The message, exactly as it should be sent."],
            ],
            "required": ["app", "to", "text"],
        ] as [String: Any],
    ]]
}

@MainActor
enum BubbleTools {
    static func call(_ name: String, _ args: [String: Any]) async -> (String, Bool) {
        switch name {
        case "prepare_message":
            return await prepareMessage(app: args["app"] as? String ?? "", to: args["to"] as? String ?? "", text: args["text"] as? String ?? "")
        default:
            return ("Unknown tool \(name).", true)
        }
    }

    static func prepareMessage(app: String, to rawTo: String, text: String) async -> (String, Bool) {
        let to = rawTo.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "@"))
        guard !to.isEmpty, !text.isEmpty else { return ("Need both who to message and what to say.", true) }
        let q = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let handle = to.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? to
        let url: URL?
        switch app.lowercased() {
        case "whatsapp":
            let digits = to.filter(\.isNumber)
            guard !digits.isEmpty else { return ("WhatsApp needs a phone number with country code.", true) }
            url = URL(string: "https://wa.me/\(digits)?text=\(q)")
        case "messenger": url = URL(string: "https://www.messenger.com/t/\(handle)")
        case "instagram": url = URL(string: "https://ig.me/m/\(handle)")
        case "messages", "imessage", "sms": url = URL(string: "sms:\(handle)")
        default: return ("Bubble can prepare messages in Messenger, Instagram, WhatsApp or Messages.", true)
        }
        guard let url else { return ("Couldn't make a link for \(to).", true) }
        NSWorkspace.shared.open(url)
        log("tools: prepare_message \(app)")
        if app.lowercased() == "whatsapp" {
            return ("Opened WhatsApp with the message filled in for \(to). It is NOT sent: the user checks it and presses Send.", false)
        }
        // Give the chat time to open, then type only into a message box (never an address bar).
        for _ in 0..<12 {
            try? await Task.sleep(for: .milliseconds(500))
            if messageBoxFocused() {
                Inserter.paste(text)
                return ("Opened the \(app) chat with \(to) and typed the message into the box. It is NOT sent: the user reads it and presses Enter to send.", false)
            }
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        return ("Opened the \(app) chat with \(to). Bubble couldn't find the message box, so the message is on the clipboard: the user clicks the box, presses ⌘V, then Enter. Tell them that.", false)
    }

    /// A text box where you'd write a message is focused (not the browser's address bar).
    private static func messageBoxFocused() -> Bool {
        guard Inserter.trusted, let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != getpid() else { return false }
        let appEl = AXUIElementCreateApplication(front.processIdentifier)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appEl, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let el = focused, CFGetTypeID(el) == AXUIElementGetTypeID() else { return false }
        let element = el as! AXUIElement
        func attr(_ name: String) -> String {
            var v: CFTypeRef?
            AXUIElementCopyAttributeValue(element, name as CFString, &v)
            return (v as? String ?? "").lowercased()
        }
        let role = attr(kAXRoleAttribute), desc = attr(kAXDescriptionAttribute) + " " + attr(kAXTitleAttribute) + " " + attr("AXPlaceholderValue")
        if desc.contains("address") || desc.contains("search") || desc.contains("url") { return false }
        if role == "AXTextArea" { return true }
        var editable: CFTypeRef?
        let rich = AXUIElementCopyAttributeValue(element, "AXEditableAncestor" as CFString, &editable) == .success && editable != nil
        return rich || (role == "AXTextField" && (desc.contains("message") || desc.contains("aa") || desc.contains("imessage")))
    }
}
