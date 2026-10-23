// Your chats with Bubble, kept on this Mac so the panel always picks up where you left off.
// One file per chat in ~/Library/Application Support/Bubble/Chats, readable only by your account.
// Screenshots are never kept here, only whether Bubble looked at your screen.

import Foundation

extension Settings {
    /// How long chats are kept: -1 forever, 0 not at all, otherwise days.
    static var chatKeepDays: Int { get { d.object(forKey: "chatKeepDays") as? Int ?? 30 } set { d.set(newValue, forKey: "chatKeepDays") } }
}

struct ChatRecord: Codable, Identifiable, Equatable {
    struct Turn: Codable, Equatable {
        var question: String
        var answer: String
        var withScreen: Bool
        var at: Date
        var reactions: [Int: [String]] = [:]
    }

    var id = UUID()
    var started = Date()
    var updated = Date()
    /// The Claude Code conversation this chat continues, so Bubble remembers it too.
    var claudeSession: String?
    var turns: [Turn] = []

    var title: String {
        let q = turns.first?.question.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return q.isEmpty ? "New chat" : String(q.prefix(60))
    }
}

enum ChatStore {
    /// Coming back after this long starts a fresh chat; the last one stays a tap away.
    static let freshAfter: TimeInterval = 6 * 3600

    static var dir: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Bubble/Chats", isDirectory: true)
        if !FileManager.default.fileExists(atPath: d.path) {
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        return d
    }

    private static func file(_ id: UUID) -> URL { dir.appendingPathComponent("\(id.uuidString).json") }

    /// Every saved chat, newest first.
    static func all() -> [ChatRecord] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? dec.decode(ChatRecord.self, from: Data(contentsOf: $0)) }
            .sorted { $0.updated > $1.updated }
    }

    static func save(_ c: ChatRecord) {
        guard Settings.chatKeepDays != 0, !c.turns.isEmpty else { return }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(c) else { return }
        let url = file(c.id)
        try? data.write(to: url, options: [.atomic, .completeFileProtection])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func delete(_ id: UUID) { try? FileManager.default.removeItem(at: file(id)) }

    static func deleteAll() {
        for c in all() { delete(c.id) }
        LocalPicture.deleteAll()
    }

    /// Removes chats older than you chose to keep them.
    static func prune() {
        let days = Settings.chatKeepDays
        if days == 0 { deleteAll(); return }
        guard days > 0 else { return }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        for c in all() where c.updated < cutoff { delete(c.id) }
        LocalPicture.prune(olderThan: cutoff)
    }
}
