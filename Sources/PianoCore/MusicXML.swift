import Foundation

/// MusicXML (.musicxml / .xml / .mxl) parser producing a `Score`.
///
/// Supports what matters for practice: pitches, durations, chords, ties,
/// backup/forward, staves (right/left hand), and tempo marks.
public enum MusicXMLParser {
    public static func parse(url: URL) throws -> Score {
        if url.pathExtension.lowercased() == "mxl" {
            return try parse(data: try extractMXL(url))
        }
        return try parse(data: Data(contentsOf: url))
    }

    public static func parse(data: Data) throws -> Score {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        guard parser.parse() || !delegate.notes.isEmpty else {
            throw ScoreError.invalidMusicXML(parser.parserError?.localizedDescription ?? "analyse impossible")
        }
        guard !delegate.notes.isEmpty else { throw ScoreError.empty }
        return Score(notes: delegate.notes, trackNames: delegate.trackNames, title: delegate.title)
    }

    /// Unzips a compressed MusicXML file and returns the root score document.
    static func extractMXL(_ url: URL) throws -> Data {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("mxl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        p.arguments = ["-qq", "-o", url.path, "-d", tmp.path]
        try p.run()
        p.waitUntilExit()

        let container = tmp.appendingPathComponent("META-INF/container.xml")
        if let xml = try? String(contentsOf: container, encoding: .utf8),
           let range = xml.range(of: #"full-path="([^"]+)""#, options: .regularExpression) {
            let attr = String(xml[range]).replacingOccurrences(of: "full-path=", with: "").trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            return try Data(contentsOf: tmp.appendingPathComponent(attr))
        }
        let files = FileManager.default.enumerator(at: tmp, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
        if let score = files.first(where: { ["xml", "musicxml"].contains($0.pathExtension.lowercased()) && !$0.path.contains("META-INF") }) {
            return try Data(contentsOf: score)
        }
        throw ScoreError.invalidMusicXML("archive .mxl sans partition")
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var notes: [ScoreNote] = []
        var trackNames: [Int: String] = [:]
        var title: String?

        // Part state
        private var partIndex = -1
        private var partNames: [String: String] = [:]
        private var currentPartID = ""
        private var divisions = 1.0
        /// Position in quarter notes within the part.
        private var position = 0.0
        private var lastNoteStart = 0.0
        /// Tempo map in quarter notes -> bpm (shared across parts, first part wins).
        private var tempos: [(Double, Double)] = [(0, 100)]
        private var pendingNotes: [(pitch: Int, startQ: Double, durQ: Double, staff: Int, tieStop: Bool, tieStart: Bool, velocity: Int)] = []

        // Note state
        private var inNote = false
        private var isRest = false
        private var isChord = false
        private var isGrace = false
        private var step = ""
        private var alter = 0.0
        private var octave = 4
        private var duration = 0.0
        private var staff = 1
        private var tieStart = false
        private var tieStop = false
        private var dynamicsVelocity = 80

        private var text = ""
        private var elementStack: [String] = []

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            elementStack.append(name)
            text = ""
            switch name {
            case "score-part":
                currentPartID = attributes["id"] ?? ""
            case "part":
                partIndex += 1
                position = 0
                lastNoteStart = 0
                divisions = 1
                if let id = attributes["id"], let n = partNames[id] {
                    trackNames[partIndex * 2] = n
                }
            case "note":
                inNote = true
                isRest = false; isChord = false; isGrace = false
                step = ""; alter = 0; octave = 4; duration = 0; staff = 1
                tieStart = false; tieStop = false
            case "rest": if inNote { isRest = true }
            case "chord": if inNote { isChord = true }
            case "grace": if inNote { isGrace = true }
            case "tie":
                if inNote {
                    if attributes["type"] == "start" { tieStart = true }
                    if attributes["type"] == "stop" { tieStop = true }
                }
            case "sound":
                if let t = attributes["tempo"], let bpm = Double(t), bpm > 0, partIndex <= 0 {
                    tempos.append((position, bpm))
                }
                if let d = attributes["dynamics"], let v = Double(d) {
                    dynamicsVelocity = max(20, min(127, Int(v * 0.9)))
                }
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            text += string
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let parent = elementStack.dropLast().last ?? ""
            defer { elementStack.removeLast(); text = "" }

            switch name {
            case "work-title", "movement-title":
                if title == nil, !value.isEmpty { title = value }
            case "part-name":
                if !currentPartID.isEmpty { partNames[currentPartID] = value }
            case "divisions":
                divisions = max(Double(value) ?? 1, 1)
            case "step": step = value
            case "alter": alter = Double(value) ?? 0
            case "octave": octave = Int(value) ?? 4
            case "staff": if inNote { staff = Int(value) ?? 1 }
            case "duration":
                let q = (Double(value) ?? 0) / divisions
                if inNote {
                    duration = q
                } else if parent == "backup" {
                    position = max(0, position - q)
                } else if parent == "forward" {
                    position += q
                }
            case "per-minute":
                if let bpm = Double(value), bpm > 0, partIndex <= 0 { tempos.append((position, bpm)) }
            case "note":
                inNote = false
                guard !isGrace else { return }
                let start = isChord ? lastNoteStart : position
                if !isChord {
                    lastNoteStart = position
                    position += duration
                }
                guard !isRest, let pitch = midiPitch() else { return }
                pendingNotes.append((pitch, start, duration, staff, tieStop, tieStart, dynamicsVelocity))
            case "part":
                flushPart()
            default: break
            }
        }

        private func midiPitch() -> Int? {
            let base: [String: Int] = ["C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11]
            guard let b = base[step.uppercased()] else { return nil }
            return (octave + 1) * 12 + b + Int(alter.rounded())
        }

        private func seconds(atQuarter q: Double) -> Double {
            // Later marks at the same position override earlier ones (index breaks ties).
            let map = tempos.enumerated().sorted { ($0.element.0, $0.offset) < ($1.element.0, $1.offset) }.map(\.element)
            var t = 0.0
            var prevQ = 0.0
            var bpm = 100.0
            for (mq, mbpm) in map {
                if mq > q { break }
                t += (mq - prevQ) * 60 / bpm
                prevQ = mq
                bpm = mbpm
            }
            return t + (q - prevQ) * 60 / bpm
        }

        private func flushPart() {
            // Merge tied notes, then convert to seconds.
            var merged: [(pitch: Int, startQ: Double, durQ: Double, staff: Int, velocity: Int)] = []
            var openTies: [Int: Int] = [:] // pitch -> index in merged
            for n in pendingNotes.sorted(by: { $0.startQ < $1.startQ }) {
                if n.tieStop, let idx = openTies[n.pitch] {
                    merged[idx].durQ = n.startQ + n.durQ - merged[idx].startQ
                    if !n.tieStart { openTies[n.pitch] = nil }
                    continue
                }
                merged.append((n.pitch, n.startQ, n.durQ, n.staff, n.velocity))
                if n.tieStart { openTies[n.pitch] = merged.count - 1 }
            }
            for m in merged {
                let s = seconds(atQuarter: m.startQ)
                let e = seconds(atQuarter: m.startQ + max(m.durQ, 0.125))
                let track = partIndex * 2 + max(0, m.staff - 1)
                notes.append(ScoreNote(pitch: m.pitch, velocity: m.velocity, start: s, duration: e - s, track: track, channel: 0))
            }
            pendingNotes.removeAll()
        }
    }
}
