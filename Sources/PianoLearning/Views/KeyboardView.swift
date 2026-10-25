import PianoCore
import SwiftUI

/// An interactive piano keyboard drawn with Canvas.
struct KeyboardView: View {
    var range: ClosedRange<Int> = 21...108
    /// Key colour overrides.
    var highlights: [Int: Color] = [:]
    /// Labels drawn on specific keys (e.g. the target note name).
    var labels: [Int: String] = [:]
    var showCLabels = true
    var onPress: ((Int) -> Void)?

    @State private var pressed: Int?

    private var whiteKeys: [Int] { range.filter { !NoteName.isBlackKey($0) } }

    var body: some View {
        GeometryReader { geo in
            let layout = Layout(range: range, size: geo.size)
            Canvas { ctx, size in
                // White keys
                for (i, midi) in layout.whites.enumerated() {
                    let rect = CGRect(x: CGFloat(i) * layout.whiteWidth, y: 0, width: layout.whiteWidth, height: size.height)
                    let path = Path(roundedRect: rect.insetBy(dx: 0.5, dy: 0), cornerSize: CGSize(width: 3, height: 3))
                    let fill = highlights[midi] ?? (pressed == midi ? Color.gray.opacity(0.35) : .white)
                    ctx.fill(path, with: .color(fill))
                    ctx.stroke(path, with: .color(.black.opacity(0.35)), lineWidth: 0.8)
                    if let label = labels[midi] {
                        ctx.draw(Text(label).font(.system(size: min(13, layout.whiteWidth * 0.42), weight: .bold)).foregroundColor(.black),
                                 at: CGPoint(x: rect.midX, y: size.height - 30))
                    } else if showCLabels, midi % 12 == 0 {
                        ctx.draw(Text(midi.noteLabel).font(.system(size: min(10, layout.whiteWidth * 0.38))).foregroundColor(.gray),
                                 at: CGPoint(x: rect.midX, y: size.height - 12))
                    }
                }
                // Black keys
                for midi in range where NoteName.isBlackKey(midi) {
                    let rect = layout.blackRect(midi, height: size.height)
                    let path = Path(roundedRect: rect, cornerSize: CGSize(width: 2, height: 2))
                    let fill = highlights[midi] ?? (pressed == midi ? Color.gray : Color(white: 0.12))
                    ctx.fill(path, with: .color(fill))
                    if let label = labels[midi] {
                        ctx.draw(Text(label).font(.system(size: min(10, layout.whiteWidth * 0.36), weight: .bold)).foregroundColor(.white),
                                 at: CGPoint(x: rect.midX, y: rect.maxY - 14))
                    }
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        let key = layout.key(at: v.location, height: geo.size.height)
                        if key != pressed {
                            pressed = key
                            if let k = key { onPress?(k) }
                        }
                    }
                    .onEnded { _ in pressed = nil }
            )
        }
    }

    /// Lights the sounding notes of a played score in their hand's colour, marked D / G.
    static func playing(_ notes: [Int: Hand]) -> (highlights: [Int: Color], labels: [Int: String]) {
        (notes.mapValues { $0.color.opacity(0.8) }, notes.mapValues(\.letter))
    }

    struct Layout {
        let whites: [Int]
        let whiteWidth: CGFloat
        let blackWidth: CGFloat
        let range: ClosedRange<Int>

        init(range: ClosedRange<Int>, size: CGSize) {
            self.range = range
            whites = range.filter { !NoteName.isBlackKey($0) }
            whiteWidth = size.width / CGFloat(max(whites.count, 1))
            blackWidth = whiteWidth * 0.6
        }

        func whiteIndex(_ midi: Int) -> Int { whites.firstIndex(of: midi) ?? 0 }

        func blackRect(_ midi: Int, height: CGFloat) -> CGRect {
            // A black key sits on the boundary after the previous white key.
            let left = whiteIndex(midi - 1)
            let x = CGFloat(left + 1) * whiteWidth - blackWidth / 2
            return CGRect(x: x, y: 0, width: blackWidth, height: height * 0.62)
        }

        func key(at p: CGPoint, height: CGFloat) -> Int? {
            if p.y < height * 0.62 {
                for midi in range where NoteName.isBlackKey(midi) && range.contains(midi - 1) {
                    if blackRect(midi, height: height).contains(p) { return midi }
                }
            }
            let i = Int(p.x / whiteWidth)
            return whites.indices.contains(i) ? whites[i] : nil
        }
    }
}

extension Hand {
    /// Right hand blue, left hand green, everywhere in the app.
    var color: Color { self == .right ? .blue : .green }
    var letter: String { self == .right ? "D" : "G" }
}

/// "● Main droite  ● Main gauche" key for the colours.
struct HandLegend: View {
    var body: some View {
        HStack(spacing: 12) {
            ForEach(Hand.allCases) { hand in
                Label {
                    Text(hand == .right ? "Main droite (D)" : "Main gauche (G)")
                } icon: {
                    Circle().fill(hand.color).frame(width: 9, height: 9)
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

