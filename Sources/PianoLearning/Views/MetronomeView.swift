import PianoCore
import SwiftUI

/// Swinging pendulum, beat lights for the bar and tempo controls.
struct MetronomeView: View {
    @ObservedObject var metronome: Metronome
    @Binding var bpm: Double
    /// The metronome follows the piece being played (its tempo is the piece's).
    let followsPiece: Bool

    private var beatsInBar: Int { max(metronome.current?.beatsInBar ?? metronome.beatsPerBar, 1) }

    var body: some View {
        TimelineView(.animation(paused: !metronome.isRunning)) { context in
            let phase = metronome.phase(at: context.date)
            HStack(spacing: 22) {
                pendulum(phase: phase)
                    .frame(width: 64, height: 86)
                beatLights(phase: phase)
                Spacer(minLength: 0)
                tempoControls
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.secondary.opacity(0.08)))
        .padding(.horizontal)
    }

    /// Like a mechanical metronome: at each beat the arm is at one end, then swings to the other.
    private func pendulum(phase: Double) -> some View {
        let side: Double = metronome.beatCount % 2 == 0 ? -1 : 1
        let angle = metronome.isRunning ? 28 * cos(.pi * phase) * side : 0
        let accent = metronome.current?.number == 1 && beatsInBar > 1
        return ZStack(alignment: .bottom) {
            Path { p in
                p.move(to: CGPoint(x: 12, y: 86)); p.addLine(to: CGPoint(x: 52, y: 86))
                p.addLine(to: CGPoint(x: 40, y: 6)); p.addLine(to: CGPoint(x: 24, y: 6)); p.closeSubpath()
            }
            .fill(Color.secondary.opacity(0.18))
            ZStack(alignment: .top) {
                Capsule().fill(Color.primary.opacity(0.75)).frame(width: 3, height: 76)
                RoundedRectangle(cornerRadius: 2)
                    .fill(accent && phase < 0.3 ? Color.orange : Color.accentColor)
                    .frame(width: 14, height: 10)
                    .offset(y: 16)
            }
            .frame(height: 76)
            .rotationEffect(.degrees(angle), anchor: .bottom)
            .offset(y: -6)
            Circle().fill(Color.primary.opacity(0.6)).frame(width: 7, height: 7).offset(y: -3)
        }
    }

    private func beatLights(phase: Double) -> some View {
        let current = metronome.isRunning ? metronome.current?.number : nil
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                ForEach(1...min(beatsInBar, 12), id: \.self) { n in
                    let lit = n == current
                    // A flash on each beat that fades until the next one.
                    let glow = lit ? 1 - phase * 0.7 : 0
                    Circle()
                        .fill(n == 1 ? Color.orange : Color.accentColor)
                        .opacity(lit ? 0.35 + 0.65 * glow : 0.18)
                        .frame(width: n == 1 ? 26 : 20, height: n == 1 ? 26 : 20)
                        .scaleEffect(lit ? 1 + 0.25 * glow : 1)
                }
            }
            Text(current.map { "Temps \($0) / \(beatsInBar)" } ?? "Métronome à l'arrêt")
                .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
        }
    }

    private var tempoControls: some View {
        VStack(alignment: .trailing, spacing: 6) {
            HStack(spacing: 6) {
                Button { bpm = max(Metronome.bpmRange.lowerBound, bpm - 5) } label: { Image(systemName: "minus") }
                Text("\(Int(bpm.rounded())) BPM")
                    .font(.title3.monospacedDigit().bold())
                    .frame(minWidth: 92)
                Button { bpm = min(Metronome.bpmRange.upperBound, bpm + 5) } label: { Image(systemName: "plus") }
            }
            .disabled(followsPiece)
            HStack(spacing: 12) {
                if followsPiece {
                    Text("Suit le morceau").font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Son", isOn: $metronome.playsSound)
                    .toggleStyle(.checkbox)
                    .help("Sans le son, le métronome reste visuel (le micro n'est jamais interrompu)")
            }
        }
    }
}
