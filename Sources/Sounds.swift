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
        players["start"]?.volume = 0.55
        players["stop"]?.volume = 0.55
        players["tick"]?.volume = 0.35
        log("sounds ready: \(players.values.count)/3")
    }

    static func start() { play("start") }
    static func stop() { play("stop") }
    static func tick() { play("tick") }

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
