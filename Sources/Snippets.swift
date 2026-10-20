// Snippets: say a trigger phrase while dictating ("email 3") and Bubble types the saved
// text instead. Stored only on this Mac in ~/Library/Application Support/Bubble/snippets.json
// (never in the app bundle or the source code).

import Foundation

struct Snippet: Codable, Identifiable, Equatable {
    var id = UUID()
    var trigger: String
    var text: String
}

final class SnippetStore: ObservableObject {
    static let shared = SnippetStore()

    @Published private(set) var snippets: [Snippet] = []

    private let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Bubble", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("snippets.json")
    }()

    private init() {
        if let data = try? Data(contentsOf: url), let list = try? JSONDecoder().decode([Snippet].self, from: data) {
            snippets = list
        }
    }

    func add(trigger: String, text: String) {
        let t = trigger.trimmingCharacters(in: .whitespacesAndNewlines), v = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !v.isEmpty else { return }
        snippets.insert(Snippet(trigger: t, text: v), at: 0)
        save()
    }

    func update(_ s: Snippet) {
        guard let i = snippets.firstIndex(where: { $0.id == s.id }) else { return }
        snippets[i] = s
        save()
    }

    func delete(_ s: Snippet) {
        snippets.removeAll { $0.id == s.id }
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(snippets) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtection])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)  // only you can read it
    }

    /// Phrases to help speech recognition hear the triggers correctly.
    var triggers: [String] { snippets.map(\.trigger) }

    /// Replaces spoken triggers with their text. Matching ignores case and punctuation, and
    /// treats "3" and "three" as the same, so "Email three." still becomes your address.
    func expand(_ text: String) -> String {
        var out = text
        for s in snippets.sorted(by: { $0.trigger.count > $1.trigger.count }) {
            let words = s.trigger.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
            guard !words.isEmpty else { continue }
            let pattern = "\\b" + words.map(Self.variants).joined(separator: "[\\s,.\\-]+") + "\\b"
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            out = re.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out),
                                              withTemplate: NSRegularExpression.escapedTemplate(for: s.text))
        }
        return out
    }

    private static let numberWords = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
                                      "eleven", "twelve"]

    private static func variants(_ word: String) -> String {
        if let n = Int(word), n < numberWords.count { return "(?:\(word)|\(numberWords[n]))" }
        if let n = numberWords.firstIndex(of: word) { return "(?:\(word)|\(n))" }
        return NSRegularExpression.escapedPattern(for: word)
    }
}
