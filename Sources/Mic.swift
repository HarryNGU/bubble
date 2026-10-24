// Microphone capture with AVCaptureSession (the same, very reliable stack as the camera).
// With noise suppression on, every buffer goes through Bubble's Denoiser, which removes
// steady background noise (fans, hum, hiss, rumble) and keeps voices.
//
// Apple's voice processing (AVAudioEngine) was tried first, but on some Macs it comes up
// silent depending on what other apps are doing, so it isn't used.

import AVFoundation
import CoreAudio
import CoreMedia

final class MicCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    static let sampleRate = 48_000.0
    private var session: AVCaptureSession?
    private let queue = DispatchQueue(label: "bubble.mic")
    private var denoiser: Denoiser?
    private var buffersSeen = 0
    private var lastBuffer = Date()
    private var noiseSuppression = false
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: MicCapture.sampleRate,
                                       channels: 1, interleaved: false)!
    var onSampleBuffer: ((CMSampleBuffer) -> Void)?
    /// Level 0...1 (about -60 dB to 0 dB), roughly 12 times a second, on the main thread.
    var onLevel: ((Float) -> Void)?
    private var lastLevelReport = Date.distantPast

    func start(noiseSuppression: Bool) async throws {
        let chosen = Settings.micDevice
        guard let device = (chosen.isEmpty ? nil : AVCaptureDevice(uniqueID: chosen)) ?? AVCaptureDevice.default(for: .audio) else {
            throw RecordError(message: "No microphone found.")
        }
        let session = AVCaptureSession()
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw RecordError(message: "Can't use the microphone.") }
        session.addInput(input)
        let output = AVCaptureAudioDataOutput()
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: MicCapture.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: true,
        ]
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { throw RecordError(message: "Can't read the microphone.") }
        session.addOutput(output)

        queue.sync {
            buffersSeen = 0
            lastBuffer = Date()
            self.noiseSuppression = noiseSuppression
            denoiser = noiseSuppression ? Denoiser() : nil
        }
        session.startRunning()
        self.session = session

        // Make sure sound is actually arriving before the recording starts.
        for _ in 0..<20 where queue.sync(execute: { buffersSeen }) < 3 {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        let seen = queue.sync { buffersSeen }
        log("mic: \(device.localizedName), \(noiseSuppression ? "noise reducer on" : "no noise reduction"), \(seen) buffers in warm-up")
        if seen == 0 { log("mic: warning, no audio yet") }
    }

    /// Microphones to offer in the picker: (unique ID, name).
    static func devices() -> [(String, String)] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone], mediaType: .audio, position: .unspecified)
            .devices
            .filter { $0.transportType != Int32(bitPattern: kAudioDeviceTransportTypeVirtual)
                && $0.transportType != Int32(bitPattern: kAudioDeviceTransportTypeAggregate) }  // skip Zoom/Teams/Loom drivers
            .map { ($0.uniqueID, $0.localizedName) }
    }

    func stop() {
        session?.stopRunning()
        session = nil
        queue.async { self.denoiser = nil }
    }

    /// True when the mic was running but no sound has arrived for a while, for example after the
    /// Mac began to sleep and powered it off. (Silence still arrives as buffers; this is no buffers at all.)
    func isStalled(after seconds: TimeInterval) -> Bool {
        guard session != nil else { return false }
        return queue.sync { Date().timeIntervalSince(lastBuffer) > seconds }
    }

    /// Testing: stops the sound coming in, as a sleeping Mac does, without Bubble knowing.
    func stallForTesting() { session?.stopRunning() }

    /// Starts the mic again with the same settings.
    func restart() async throws {
        let suppress = queue.sync { noiseSuppression }
        stop()
        try await start(noiseSuppression: suppress)
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from connection: AVCaptureConnection) {
        buffersSeen += 1
        lastBuffer = Date()
        reportLevel(sb)
        guard let denoiser else { onSampleBuffer?(sb); return }

        let frames = CMSampleBufferGetNumSamples(sb)
        guard frames > 0, let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return }
        pcm.frameLength = AVAudioFrameCount(frames)
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sb, at: 0, frameCount: Int32(frames),
                                                           into: pcm.mutableAudioBufferList) == noErr,
              let p = pcm.floatChannelData?[0] else { return }
        let cleaned = denoiser.process(Array(UnsafeBufferPointer(start: p, count: frames)), sampleRate: Float(MicCapture.sampleRate))
        cleaned.withUnsafeBufferPointer { p.update(from: $0.baseAddress!, count: frames) }
        if let out = Self.sampleBuffer(from: pcm, pts: CMSampleBufferGetPresentationTimeStamp(sb)) { onSampleBuffer?(out) }
    }

    private func reportLevel(_ sb: CMSampleBuffer) {
        guard onLevel != nil, Date().timeIntervalSince(lastLevelReport) > 0.08,
              let block = CMSampleBufferGetDataBuffer(sb) else { return }
        lastLevelReport = Date()
        var length = 0
        var ptr: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length,
                                          dataPointerOut: &ptr) == noErr, let ptr, length >= 4 else { return }
        let count = length / 4
        var sum: Float = 0
        ptr.withMemoryRebound(to: Float.self, capacity: count) { f in
            for i in 0..<count { sum += f[i] * f[i] }
        }
        let db = 10 * log10(max(sum / Float(count), 1e-12))
        let level = max(0, min(1, (db + 60) / 60))
        DispatchQueue.main.async { self.onLevel?(level) }
    }

    /// Silence in the mic's format, to fill a gap left while the mic was off.
    static func silence(at pts: CMTime, seconds: Double) -> CMSampleBuffer? {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
        let frames = AVAudioFrameCount(seconds * sampleRate)
        guard frames > 0, let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        pcm.frameLength = frames  // a new buffer is already zeroed
        return sampleBuffer(from: pcm, pts: pts)
    }

    private static func sampleBuffer(from buffer: AVAudioPCMBuffer, pts: CMTime) -> CMSampleBuffer? {
        var desc: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: buffer.format.streamDescription, layoutSize: 0, layout: nil,
                                       magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &desc)
        guard let desc else { return nil }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(buffer.format.sampleRate)),
                                        presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var sb: CMSampleBuffer?
        CMSampleBufferCreate(allocator: nil, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil,
                             formatDescription: desc, sampleCount: CMItemCount(buffer.frameLength),
                             sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                             sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sb)
        guard let sb else { return nil }
        let status = CMSampleBufferSetDataBufferFromAudioBufferList(sb, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
                                                                    flags: 0, bufferList: buffer.audioBufferList)
        return status == noErr ? sb : nil
    }
}
