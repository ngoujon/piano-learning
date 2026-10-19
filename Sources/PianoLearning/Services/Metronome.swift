import Foundation
import PianoCore

/// Beats time for the lesson. On its own it ticks at `bpm`; while the piece is playing it
/// follows the score's beat grid on the playback clock, so it stays with tempo changes.
@MainActor
final class Metronome: ObservableObject {
    @Published private(set) var isRunning = false
    @Published var bpm: Double = 100 { didSet { if isRunning, following == nil, bpm != oldValue { restart() } } }
    @Published var beatsPerBar = 4 { didSet { if isRunning, following == nil, beatsPerBar != oldValue { restart() } } }
    @Published var playsSound = true
    /// The beat that last sounded.
    @Published private(set) var current: Beat?
    /// Counts beats since start; its parity tells the pendulum which way it swings.
    @Published private(set) var beatCount = 0

    static let bpmRange = 30.0...240.0

    private var timer: Timer?
    private var startDate = Date()
    private var following: (beats: [Beat], clock: () -> Double)?
    private var nextIndex = 0

    func start() {
        stopTimer()
        following = nil
        startDate = Date()
        nextIndex = 0
        beatCount = 0
        isRunning = true
        startTimer()
    }

    /// Follows a beat grid read on `clock` (seconds of the piece), e.g. the score being played.
    func follow(_ beats: [Beat], clock: @escaping () -> Double) {
        guard !beats.isEmpty else { return start() }
        stopTimer()
        following = (beats, clock)
        let now = clock()
        nextIndex = beats.firstIndex { $0.time >= now - 0.02 } ?? beats.count
        beatCount = 0
        isRunning = true
        startTimer()
    }

    func stop() {
        stopTimer()
        following = nil
        isRunning = false
        current = nil
    }

    /// Progress from the last beat to the next one (0...1), for the animation.
    func phase(at date: Date = Date()) -> Double {
        guard isRunning else { return 0 }
        if let f = following {
            let now = f.clock()
            let i = nextIndex
            guard i > 0, i < f.beats.count else { return 0 }
            let a = f.beats[i - 1].time, b = f.beats[i].time
            return b > a ? min(1, max(0, (now - a) / (b - a))) : 0
        }
        let elapsed = date.timeIntervalSince(startDate) * bpm / 60
        return elapsed - floor(elapsed)
    }

    private func restart() {
        start()
    }

    private func startTimer() {
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 0.004, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        if let f = following {
            let now = f.clock()
            var due: Beat?
            while nextIndex < f.beats.count, f.beats[nextIndex].time <= now + 0.005 {
                due = f.beats[nextIndex]
                nextIndex += 1
            }
            if let due { sound(due) }
        } else {
            let index = Int(Date().timeIntervalSince(startDate) * bpm / 60)
            guard index >= nextIndex else { return }
            nextIndex = index + 1
            sound(Beat(time: 0, number: index % max(beatsPerBar, 1) + 1, beatsInBar: beatsPerBar))
        }
    }

    private func sound(_ beat: Beat) {
        current = beat
        beatCount += 1
        if playsSound { SoundEngine.shared.click(accent: beat.number == 1 && beat.beatsInBar > 1) }
    }
}
