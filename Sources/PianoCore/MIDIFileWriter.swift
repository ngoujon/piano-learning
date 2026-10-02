import Foundation

/// Writes a `Score` as a Standard MIDI File (type 1, one track per score track).
public enum MIDIFileWriter {
    public static let ticksPerQuarter = 480
    /// Fixed tempo of 120 bpm: 1 second = 960 ticks.
    static let ticksPerSecond = Double(ticksPerQuarter) * 2

    public static func data(for score: Score) -> Data {
        var out: [UInt8] = Array("MThd".utf8) + be32(6) + be16(1)
        let tracks = score.tracks
        out += be16(UInt16(tracks.count + 1)) + be16(UInt16(ticksPerQuarter))

        // Tempo / title track.
        var meta: [UInt8] = []
        if let title = score.title, !title.isEmpty {
            let bytes = Array(title.utf8.prefix(120))
            meta += [0x00, 0xFF, 0x03] + varLen(bytes.count) + bytes
        }
        meta += [0x00, 0xFF, 0x51, 0x03, 0x07, 0xA1, 0x20] // 500000 µs per quarter
        meta += [0x00, 0xFF, 0x2F, 0x00]
        out += Array("MTrk".utf8) + be32(UInt32(meta.count)) + meta

        for (i, t) in tracks.enumerated() {
            var events: [(tick: Int, order: Int, bytes: [UInt8])] = []
            let channel = UInt8(i % 16 == 9 ? 10 : i % 16)
            for n in score.notes where n.track == t {
                let on = Int((n.start * ticksPerSecond).rounded())
                let off = max(on + 1, Int((n.end * ticksPerSecond).rounded()))
                let p = UInt8(max(0, min(127, n.pitch)))
                events.append((on, 1, [0x90 | channel, p, UInt8(max(1, min(127, n.velocity)))]))
                events.append((off, 0, [0x80 | channel, p, 0]))
            }
            events.sort { ($0.tick, $0.order) < ($1.tick, $1.order) }
            var body: [UInt8] = []
            if let name = score.trackNames[t], !name.isEmpty {
                let bytes = Array(name.utf8.prefix(60))
                body += [0x00, 0xFF, 0x03] + varLen(bytes.count) + bytes
            }
            var last = 0
            for e in events {
                body += varLen(e.tick - last) + e.bytes
                last = e.tick
            }
            body += [0x00, 0xFF, 0x2F, 0x00]
            out += Array("MTrk".utf8) + be32(UInt32(body.count)) + body
        }
        return Data(out)
    }

    /// Concatenates scores one after another (e.g. pages recognised separately).
    public static func concatenate(_ scores: [Score], gap: Double = 0.5) -> Score {
        var notes: [ScoreNote] = []
        var names: [Int: String] = [:]
        var offset = 0.0
        for s in scores {
            for var n in s.notes {
                n.start += offset
                notes.append(n)
            }
            names.merge(s.trackNames) { a, _ in a }
            offset += s.duration + gap
        }
        return Score(notes: notes, trackNames: names, title: scores.first?.title)
    }

    private static func be16(_ v: UInt16) -> [UInt8] { [UInt8(v >> 8), UInt8(v & 0xFF)] }
    private static func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }

    private static func varLen(_ value: Int) -> [UInt8] {
        var v = max(0, value)
        var bytes = [UInt8(v & 0x7F)]
        v >>= 7
        while v > 0 {
            bytes.insert(UInt8(v & 0x7F) | 0x80, at: 0)
            v >>= 7
        }
        return bytes
    }
}
