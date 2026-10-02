import Foundation

public enum Hand: String, Codable, CaseIterable, Sendable, Identifiable {
    case right, left
    public var id: String { rawValue }
}

public enum HandSelection: String, Codable, CaseIterable, Sendable, Identifiable {
    case right, left, both
    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .right: return "Main droite"
        case .left: return "Main gauche"
        case .both: return "Deux mains"
        }
    }

    func includes(_ hand: Hand) -> Bool {
        switch self {
        case .both: return true
        case .right: return hand == .right
        case .left: return hand == .left
        }
    }
}

/// One thing the student must play: a single note or a chord.
public struct PracticeStep: Hashable, Sendable, Identifiable {
    public var id: Int
    public var pitches: [Int]
    public var hands: [Int: Hand]
    public var time: Double
    public var duration: Double

    public var isChord: Bool { pitches.count > 1 }
}

public struct PracticeOptions: Sendable, Equatable {
    public var hands: HandSelection = .right
    /// Keep only the highest note (right hand) / lowest note (left hand) of each chord.
    public var melodyOnly: Bool = true
    /// Notes starting within this window are grouped into one step.
    public var chordWindow: Double = 0.05
    /// Maximum number of notes kept in a chord when `melodyOnly` is off.
    public var maxChordSize: Int = 4

    public init(hands: HandSelection = .right, melodyOnly: Bool = true) {
        self.hands = hands
        self.melodyOnly = melodyOnly
    }
}

public enum PracticeSequence {
    /// Assigns each note of the score to a hand.
    public static func handAssignment(for score: Score) -> (ScoreNote) -> Hand {
        let tracks = score.tracks
        if tracks.count >= 2 {
            var avg: [Int: Double] = [:]
            for t in tracks {
                let ps = score.notes.filter { $0.track == t }.map { Double($0.pitch) }
                avg[t] = ps.reduce(0, +) / Double(max(ps.count, 1))
            }
            let names = score.trackNames.mapValues { $0.lowercased() }
            func explicitHand(_ t: Int) -> Hand? {
                guard let n = names[t] else { return nil }
                if n.contains("droite") || n.contains("right") || n.contains("treble") { return .right }
                if n.contains("gauche") || n.contains("left") || n.contains("bass") { return .left }
                return nil
            }
            var map: [Int: Hand] = [:]
            if tracks.count == 2 {
                let (a, b) = (tracks[0], tracks[1])
                let aHigh = (avg[a] ?? 0) >= (avg[b] ?? 0)
                map[a] = explicitHand(a) ?? (aHigh ? .right : .left)
                map[b] = explicitHand(b) ?? (aHigh ? .left : .right)
                if map[a] == map[b] { map[a] = aHigh ? .right : .left; map[b] = aHigh ? .left : .right }
            } else {
                for t in tracks { map[t] = explicitHand(t) ?? ((avg[t] ?? 60) >= 59 ? .right : .left) }
            }
            if Set(map.values).count == 2 {
                return { map[$0.track] ?? ($0.pitch >= 60 ? .right : .left) }
            }
        }
        return { $0.pitch >= 60 ? .right : .left }
    }

    public static func build(score: Score, options: PracticeOptions) -> [PracticeStep] {
        let handOf = handAssignment(for: score)
        let selected = score.notes
            .filter { NoteName.pianoRange.contains($0.pitch) }
            .map { ($0, handOf($0)) }
            .filter { options.hands.includes($0.1) }
            .sorted { $0.0.start < $1.0.start }

        var steps: [PracticeStep] = []
        var group: [(ScoreNote, Hand)] = []

        func flush() {
            guard let first = group.first else { return }
            var chosen = group
            if options.melodyOnly {
                // Per hand, keep the melodic line: top note for the right hand, bottom note for the left.
                var result: [(ScoreNote, Hand)] = []
                if let top = group.filter({ $0.1 == .right }).max(by: { $0.0.pitch < $1.0.pitch }) { result.append(top) }
                if let bottom = group.filter({ $0.1 == .left }).min(by: { $0.0.pitch < $1.0.pitch }) { result.append(bottom) }
                chosen = result
            } else if chosen.count > options.maxChordSize {
                chosen = Array(chosen.sorted { $0.0.pitch > $1.0.pitch }.prefix(options.maxChordSize))
            }
            var hands: [Int: Hand] = [:]
            for (n, h) in chosen { hands[n.pitch] = h }
            let pitches = Array(Set(chosen.map(\.0.pitch))).sorted()
            let duration = chosen.map(\.0.duration).max() ?? 0.3
            steps.append(PracticeStep(id: steps.count, pitches: pitches, hands: hands, time: first.0.start, duration: duration))
            group.removeAll()
        }

        for item in selected {
            if let first = group.first, item.0.start - first.0.start > options.chordWindow {
                flush()
            }
            group.append(item)
        }
        flush()
        return steps
    }
}
