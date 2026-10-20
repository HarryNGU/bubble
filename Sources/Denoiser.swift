// A small spectral noise reducer, used when Apple's voice processing isn't available.
// It learns the steady background noise (fans, hum, hiss) per frequency and turns those
// frequencies down, leaving voices. 1024-sample frames, 50% overlap, Hann window.

import Accelerate

final class Denoiser {
    private let n = 1024
    private let hop = 512
    private let window: [Float]
    private let forward: vDSP.DFT<Float>
    private let inverse: vDSP.DFT<Float>
    private var pending: [Float] = []
    private var overlap: [Float]
    private var ready: [Float]
    private var smoothed: [Float]       // per-bin power, lightly smoothed over time
    private var blockMin: [Float]       // quietest power in the current block of frames
    private var history: [[Float]] = [] // quietest power in each recent block
    private var lastGain: [Float]
    private var frames = 0

    private let floorGain: Float = 0.08      // at most about -22 dB of reduction
    private let overSubtract: Float = 4.0    // in power terms
    private let blockFrames = 24             // ~0.25 s at 48 kHz
    private let blocks = 6                   // noise = quietest level over the last ~1.5 s
    private let minBias: Float = 2.0         // the minimum sits below the average noise level
    private let lowCutHz: Float = 80

    init?() {
        guard let f = vDSP.DFT(count: 1024, direction: .forward, transformType: .complexReal, ofType: Float.self),
              let i = vDSP.DFT(count: 1024, direction: .inverse, transformType: .complexReal, ofType: Float.self) else { return nil }
        forward = f
        inverse = i
        // Periodic Hann: overlapping frames at 50% sum to exactly 1, so unchanged audio passes through.
        window = (0..<1024).map { 0.5 - 0.5 * cos(2 * Float.pi * Float($0) / 1024) }
        overlap = [Float](repeating: 0, count: 1024)
        ready = [Float](repeating: 0, count: 1024)  // primes the output (21 ms latency)
        smoothed = [Float](repeating: 0, count: 513)
        blockMin = [Float](repeating: .greatestFiniteMagnitude, count: 513)
        lastGain = [Float](repeating: 1, count: 513)
    }

    /// Returns the same number of samples it was given (delayed by one frame).
    func process(_ input: [Float], sampleRate: Float) -> [Float] {
        pending += input
        while pending.count >= n {
            processFrame(Array(pending[0..<n]), sampleRate: sampleRate)
            pending.removeFirst(hop)
        }
        let k = min(input.count, ready.count)
        var out = Array(ready[0..<k])
        ready.removeFirst(k)
        if out.count < input.count { out = [Float](repeating: 0, count: input.count - out.count) + out }
        return out
    }

    private func processFrame(_ frame: [Float], sampleRate: Float) {
        let half = n / 2
        let w = vDSP.multiply(frame, window)
        var re = [Float](repeating: 0, count: half), im = re
        for i in 0..<half { re[i] = w[2 * i]; im[i] = w[2 * i + 1] }
        var fr = [Float](repeating: 0, count: half), fi = fr
        forward.transform(inputReal: re, inputImaginary: im, outputReal: &fr, outputImaginary: &fi)

        // Packed layout: fr[0] = DC, fi[0] = Nyquist, bins 1..<half in fr/fi.
        var power = [Float](repeating: 0, count: half + 1)
        power[0] = fr[0] * fr[0]; power[half] = fi[0] * fi[0]
        for k in 1..<half { power[k] = fr[k] * fr[k] + fi[k] * fi[k] }

        // Minimum statistics: background noise is the quietest the signal gets over ~1.5 s.
        // Voices come and go, so they rarely set the minimum; fans and hum never go away.
        frames += 1
        for k in 0...half {
            smoothed[k] = frames == 1 ? power[k] : 0.75 * smoothed[k] + 0.25 * power[k]
            blockMin[k] = min(blockMin[k], smoothed[k])
        }
        if frames % blockFrames == 0 {
            history.append(blockMin)
            if history.count > blocks { history.removeFirst() }
            blockMin = [Float](repeating: .greatestFiniteMagnitude, count: half + 1)
        }

        let binHz = sampleRate / Float(n)
        var gain = [Float](repeating: 1, count: half + 1)
        for k in 0...half {
            // Until two blocks (~0.5 s) have been seen there's no trustworthy noise estimate:
            // leave the audio alone rather than risk treating the first words as noise.
            guard history.count >= 2 else { gain[k] = 1; continue }
            var floorPower = Float.greatestFiniteMagnitude
            for h in history { floorPower = min(floorPower, h[k]) }
            let noisePower = floorPower == .greatestFiniteMagnitude ? 0 : floorPower * minBias
            var g = power[k] > 1e-12 ? 1 - overSubtract * noisePower / power[k] : 0
            g = max(floorGain * floorGain, min(1, g)).squareRoot()
            if Float(k) * binHz < lowCutHz { g = 0 }
            g = 0.55 * lastGain[k] + 0.45 * g  // smooth over time to avoid "musical" artefacts
            lastGain[k] = g
            gain[k] = g
        }
        fr[0] *= gain[0]; fi[0] *= gain[half]
        for k in 1..<half { fr[k] *= gain[k]; fi[k] *= gain[k] }

        var tr = [Float](repeating: 0, count: half), ti = tr
        inverse.transform(inputReal: fr, inputImaginary: fi, outputReal: &tr, outputImaginary: &ti)
        let scale = 1 / Float(2 * n)  // vDSP's forward+inverse round trip scales by 2n
        for i in 0..<half {
            overlap[2 * i] += tr[i] * scale
            overlap[2 * i + 1] += ti[i] * scale
        }
        ready += overlap[0..<hop]
        overlap = Array(overlap[hop...]) + [Float](repeating: 0, count: hop)
    }
}
