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
    /// Only react to sounds shaped like piano notes (ignores voice and room noise).
    public var pianoOnly = true
    /// Whether the last processed frame sounded like a piano note.
    public private(set) var isPianoTone = false

    private var toneFilter = PianoToneFilter()

    private var noiseFloor: Float = 0.002
    private var previousRMS: Float = 0
    private var hits = 0
    private var onsetSeen = false
    private var wrongCandidate: Int?
    private var wrongFrames = 0
    private var wrongReported = false
    /// Notes of the previous step: their decaying sound must not count as a wrong note.
    private var previousExpected: Set<Int> = []
    /// Chord notes must be struck within this many frames of each other (~40 ms per frame).
    public var chordWindowFrames = 3
    /// Keys of a chord must be pressed within this delay of each other (exact input).
    public var chordWindowSeconds: TimeInterval = 0.15
    private var frameIndex = 0
    /// Recent loudness of each expected note, to tell a fresh strike from a ringing note.
    private var levels: [Int: [Float]] = [:]
    /// Frame at which each expected note was last struck during this step.
    private var struckAt: [Int: Int] = [:]

    public init() {}

    /// Call when moving to a new step.
    public mutating func reset(expected: Set<Int>, requireOnset: Bool = true) {
        previousExpected = self.expected
        self.expected = expected
        hits = 0
        onsetSeen = !requireOnset
        wrongCandidate = nil
        wrongFrames = 0
        wrongReported = false
        struckAt = [:]
    }

    /// A wrong note still ringing (e.g. after going back to the loop start) must not be reported again.
    public mutating func ignoreRinging(_ note: Int) {
        previousExpected.insert(note)
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

    /// Absolute loudness estimate of a note (in any accepted octave). Uses the fundamental only:
    /// the harmonics of a low note are boosted when higher notes of the chord are struck.
    private func level(of note: Int, in frame: AnalysisFrame) -> Float {
        let candidates = ignoreOctave
            ? stride(from: note % 12 + 12, through: 108, by: 12).filter { NoteName.pianoRange.contains($0) }
            : [note]
        return frame.rms * (candidates.map { frame.fundamental(of: $0) }.max() ?? 0)
    }

    /// Records which chord notes were just struck: a note counts only when its own sound rises,
    /// so a note still ringing from earlier is not taken as played together with a new one.
    private mutating func trackStrikes(_ frame: AnalysisFrame) {
        for note in expected {
            let l = level(of: note, in: frame)
            let history = levels[note] ?? []
            if isPresent(note, in: frame), l >= (history.min() ?? 0) * 1.4 {
                struckAt[note] = frameIndex
            }
            levels[note] = Array((history + [l]).suffix(4))
        }    }

    /// The chord notes were all struck at (almost) the same moment.
    private var struckTogether: Bool {
        guard expected.count > 1 else { return true }
        let frames = expected.compactMap { struckAt[$0] }
        guard frames.count == expected.count, let first = frames.min(), let last = frames.max() else { return false }
        return last - first <= chordWindowFrames
    }

    public mutating func process(_ frame: AnalysisFrame) -> Verdict {
        defer { previousRMS = frame.rms; frameIndex += 1 }
        isPianoTone = toneFilter.process(frame) || !pianoOnly

        // Track the noise floor slowly upward, quickly downward.
        if frame.rms < noiseFloor { noiseFloor = max(0.0005, noiseFloor * 0.9 + frame.rms * 0.1) }
        else if frame.rms < gate { noiseFloor = noiseFloor * 0.995 + frame.rms * 0.005 }

        // Treble notes lose most of their loudness right after the hammer. A clean, confident
        // high pitch is far above the noise (noise is not periodic), so a lower gate is safe.
        let clearTreble = (frame.midiPitch ?? 0) >= 72 && frame.pitchConfidence > 0.9
        guard frame.rms > (clearTreble ? gate * 0.5 : gate) else {
            hits = 0
            wrongCandidate = nil
            wrongFrames = 0
            wrongReported = false
            levels = [:]
            // Silence after a note counts as a "release": the next strike is an onset.
            if frame.rms < gate * 0.7 { onsetSeen = true }
            isPianoTone = false
            return .silence
        }

        if frame.rms > previousRMS * 1.35 && frame.rms > gate * 1.5 { onsetSeen = true }
        guard !expected.isEmpty, isPianoTone else {
            hits = 0
            wrongFrames = 0
            return .listening
        }

        if expected.count > 1 { trackStrikes(frame) }
        let allPresent = expected.allSatisfy { isPresent($0, in: frame) }
        if allPresent && onsetSeen && struckTogether {
            hits += 1
            if hits >= requiredFrames { return .correct }
            return .listening
        }
        hits = 0

        // Wrong-note detection (needs a confident monophonic estimate held for a few frames).
        if let m = frame.midiPitch, frame.pitchConfidence > 0.85, NoteName.pianoRange.contains(m),
           !expected.contains(where: { same($0, m) }), !previousExpected.contains(m) {
            if wrongCandidate == m { wrongFrames += 1 } else { wrongCandidate = m; wrongFrames = 1 }
            if wrongFrames >= 3 && !wrongReported {
                wrongReported = true
                return .wrong(m)
            }
        }
        return .listening
    }

    /// Exact input (e.g. MIDI keyboard): `pressedAt` gives, for each key held down, when it was pressed.
    /// The step is played when its keys are all held and were pressed together (keys held since an
    /// earlier step, or pressed one after the other, don't count).
    public func matches(pressedAt: [Int: Date], since stepStart: Date) -> Bool {
        var times: [Date] = []
        for e in expected {
            guard let t = pressedAt.filter({ same($0.key, e) && $0.value >= stepStart }).map(\.value).max() else { return false }
            times.append(t)
        }
        guard let first = times.min(), let last = times.max() else { return false }
        return last.timeIntervalSince(first) <= chordWindowSeconds
    }
}
