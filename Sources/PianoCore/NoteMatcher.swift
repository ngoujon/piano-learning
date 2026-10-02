import Foundation

/// Decides, frame after frame, whether the student played the expected note(s).
public struct NoteMatcher {
    public enum Verdict: Equatable {
        case silence
        case listening
        /// A clear note that is not part of the expected step.
        case wrong(Int)
        case correct
    }

    public var expected: Set<Int> = []
    /// Accept the right note in any octave.
    public var ignoreOctave = false
    /// Frames in a row where all expected notes must be present.
    public var requiredFrames = 2
    /// Multiplier applied to the noise floor to open the gate (higher = less sensitive).
    public var sensitivity: Float = 1.0

    private var noiseFloor: Float = 0.002
    private var previousRMS: Float = 0
    private var hits = 0
    private var onsetSeen = false
    private var wrongCandidate: Int?
    private var wrongFrames = 0
    private var wrongReported = false

    public init() {}

    /// Call when moving to a new step.
    public mutating func reset(expected: Set<Int>, requireOnset: Bool = true) {
        self.expected = expected
        hits = 0
        onsetSeen = !requireOnset
        wrongCandidate = nil
        wrongFrames = 0
        wrongReported = false
    }

    public var gate: Float { max(0.004, noiseFloor * 3.0) * sensitivity }

    private func same(_ a: Int, _ b: Int) -> Bool {
        ignoreOctave ? (a - b) % 12 == 0 : a == b
    }

    /// Is a specific expected note audible in this frame?
    public func isPresent(_ note: Int, in frame: AnalysisFrame) -> Bool {
        if let m = frame.midiPitch, frame.pitchConfidence > 0.6, same(m, note) { return true }
        let candidates = ignoreOctave
            ? stride(from: note % 12 + 12, through: 108, by: 12).filter { NoteName.pianoRange.contains($0) }
            : [note]
        for c in candidates {
            // Low piano notes have weak fundamentals: rely more on harmonics.
            let fundamentalThreshold: Float = c < 48 ? 0.04 : 0.18
            let salienceThreshold: Float = expected.count > 1 ? 0.35 : 0.55
            if frame.salience(of: c) >= salienceThreshold && frame.fundamental(of: c) >= fundamentalThreshold {
                if expected.count == 1, let m = frame.midiPitch, frame.pitchConfidence > 0.8, !same(m, c),
                   (m - c) % 12 != 0 {
                    // YIN is confident about another, unrelated note.
                    continue
                }
                return true
            }
        }
        return false
    }

    public mutating func process(_ frame: AnalysisFrame) -> Verdict {
        defer { previousRMS = frame.rms }

        // Track the noise floor slowly upward, quickly downward.
        if frame.rms < noiseFloor { noiseFloor = max(0.0005, noiseFloor * 0.9 + frame.rms * 0.1) }
        else if frame.rms < gate { noiseFloor = noiseFloor * 0.995 + frame.rms * 0.005 }

        guard frame.rms > gate else {
            hits = 0
            wrongCandidate = nil
            wrongFrames = 0
            wrongReported = false
            // Silence after a note counts as a "release": the next strike is an onset.
            if frame.rms < gate * 0.7 { onsetSeen = true }
            return .silence
        }

        if frame.rms > previousRMS * 1.35 && frame.rms > gate * 1.5 { onsetSeen = true }
        guard !expected.isEmpty else { return .listening }

        let allPresent = expected.allSatisfy { isPresent($0, in: frame) }
        if allPresent && onsetSeen {
            hits += 1
            if hits >= requiredFrames { return .correct }
            return .listening
        }
        hits = 0

        // Wrong-note detection (needs a confident monophonic estimate held for a few frames).
        if let m = frame.midiPitch, frame.pitchConfidence > 0.85, NoteName.pianoRange.contains(m),
           !expected.contains(where: { same($0, m) }) {
            if wrongCandidate == m { wrongFrames += 1 } else { wrongCandidate = m; wrongFrames = 1 }
            if wrongFrames >= 3 && !wrongReported {
                wrongReported = true
                return .wrong(m)
            }
        }
        return .listening
    }

    /// Exact input (e.g. MIDI keyboard): returns true when the set of held keys covers the step.
    public func matches(heldKeys: Set<Int>) -> Bool {
        expected.allSatisfy { e in heldKeys.contains { same($0, e) } }
    }
}
