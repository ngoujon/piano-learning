import Foundation

/// A single note extracted from a score (MIDI or MusicXML).
public struct ScoreNote: Hashable, Codable, Sendable {
    public var pitch: Int
    public var velocity: Int
    /// Onset in seconds from the beginning of the piece.
    public var start: Double
    public var duration: Double
    /// Logical track (MIDI track or MusicXML part/staff).
    public var track: Int
    public var channel: Int

    public init(pitch: Int, velocity: Int = 80, start: Double, duration: Double, track: Int = 0, channel: Int = 0) {
        self.pitch = pitch
        self.velocity = velocity
        self.start = start
        self.duration = duration
        self.track = track
        self.channel = channel
    }

    public var end: Double { start + duration }
}

/// One beat of the piece's metre, as a metronome would click it.
public struct Beat: Hashable, Sendable {
    /// Seconds from the beginning of the piece.
    public var time: Double
    /// 1 for the downbeat of a bar.
    public var number: Int
    public var beatsInBar: Int

    public init(time: Double, number: Int, beatsInBar: Int) {
        self.time = time
        self.number = number
        self.beatsInBar = beatsInBar
    }
}

/// A parsed piece of music, independent of its source format.
public struct Score: Sendable {
    public var notes: [ScoreNote]
    public var trackNames: [Int: String]
    public var title: String?
    /// The beat grid (follows tempo and time signature changes); empty when the file has no metre.
    public var beats: [Beat]

    public init(notes: [ScoreNote], trackNames: [Int: String] = [:], title: String? = nil, beats: [Beat] = []) {
        self.notes = notes.sorted { ($0.start, $0.pitch) < ($1.start, $1.pitch) }
        self.trackNames = trackNames
        self.title = title
        self.beats = beats
    }

    public var duration: Double { notes.map(\.end).max() ?? 0 }
    public var tracks: [Int] { Array(Set(notes.map(\.track))).sorted() }

    /// Tempo at the start of the piece, in beats per minute of the notated beat.
    public var initialBPM: Double? {
        guard beats.count >= 2, beats[1].time > beats[0].time else { return nil }
        return 60 / (beats[1].time - beats[0].time)
    }

    /// Builds the beat grid from time signatures given in quarter notes (`at`, beats per bar, beat unit),
    /// up to `length` quarters, converting positions with the piece's tempo map.
    public static func beatGrid(signatures: [(at: Double, beats: Int, unit: Int)], length: Double,
                                seconds: (Double) -> Double) -> [Beat] {
        var sigs = signatures.filter { $0.beats > 0 && $0.unit > 0 }.sorted { $0.at < $1.at }
        if sigs.first.map({ $0.at > 0 }) ?? true { sigs.insert((0, 4, 4), at: 0) }
        var beats: [Beat] = []
        for (i, sig) in sigs.enumerated() {
            let end = i + 1 < sigs.count ? sigs[i + 1].at : length
            let step = 4.0 / Double(sig.unit)
            var q = sig.at
            var n = 0
            while q < end - 1e-6, beats.count < 100_000 {
                beats.append(Beat(time: seconds(q), number: n % sig.beats + 1, beatsInBar: sig.beats))
                n += 1
                q = sig.at + Double(n) * step
            }
        }
        return beats
    }
}

public enum ScoreError: Error, LocalizedError {
    case invalidMIDI(String)
    case invalidMusicXML(String)
    case empty

    public var errorDescription: String? {
        switch self {
        case .invalidMIDI(let r): return "Fichier MIDI invalide : \(r)"
        case .invalidMusicXML(let r): return "Fichier MusicXML invalide : \(r)"
        case .empty: return "Aucune note trouvée dans ce fichier."
        }
    }
}

/// Minimal Standard MIDI File (SMF type 0/1) parser.
public enum MIDIFileParser {
    private struct RawEvent {
        var tick: Int
        var kind: Kind
        enum Kind {
            case noteOn(channel: Int, pitch: Int, velocity: Int)
            case noteOff(channel: Int, pitch: Int)
            case tempo(microsPerQuarter: Int)
            case timeSignature(beats: Int, unit: Int)
            case trackName(String)
        }
    }

    public static func parse(url: URL) throws -> Score {
        try parse(data: Data(contentsOf: url))
    }

    public static func parse(data: Data) throws -> Score {
        let bytes = [UInt8](data)
        var reader = ByteReader(bytes: bytes)

        // Some files carry a RIFF wrapper (RMID).
        if bytes.count > 20, bytes[0...3] == [0x52, 0x49, 0x46, 0x46] {
            guard let idx = findChunk("MThd", in: bytes) else { throw ScoreError.invalidMIDI("en-tête RMID") }
            reader.pos = idx
        }

        guard reader.readTag() == "MThd" else { throw ScoreError.invalidMIDI("en-tête MThd manquant") }
        let headerLength = Int(try reader.readUInt32())
        let format = Int(try reader.readUInt16())
        let trackCount = Int(try reader.readUInt16())
        let division = Int(try reader.readUInt16())
        reader.pos += max(0, headerLength - 6)
        _ = format

        var events: [(track: Int, event: RawEvent)] = []
        var trackIndex = 0
        while trackIndex < trackCount, reader.remaining >= 8 {
            let tag = reader.readTag()
            let length = Int(try reader.readUInt32())
            let end = min(reader.pos + length, bytes.count)
            if tag != "MTrk" {
                reader.pos = end
                continue
            }
            var trackReader = ByteReader(bytes: bytes, pos: reader.pos, end: end)
            for e in try parseTrack(&trackReader) {
                events.append((trackIndex, e))
            }
            reader.pos = end
            trackIndex += 1
        }

        // Tempo map (ticks -> seconds).
        var tempoChanges = events.compactMap { item -> (Int, Int)? in
            if case .tempo(let t) = item.event.kind { return (item.event.tick, t) }
            return nil
        }.sorted { $0.0 < $1.0 }
        if tempoChanges.first?.0 != 0 { tempoChanges.insert((0, 500_000), at: 0) }

        let secondsForTick: (Int) -> Double
        if division & 0x8000 != 0 {
            // SMPTE time division.
            let fps = Double(256 - (division >> 8))
            let ticksPerFrame = Double(division & 0xFF)
            secondsForTick = { Double($0) / (fps * ticksPerFrame) }
        } else {
            let ppq = Double(max(division, 1))
            // Precompute cumulative seconds at each tempo change.
            var cumulative: [(tick: Int, seconds: Double, tempo: Int)] = []
            var seconds = 0.0
            for (i, change) in tempoChanges.enumerated() {
                if i > 0 {
                    let prev = tempoChanges[i - 1]
                    seconds += Double(change.0 - prev.0) * Double(prev.1) / 1_000_000.0 / ppq
                }
                cumulative.append((change.0, seconds, change.1))
            }
            secondsForTick = { tick in
                var lo = 0, hi = cumulative.count - 1
                while lo < hi {
                    let mid = (lo + hi + 1) / 2
                    if cumulative[mid].tick <= tick { lo = mid } else { hi = mid - 1 }
                }
                let c = cumulative[lo]
                return c.seconds + Double(tick - c.tick) * Double(c.tempo) / 1_000_000.0 / ppq
            }
        }

        // Match note on/off pairs.
        struct Key: Hashable { let track: Int; let channel: Int; let pitch: Int }
        var open: [Key: [(tick: Int, velocity: Int)]] = [:]
        var notes: [ScoreNote] = []
        var names: [Int: String] = [:]
        let sorted = events.enumerated().sorted { a, b in
            a.element.event.tick != b.element.event.tick ? a.element.event.tick < b.element.event.tick : a.offset < b.offset
        }.map(\.element)

        func close(_ key: Key, at tick: Int) {
            guard var stack = open[key], !stack.isEmpty else { return }
            let start = stack.removeFirst()
            open[key] = stack
            let s = secondsForTick(start.tick)
            let e = secondsForTick(tick)
            notes.append(ScoreNote(pitch: key.pitch, velocity: start.velocity, start: s,
                                   duration: max(e - s, 0.05), track: key.track, channel: key.channel))
        }

        var lastTick = 0
        for item in sorted {
            lastTick = max(lastTick, item.event.tick)
            switch item.event.kind {
            case .noteOn(let ch, let p, let v):
                guard ch != 9 else { continue } // ignore percussion
                let key = Key(track: item.track, channel: ch, pitch: p)
                if v == 0 {
                    close(key, at: item.event.tick)
                } else {
                    open[key, default: []].append((item.event.tick, v))
                }
            case .noteOff(let ch, let p):
                guard ch != 9 else { continue }
                close(Key(track: item.track, channel: ch, pitch: p), at: item.event.tick)
            case .trackName(let n):
                if names[item.track] == nil { names[item.track] = n }
            case .tempo, .timeSignature:
                break
            }
        }
        // Close dangling notes.
        for (key, stack) in open {
            for _ in stack { close(key, at: max(lastTick, (stack.first?.tick ?? 0) + Int(max(division & 0x7FFF, 1)))) }
        }

        guard !notes.isEmpty else { throw ScoreError.empty }
        var beats: [Beat] = []
        if division & 0x8000 == 0 {
            let ppq = Double(max(division, 1))
            let signatures = sorted.compactMap { item -> (at: Double, beats: Int, unit: Int)? in
                if case .timeSignature(let b, let u) = item.event.kind { return (Double(item.event.tick) / ppq, b, u) }
                return nil
            }
            // A later signature at the same tick replaces the earlier one.
            let unique = Dictionary(signatures.map { ($0.at, $0) }, uniquingKeysWith: { _, last in last }).values
            let lastNoteTick = Double(lastTick) / ppq
            beats = Score.beatGrid(signatures: Array(unique), length: lastNoteTick) { secondsForTick(Int(($0 * ppq).rounded())) }
        }
        return Score(notes: notes, trackNames: names, title: names[0], beats: beats)
    }

    private static func parseTrack(_ r: inout ByteReader) throws -> [RawEvent] {
        var events: [RawEvent] = []
        var tick = 0
        var runningStatus: UInt8 = 0
        while r.remaining > 0 {
            tick += try r.readVarLen()
            var status = try r.readByte()
            if status < 0x80 {
                // Running status: this byte is the first data byte.
                guard runningStatus != 0 else { throw ScoreError.invalidMIDI("running status sans statut") }
                r.pos -= 1
                status = runningStatus
            }
            switch status {
            case 0xFF:
                let type = try r.readByte()
                let len = try r.readVarLen()
                let data = try r.readBytes(len)
                if type == 0x51, data.count == 3 {
                    let t = Int(data[0]) << 16 | Int(data[1]) << 8 | Int(data[2])
                    if t > 0 { events.append(RawEvent(tick: tick, kind: .tempo(microsPerQuarter: t))) }
                } else if type == 0x58, data.count >= 2 {
                    events.append(RawEvent(tick: tick, kind: .timeSignature(beats: Int(data[0]), unit: 1 << Int(min(data[1], 6)))))
                } else if type == 0x03 {
                    let name = String(bytes: data, encoding: .utf8) ?? String(bytes: data, encoding: .isoLatin1) ?? ""
                    events.append(RawEvent(tick: tick, kind: .trackName(name.trimmingCharacters(in: .whitespacesAndNewlines))))
                } else if type == 0x2F {
                    return events
                }
            case 0xF0, 0xF7:
                let len = try r.readVarLen()
                r.pos += len
            default:
                runningStatus = status
                let channel = Int(status & 0x0F)
                switch status & 0xF0 {
                case 0x80:
                    let p = try r.readByte(); _ = try r.readByte()
                    events.append(RawEvent(tick: tick, kind: .noteOff(channel: channel, pitch: Int(p))))
                case 0x90:
                    let p = try r.readByte(); let v = try r.readByte()
                    events.append(RawEvent(tick: tick, kind: .noteOn(channel: channel, pitch: Int(p), velocity: Int(v))))
                case 0xA0, 0xB0, 0xE0:
                    r.pos += 2
                case 0xC0, 0xD0:
                    r.pos += 1
                default:
                    throw ScoreError.invalidMIDI("statut inconnu \(status)")
                }
            }
        }
        return events
    }

    private static func findChunk(_ tag: String, in bytes: [UInt8]) -> Int? {
        let t = Array(tag.utf8)
        guard bytes.count >= t.count else { return nil }
        for i in 0...(bytes.count - t.count) where Array(bytes[i..<i + t.count]) == t { return i }
        return nil
    }
}

struct ByteReader {
    let bytes: [UInt8]
    var pos: Int
    let end: Int

    init(bytes: [UInt8], pos: Int = 0, end: Int? = nil) {
        self.bytes = bytes
        self.pos = pos
        self.end = end ?? bytes.count
    }

    var remaining: Int { end - pos }

    mutating func readByte() throws -> UInt8 {
        guard pos < end else { throw ScoreError.invalidMIDI("fin de données inattendue") }
        defer { pos += 1 }
        return bytes[pos]
    }

    mutating func readBytes(_ n: Int) throws -> [UInt8] {
        guard n >= 0, pos + n <= end else { throw ScoreError.invalidMIDI("fin de données inattendue") }
        defer { pos += n }
        return Array(bytes[pos..<pos + n])
    }

    mutating func readUInt16() throws -> UInt16 {
        let b = try readBytes(2)
        return UInt16(b[0]) << 8 | UInt16(b[1])
    }

    mutating func readUInt32() throws -> UInt32 {
        let b = try readBytes(4)
        return UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3])
    }

    mutating func readTag() -> String {
        guard let b = try? readBytes(4) else { return "" }
        return String(bytes: b, encoding: .ascii) ?? ""
    }

    mutating func readVarLen() throws -> Int {
        var value = 0
        for _ in 0..<4 {
            let b = try readByte()
            value = (value << 7) | Int(b & 0x7F)
            if b & 0x80 == 0 { return value }
        }
        return value
    }
}
