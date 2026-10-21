import Combine
import Foundation
import PianoCore
import SwiftUI

/// Drives a "wait mode" lesson: shows the next note(s), listens through the microphone
/// (or a MIDI keyboard), and moves on only when the right key is played.
@MainActor
final class PracticeSession: ObservableObject {
    enum Feedback: Equatable {
        case none
        case correct
        case wrong(Int)
    }

    let piece: Piece
    let score: Score

    @Published var options: PracticeOptions {
        didSet { if options != oldValue { rebuild(keepPosition: true) } }
    }
    @Published var ignoreOctave = false {
        didSet { matcher.ignoreOctave = ignoreOctave }
    }
    @Published var sensitivity: Double = 1.0 {
        didSet { matcher.sensitivity = Float(sensitivity) }
    }
    /// Only react to piano notes, not to voice or room noise.
    @Published var pianoOnly = true {
        didSet { matcher.pianoOnly = pianoOnly }
    }
    /// Plays each new target note automatically (helps beginners find it by ear).
    @Published var autoPlayTarget = false

    @Published private(set) var steps: [PracticeStep] = []
    @Published private(set) var index = 0
    @Published private(set) var feedback: Feedback = .none
    @Published private(set) var detectedNotes: Set<Int> = []
    @Published private(set) var detectedLabel: String?
    @Published private(set) var cents: Double?
    @Published private(set) var correctCount = 0
    @Published private(set) var wrongCount = 0
    @Published private(set) var finished = false
    @Published private(set) var isListening = false
    /// Range of steps being looped (nil = whole piece).
    @Published var loopRange: ClosedRange<Int>?
    /// The app is playing the piece in rhythm; the cursor follows it and input is ignored.
    @Published private(set) var isPlayingPiece = false

    private var matcher = NoteMatcher()
    /// The finished run was already recorded (avoid counting it twice when leaving).
    private var completionSaved = false
    private var startedAt = Date()
    private var feedbackTask: Task<Void, Never>?
    private let onFinish: (Double, Double?, Int?) -> Void
    private var playback: AnyCancellable?
    private var playbackStartIndex = 0

    init(piece: Piece, score: Score, startStep: Int? = nil, onFinish: @escaping (Double, Double?, Int?) -> Void) {
        self.piece = piece
        self.score = score
        self.onFinish = onFinish
        // Beginners start with the right hand melody; advanced pieces with both hands.
        self.options = PracticeOptions(hands: (piece.level ?? 1) >= 4 ? .both : .right, melodyOnly: true)
        rebuild(keepPosition: false)
        if let s = startStep, steps.indices.contains(s) { index = s }
        prepareStep()
    }

    // MARK: - Derived state

    var currentStep: PracticeStep? { steps.indices.contains(index) ? steps[index] : nil }
    var progress: Double { steps.isEmpty ? 0 : Double(index) / Double(steps.count) }
    var accuracy: Double? {
        let total = correctCount + wrongCount
        return total == 0 ? nil : Double(correctCount) / Double(total)
    }
    var elapsed: TimeInterval { Date().timeIntervalSince(startedAt) }

    func upcoming(_ count: Int) -> [PracticeStep] {
        guard index < steps.count else { return [] }
        return Array(steps[index..<min(steps.count, index + count)])
    }

    func previous(_ count: Int) -> [PracticeStep] {
        Array(steps[max(0, index - count)..<min(index, steps.count)])
    }

    // MARK: - Lifecycle

    func startListening() {
        let mic = MicrophoneListener.shared
        mic.onFrame = { [weak self] frame in self?.handle(frame) }
        mic.start()
        MIDIInputService.shared.onNote = { [weak self] pitch, on in self?.handleMIDI(pitch, on: on) }
        isListening = true
    }

    func stopListening() {
        MicrophoneListener.shared.onFrame = nil
        MicrophoneListener.shared.stop()
        MIDIInputService.shared.onNote = nil
        isListening = false
    }

    func saveProgress() {
        // Opening a lesson without playing anything is not a practice session.
        guard correctCount > 0, !completionSaved else { return }
        onFinish(progress, finished ? accuracy : nil, finished || index == 0 ? nil : index)
    }

    // MARK: - Navigation

    func restart() {
        stopPiece()
        index = loopRange?.lowerBound ?? 0
        correctCount = 0
        wrongCount = 0
        finished = false
        completionSaved = false
        startedAt = Date()
        prepareStep()
    }

    func jump(to step: Int) {
        stopPiece()
        guard !steps.isEmpty else { return }
        index = max(0, min(steps.count - 1, step))
        finished = false
        prepareStep()
    }

    func skip() {
        advance(countAsCorrect: false)
    }

    func back() {
        jump(to: index - 1)
    }

    func playTarget() {
        guard let step = currentStep else { return }
        SoundEngine.shared.play(step.pitches, duration: max(0.5, min(step.duration, 1.2)))
    }

    /// Plays the piece in its own rhythm from the current note (or the looped passage),
    /// moving the cursor along; afterwards the student is back where the playback started.
    func playPiece(onlyPracticedHands: Bool, tempo: Double) {
        guard !steps.isEmpty else { return }
        stopPiece()
        if let loop = loopRange, !loop.contains(index) { index = loop.lowerBound }
        let from = min(index, steps.count - 1)
        let end = loopRange.map { steps[$0.upperBound].time + steps[$0.upperBound].duration }
        playbackStartIndex = from
        isPlayingPiece = true
        let sound = SoundEngine.shared
        sound.play(score: score, id: "practice-\(piece.id)", hands: onlyPracticedHands ? options.hands : .both,
                   from: steps[from].time, to: end, tempo: tempo)
        playback = sound.$position.combineLatest(sound.$isPlaying)
            .receive(on: RunLoop.main)
            .sink { [weak self] position, playing in
                guard let self, self.isPlayingPiece else { return }
                guard playing else { self.finishPlayback(); return }
                // Last note already started, without going back.
                if let i = self.steps.lastIndex(where: { $0.time <= position + 0.02 }), i > self.index { self.index = i }
            }
    }

    func stopPiece() {
        guard isPlayingPiece else { return }
        SoundEngine.shared.stop()
        finishPlayback()
    }

    private func finishPlayback() {
        playback = nil
        isPlayingPiece = false
        index = playbackStartIndex
        prepareStep()
    }

    /// Simulates a correct answer (used by the on-screen keyboard).
    func keyPressed(_ pitch: Int) {
        SoundEngine.shared.play([pitch], duration: 0.4)
        handleMIDI(pitch, on: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.heldVirtual.remove(pitch) }
    }

    private var heldVirtual: Set<Int> = []

    private func rebuild(keepPosition: Bool) {
        let oldTime = currentStep?.time ?? 0
        steps = PracticeSequence.build(score: score, options: options)
        if keepPosition {
            index = steps.firstIndex { $0.time >= oldTime - 0.01 } ?? 0
        } else {
            index = 0
        }
        loopRange = nil
        prepareStep()
    }

    private func prepareStep(requireOnset: Bool = true) {
        matcher.ignoreOctave = ignoreOctave
        matcher.sensitivity = Float(sensitivity)
        matcher.pianoOnly = pianoOnly
        matcher.reset(expected: Set(currentStep?.pitches ?? []), requireOnset: requireOnset)
        heldVirtual.removeAll()
        if autoPlayTarget, currentStep != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.playTarget() }
        }
    }

    private func advance(countAsCorrect: Bool) {
        guard !steps.isEmpty, !finished else { return }
        if countAsCorrect { correctCount += 1 }
        showFeedback(countAsCorrect ? .correct : .none)

        if let loop = loopRange, index >= loop.upperBound {
            index = loop.lowerBound
            prepareStep()
            return
        }
        if index + 1 >= steps.count {
            index = steps.count
            finished = true
            onFinish(1.0, accuracy, nil)
            completionSaved = true
            return
        }
        index += 1
        prepareStep()
    }

    private func showFeedback(_ f: Feedback) {
        feedback = f
        feedbackTask?.cancel()
        feedbackTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled else { return }
            self?.feedback = .none
        }
    }

    // MARK: - Input handling

    private func handle(_ frame: AnalysisFrame) {
        // A plugged-in keyboard gives exact notes; the microphone would only hear its speakers.
        guard !MIDIInputService.shared.isKeyboardConnected else { return }
        let verdict = matcher.process(frame)
        // Display what the microphone hears (piano notes only, not voices or noise).
        if verdict != .silence, matcher.isPianoTone {
            if let m = frame.midiPitch, frame.pitchConfidence > 0.7, NoteName.pianoRange.contains(m) {
                detectedNotes = [m]
                detectedLabel = m.noteLabel
                cents = frame.cents
            } else {
                let strong = frame.strongNotes()
                detectedNotes = Set(strong)
                detectedLabel = strong.isEmpty ? nil : strong.map(\.noteLabel).joined(separator: " + ")
                cents = nil
            }
        } else {
            detectedNotes = []
            detectedLabel = nil
            cents = nil
        }

        guard !finished, !isPlayingPiece, currentStep != nil else { return }
        switch verdict {
        case .correct:
            advance(countAsCorrect: true)
        case .wrong(let n):
            wrongCount += 1
            showFeedback(.wrong(n))
        case .silence, .listening:
            break
        }
    }

    private func handleMIDI(_ pitch: Int, on: Bool) {
        guard on, !isPlayingPiece else { return }
        heldVirtual.insert(pitch)
        detectedNotes = [pitch]
        detectedLabel = pitch.noteLabel
        guard !finished, let step = currentStep else { return }
        let held = MIDIInputService.shared.heldKeys.union(heldVirtual)
        if matcher.matches(heldKeys: held) {
            advance(countAsCorrect: true)
        } else if !step.pitches.contains(where: { ignoreOctave ? ($0 - pitch) % 12 == 0 : $0 == pitch }) {
            wrongCount += 1
            showFeedback(.wrong(pitch))
        }
    }
}

extension Int {
    /// Note label honouring the user's naming preference (Do Ré Mi / C D E).
    var noteLabel: String {
        UserDefaults.standard.string(forKey: "noteNaming") == "en" ? NoteName.english(self) : NoteName.french(self)
    }
}
