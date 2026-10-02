import Accelerate
import Foundation

/// Result of analysing one audio window.
public struct AnalysisFrame: Sendable {
    public var rms: Float
    /// Monophonic pitch estimate (YIN), in Hz.
    public var pitch: Double?
    /// 0...1, higher is more reliable.
    public var pitchConfidence: Double
    /// Harmonic salience per MIDI note (index = midi - 21), normalised so max = 1.
    public var salience: [Float]
    /// Fundamental peak magnitude per MIDI note, normalised by the strongest peak.
    public var fundamental: [Float]

    public var midiPitch: Int? {
        guard let p = pitch else { return nil }
        return Int(NoteName.midi(forFrequency: p).rounded())
    }

    /// Cents deviation of the YIN estimate from the nearest note.
    public var cents: Double? {
        guard let p = pitch else { return nil }
        let m = NoteName.midi(forFrequency: p)
        return (m - m.rounded()) * 100
    }

    public func salience(of midi: Int) -> Float {
        let i = midi - NoteName.pianoRange.lowerBound
        return salience.indices.contains(i) ? salience[i] : 0
    }

    public func fundamental(of midi: Int) -> Float {
        let i = midi - NoteName.pianoRange.lowerBound
        return fundamental.indices.contains(i) ? fundamental[i] : 0
    }

    /// Notes that look present in the spectrum, strongest first (rough polyphonic estimate).
    public func strongNotes(threshold: Float = 0.6, limit: Int = 4) -> [Int] {
        var result: [Int] = []
        let order = salience.indices.sorted { salience[$0] > salience[$1] }
        for i in order {
            guard salience[i] >= threshold, result.count < limit else { break }
            let midi = i + NoteName.pianoRange.lowerBound
            // Skip notes that are just harmonics of an already detected lower note.
            let isHarmonic = result.contains { base in
                let d = midi - base
                return [12, 19, 24, 28, 31].contains(d)
            }
            if !isHarmonic && fundamental[i] > 0.1 { result.append(midi) }
        }
        return result
    }
}

/// Pitch analysis combining YIN (monophonic, octave-accurate) and an FFT
/// harmonic-salience map (used to verify chords).
public final class PitchAnalyzer {
    public let sampleRate: Double
    public let fftSize: Int
    private let log2n: vDSP_Length
    private let fftSetup: FFTSetup
    private var window: [Float]

    public init(sampleRate: Double, fftSize: Int = 8192) {
        self.sampleRate = sampleRate
        self.fftSize = fftSize
        self.log2n = vDSP_Length(log2(Double(fftSize)))
        self.fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        self.window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
    }

    /// Analyse the last `fftSize` samples (fewer is OK, zero padded).
    public func analyze(_ input: [Float]) -> AnalysisFrame {
        var samples = input.count > fftSize ? Array(input.suffix(fftSize)) : input
        // Remove DC.
        var mean: Float = 0
        vDSP_meanv(samples, 1, &mean, vDSP_Length(samples.count))
        var negMean = -mean
        vDSP_vsadd(samples, 1, &negMean, &samples, 1, vDSP_Length(samples.count))

        // RMS on the most recent part only so that onsets are reactive.
        let recent = Array(samples.suffix(2048))
        var rms: Float = 0
        vDSP_rmsqv(recent, 1, &rms, vDSP_Length(recent.count))

        let (pitch, conf) = yin(Array(samples.suffix(4096)))
        let (sal, fund) = spectrum(samples)
        return AnalysisFrame(rms: rms, pitch: pitch, pitchConfidence: conf, salience: sal, fundamental: fund)
    }

    // MARK: - YIN

    private func yin(_ x: [Float], threshold: Float = 0.15) -> (Double?, Double) {
        let n = x.count
        guard n >= 512 else { return (nil, 0) }
        let w = n / 2
        let minTau = max(2, Int(sampleRate / 4500))
        let maxTau = min(w - 1, Int(sampleRate / 26))
        var d = [Float](repeating: 0, count: maxTau + 1)

        var e1: Float = 0
        x.withUnsafeBufferPointer { p in
            vDSP_svesq(p.baseAddress!, 1, &e1, vDSP_Length(w))
            var e2 = e1
            for tau in 1...maxTau {
                // Update energy of the shifted window incrementally.
                let out = x[tau - 1], inn = x[tau + w - 1]
                e2 += inn * inn - out * out
                var dot: Float = 0
                vDSP_dotpr(p.baseAddress!, 1, p.baseAddress! + tau, 1, &dot, vDSP_Length(w))
                d[tau] = max(0, e1 + e2 - 2 * dot)
            }
        }
        guard e1 > 1e-7 else { return (nil, 0) }

        // Cumulative mean normalised difference.
        var cmnd = [Float](repeating: 1, count: maxTau + 1)
        var running: Float = 0
        for tau in 1...maxTau {
            running += d[tau]
            cmnd[tau] = running > 0 ? d[tau] * Float(tau) / running : 1
        }

        var tauEstimate = -1
        var tau = minTau
        while tau <= maxTau {
            if cmnd[tau] < threshold {
                while tau + 1 <= maxTau && cmnd[tau + 1] < cmnd[tau] { tau += 1 }
                tauEstimate = tau
                break
            }
            tau += 1
        }
        if tauEstimate < 0 {
            // Fall back to the global minimum if it is reasonably low.
            var best = minTau
            for t in minTau...maxTau where cmnd[t] < cmnd[best] { best = t }
            guard cmnd[best] < 0.35 else { return (nil, 0) }
            tauEstimate = best
        }

        // Parabolic interpolation.
        var refined = Double(tauEstimate)
        if tauEstimate > 1 && tauEstimate < maxTau {
            let s0 = Double(cmnd[tauEstimate - 1]), s1 = Double(cmnd[tauEstimate]), s2 = Double(cmnd[tauEstimate + 1])
            let denom = 2 * (2 * s1 - s2 - s0)
            if abs(denom) > 1e-9 { refined += (s2 - s0) / denom }
        }
        let f = sampleRate / refined
        guard f >= 26, f <= 4500 else { return (nil, 0) }
        return (f, Double(max(0, 1 - cmnd[tauEstimate])))
    }

    // MARK: - Spectrum

    private func spectrum(_ x: [Float]) -> ([Float], [Float]) {
        var buf = [Float](repeating: 0, count: fftSize)
        let offset = fftSize - x.count
        for i in 0..<x.count { buf[offset + i] = x[i] }
        vDSP_vmul(buf, 1, window, 1, &buf, 1, vDSP_Length(fftSize))

        let half = fftSize / 2
        var real = [Float](repeating: 0, count: half)
        var imag = [Float](repeating: 0, count: half)
        var mags = [Float](repeating: 0, count: half)
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                buf.withUnsafeBufferPointer { bp in
                    bp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvabs(&split, 1, &mags, 1, vDSP_Length(half))
            }
        }
        mags[0] = 0

        let binHz = sampleRate / Double(fftSize)
        func peak(_ f: Double) -> Float {
            // Search ±40 cents (at least ±1 bin) around the target frequency.
            let lo = max(1, Int((f * pow(2, -0.4 / 12)) / binHz))
            let hi = min(half - 1, max(lo + 1, Int(ceil((f * pow(2, 0.4 / 12)) / binHz))))
            guard lo < half - 1 else { return 0 }
            var m: Float = 0
            for b in lo...hi where mags[b] > m { m = mags[b] }
            return m
        }

        let range = NoteName.pianoRange
        var sal = [Float](repeating: 0, count: range.count)
        var fund = [Float](repeating: 0, count: range.count)
        let weights: [Float] = [1.0, 0.8, 0.6, 0.45, 0.35, 0.25]
        for (i, midi) in range.enumerated() {
            let f0 = NoteName.frequency(midi)
            fund[i] = peak(f0)
            var s: Float = 0
            for (h, w) in weights.enumerated() {
                let fh = f0 * Double(h + 1)
                if fh > sampleRate / 2 - binHz { break }
                s += w * peak(fh)
            }
            sal[i] = s
        }
        var maxSal: Float = 0, maxFund: Float = 0
        vDSP_maxv(sal, 1, &maxSal, vDSP_Length(sal.count))
        vDSP_maxv(fund, 1, &maxFund, vDSP_Length(fund.count))
        if maxSal > 0 { var d = maxSal; vDSP_vsdiv(sal, 1, &d, &sal, 1, vDSP_Length(sal.count)) }
        if maxFund > 0 { var d = maxFund; vDSP_vsdiv(fund, 1, &d, &fund, 1, vDSP_Length(fund.count)) }
        return (sal, fund)
    }
}
