// Blurs private details in a recording as it's made: passwords, email addresses, phone and card
// numbers, API keys and the like. Apple's Vision reads the text on screen a few times a second, on
// this Mac; nothing it reads is sent anywhere, kept or written to the log. Password managers are
// left out of screen recordings altogether (see Recorder).
//
// It catches most things, not everything: something can show for a moment before it's spotted,
// and text Vision can't read isn't blurred. The setting says so.

import AppKit
import CoreImage
import CoreMedia
import Vision

extension Settings {
    static var blurPrivate: Bool { get { d.object(forKey: "blurPrivate") as? Bool ?? true } set { d.set(newValue, forKey: "blurPrivate") } }
}

final class Redactor {
    /// Apps whose windows are never recorded while this is on.
    static let passwordApps: Set<String> = [
        "com.apple.Passwords", "com.apple.keychainaccess", "com.1password.1password", "com.agilebits.onepassword7",
        "com.bitwarden.desktop", "com.lastpass.LastPass", "com.dashlane.dashlanephonefinal", "in.sinew.Enpass-Desktop",
        "org.keepassxc.keepassxc", "com.nordpass.macos.NordPass",
    ]

    private struct Region { var rect: CGRect; var until: CFAbsoluteTime }  // rect: 0...1, bottom-left origin

    // Everything below runs on the recorder's writer queue.
    private var regions: [Region] = []
    private var lastScan: CFAbsoluteTime = 0
    private let ci = CIContext(options: [.cacheIntermediates: false])
    private var pool: CVPixelBufferPool?
    private var poolKey = (0, 0, OSType(0))
    /// How many private things were spotted, for the log (never what they were).
    private(set) var spotted = 0

    /// How long a spotted region stays blurred after it was last seen, so it doesn't flicker.
    private static let hold: CFAbsoluteTime = 1.5
    private static let scanEvery: CFAbsoluteTime = 0.3

    /// Loads Vision's text reader before recording starts, so the first check doesn't hold up a frame.
    func warmUp() {
        let img = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 32))
        _ = try? VNImageRequestHandler(ciImage: img).perform([request()])
    }

    /// Called with each video frame (on the writer queue). Returns the frame with private details blurred.
    /// A frame that's due a check is checked before it's written, never after: macOS sends no new frames
    /// while the screen is still, so an unchecked frame could otherwise stay in the video for seconds.
    func process(_ sb: CMSampleBuffer) -> CMSampleBuffer {
        guard let px = CMSampleBufferGetImageBuffer(sb) else { return sb }
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastScan > Self.scanEvery {
            lastScan = now
            scan(px)
        }
        regions.removeAll { $0.until < now }
        guard !regions.isEmpty else { return sb }
        return blurred(sb, px, regions.map(\.rect)) ?? sb
    }

    // MARK: Finding private text

    private func request() -> VNRecognizeTextRequest {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .fast
        req.usesLanguageCorrection = false
        return req
    }

    private func scan(_ px: CVPixelBuffer) {
        // Half size is still sharp on a Retina screen and reads several times faster.
        var img = CIImage(cvPixelBuffer: px)
        if img.extent.width > 1800 { img = img.transformed(by: CGAffineTransform(scaleX: 0.5, y: 0.5)) }
        let req = request()
        guard (try? VNImageRequestHandler(ciImage: img, options: [.ciContext: ci]).perform([req])) != nil,
              let lines = req.results, !lines.isEmpty else { return }
        let found = Self.privateRects(in: lines)
        let until = CFAbsoluteTimeGetCurrent() + Self.hold
        for r in found {
            if let i = regions.firstIndex(where: { Self.similar($0.rect, r) }) {
                regions[i].rect = regions[i].rect.union(r)
                regions[i].until = until
            } else {
                regions.append(Region(rect: r, until: until))
                spotted += 1
            }
        }
    }

    private static func similar(_ a: CGRect, _ b: CGRect) -> Bool {
        let i = a.intersection(b)
        return !i.isNull && i.width * i.height > 0.3 * min(a.width * a.height, b.width * b.height)
    }

    /// Areas (normalised) of the lines' private parts.
    static func privateRects(in lines: [VNRecognizedTextObservation]) -> [CGRect] {
        var out: [CGRect] = []
        for (i, line) in lines.enumerated() {
            guard let cand = line.topCandidates(1).first else { continue }
            let s = cand.string
            for range in privateRanges(in: s) {
                if let box = try? cand.boundingBox(for: range)?.boundingBox { out.append(padded(box)) }
            }
            // A label on its own ("Password", "API key") with its value further along the same row.
            if isBareLabel(s) {
                let me = line.boundingBox
                let next = lines.enumerated()
                    .filter { $0.offset != i && $0.element.boundingBox.minX >= me.maxX - 0.005
                              && $0.element.boundingBox.minX - me.maxX < 0.35 && sameRow(me, $0.element.boundingBox) }
                    .min { $0.element.boundingBox.minX < $1.element.boundingBox.minX }
                if let n = next, !(n.element.topCandidates(1).first.map { isHiddenAlready($0.string) } ?? true) {
                    out.append(padded(n.element.boundingBox))
                }
            }
        }
        return out
    }

    private static func sameRow(_ a: CGRect, _ b: CGRect) -> Bool {
        let overlap = min(a.maxY, b.maxY) - max(a.minY, b.minY)
        return overlap > 0.5 * min(a.height, b.height)
    }

    private static func padded(_ r: CGRect) -> CGRect {
        r.insetBy(dx: -max(0.004, r.height * 0.3), dy: -r.height * 0.35)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    // MARK: What counts as private

    private static func re(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p) }

    private static let email = re(#"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#)
    private static let cardLike = re(#"(?<![\d.])(?:\d[ \-]?){12,18}\d(?![\d.])"#)
    private static let phoneLike = re(#"(?<![\w.])\+?\(?\d[\d \-().]{7,16}\d(?![\w.])"#)
    private static let ssn = re(#"\b\d{3}-\d{2}-\d{4}\b"#)
    private static let knownKeys = re(#"\b(?:(?:sk|pk|rk)-[A-Za-z0-9_\-]{16,}|gh[pousr]_[A-Za-z0-9]{20,}|xox[abpr]-[A-Za-z0-9\-]{10,}|AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_\-]{30,}|eyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}(?:\.[A-Za-z0-9_\-]+)?)"#)
    private static let longToken = re(#"[A-Za-z0-9_\-+/=]{28,}"#)
    private static let labelled = re(#"(?i)\b(?:password|passwd|passcode|pin|api[ _\-]?key|secret|token|tfn|tax file (?:number|no\.?)|ssn|social security(?: number)?|account (?:number|no\.?)|bsb|cvv|cvc|security code|card number|medicare(?: number)?|one[- ]time code|verification code|recovery (?:key|code))\b\s*[:=#]?\s*(\S.*)$"#)
    private static let bareLabel = re(#"(?i)^\s*(?:password|passwd|passcode|pin|api[ _\-]?key|secret(?: key)?|token|tfn|tax file number|ssn|account number|bsb|cvv|cvc|security code|card number|medicare number|verification code|recovery (?:key|code))\s*[:=]?\s*$"#)

    static func isBareLabel(_ s: String) -> Bool { bareLabel.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil }

    /// Dots or asterisks: already hidden by the app.
    private static func isHiddenAlready(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        return !t.isEmpty && t.allSatisfy { "•●*·∙⋅".contains($0) }
    }

    static func privateRanges(in s: String) -> [Range<String.Index>] {
        let all = NSRange(s.startIndex..., in: s)
        var out: [Range<String.Index>] = []
        func add(_ r: NSRange) { if let x = Range(r, in: s) { out.append(x) } }
        func digits(_ r: NSRange) -> String { (Range(r, in: s).map { String(s[$0]) } ?? "").filter(\.isNumber) }

        for m in email.matches(in: s, range: all) { add(m.range) }
        for m in knownKeys.matches(in: s, range: all) { add(m.range) }
        for m in ssn.matches(in: s, range: all) { add(m.range) }
        for m in cardLike.matches(in: s, range: all) where luhn(digits(m.range)) { add(m.range) }
        for m in phoneLike.matches(in: s, range: all) {
            let d = digits(m.range)
            if (9...15).contains(d.count), !looksLikeDateOrMath(Range(m.range, in: s).map { String(s[$0]) } ?? "") { add(m.range) }
        }
        for m in longToken.matches(in: s, range: all) {
            let t = Range(m.range, in: s).map { String(s[$0]) } ?? ""
            // Keys mix capitals, small letters and digits; long words, paths and links don't.
            if t.contains(where: \.isUppercase), t.contains(where: \.isLowercase), t.filter(\.isNumber).count >= 4,
               !t.contains("/") || t.filter({ $0 == "/" }).count < 2 { add(m.range) }
        }
        if let m = labelled.firstMatch(in: s, range: all), m.numberOfRanges > 1, m.range(at: 1).length >= 3,
           let v = Range(m.range(at: 1), in: s), !isHiddenAlready(String(s[v])) {
            out.append(v)
        }
        return out
    }

    private static func looksLikeDateOrMath(_ t: String) -> Bool {
        t.contains(".") && t.filter({ $0 == "." }).count == 1 && t.split(separator: ".").last.map { $0.count <= 2 } == true
    }

    static func luhn(_ d: String) -> Bool {
        guard (13...19).contains(d.count) else { return false }
        var sum = 0
        for (i, c) in d.reversed().enumerated() {
            var n = Int(String(c)) ?? 0
            if i % 2 == 1 { n *= 2; if n > 9 { n -= 9 } }
            sum += n
        }
        return sum % 10 == 0
    }

    // MARK: Blurring

    private func blurred(_ sb: CMSampleBuffer, _ px: CVPixelBuffer, _ rects: [CGRect]) -> CMSampleBuffer? {
        let w = CVPixelBufferGetWidth(px), h = CVPixelBufferGetHeight(px), fmt = CVPixelBufferGetPixelFormatType(px)
        if pool == nil || poolKey != (w, h, fmt) {
            var p: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, nil, [kCVPixelBufferPixelFormatTypeKey: fmt, kCVPixelBufferWidthKey: w,
                                               kCVPixelBufferHeightKey: h, kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &p)
            pool = p
            poolKey = (w, h, fmt)
        }
        guard let pool else { return nil }
        var outPx: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outPx)
        guard let outPx else { return nil }

        let img = CIImage(cvPixelBuffer: px)
        let ext = img.extent
        // Coarse blocks first, then a blur, so nothing underneath can be read back.
        let scale = max(14, ext.height / 70)
        let hidden = img.clampedToExtent()
            .applyingFilter("CIPixellate", parameters: [kCIInputScaleKey: scale])
            .applyingGaussianBlur(sigma: scale * 0.9)
        var out = img
        for r in rects {
            let box = CGRect(x: r.minX * ext.width, y: r.minY * ext.height, width: r.width * ext.width, height: r.height * ext.height).integral
            out = hidden.cropped(to: box).composited(over: out)
        }
        ci.render(out.cropped(to: ext), to: outPx, bounds: ext, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        if let att = CVBufferCopyAttachments(px, .shouldPropagate) { CVBufferSetAttachments(outPx, att, .shouldPropagate) }

        var timing = CMSampleTimingInfo()
        CMSampleBufferGetSampleTimingInfo(sb, at: 0, timingInfoOut: &timing)
        var desc: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: outPx, formatDescriptionOut: &desc)
        guard let desc else { return nil }
        var result: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: outPx, formatDescription: desc,
                                                 sampleTiming: &timing, sampleBufferOut: &result)
        return result
    }
}
