// Reactive sound level for the visualizer. Captures system audio via ScreenCaptureKit
// (needs the "Screen Recording" permission), computes the spectrum with vDSP, and exposes 5 bands in 0…1.
// If the permission is missing or capture fails, it stays inactive and the visualizer draws a fallback animation.
// It only runs while something is playing and the island is on screen; otherwise capture is turned off (saves battery).

import AVFoundation
import Accelerate
import ScreenCaptureKit

final class AudioMeter: NSObject, ObservableObject, SCStreamOutput, SCStreamDelegate {
    static let bandCount = 5
    /// Band edges, Hz (bass → treble). Musical energy is mostly below ~10 kHz.
    private static let edges: [Float] = [40, 160, 500, 1500, 5000, 12000]
    private static let fftSize = 1024

    /// Whether capture is actually running with data — then the visualizer dances to the sound.
    @Published private(set) var isReactive = false

    private let lock = NSLock()
    private var levels = [Float](repeating: 0, count: bandCount)
    /// Slowly converging ceiling and floor per band: the level is stretched across this span, so the bars
    /// jump with the music's dynamics (beat ↔ pause) instead of sticking at the maximum.
    private var ceil = [Float](repeating: 0, count: bandCount)
    private var floor = [Float](repeating: 1, count: bandCount)

    private let queue = DispatchQueue(label: "island.audio")
    private var stream: SCStream?
    private var running = false
    private var starting = false
    private var wantActive = false

    private let fft = vDSP_create_fftsetup(vDSP_Length(log2(Float(AudioMeter.fftSize))), FFTRadix(kFFTRadix2))
    private var hann: [Float]
    private var pending: [Float] = []
    private var sampleRate: Float = 48000

    override init() {
        hann = [Float](repeating: 0, count: Self.fftSize)
        vDSP_hann_window(&hann, vDSP_Length(Self.fftSize), Int32(vDSP_HANN_NORM))
        super.init()
    }

    /// The current band levels (a copy, callable from any thread).
    func read() -> [Float] {
        lock.lock(); defer { lock.unlock() }
        return levels
    }

    func setActive(_ on: Bool) {
        wantActive = on
        if on { startCapture() } else { stopCapture() }
    }

    // MARK: - Capture

    private func startCapture() {
        guard !running, !starting else { return }
        starting = true
        Task { [weak self] in
            guard let self else { return }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                guard let display = content.displays.first, self.wantActive else {
                    self.starting = false
                    return
                }
                let config = SCStreamConfiguration()
                config.capturesAudio = true
                config.excludesCurrentProcessAudio = true
                config.sampleRate = 48000
                config.channelCount = 2
                config.width = 2
                config.height = 2
                let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []),
                                      configuration: config, delegate: self)
                try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: self.queue)
                try await stream.startCapture()
                self.sampleRate = Float(config.sampleRate)
                self.stream = stream
                self.running = true
                self.starting = false
                if !self.wantActive { self.stopCapture() }    // turned off while capture was coming up
            } catch {
                // Most often the "Screen Recording" permission isn't granted. Fall back to the animation silently.
                self.starting = false
                self.running = false
                await MainActor.run { self.isReactive = false }
            }
        }
    }

    private func stopCapture() {
        running = false
        let dying = stream
        stream = nil
        Task { try? await dying?.stopCapture() }
        lock.lock()
        levels = [Float](repeating: 0, count: Self.bandCount)
        ceil = [Float](repeating: 0, count: Self.bandCount)
        floor = [Float](repeating: 1, count: Self.bandCount)
        lock.unlock()
        DispatchQueue.main.async { if self.isReactive { self.isReactive = false } }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        running = false
        self.stream = nil
        DispatchQueue.main.async { if self.isReactive { self.isReactive = false } }
        // Try again if it's still wanted (for example the display changed).
        if wantActive { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.startCapture() } }
    }

    // MARK: - Receiving audio

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, running, let mono = Self.monoSamples(from: sampleBuffer) else { return }
        pending.append(contentsOf: mono)
        guard pending.count >= Self.fftSize else { return }
        let frame = Array(pending.suffix(Self.fftSize))
        pending.removeAll(keepingCapacity: true)

        let bands = Self.spectrum(frame, sampleRate: sampleRate, fft: fft, hann: hann)
        lock.lock()
        var dyn = [Float](repeating: 0, count: Self.bandCount)
        for i in 0..<Self.bandCount {
            let raw = bands[i]
            // Ceiling snaps up to the loud and lowers slowly; floor does the opposite. Stretch the band's span into 0…1.
            ceil[i] = raw > ceil[i] ? raw : ceil[i] + (raw - ceil[i]) * 0.06
            floor[i] = raw < floor[i] ? raw : floor[i] + (raw - floor[i]) * 0.06
            let span = ceil[i] - floor[i]
            let d = span > 0.05 ? min(max((raw - floor[i]) / span, 0), 1) : 0
            dyn[i] = pow(d, 1.8)        // gamma squeezes the middle and keeps the peaks — bars drop lower
        }
        // Per-frame contrast: subtract a fraction of the mean — the band that's sounding now stands out, the rest drop.
        // Otherwise dense, loud music keeps all bars up in a clump — this way they dance separately.
        let mean = dyn.reduce(0, +) / Float(Self.bandCount)
        for i in 0..<Self.bandCount {
            let target = min(max((dyn[i] - mean * 0.6) * 1.5, 0), 1)
            // Fast rise, gentle fall — like a real equalizer stack.
            levels[i] = target > levels[i] ? target : levels[i] * 0.8 + target * 0.2
        }
        lock.unlock()

        // Reactive = capture is running and delivering frames (in silence the bars simply drop, not fake motion).
        if !isReactive { DispatchQueue.main.async { self.isReactive = true } }
    }

    /// Averages the channels into mono Float32 from a ScreenCaptureKit buffer.
    private static func monoSamples(from sb: CMSampleBuffer) -> [Float]? {
        guard let format = CMSampleBufferGetFormatDescription(sb),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              asbd.mFormatID == kAudioFormatLinearPCM,
              asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0 else { return nil }

        // First learn the required list size (for non-interleaved stereo that's two buffers),
        // then allocate and fill it — otherwise the call would return an "array too small" error for stereo.
        var needed = 0
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sb, bufferListSizeNeededOut: &needed, bufferListOut: nil, bufferListSize: 0,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: 0, blockBufferOut: nil) == noErr, needed > 0 else { return nil }

        let raw = UnsafeMutableRawPointer.allocate(byteCount: needed, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        let ablPtr = raw.assumingMemoryBound(to: AudioBufferList.self)
        var blockBuffer: CMBlockBuffer?
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sb, bufferListSizeNeededOut: nil, bufferListOut: ablPtr, bufferListSize: needed,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: 0, blockBufferOut: &blockBuffer) == noErr else { return nil }

        let buffers = UnsafeMutableAudioBufferListPointer(ablPtr)
        if asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0 {
            // Channels in separate buffers — average element-wise.
            let frames = Int(buffers[0].mDataByteSize) / MemoryLayout<Float>.size
            guard frames > 0 else { return nil }
            var mono = [Float](repeating: 0, count: frames)
            var used = 0
            for buffer in buffers {
                guard let data = buffer.mData else { continue }
                let ptr = data.bindMemory(to: Float.self, capacity: frames)
                vDSP_vadd(mono, 1, ptr, 1, &mono, 1, vDSP_Length(frames))
                used += 1
            }
            if used > 1 { var scale = 1 / Float(used); vDSP_vsmul(mono, 1, &scale, &mono, 1, vDSP_Length(frames)) }
            return mono
        } else {
            // Interleaved channels in one buffer.
            guard let buffer = buffers.first, let data = buffer.mData else { return nil }
            let channels = Int(asbd.mChannelsPerFrame)
            let total = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            let frames = channels > 0 ? total / channels : total
            guard frames > 0 else { return nil }
            let ptr = data.bindMemory(to: Float.self, capacity: total)
            var mono = [Float](repeating: 0, count: frames)
            for f in 0..<frames {
                var sum: Float = 0
                for c in 0..<channels { sum += ptr[f * channels + c] }
                mono[f] = sum / Float(channels)
            }
            return mono
        }
    }

    /// Pure transform of a sample window into band levels 0…1 (also checked by the sine-wave test).
    static func spectrum(_ input: [Float], sampleRate: Float, fft: FFTSetup?, hann: [Float]) -> [Float] {
        let n = input.count
        guard let fft, n == fftSize, n == hann.count else { return [Float](repeating: 0, count: bandCount) }

        var windowed = [Float](repeating: 0, count: n)
        vDSP_vmul(input, 1, hann, 1, &windowed, 1, vDSP_Length(n))

        let half = n / 2
        var realp = [Float](repeating: 0, count: half)
        var imagp = [Float](repeating: 0, count: half)
        var mags = [Float](repeating: 0, count: half)
        realp.withUnsafeMutableBufferPointer { rp in
            imagp.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                windowed.withUnsafeBufferPointer { wp in
                    wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { cp in
                        vDSP_ctoz(cp, 2, &split, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zrip(fft, &split, 1, vDSP_Length(log2(Float(n))), FFTDirection(FFT_FORWARD))
                split.imagp[0] = 0    // zrip packs Nyquist here — not needed for the bands
                vDSP_zvabs(&split, 1, &mags, 1, vDSP_Length(half))
            }
        }

        // Take the PEAK in the band, not the average: the upper bands span tens of times more bins, and the
        // average would smear them to zero — that was the "downward slope". The AGC finishes the balancing.
        let binHz = sampleRate / Float(n)
        var bands = [Float](repeating: 0, count: bandCount)
        for b in 0..<bandCount {
            let lo = max(1, Int(edges[b] / binHz))
            let hi = min(half - 1, Int(edges[b + 1] / binHz))
            guard hi >= lo else { continue }
            var peak: Float = 0
            mags.withUnsafeBufferPointer { vDSP_maxv($0.baseAddress! + lo, 1, &peak, vDSP_Length(hi - lo + 1)) }
            // A wide log scale (−80…−12 dB) so loud music doesn't hit 1 and keeps dynamics for the span stretch.
            let db = 20 * log10(peak / Float(n) + 1e-7)
            bands[b] = min(max((db + 80) / 68, 0), 1)
        }
        return bands
    }
}
