import Foundation

/// Tells piano notes apart from voice and other room noise.
///
/// A struck piano string has a fixed pitch and a sound that only fades after the attack.
/// Speech glides in pitch from one frame to the next and its loudness goes up and down
/// with each syllable. A frame counts as "piano" when the last few frames agree on both.
public struct PianoToneFilter {
    /// Frames considered (40 ms apart).
    public var window = 3
    /// Largest step-to-step loudness rise allowed once the attack is over (piano strings beat a little).
    public var maxRise: Float = 1.12
    /// Fastest step-to-step fade allowed: a voice stops abruptly, a piano string rings on.
    public var maxFade: Float = 0.7
    /// Largest pitch spread, in semitones, allowed across the window.
    public var maxPitchSpread = 0.15

    private var rms: [Float] = []
    private var pitches: [Double?] = []

    public init() {}

    public mutating func reset() {
        rms.removeAll()
        pitches.removeAll()
    }

    /// Feeds one frame and returns whether the current sound looks like a piano note.
    @discardableResult
    public mutating func process(_ frame: AnalysisFrame) -> Bool {
        rms.append(frame.rms)
        pitches.append(frame.pitchConfidence > 0.6 ? frame.pitch.map { NoteName.midi(forFrequency: $0) } : nil)
        if rms.count > window { rms.removeFirst(); pitches.removeFirst() }
        guard rms.count == window else { return false }

        // Envelope: after the attack a piano note only decays.
        for i in 1..<window where rms[i] > rms[i - 1] * maxRise || rms[i] < rms[i - 1] * maxFade { return false }
        guard rms[window - 1] <= rms[0] else { return false }

        // Pitch: steady to within a few cents. A piano note has a clear pitch right after its
        // attack (a chord may blur one frame); breath and consonants have none.
        let voiced = pitches.compactMap { $0 }
        guard pitches.last! != nil, voiced.count >= window - 1, let lo = voiced.min(), let hi = voiced.max() else { return false }
        return hi - lo <= maxPitchSpread
    }
}
