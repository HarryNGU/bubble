// Chrome tab support. ScreenCaptureKit can't capture a single browser tab, so a "tab" is
// recorded as the Chrome window with its tab strip, address bar and bookmarks bar cropped off.

import AppKit

enum Chrome {
    static let bundleID = "com.google.Chrome"
    static var pid: pid_t? { NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.processIdentifier }

    private static var measured: CGFloat?

    /// Height of Chrome's tab strip + toolbar (+ bookmarks bar) in points, for a normal
    /// (not full-screen) window. Exact when Chrome allows JavaScript from Apple Events
    /// (View → Developer); otherwise worked out from whether the bookmarks bar is shown.
    static func toolbarHeight() -> CGFloat {
        if let measured { return measured }
        var err: NSDictionary?
        let script = """
        tell application id "\(bundleID)" to execute active tab of front window javascript "String(window.outerHeight - window.innerHeight)"
        """
        if let s = NSAppleScript(source: script)?.executeAndReturnError(&err).stringValue, let v = Double(s), v > 20, v < 300 {
            log("chrome toolbar height (measured) = \(v)")
            measured = CGFloat(v)
            return CGFloat(v)
        }
        let h: CGFloat = bookmarksBarShown ? 122 : 87
        log("chrome toolbar height (estimated, bookmarks bar \(bookmarksBarShown ? "on" : "off")) = \(h)")
        return h
    }

    private static var bookmarksBarShown: Bool {
        let prefs = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Google/Chrome/Default/Preferences")
        guard let data = try? Data(contentsOf: prefs),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let bar = json["bookmark_bar"] as? [String: Any] else { return true }
        return bar["show_on_all_tabs"] as? Bool ?? false
    }
}
