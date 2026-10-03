import Foundation
import Testing
@testable import PianoCore

private func fixture(_ name: String) throws -> URL {
    try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
}

/// Piano-like tone: decaying harmonics with slight inharmonicity.
private func pianoTone(midi notes: [Int], sampleRate: Double = 48_000, count: Int = 8192, amplitude: Float = 0.3) -> [Float] {
    var out = [Float](repeating: 0, count: count)
    for note in notes {
        let f0 = NoteName.frequency(note)
        let partials: [Float] = [1.0, 0.6, 0.35, 0.25, 0.15, 0.1]
        for (h, a) in partials.enumerated() {
            let f = f0 * Double(h + 1) * (1 + 0.0004 * Double((h + 1) * (h + 1)))
            guard f < sampleRate / 2 else { continue }
            for i in 0..<count {
                let t = Double(i) / sampleRate
                out[i] += amplitude * a * Float(sin(2 * .pi * f * t)) * Float(exp(-t * 1.5))
            }
        }
    }
    return out
}

@Suite struct NoteNameTests {
    @Test func frenchNames() {
        #expect(NoteName.french(60) == "Do4")
        #expect(NoteName.french(69) == "La4")
        #expect(NoteName.french(61) == "Do♯4")
        #expect(abs(NoteName.frequency(69) - 440) < 0.001)
        #expect(Int(NoteName.midi(forFrequency: 261.63).rounded()) == 60)
    }
}

@Suite struct MIDIParserTests {
    @Test func parsesFurElise() throws {
        let score = try MIDIFileParser.parse(url: try fixture("elise.mid"))
        #expect(score.notes.count > 100)
        #expect(score.tracks.count == 2)
        // Für Elise starts E5 D#5 E5 D#5 E5 B4 D5 C5 A4.
        let steps = PracticeSequence.build(score: score, options: PracticeOptions(hands: .right, melodyOnly: true))
        let first = steps.prefix(9).map { $0.pitches.first! }
        #expect(first == [76, 75, 76, 75, 76, 71, 74, 72, 69])
    }

    @Test func handAssignmentSplitsTracks() throws {
        let score = try MIDIFileParser.parse(url: try fixture("elise.mid"))
        let right = PracticeSequence.build(score: score, options: PracticeOptions(hands: .right, melodyOnly: false))
        let left = PracticeSequence.build(score: score, options: PracticeOptions(hands: .left, melodyOnly: false))
        let both = PracticeSequence.build(score: score, options: PracticeOptions(hands: .both, melodyOnly: false))
        #expect(!right.isEmpty && !left.isEmpty)
        #expect(both.count >= right.count)
        let avgRight = right.flatMap(\.pitches).reduce(0, +) / right.flatMap(\.pitches).count
        let avgLeft = left.flatMap(\.pitches).reduce(0, +) / left.flatMap(\.pitches).count
        #expect(avgRight > avgLeft)
    }

    @Test func runningStatusAndTempo() throws {
        // Format 0, 96 ppq, tempo 120bpm, C4 for one beat then D4 using running status.
        let track: [UInt8] = [
            0x00, 0xFF, 0x51, 0x03, 0x07, 0xA1, 0x20,
            0x00, 0x90, 60, 100,
            0x60, 60, 0,          // running status note-on vel 0 = off
            0x00, 62, 100,
            0x60, 0x80, 62, 0,
            0x00, 0xFF, 0x2F, 0x00,
        ]
        var data: [UInt8] = Array("MThd".utf8) + [0, 0, 0, 6, 0, 0, 0, 1, 0, 96]
        data += Array("MTrk".utf8) + [0, 0, 0, UInt8(track.count)] + track
        let score = try MIDIFileParser.parse(data: Data(data))
        #expect(score.notes.map(\.pitch) == [60, 62])
        #expect(abs(score.notes[1].start - 0.5) < 0.001)
        #expect(abs(score.notes[0].duration - 0.5) < 0.001)
    }
}

@Suite struct MusicXMLTests {
    @Test func parsesChordsTiesAndStaves() throws {
        let xml = """
        <?xml version="1.0"?>
        <score-partwise><work><work-title>Test</work-title></work>
        <part-list><score-part id="P1"><part-name>Piano</part-name></score-part></part-list>
        <part id="P1"><measure number="1">
          <attributes><divisions>2</divisions><staves>2</staves></attributes>
          <direction><sound tempo="120"/></direction>
          <note><pitch><step>C</step><octave>5</octave></pitch><duration>2</duration><staff>1</staff></note>
          <note><chord/><pitch><step>E</step><octave>5</octave></pitch><duration>2</duration><staff>1</staff></note>
          <note><pitch><step>F</step><alter>1</alter><octave>5</octave></pitch><duration>2</duration><tie type="start"/><staff>1</staff></note>
          <note><pitch><step>F</step><alter>1</alter><octave>5</octave></pitch><duration>2</duration><tie type="stop"/><staff>1</staff></note>
          <backup><duration>6</duration></backup>
          <note><pitch><step>C</step><octave>3</octave></pitch><duration>6</duration><staff>2</staff></note>
        </measure></part></score-partwise>
        """
        let score = try MusicXMLParser.parse(data: Data(xml.utf8))
        #expect(score.title == "Test")
        #expect(score.notes.count == 4)
        let fs = try #require(score.notes.first { $0.pitch == 78 })
        #expect(abs(fs.start - 0.5) < 0.001)
        #expect(abs(fs.duration - 1.0) < 0.001)
        let bass = try #require(score.notes.first { $0.pitch == 48 })
        #expect(bass.start == 0)
        #expect(bass.track != fs.track)
        let steps = PracticeSequence.build(score: score, options: PracticeOptions(hands: .right, melodyOnly: false))
        #expect(steps.first?.pitches == [72, 76])
    }
}

@Suite struct CatalogTests {
    @Test func parsesEntries() throws {
        let html = try String(contentsOf: try fixture("catalog_excerpt.html"), encoding: .utf8)
        let entries = CatalogParser.parse(html: html)
        #expect(entries.count == 2) // the first table is the legend header
        for e in entries {
            #expect(!e.title.isEmpty)
            #expect(!e.composer.isEmpty)
            #expect(e.level != nil)
            #expect(e.pdfURL?.scheme == "https")
            #expect(e.previewURL?.scheme == "https")
        }
    }

    @Test func fuzzyMatch() {
        let e = CatalogEntry(id: "x", title: "La Lettre à Élise", composer: "Beethoven", level: 3, info: "",
                             previewURL: nil, pdfURL: URL(string: "https://x/lettre-a-elise.pdf"),
                             midiURL: URL(string: "https://x/lettre-a-elise.mid"), zipURL: nil)
        #expect(CatalogParser.bestMatch(forFileName: "lettre-a-elise", in: [e])?.id == "x")
        #expect(CatalogParser.bestMatch(forFileName: "Lettre à Elise (copie)", in: [e])?.id == "x")
        #expect(CatalogParser.bestMatch(forFileName: "Clair de lune", in: [e]) == nil)
    }
}

@Suite struct PitchTests {
    let analyzer = PitchAnalyzer(sampleRate: 48_000)

    @Test(arguments: [33, 45, 57, 60, 64, 69, 76, 84, 96])
    func detectsSingleNotes(midi: Int) {
        let frame = analyzer.analyze(pianoTone(midi: [midi]))
        #expect(frame.midiPitch == midi)
        var m = NoteMatcher()
        m.reset(expected: [midi], requireOnset: false)
        #expect(m.isPresent(midi, in: frame))
        #expect(!m.isPresent(midi + 2, in: frame))
        #expect(!m.isPresent(midi - 1, in: frame))
    }

    @Test func detectsChord() {
        let frame = analyzer.analyze(pianoTone(midi: [60, 64, 67], amplitude: 0.15))
        var m = NoteMatcher()
        m.reset(expected: [60, 64, 67], requireOnset: false)
        #expect([60, 64, 67].allSatisfy { m.isPresent($0, in: frame) })
        m.reset(expected: [60, 65, 69], requireOnset: false)
        #expect(!m.isPresent(65, in: frame))
    }

    @Test func matcherFlow() {
        var m = NoteMatcher()
        m.reset(expected: [69])
        let silence = analyzer.analyze([Float](repeating: 0, count: 8192))
        for _ in 0..<5 { #expect(m.process(silence) == .silence) }
        let tone = analyzer.analyze(pianoTone(midi: [69]))
        var verdicts: [NoteMatcher.Verdict] = []
        // A piano note is recognised once its pitch and envelope have been steady for a few frames.
        for _ in 0..<5 { verdicts.append(m.process(tone)) }
        #expect(verdicts.contains(.correct))

        // Wrong note gets reported (but not the previous step's note, which may still ring).
        m.reset(expected: [72])
        _ = m.process(silence)
        #expect(!(0..<6).map { _ in m.process(tone) }.contains(.wrong(69)))
        m.reset(expected: [74])
        _ = m.process(silence)
        let other = analyzer.analyze(pianoTone(midi: [65]))
        let wrong = (0..<6).map { _ in m.process(other) }
        #expect(wrong.contains(.wrong(65)))
        #expect(!wrong.contains(.correct))
    }

    @Test func silenceHasNoPitch() {
        let noise = (0..<8192).map { _ in Float.random(in: -0.001...0.001) }
        let frame = analyzer.analyze(noise)
        var m = NoteMatcher()
        m.reset(expected: [60])
        #expect(m.process(frame) == .silence)
    }
}

@Suite struct OMRMusicXMLTests {
    /// `clair-omr.mxl` was produced by Audiveris from the site's PDF: its melody must match the site's MIDI.
    @Test func compressedMusicXMLFromOMRMatchesMIDI() throws {
        let omr = try MusicXMLParser.parse(url: try fixture("clair-omr.mxl"))
        let midi = try MIDIFileParser.parse(url: try fixture("clair.mid"))
        let opts = PracticeOptions(hands: .right, melodyOnly: true)
        let a = PracticeSequence.build(score: omr, options: opts).map { $0.pitches[0] }
        let b = PracticeSequence.build(score: midi, options: opts).map { $0.pitches[0] }
        print("OMR :", a.prefix(24).map { NoteName.french($0) }.joined(separator: " "))
        print("MIDI:", b.prefix(24).map { NoteName.french($0) }.joined(separator: " "))
        #expect(Array(a.prefix(11)) == Array(b.prefix(11)))
    }
}

@Suite struct MIDIWriterTests {
    @Test func roundTrip() throws {
        let original = try MIDIFileParser.parse(url: try fixture("elise.mid"))
        let reparsed = try MIDIFileParser.parse(data: MIDIFileWriter.data(for: original))
        #expect(reparsed.notes.count == original.notes.count)
        for (a, b) in zip(original.notes, reparsed.notes).prefix(200) {
            #expect(a.pitch == b.pitch)
            #expect(abs(a.start - b.start) < 0.002)
        }
        let opts = PracticeOptions(hands: .right, melodyOnly: true)
        #expect(PracticeSequence.build(score: original, options: opts).map(\.pitches)
                == PracticeSequence.build(score: reparsed, options: opts).map(\.pitches))
    }

    @Test func concatenatePages() throws {
        let page = try MusicXMLParser.parse(url: try fixture("clair-omr.mxl"))
        let both = MIDIFileWriter.concatenate([page, page])
        #expect(both.notes.count == page.notes.count * 2)
        #expect(both.duration > page.duration * 2)
    }
}
