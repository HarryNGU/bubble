// Bubble's own sound effects, synthesised at launch (no audio files): a rising "bloop" when
// recording starts, a falling one when it ends, and a soft tick for each countdown number.

import AVFoundation

enum Sounds {
    private static var players: [String: AVAudioPlayer] = [:]
    private static let rate = 48_000.0

    static func preload() {
        players["start"] = player(bloop(from: 520, to: 980, second: 1320))
        players["stop"] = player(bloop(from: 980, to: 560, second: 440))
        players["tick"] = player(tick())
        loadVoiceSounds()
        players["start"]?.volume = 0.55
        players["stop"]?.volume = 0.55
        players["tick"]?.volume = 0.35
        log("sounds ready: \(players.values.count)/5")
    }

    static func start() { play("start") }
    static func stop() { play("stop") }
    static func tick() { play("tick") }
    /// Dictation starts listening / stops listening.
    static func listen() { play("listen") }
    static func heard() { play("heard") }

    /// The voice sounds you can pick in Dictation settings.
    enum VoiceStyle: String, CaseIterable, Identifiable {
        case pop, wood, glass
        var id: String { rawValue }
        var title: String { switch self { case .pop: "Soft pop"; case .wood: "Wood"; case .glass: "Glass" } }
    }

    static var voiceStyle: VoiceStyle {
        get { VoiceStyle(rawValue: Settings.d.string(forKey: "voiceSound") ?? "") ?? .pop }
        set { Settings.d.set(newValue.rawValue, forKey: "voiceSound"); loadVoiceSounds() }
    }

    static func loadVoiceSounds() {
        switch voiceStyle {
        case .pop:
            players["listen"] = player(pops([(250, 360), (300, 430)]))   // two low, rounded pops, rising
            players["heard"] = player(pops([(380, 260)]))                // one pop, falling
        case .wood:
            players["listen"] = player(chime([392.0, 523.3]))  // G4 then C5
            players["heard"] = player(chime([523.3, 392.0]))
        case .glass:
            players["listen"] = player(chime([659.3, 987.8]))  // the original: E5 then B5
            players["heard"] = player(chime([987.8, 784.0]))
        }
        players["listen"]?.volume = voiceStyle == .pop ? 0.85 : 0.45
        players["heard"]?.volume = voiceStyle == .pop ? 0.75 : 0.38
    }

    private static func play(_ name: String) {
        guard Settings.sounds, let p = players[name] else { return }
        p.currentTime = 0
        p.play()
    }

    // MARK: Synthesis

    /// Two quick sine "drops": a pitch glide with a soft attack, then a higher (or lower) chime.
    private static func bloop(from f0: Double, to f1: Double, second f2: Double) -> [Float] {
        let n = Int(rate * 0.42)
        var out = [Float](repeating: 0, count: n)
        var phase = 0.0
        for i in 0..<Int(rate * 0.16) {
            let t = Double(i) / rate
            let f = f0 + (f1 - f0) * min(1, t / 0.07)
            phase += 2 * .pi * f / rate
            let env = min(1, t / 0.006) * exp(-t / 0.05)
            out[i] += Float(sin(phase) * env * 0.8)
        }
        let offset = Int(rate * 0.075)
        var p2 = 0.0
        for i in 0..<(n - offset) {
            let t = Double(i) / rate
            p2 += 2 * .pi * f2 / rate
            let env = min(1, t / 0.004) * exp(-t / 0.09)
            out[offset + i] += Float((sin(p2) + 0.25 * sin(2 * p2)) * env * 0.45)
        }
        return out
    }

    /// Muted "bloop" pops: a sine whose pitch slides like a bubble, with a soft start, a quick
    /// fade and the top end rolled off, so it reads as a gentle tap rather than a beep.
    private static func pops(_ glides: [(Double, Double)]) -> [Float] {
        let n = Int(rate * 0.32)
        var out = [Double](repeating: 0, count: n)
        for (k, g) in glides.enumerated() {
            let offset = Int(rate * 0.075) * k
            var phase = 0.0
            for i in 0..<(n - offset) {
                let t = Double(i) / rate
                let f = g.0 + (g.1 - g.0) * (1 - exp(-t / 0.025))
                phase += 2 * .pi * f / rate
                let env = min(1, t / 0.008) * exp(-t / 0.055)
                out[offset + i] += (sin(phase) + 0.12 * sin(2 * phase)) * env * 0.45
            }
        }
        var y = 0.0, y2 = 0.0
        return out.map { x in y += 0.22 * (x - y); y2 += 0.22 * (y - y2); return Float(y2) }
    }

    /// Two soft mallet notes, like a marimba in a small room: a rounded attack, a tiny pitch
    /// settle, a fast-fading bright overtone, gentle low-pass and a short room echo.
    private static func chime(_ notes: [Double]) -> [Float] {
        let n = Int(rate * 0.55)
        var dry = [Double](repeating: 0, count: n)
        for (k, f) in notes.enumerated() {
            let offset = Int(rate * 0.085) * k
            let gain = k == 0 ? 0.8 : 1.0
            var p1 = 0.0, p4 = 0.0
            for i in 0..<(n - offset) {
                let t = Double(i) / rate
                let bend = 1 + 0.012 * exp(-t / 0.012)  // lands on pitch, like a struck bar
                p1 += 2 * .pi * f * bend / rate
                p4 += 2 * .pi * f * 3.9 / rate
                let body = sin(p1) * exp(-t / 0.16)
                let bright = sin(p4) * 0.18 * exp(-t / 0.018)
                let attack = min(1, t / 0.005)
                dry[offset + i] += (body + bright) * attack * gain * 0.42
            }
        }
        // Room: a few soft early reflections.
        var wet = dry
        for (ms, g) in [(23.0, 0.22), (41.0, 0.16), (67.0, 0.11), (97.0, 0.07)] {
            let d = Int(rate * ms / 1000)
            for i in d..<n { wet[i] += dry[i - d] * g }
        }
        // One-pole low-pass takes the edge off.
        var y = 0.0
        return wet.map { x in y += 0.35 * (x - y); return Float(y) }
    }

    /// A short, soft wooden tick.
    private static func tick() -> [Float] {
        let n = Int(rate * 0.09)
        return (0..<n).map { i in
            let t = Double(i) / rate
            let env = min(1, t / 0.002) * exp(-t / 0.018)
            return Float((sin(2 * .pi * 1250 * t) * 0.7 + sin(2 * .pi * 2500 * t) * 0.2) * env)
        }
    }

    private static func player(_ samples: [Float]) -> AVAudioPlayer? {
        try? AVAudioPlayer(data: wav(samples))
    }

    /// 16-bit mono PCM WAV in memory.
    private static func wav(_ samples: [Float]) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
        let bytes = UInt32(samples.count * 2)
        d.append("RIFF".data(using: .ascii)!); u32(36 + bytes)
        d.append("WAVEfmt ".data(using: .ascii)!); u32(16); u16(1); u16(1)
        u32(UInt32(rate)); u32(UInt32(rate) * 2); u16(2); u16(16)
        d.append("data".data(using: .ascii)!); u32(bytes)
        for s in samples {
            var v = Int16(max(-1, min(1, s)) * 32767).littleEndian
            d.append(Data(bytes: &v, count: 2))
        }
        return d
    }
}
