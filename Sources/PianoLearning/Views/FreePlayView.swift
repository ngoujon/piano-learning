import PianoCore
import SwiftUI

/// Free practice: the microphone shows which key you are playing, while reading any PDF score.
struct FreePlayView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var app: AppState
    @ObservedObject private var mic = MicrophoneListener.shared
    @ObservedObject private var midi = MIDIInputService.shared
    @AppStorage("micSensitivity") private var micSensitivity = 1.0

    @State private var detected: [Int] = []
    @State private var label: String?
    @State private var cents: Double?
    @State private var history: [Int] = []
    @State private var matcher = NoteMatcher()
    @State private var lastNote: Int?

    private var pdfPieces: [Piece] { library.pieces.filter { $0.pdfFile != nil } }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Partition", selection: $app.freePlayPieceID) {
                    Text("Aucune partition").tag(UUID?.none)
                    ForEach(pdfPieces) { Text($0.title).tag(UUID?.some($0.id)) }
                }
                .frame(maxWidth: 360)
                Spacer()
                InputDevicePicker().frame(maxWidth: 280)
                switch mic.state {
                case .running:
                    Label(mic.deviceName, systemImage: "mic.fill").foregroundStyle(.green)
                    LevelMeter(level: mic.level).frame(width: 80, height: 8)
                case .denied:
                    Button("Autoriser l'accès au micro") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
                    }
                default:
                    ProgressView().controlSize(.small)
                }
            }
            .padding()
            Divider()
            HSplitView {
                if let id = app.freePlayPieceID, let p = library.piece(withID: id), let url = library.pdfURL(for: p) {
                    PDFKitView(url: url).frame(minWidth: 360)
                }
                VStack(spacing: 18) {
                    Spacer()
                    Text("Note entendue").font(.caption).textCase(.uppercase).foregroundStyle(.secondary)
                    Text(label ?? "—")
                        .font(.system(size: 72, weight: .bold, design: .rounded))
                        .foregroundStyle(label == nil ? Color.secondary : Color.accentColor)
                        .contentTransition(.numericText())
                    if let c = cents {
                        TunerNeedle(cents: c).frame(width: 200, height: 12)
                        Text(String(format: "%+.0f cents", c)).font(.caption).foregroundStyle(.secondary)
                    }
                    if !history.isEmpty {
                        Text("Dernières notes : " + history.suffix(12).map(\.noteLabel).joined(separator: "  "))
                            .font(.callout.monospaced()).foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Text("Jouez sur votre piano : la touche détectée s'allume sur le clavier. Idéal pour déchiffrer une partition PDF.")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                .frame(minWidth: 360, maxWidth: .infinity)
                .padding()
            }
            KeyboardView(highlights: Dictionary(uniqueKeysWithValues: Set(detected).union(midi.heldKeys).map { ($0, Color.orange.opacity(0.8)) })) { p in
                SoundEngine.shared.play([p], duration: 0.5)
            }
            .frame(height: 130)
            .padding(6)
        }
        .navigationTitle("Pratique libre")
        .onAppear {
            matcher.sensitivity = Float(micSensitivity)
            let mic = MicrophoneListener.shared
            mic.onFrame = { frame in handle(frame) }
            mic.start()
            MIDIInputService.shared.onNote = { pitch, on in
                if on { label = pitch.noteLabel; history.append(pitch) }
            }
        }
        .onDisappear {
            MicrophoneListener.shared.onFrame = nil
            MicrophoneListener.shared.stop()
            MIDIInputService.shared.onNote = nil
        }
    }

    private func handle(_ frame: AnalysisFrame) {
        let verdict = matcher.process(frame)
        guard verdict != .silence else {
            detected = []
            label = nil
            cents = nil
            lastNote = nil
            return
        }
        if let m = frame.midiPitch, frame.pitchConfidence > 0.7, NoteName.pianoRange.contains(m) {
            detected = [m]
            label = m.noteLabel
            cents = frame.cents
            if lastNote != m { history.append(m); lastNote = m }
        } else {
            let strong = frame.strongNotes()
            detected = strong
            label = strong.isEmpty ? nil : strong.map(\.noteLabel).joined(separator: " + ")
            cents = nil
        }
        if history.count > 200 { history.removeFirst(100) }
    }
}
