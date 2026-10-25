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
    /// Notes of the score sounding right now, with the hand that plays each.
    @Published private(set) var activeNotes: [Int: Hand] = [:]
    @Published private(set) var position: Double = 0
    @Published private(set) var duration: Double = 0

    /// Called whenever the app produces sound, so the microphone can ignore it.
    var onSoundProduced: ((TimeInterval) -> Void)?

    private let engine = AVAudioEngine()
    private let sampler = AVAudioUnitSampler()
    /// GM percussion kit, for the metronome.
    private let clicks = AVAudioUnitSampler()
    /// Piano voice for a plugged-in keyboard.
    private let keyboard = AVAudioUnitSampler()
    private var started = false

    private var timer: Timer?
    private var events: [(time: Double, pitch: Int, on: Bool, velocity: Int, hand: Hand)] = []
    private var nextEvent = 0
    private var playStart = Date()
    private var startOffset = 0.0
    private var tempo = 1.0
    private var playingID: String?

    private init() {
        engine.attach(sampler)
        engine.connect(sampler, to: engine.mainMixerNode, format: nil)
        engine.attach(clicks)
        engine.connect(clicks, to: engine.mainMixerNode, format: nil)
        engine.attach(keyboard)
        engine.connect(keyboard, to: engine.mainMixerNode, format: nil)
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
                try? keyboard.loadSoundBankInstrument(at: URL(fileURLWithPath: path), program: 0,
                                                      bankMSB: UInt8(kAUSampler_DefaultMelodicBankMSB),
                                                      bankLSB: UInt8(kAUSampler_DefaultBankLSB))
                try? clicks.loadSoundBankInstrument(at: URL(fileURLWithPath: path), program: 0,
                                                    bankMSB: UInt8(kAUSampler_DefaultPercussionBankMSB),
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

    // MARK: - Plugged-in keyboard

    // Notes from a USB keyboard use their own sampler, so score playback, its "all notes off"
    // and the keyboard's sustain pedal do not interfere with each other.

    func keyboardNoteOn(_ pitch: Int, velocity: Int) {
        ensureStarted()
        keyboard.startNote(UInt8(pitch), withVelocity: UInt8(max(1, min(127, velocity))), onChannel: 0)
        onSoundProduced?(1.2)
    }

    func keyboardNoteOff(_ pitch: Int) {
        keyboard.stopNote(UInt8(pitch), onChannel: 0)
    }

    /// Sustain pedal (0 = up, 127 = down).
    func keyboardSustain(_ value: Int) {
        ensureStarted()
        keyboard.sendController(64, withValue: UInt8(max(0, min(127, value))), onChannel: 0)
    }

    /// Plays notes together for a given duration (used for "listen to the next note").
    func play(_ pitches: [Int], duration: Double = 0.8, velocity: Int = 90) {
        for p in pitches { noteOn(p, velocity: velocity) }
        onSoundProduced?(duration + 0.6)
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            for p in pitches { self?.noteOff(p) }
        }
    }

    /// Metronome tick: high wood block on the downbeat, low wood block otherwise.
    /// Confirmation sounds are avoided on purpose (they would leak into the microphone); the metronome
    /// only pauses the microphone for the length of the tick.
    func click(accent: Bool) {
        ensureStarted()
        let note: UInt8 = accent ? 76 : 77
        clicks.startNote(note, withVelocity: accent ? 120 : 95, onChannel: 9)
        onSoundProduced?(0.12)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.clicks.stopNote(note, onChannel: 9) }
    }

    // MARK: - Score playback

    func isPlaying(id: String) -> Bool { isPlaying && playingID == id }

    /// Plays the score in its own rhythm from `start`, stopping at `end` when given (a looped passage).
    func play(score: Score, id: String, hands: HandSelection = .both, from start: Double = 0, to end: Double? = nil, tempo: Double = 1.0) {
        stop()
        ensureStarted()
        let handOf = PracticeSequence.handAssignment(for: score)
        var evts: [(Double, Int, Bool, Int, Hand)] = []
        for n in score.notes where hands == .both || (hands == .right) == (handOf(n) == .right) {
            guard n.end > start, n.start < (end ?? .infinity) else { continue }
            let hand = handOf(n)
            evts.append((n.start, n.pitch, true, n.velocity, hand))
            evts.append((min(n.end, end ?? .infinity), n.pitch, false, 0, hand))
        }
        // Note-offs before note-ons at identical times so repeated notes re-trigger.
        events = evts.sorted { $0.0 != $1.0 ? $0.0 < $1.0 : (!$0.2 && $1.2) }
            .map { (time: $0.0, pitch: $0.1, on: $0.2, velocity: $0.3, hand: $0.4) }
        nextEvent = events.firstIndex { $0.time >= start } ?? events.count
        duration = end ?? score.duration
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
                activeNotes[e.pitch] = e.hand
            } else {
                sampler.stopNote(UInt8(e.pitch), onChannel: 0)
                activeNotes[e.pitch] = nil
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
        for p in activeNotes.keys { sampler.stopNote(UInt8(p), onChannel: 0) }
        // Send "all notes off" for safety.
        for ch in 0..<16 { sampler.sendController(123, withValue: 0, onChannel: UInt8(ch)) }
        activeNotes = [:]
        isPlaying = false
        playingID = nil
    }
}

/// Streams the MP3 previews hosted on partition-piano-gratuite.fr, or plays a catalogue
/// entry's MIDI file on the built-in piano when it has no MP3 (the bundled classics).
@MainActor
final class PreviewPlayer: ObservableObject {
    static let shared = PreviewPlayer()

    @Published private(set) var playingURL: URL?
    /// Catalogue entry being previewed (MP3 or MIDI).
    @Published private(set) var playingEntryID: String?
    @Published private(set) var isBuffering = false
    @Published private(set) var progress: Double = 0

    private var player: AVPlayer?
    private var observer: Any?
    private var endObserver: NSObjectProtocol?

    private static let midiPlaybackID = "catalog-preview"
    private var midiTask: Task<Void, Never>?
    private var midiTimer: Timer?
    private var midiScores: [URL: Score] = [:]

    /// Starts or stops the preview of a catalogue entry. `onError` is called if its MIDI file cannot be loaded.
    func toggle(_ entry: CatalogEntry, onError: @escaping (String) -> Void = { _ in }) {
        if playingEntryID == entry.id { stop(); return }
        if let url = entry.previewURL {
            toggle(url)
            playingEntryID = entry.id
            return
        }
        guard let midi = entry.midiURL else { return }
        stop()
        SoundEngine.shared.stop()
        playingEntryID = entry.id
        isBuffering = true
        midiTask = Task { [weak self] in
            do {
                let score = try await self?.score(at: midi)
                guard let self, let score, !Task.isCancelled, self.playingEntryID == entry.id else { return }
                self.isBuffering = false
                SoundEngine.shared.play(score: score, id: Self.midiPlaybackID)
                self.midiTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.followMIDI() }
                }
            } catch {
                guard let self, !Task.isCancelled, self.playingEntryID == entry.id else { return }
                self.stop()
                onError("Aperçu indisponible : \(error.localizedDescription)")
            }
        }
    }

    private func score(at url: URL) async throws -> Score {
        if let cached = midiScores[url] { return cached }
        var request = URLRequest(url: url)
        request.setValue("PianoLearning/1.0 (macOS)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        let score = try MIDIFileParser.parse(data: data)
        midiScores[url] = score
        return score
    }

    private func followMIDI() {
        let sound = SoundEngine.shared
        // Finished, or replaced by another playback.
        guard sound.isPlaying(id: Self.midiPlaybackID) else { stop(); return }
        if sound.duration > 0 { progress = min(1, sound.position / sound.duration) }
    }

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
        midiTask?.cancel()
        midiTask = nil
        midiTimer?.invalidate()
        midiTimer = nil
        if SoundEngine.shared.isPlaying(id: Self.midiPlaybackID) { SoundEngine.shared.stop() }
        playingEntryID = nil
        progress = 0
        isBuffering = false
    }
}
