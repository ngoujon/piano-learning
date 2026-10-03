import AVFoundation
import AudioToolbox
import Foundation
import Testing
@testable import PianoCore

/// Renders real piano audio with the macOS General MIDI sound bank (offline), then streams it
/// through the analyzer + matcher exactly like the microphone pipeline does.
@Suite(.serialized) struct EndToEndTests {
    static let dls = URL(fileURLWithPath: "/System/Library/Components/CoreAudio.component/Contents/Resources/gs_instruments.dls")

    /// Renders the given steps: each step is struck at `interval` seconds.
    func render(_ steps: [[Int]], interval: Double, sampleRate: Double = 48_000, legato: Bool = false) throws -> [Float] {
        let engine = AVAudioEngine()
        let sampler = AVAudioUnitSampler()
        engine.attach(sampler)
        engine.connect(sampler, to: engine.mainMixerNode, format: nil)
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
        try sampler.loadSoundBankInstrument(at: Self.dls, program: 0,
                                            bankMSB: UInt8(kAUSampler_DefaultMelodicBankMSB), bankLSB: UInt8(kAUSampler_DefaultBankLSB))
        try engine.start()

        let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 512)!
        var out: [Float] = []
        let total = Int((Double(steps.count) * interval + 1.0) * sampleRate)
        var nextStep = 0
        var sounding: [Int] = []
        var frame = 0
        while frame < total {
            let t = Double(frame) / sampleRate
            if nextStep < steps.count, t >= Double(nextStep) * interval + 0.3 {
                for p in sounding { sampler.stopNote(UInt8(p), onChannel: 0) }
                sounding = steps[nextStep]
                for p in sounding { sampler.startNote(UInt8(p), withVelocity: 80, onChannel: 0) }
                nextStep += 1
            } else if !legato, !sounding.isEmpty, t >= Double(nextStep - 1) * interval + 0.3 + interval * 0.8 {
                for p in sounding { sampler.stopNote(UInt8(p), onChannel: 0) }
                sounding = []
            }
            _ = try engine.renderOffline(512, to: buffer)
            let ptr = buffer.floatChannelData![0]
            out.append(contentsOf: UnsafeBufferPointer(start: ptr, count: Int(buffer.frameLength)))
            frame += 512
        }
        engine.stop()
        return out
    }

    /// Simulates a lesson: returns how many steps were validated.
    func simulate(audio: [Float], steps: [[Int]], sampleRate: Double = 48_000, ignoreOctave: Bool = false,
                  noise: Float = 0) -> (completed: Int, wrong: Int) {
        let analyzer = PitchAnalyzer(sampleRate: sampleRate)
        var matcher = NoteMatcher()
        matcher.ignoreOctave = ignoreOctave
        var index = 0
        var wrong = 0
        matcher.reset(expected: Set(steps[0]))
        let hop = Int(sampleRate * 0.04)
        var pos = analyzer.fftSize
        while pos <= audio.count, index < steps.count {
            var window = Array(audio[(pos - analyzer.fftSize)..<pos])
            if noise > 0 { for i in window.indices { window[i] += Float.random(in: -noise...noise) } }
            switch matcher.process(analyzer.analyze(window)) {
            case .correct:
                index += 1
                if index < steps.count { matcher.reset(expected: Set(steps[index])) }
            case .wrong:
                wrong += 1
            default: break
            }
            pos += hop
        }
        return (index, wrong)
    }

    @Test func furEliseRightHandWithRealPianoSound() throws {
        let score = try MIDIFileParser.parse(url: try #require(Bundle.module.url(forResource: "elise", withExtension: "mid", subdirectory: "Fixtures")))
        let steps = PracticeSequence.build(score: score, options: PracticeOptions(hands: .right, melodyOnly: true))
            .prefix(24).map(\.pitches)
        let audio = try render(Array(steps), interval: 0.6)
        let result = simulate(audio: audio, steps: Array(steps))
        #expect(result.completed == steps.count, "validated \(result.completed)/\(steps.count)")
        #expect(result.wrong == 0)
    }

    @Test func repeatedNotesNeedNewStrikes() throws {
        // "Au clair de la lune": Do Do Do Ré Mi Ré Do Mi Ré Ré Do
        let steps = [60, 60, 60, 62, 64, 62, 60, 64, 62, 62, 60].map { [$0] }
        let audio = try render(steps, interval: 0.55)
        #expect(simulate(audio: audio, steps: steps).completed == steps.count)

        // A single held note must not validate three repeated steps.
        let one = try render([[60]], interval: 2.0)
        #expect(simulate(audio: one, steps: [[60], [60], [60]]).completed == 1)
    }

    @Test func wrongNoteDoesNotAdvance() throws {
        let audio = try render([[62]], interval: 1.5)
        let result = simulate(audio: audio, steps: [[60]])
        #expect(result.completed == 0)
        #expect(result.wrong >= 1)
    }

    @Test func octaveMistakeRejectedUnlessTolerated() throws {
        let audio = try render([[72]], interval: 1.5)
        #expect(simulate(audio: audio, steps: [[60]]).completed == 0)
        #expect(simulate(audio: audio, steps: [[60]], ignoreOctave: true).completed == 1)
    }

    @Test func chordsBothHands() throws {
        let steps = [[48, 64], [43, 62], [48, 60], [53, 65], [55, 67]]
        let audio = try render(steps, interval: 0.8)
        #expect(simulate(audio: audio, steps: steps).completed == steps.count)
    }

    @Test func toleratesRoomNoise() throws {
        let steps = [67, 69, 71, 72, 74, 76].map { [$0] }
        let audio = try render(steps, interval: 0.6)
        #expect(simulate(audio: audio, steps: steps, noise: 0.003).completed == steps.count)
    }

    @Test func lowBassNotes() throws {
        let steps = [36, 38, 40, 41, 43].map { [$0] }
        let audio = try render(steps, interval: 0.8)
        #expect(simulate(audio: audio, steps: steps).completed == steps.count)
    }

    @Test func furEliseBothHandsLegato() throws {
        let score = try MIDIFileParser.parse(url: try #require(Bundle.module.url(forResource: "elise", withExtension: "mid", subdirectory: "Fixtures")))
        let steps = PracticeSequence.build(score: score, options: PracticeOptions(hands: .both, melodyOnly: true))
            .prefix(30).map(\.pitches)
        let audio = try render(Array(steps), interval: 0.5, legato: true)
        let result = simulate(audio: audio, steps: Array(steps))
        #expect(result.completed == steps.count, "validated \(result.completed)/\(steps.count)")
    }

    /// Loads a speech recording (made with `say`) as mono samples.
    func speech(_ name: String) throws -> ([Float], Double) {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "wav", subdirectory: "Fixtures"))
        let file = try AVAudioFile(forReading: url)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        return (samples, file.processingFormat.sampleRate)
    }

    @Test(arguments: ["speech-fr", "speech-en"])
    func talkingIsNotTakenForNotes(name: String) throws {
        let (audio, rate) = try speech(name)
        // Whatever note the lesson expects in the voice range, talking must neither validate it nor count as a mistake.
        for note in 40...64 {
            let result = simulate(audio: audio, steps: [[note]], sampleRate: rate)
            #expect(result.completed == 0, "note \(note) validated by speech")
            #expect(result.wrong == 0, "speech reported as a wrong note while expecting \(note)")
        }
    }

    @Test func pianoFilterCanBeTurnedOff() throws {
        let (audio, rate) = try speech("speech-fr")
        let analyzer = PitchAnalyzer(sampleRate: rate)
        var filtered = NoteMatcher(), unfiltered = NoteMatcher()
        unfiltered.pianoOnly = false
        var heard = (filtered: 0, unfiltered: 0)
        let hop = Int(rate * 0.04)
        var pos = 4096
        while pos <= audio.count {
            let frame = analyzer.analyze(Array(audio[max(0, pos - analyzer.fftSize)..<pos]))
            if filtered.process(frame) != .silence, filtered.isPianoTone { heard.filtered += 1 }
            if unfiltered.process(frame) != .silence, unfiltered.isPianoTone { heard.unfiltered += 1 }
            pos += hop
        }
        #expect(heard.unfiltered > 100)
        #expect(heard.filtered * 20 < heard.unfiltered)
    }
}
