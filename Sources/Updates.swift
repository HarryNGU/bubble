// Tells you when a newer Bubble is out, so fixes reach you. It reads one small public file from
// Bubble's website (no account, nothing about you is sent beyond a normal web request), at most once
// a day, and only if "Check for updates" is on. Installing is up to you.

import AppKit

extension Settings {
    static var checkUpdates: Bool { get { d.object(forKey: "checkUpdates") as? Bool ?? true } set { d.set(newValue, forKey: "checkUpdates") } }
    fileprivate static var lastUpdateCheck: Date? { get { d.object(forKey: "lastUpdateCheck") as? Date } set { d.set(newValue, forKey: "lastUpdateCheck") } }
}

enum Updates {
    struct Release { let version: String; let page: URL }

    static let feed = URL(string: "https://harryngu.github.io/bubble/release.json")!
    static var current: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }

    /// A newer version found by the last check, if any.
    private(set) static var available: Release?

    /// Once a day at most, when it's turned on.
    static func checkIfDue(changed: @escaping () -> Void) {
        guard Settings.checkUpdates else { return }
        if let last = Settings.lastUpdateCheck, Date().timeIntervalSince(last) < 86_400 { return }
        check(manual: false, changed: changed)
    }

    static func check(manual: Bool, changed: @escaping () -> Void) {
        var req = URLRequest(url: feed, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        req.setValue("Bubble/\(current)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { data, _, error in
            let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            DispatchQueue.main.async {
                Settings.lastUpdateCheck = Date()
                guard let json, let v = json["version"] as? String else {
                    if manual { alert("Couldn't check for updates", "Check your internet connection and try again.") }
                    return
                }
                let public_ = json["available"] as? Bool ?? true
                if public_ && isNewer(v, than: current) {
                    available = Release(version: v, page: URL(string: "https://harryngu.github.io/bubble/#download")!)
                    log("updates: \(v) available")
                    changed()
                    if manual {
                        if alert("Bubble \(v) is available", "You have \(current). The new version has fixes and improvements.", ok: "Get It", cancel: "Later") {
                            NSWorkspace.shared.open(available!.page)
                        }
                    }
                } else {
                    available = nil
                    changed()
                    if manual { alert("You're up to date", "Bubble \(current) is the newest version.") }
                }
            }
        }.resume()
    }

    /// "1.10.0" is newer than "1.9.2".
    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }

    @discardableResult
    private static func alert(_ title: String, _ text: String, ok: String = "OK", cancel: String? = nil) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.addButton(withTitle: ok)
        if let cancel { a.addButton(withTitle: cancel) }
        return a.runModal() == .alertFirstButtonReturn
    }
}
