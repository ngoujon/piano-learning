import AVFoundation
import AudioToolbox
import Foundation
import PianoCore

/// Plays piano notes (General MIDI piano from the macOS sound bank) and whole scores,
/// reporting which keys are sounding so the keyboard can light up.
@MainActor
final class SoundEngine: ObservableObject {
    static let shared = SoundEngine()

    @Published private(set) var isPlaying = false
    @Published private(set) var activeNotes: Set<Int> = []
    @Published private(set) var position: Double = 0
    @Published private(set) var duration: Double = 0

    /// Called whenever the app produces sound, so the microphone can ignore it.
    var onSoundProduced: ((TimeInterval) -> Void)?

    private let engine = AVAudioEngine()
    private let sampler = AVAudioUnitSampler()
    private var started = false

    private var timer: Timer?
    private var events: [(time: Double, pitch: Int, on: Bool, velocity: Int)] = []
    private var nextEvent = 0
    private var playStart = Date()
    private var startOffset = 0.0
    private var tempo = 1.0
    private var playingID: String?

    private init() {
        engine.attach(sampler)
        engine.connect(sampler, to: engine.mainMixerNode, format: nil)
        loadPiano()
    }

    private func loadPiano() {
        let candidates = [
            "/System/Library/Components/CoreAudio.component/Contents/Resources/gs_instruments.dls",
            "/Library/Audio/Sounds/Banks/gs_instruments.dls",
        ]
        for path in candidates where FileManager.default.fileExists(atPath: path) {
            do {
                try sampler.loadSoundBankInstrument(at: URL(fileURLWithPath: path), program: 0,
                                                    bankMSB: UInt8(kAUSampler_DefaultMelodicBankMSB),
                                                    bankLSB: UInt8(kAUSampler_DefaultBankLSB))
                return
            } catch {
                NSLog("PianoLearning: impossible de charger \(path): \(error)")
            }
        }
    }

    private func ensureStarted() {
        guard !started || !engine.isRunning else { return }
        do {
            try engine.start()
            started = true
        } catch {
            NSLog("PianoLearning: moteur audio indisponible: \(error)")
        }
    }

    // MARK: - Single notes

    func noteOn(_ pitch: Int, velocity: Int = 90) {
        ensureStarted()
        sampler.startNote(UInt8(pitch), withVelocity: UInt8(velocity), onChannel: 0)
        onSoundProduced?(1.2)
    }

    func noteOff(_ pitch: Int) {
        sampler.stopNote(UInt8(pitch), onChannel: 0)
    }

    /// Plays notes together for a given duration (used for "listen to the next note").
    func play(_ pitches: [Int], duration: Double = 0.8, velocity: Int = 90) {
        for p in pitches { noteOn(p, velocity: velocity) }
        onSoundProduced?(duration + 0.6)
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            for p in pitches { self?.noteOff(p) }
        }
    }

    /// Short confirmation "click" sounds are avoided on purpose: they would leak into the microphone.

    // MARK: - Score playback

    func isPlaying(id: String) -> Bool { isPlaying && playingID == id }

    func play(score: Score, id: String, hands: HandSelection = .both, from start: Double = 0, tempo: Double = 1.0) {
        stop()
        ensureStarted()
        let handOf = PracticeSequence.handAssignment(for: score)
        var evts: [(Double, Int, Bool, Int)] = []
        for n in score.notes where hands == .both || (hands == .right) == (handOf(n) == .right) {
            guard n.end > start else { continue }
            evts.append((n.start, n.pitch, true, n.velocity))
            evts.append((n.end, n.pitch, false, 0))
        }
        // Note-offs before note-ons at identical times so repeated notes re-trigger.
        events = evts.sorted { $0.0 != $1.0 ? $0.0 < $1.0 : (!$0.2 && $1.2) }
            .map { (time: $0.0, pitch: $0.1, on: $0.2, velocity: $0.3) }
        nextEvent = events.firstIndex { $0.time >= start } ?? events.count
        duration = score.duration
        startOffset = start
        self.tempo = tempo
        playStart = Date()
        playingID = id
        isPlaying = true
        timer = Timer.scheduledTimer(withTimeInterval: 0.005, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    private func tick() {
        let now = startOffset + Date().timeIntervalSince(playStart) * tempo
        position = now
        var changed = false
        while nextEvent < events.count, events[nextEvent].time <= now {
            let e = events[nextEvent]
            if e.on {
                sampler.startNote(UInt8(e.pitch), withVelocity: UInt8(max(1, min(127, e.velocity))), onChannel: 0)
                activeNotes.insert(e.pitch)
            } else {
                sampler.stopNote(UInt8(e.pitch), onChannel: 0)
                activeNotes.remove(e.pitch)
            }
            changed = true
            nextEvent += 1
        }
        if changed { onSoundProduced?(0.8) }
        if nextEvent >= events.count { stop() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        for p in activeNotes { sampler.stopNote(UInt8(p), onChannel: 0) }
        // Send "all notes off" for safety.
        for ch in 0..<16 { sampler.sendController(123, withValue: 0, onChannel: UInt8(ch)) }
        activeNotes = []
        isPlaying = false
        playingID = nil
    }
}

/// Streams the MP3 previews hosted on partition-piano-gratuite.fr.
@MainActor
final class PreviewPlayer: ObservableObject {
    static let shared = PreviewPlayer()

    @Published private(set) var playingURL: URL?
    @Published private(set) var isBuffering = false
    @Published private(set) var progress: Double = 0

    private var player: AVPlayer?
    private var observer: Any?
    private var endObserver: NSObjectProtocol?

    func toggle(_ url: URL) {
        if playingURL == url { stop(); return }
        stop()
        SoundEngine.shared.stop()
        let item = AVPlayerItem(url: url)
        let p = AVPlayer(playerItem: item)
        player = p
        playingURL = url
        isBuffering = true
        observer = p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self, let item = self.player?.currentItem else { return }
                let d = item.duration.seconds
                self.isBuffering = self.player?.timeControlStatus == .waitingToPlayAtSpecifiedRate
                if d.isFinite, d > 0 { self.progress = t.seconds / d }
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
        p.play()
    }

    func stop() {
        if let o = observer { player?.removeTimeObserver(o) }
        if let e = endObserver { NotificationCenter.default.removeObserver(e) }
        observer = nil
        endObserver = nil
        player?.pause()
        player = nil
        playingURL = nil
        progress = 0
        isBuffering = false
    }
}
