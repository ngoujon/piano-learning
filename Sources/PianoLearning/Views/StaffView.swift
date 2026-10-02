import PianoCore
import SwiftUI

/// A grand staff (treble + bass clef) showing the steps around the current one,
/// so the student learns to read the notes while playing.
struct StaffView: View {
    struct Column: Identifiable {
        let id: Int
        let pitches: [Int]
        let hands: [Int: Hand]
        let state: State
        enum State { case done, current, upcoming }
    }

    var columns: [Column]
    var showNames = true
    var wrongNote: Int?

    // Diatonic index (C0 = 0) and accidental for each pitch class, sharp spelling.
    private static let spelling: [(Int, Bool)] = [(0, false), (0, true), (1, false), (1, true), (2, false), (3, false),
                                                 (3, true), (4, false), (4, true), (5, false), (5, true), (6, false)]

    static func diatonic(_ midi: Int) -> (Int, Bool) {
        let (step, sharp) = spelling[((midi % 12) + 12) % 12]
        return ((midi / 12 - 1) * 7 + step, sharp)
    }

    var body: some View {
        Canvas { ctx, size in
            let space = min(size.height / 20, 18.0)
            let half = space / 2
            let middleY = size.height / 2
            // Treble lines: E4 G4 B4 D5 F5 ; Bass lines: G2 B2 D3 F3 A3. Middle C (diatonic 28) sits between.
            let c4 = 28
            func y(_ d: Int) -> CGFloat { middleY - CGFloat(d - c4) * half }
            let trebleLines = [30, 32, 34, 36, 38]
            let bassLines = [18, 20, 22, 24, 26]
            let left: CGFloat = 8
            let right = size.width - 8
            for d in trebleLines + bassLines {
                var p = Path()
                p.move(to: CGPoint(x: left, y: y(d)))
                p.addLine(to: CGPoint(x: right, y: y(d)))
                ctx.stroke(p, with: .color(.primary.opacity(0.55)), lineWidth: 1)
            }
            // Brace line and clefs.
            var bar = Path()
            bar.move(to: CGPoint(x: left, y: y(38)))
            bar.addLine(to: CGPoint(x: left, y: y(18)))
            ctx.stroke(bar, with: .color(.primary.opacity(0.7)), lineWidth: 2)
            ctx.draw(Text("𝄞").font(.system(size: space * 6.2)), at: CGPoint(x: left + space * 2, y: y(33) + space * 0.3))
            ctx.draw(Text("𝄢").font(.system(size: space * 3.3)), at: CGPoint(x: left + space * 2, y: y(23) + space * 0.2))

            let startX = left + space * 5
            let colWidth = max(space * 3.2, (right - startX) / CGFloat(max(columns.count, 1)))
            for (i, col) in columns.enumerated() {
                let x = startX + colWidth * (CGFloat(i) + 0.5)
                let color: Color
                switch col.state {
                case .done: color = .green.opacity(0.75)
                case .current: color = .accentColor
                case .upcoming: color = .primary.opacity(0.8)
                }
                if col.state == .current {
                    let highlight = Path(roundedRect: CGRect(x: x - colWidth / 2 + 2, y: y(42), width: colWidth - 4, height: y(14) - y(42)),
                                         cornerSize: CGSize(width: 8, height: 8))
                    ctx.fill(highlight, with: .color(.accentColor.opacity(0.10)))
                }
                for pitch in col.pitches {
                    let (d, sharp) = Self.diatonic(pitch)
                    let onTreble = (col.hands[pitch] ?? (pitch >= 60 ? .right : .left)) == .right
                    let color = col.state == .current && !onTreble ? Color.green : color
                    drawLedgers(ctx: ctx, d: d, x: x, space: space, onTreble: onTreble, y: y)
                    let center = CGPoint(x: x, y: y(d))
                    let head = Path(ellipseIn: CGRect(x: center.x - space * 0.65, y: center.y - space * 0.45, width: space * 1.3, height: space * 0.9))
                    ctx.fill(head, with: .color(color))
                    if sharp {
                        ctx.draw(Text("♯").font(.system(size: space * 1.5, weight: .semibold)).foregroundColor(color),
                                 at: CGPoint(x: x - space * 1.5, y: center.y))
                    }
                    if showNames, col.state == .current {
                        ctx.draw(Text(pitch.noteLabel).font(.system(size: max(10, space * 0.95), weight: .bold)).foregroundColor(color),
                                 at: CGPoint(x: x, y: onTreble ? y(max(d, 40)) - space * 1.6 : y(min(d, 16)) + space * 1.6))
                    }
                }
                if col.state == .current, let w = wrongNote {
                    let (d, _) = Self.diatonic(w)
                    let head = Path(ellipseIn: CGRect(x: x - space * 0.65, y: y(d) - space * 0.45, width: space * 1.3, height: space * 0.9))
                    ctx.stroke(head, with: .color(.red), lineWidth: 2)
                }
            }
        }
        .accessibilityLabel("Portée")
    }

    private func drawLedgers(ctx: GraphicsContext, d: Int, x: CGFloat, space: CGFloat, onTreble: Bool, y: (Int) -> CGFloat) {
        var ledgers: [Int] = []
        if d >= 40 { ledgers += stride(from: 40, through: d, by: 2) }
        if d <= 16 { ledgers += stride(from: 16, through: d, by: -2) }
        if d == 28 { ledgers.append(28) } // middle C
        if onTreble, d < 30, d != 28 { ledgers += stride(from: 28, through: d, by: -2) }
        if !onTreble, d > 26, d != 28 { ledgers += stride(from: 28, through: d, by: 2) }
        for l in Set(ledgers) where l % 2 == 0 {
            var p = Path()
            p.move(to: CGPoint(x: x - space, y: y(l)))
            p.addLine(to: CGPoint(x: x + space, y: y(l)))
            ctx.stroke(p, with: .color(.primary.opacity(0.6)), lineWidth: 1)
        }
    }
}
