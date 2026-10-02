import AVFoundation
import Foundation
import PianoCore

/// Captures the microphone and runs pitch analysis in the background.
@MainActor
final class MicrophoneListener: ObservableObject {
    static let shared = MicrophoneListener()

    enum State: Equatable {
        case idle, requesting, running, denied, failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var level: Float = 0
    @Published private(set) var lastFrame: AnalysisFrame?
    @Published private(set) var deviceName: String = ""

    /// Receives every analysed frame on the main actor.
    var onFrame: ((AnalysisFrame) -> Void)?

    private var engine = AVAudioEngine()
    private let queue = DispatchQueue(label: "piano.pitch-analysis", qos: .userInteractive)
    private var processor: TapProcessor?
    private var suppressedUntil = Date.distantPast
    private var clients = 0

    private init() {
        SoundEngine.shared.onSoundProduced = { [weak self] seconds in
            self?.suppress(for: seconds)
        }
    }

    /// Ignore the microphone for a while (the app itself is making sound).
    func suppress(for seconds: TimeInterval) {
        let until = Date().addingTimeInterval(seconds)
        if until > suppressedUntil { suppressedUntil = until }
    }

    var isSuppressed: Bool { Date() < suppressedUntil }

    func start() {
        clients += 1
        guard state != .running, state != .requesting else { return }
        if ProcessInfo.processInfo.environment["PIANO_TEST_AUDIO"] != nil {
            startEngine() // test file input: no microphone permission needed
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            startEngine()
        case .notDetermined:
            state = .requesting
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                Task { @MainActor in
                    if granted { self.startEngine() } else { self.state = .denied }
                }
            }
        default:
            state = .denied
        }
    }

    func stop() {
        clients = max(0, clients - 1)
        guard clients == 0 else { return }
        tappedNode?.removeTap(onBus: 0)
        tappedNode = nil
        testPlayer?.stop()
        testPlayer = nil
        engine.stop()
        state = .idle
        level = 0
        lastFrame = nil
    }

    /// Restarts capture (e.g. after choosing another input device).
    func restart() {
        guard state == .running else { return }
        tappedNode?.removeTap(onBus: 0)
        engine.stop()
        startEngine()
    }

    private let debugLog = ProcessInfo.processInfo.environment["PIANO_DEBUG"] != nil
    private var tappedNode: AVAudioNode?
    private var testPlayer: AVAudioPlayerNode?

    private func startEngine() {
        engine = AVAudioEngine()
        let analyzerFor: (Double) -> TapProcessor = { [weak self, queue] rate in
            TapProcessor(analyzer: PitchAnalyzer(sampleRate: rate), queue: queue) { frame in
                Task { @MainActor in self?.deliver(frame) }
            }
        }

        // Test hook: PIANO_TEST_AUDIO=/path/file.wav replaces the microphone with an audio file
        // (played silently through the same analysis pipeline), to check lessons without a piano.
        if let path = ProcessInfo.processInfo.environment["PIANO_TEST_AUDIO"],
           let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)) {
            let player = AVAudioPlayerNode()
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: file.processingFormat)
            engine.mainMixerNode.outputVolume = 0
            let processor = analyzerFor(file.processingFormat.sampleRate)
            self.processor = processor
            player.installTap(onBus: 0, bufferSize: 1024, format: file.processingFormat, block: processor.makeBlock())
            tappedNode = player
            testPlayer = player
            deviceName = "Fichier de test"
            do {
                try engine.start()
                player.scheduleFile(file, at: nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { player.play() }
                state = .running
            } catch {
                state = .failed(error.localizedDescription)
            }
            return
        }

        let input = engine.inputNode
        if let uid = UserDefaults.standard.string(forKey: "inputDeviceUID"), !uid.isEmpty,
           let device = AudioInputDevices.all().first(where: { $0.uid == uid }) {
            AudioInputDevices.select(device.id, on: input)
            deviceName = device.name
        } else {
            deviceName = AudioInputDevices.all().first(where: { $0.isDefault })?.name ?? "Micro"
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            state = .failed("Aucun micro détecté.")
            return
        }
        let processor = analyzerFor(format.sampleRate)
        self.processor = processor
        input.installTap(onBus: 0, bufferSize: 1024, format: format, block: processor.makeBlock())
        tappedNode = input

        do {
            engine.prepare()
            try engine.start()
            state = .running
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func deliver(_ frame: AnalysisFrame) {
        if debugLog { FileHandle.standardError.write("frame rms=\(frame.rms) pitch=\(frame.midiPitch ?? -1) conf=\(frame.pitchConfidence) suppressed=\(isSuppressed)\n".data(using: .utf8)!) }
        level = level * 0.6 + min(1, frame.rms * 8) * 0.4
        guard !isSuppressed else {
            lastFrame = nil
            return
        }
        lastFrame = frame
        onFrame?(frame)
    }
}

/// Runs on the real-time audio thread: accumulates samples and hands windows to the analysis queue.
private final class TapProcessor: @unchecked Sendable {
    private let analyzer: PitchAnalyzer
    private let queue: DispatchQueue
    private let deliver: @Sendable (AnalysisFrame) -> Void
    private var ring: [Float] = []
    private var pending = 0
    private let hop: Int

    init(analyzer: PitchAnalyzer, queue: DispatchQueue, deliver: @escaping @Sendable (AnalysisFrame) -> Void) {
        self.analyzer = analyzer
        self.queue = queue
        self.deliver = deliver
        self.hop = Int(analyzer.sampleRate * 0.04) // ~25 analyses per second
        ring.reserveCapacity(analyzer.fftSize * 2)
    }

    nonisolated func makeBlock() -> AVAudioNodeTapBlock {
        return { [self] buffer, _ in self.process(buffer) }
    }

    private func process(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData else { return }
        let n = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        var mono = [Float](repeating: 0, count: n)
        for c in 0..<channels {
            let ptr = data[c]
            for i in 0..<n { mono[i] += ptr[i] }
        }
        if channels > 1 { let s = 1 / Float(channels); for i in 0..<n { mono[i] *= s } }

        ring.append(contentsOf: mono)
        if ring.count > analyzer.fftSize { ring.removeFirst(ring.count - analyzer.fftSize) }
        pending += n
        guard pending >= hop, ring.count >= 4096 else { return }
        pending = 0
        let window = ring
        let analyzer = self.analyzer
        let deliver = self.deliver
        queue.async { deliver(analyzer.analyze(window)) }
    }
}
