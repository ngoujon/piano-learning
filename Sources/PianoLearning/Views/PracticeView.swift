import PianoCore
import SwiftUI

/// The lesson screen: shows the next note(s), listens through the microphone and
/// moves on as soon as the right key is played.
struct PracticeView: View {
    @StateObject private var session: PracticeSession
    @ObservedObject private var mic = MicrophoneListener.shared
    @ObservedObject private var midi = MIDIInputService.shared
    @ObservedObject private var sound = SoundEngine.shared
    @StateObject private var metronome = Metronome()
    @EnvironmentObject private var library: LibraryStore
    @AppStorage("showNoteNames") private var showNoteNames = true
    @AppStorage("micSensitivity") private var micSensitivity = 1.0
    @AppStorage("ignoreOctave") private var ignoreOctave = false
    @AppStorage("pianoOnly") private var pianoOnly = true
    @AppStorage("showPDFInPractice") private var showPDF = true
    /// Speed for "listen to the piece" and the metronome (1 = the piece's tempo).
    @AppStorage("practiceTempo") private var tempo = 1.0
    @AppStorage("playOnlyPracticedHands") private var playOnlyPracticedHands = false
    @AppStorage("metronomeSound") private var metronomeSound = true
    @AppStorage("errorFreeMode") private var errorFree = false
    let pdfURL: URL?
    let onClose: () -> Void

    @State private var loopStart: Int?

    init(piece: Piece, score: Score, pdfURL: URL?, onFinish: @escaping (Double, Double?, Int?) -> Void, onClose: @escaping () -> Void) {
        _session = StateObject(wrappedValue: PracticeSession(piece: piece, score: score, startStep: piece.resumeStep, onFinish: onFinish))
        self.pdfURL = pdfURL
        self.onClose = onClose
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            HSplitView {
                if showPDF, let pdfURL {
                    PDFKitView(url: pdfURL).frame(minWidth: 280, idealWidth: 420)
                }
                lessonPanel.frame(minWidth: 520)
            }
            Divider()
            controls
            progressSlider
            keyboard
        }
        .onAppear {
            session.sensitivity = micSensitivity
            session.ignoreOctave = ignoreOctave
            session.pianoOnly = pianoOnly
            session.errorFree = errorFree
            session.startListening()
            metronome.beatsPerBar = session.score.beats.first?.beatsInBar ?? 4
            metronome.bpm = baseBPM * tempo
            metronome.playsSound = metronomeSound
        }
        .onDisappear {
            session.saveProgress()
            session.stopListening()
            session.stopPiece()
            metronome.stop()
            SoundEngine.shared.stop()
        }
        .onChange(of: tempo) { _, t in
            metronome.bpm = baseBPM * t
            if session.isPlayingPiece { playPiece() }
        }
        .onChange(of: metronome.playsSound) { _, v in metronomeSound = v }
        .onChange(of: session.isPlayingPiece) { _, playing in
            // While the piece plays the metronome rides its beat grid; afterwards it ticks on its own again.
            guard metronome.isRunning else { return }
            if playing { metronome.follow(session.score.beats) { SoundEngine.shared.position } } else { metronome.start() }
        }
        .onChange(of: micSensitivity) { _, v in session.sensitivity = v }
        .onChange(of: ignoreOctave) { _, v in session.ignoreOctave = v }
        .onChange(of: pianoOnly) { _, v in session.pianoOnly = v }
        .onChange(of: errorFree) { _, v in session.errorFree = v }
        .onChange(of: midi.mode) { _, _ in session.inputModeChanged() }
        .overlay { if session.finished { finishedOverlay } }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: 14) {
            Button(action: onClose) { Label("Terminer", systemImage: "chevron.left") }
                .keyboardShortcut(.cancelAction)
            VStack(alignment: .leading, spacing: 0) {
                Text(session.piece.title).font(.headline).lineLimit(1)
                if !session.piece.composer.isEmpty {
                    Text(session.piece.composer).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Picker("Mains", selection: $session.options.hands) {
                ForEach(HandSelection.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 290)
            .labelsHidden()
            Toggle("Mélodie seule", isOn: $session.options.melodyOnly)
                .help("Ne garder que la note principale de chaque accord (recommandé pour débuter et pour la détection au micro)")
            Menu {
                Toggle("Mode sans erreur (une fausse note ramène au début de la boucle)", isOn: $errorFree)
                Toggle("Accepter n'importe quelle octave", isOn: $ignoreOctave)
                Toggle("Ignorer la voix et les bruits", isOn: $pianoOnly)
                Toggle("Jouer automatiquement chaque nouvelle note", isOn: $session.autoPlayTarget)
                Toggle("Afficher le nom des notes", isOn: $showNoteNames)
                Toggle("« Écouter le morceau » : seulement la main travaillée", isOn: $playOnlyPracticedHands)
                if pdfURL != nil { Toggle("Afficher la partition PDF", isOn: $showPDF) }
                Divider()
                Picker("Détection des notes", selection: Binding(get: { midi.mode }, set: { midi.mode = $0 })) {
                    ForEach(MIDIInputService.InputMode.allCases) { Text($0 == .microphone ? "Au micro (son du piano)" : "Par le câble USB").tag($0) }
                }
                InputDevicePicker()
                Text("Sensibilité du micro")
                Picker("Sensibilité", selection: $micSensitivity) {
                    Text("Très sensible (pièce calme)").tag(0.6)
                    Text("Normale").tag(1.0)
                    Text("Peu sensible (pièce bruyante)").tag(1.8)
                }
                .pickerStyle(.inline)
            } label: {
                Label("Options", systemImage: "slider.horizontal.3")
            }
            .fixedSize()
            micIndicator
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var micIndicator: some View {
        HStack(spacing: 6) {
            InputModePicker()
            if midi.usesKeyboard {
                if midi.isKeyboardConnected {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.blue)
                        .help("\(midi.sources.joined(separator: ", ")) : les touches sont lues par le câble, le micro n'est pas utilisé.")
                }
            } else {
                microphoneStatus
            }
        }
    }

    @ViewBuilder private var microphoneStatus: some View {
        switch mic.state {
        case .running:
            Image(systemName: mic.isSuppressed ? "speaker.wave.2.fill" : "mic.fill")
                .foregroundStyle(mic.isSuppressed ? Color.secondary : Color.green)
                .help(mic.isSuppressed ? "Micro en pause pendant que l'application joue" : "Micro actif : \(mic.deviceName)")
            LevelMeter(level: mic.level).frame(width: 50, height: 8)
        case .denied:
            Button {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
            } label: {
                Label("Autoriser le micro", systemImage: "mic.slash.fill")
            }
            .foregroundStyle(.red)
        case .failed(let e):
            Label(e, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.caption)
        default:
            ProgressView().controlSize(.small)
        }
    }

    // MARK: - Lesson panel

    /// The piece's own tempo, in beats per minute.
    private var baseBPM: Double { session.score.initialBPM ?? 100 }

    private var metronomeBPM: Binding<Double> {
        Binding(get: { baseBPM * tempo },
                set: { tempo = min(2, max(0.25, $0 / baseBPM)) })
    }

    private func playPiece() {
        session.playPiece(onlyPracticedHands: playOnlyPracticedHands, tempo: tempo)
    }

    private func toggleMetronome() {
        if metronome.isRunning {
            metronome.stop()
        } else if session.isPlayingPiece {
            metronome.follow(session.score.beats) { SoundEngine.shared.position }
        } else {
            metronome.start()
        }
    }

    private var lessonPanel: some View {
        VStack(spacing: 16) {
            targetCard
            if metronome.isRunning {
                MetronomeView(metronome: metronome, bpm: metronomeBPM, followsPiece: session.isPlayingPiece)
                    .transition(.opacity)
            }
            StaffView(columns: staffColumns, showNames: showNoteNames, wrongNote: wrongNote)
                .frame(minHeight: 220, maxHeight: 320)
                .padding(.horizontal)
            heardLabel
            Spacer(minLength: 0)
        }
        .padding(.top, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var wrongNote: Int? {
        if case .wrong(let n) = session.feedback { return n }
        return nil
    }

    private var targetCard: some View {
        let step = session.currentStep
        let bg: Color = {
            switch session.feedback {
            case .correct: return .green.opacity(0.25)
            case .wrong: return .red.opacity(0.22)
            case .none: return Color.accentColor.opacity(0.08)
            }
        }()
        return VStack(spacing: 6) {
            Text(session.steps.isEmpty ? "Aucune note pour cette main" : session.isPlayingPiece ? "Écoutez" : "Jouez")
                .font(.caption).foregroundStyle(.secondary).textCase(.uppercase)
            if let step {
                HStack(spacing: 18) {
                    ForEach(step.pitches.reversed(), id: \.self) { p in
                        VStack(spacing: 2) {
                            Text(showNoteNames ? p.noteLabel : "?")
                                .font(.system(size: step.pitches.count > 2 ? 34 : 48, weight: .bold, design: .rounded))
                                .foregroundStyle((step.hands[p] ?? .right).color)
                            Text(step.hands[p] == .left ? "main gauche" : "main droite")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            switch session.feedback {
            case .wrong(let n):
                Text("Ce n'est pas la bonne touche (\(n.noteLabel)) — réessayez").font(.callout.bold()).foregroundStyle(.red)
            case .correct:
                Text("Bravo !").font(.callout.bold()).foregroundStyle(.green)
            case .none:
                Text(session.isPlayingPiece ? "Le morceau est joué dans son rythme : suivez les notes sur la portée"
                     : session.isListening ? "Le micro écoute… jouez la note sur votre piano" : " ")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(RoundedRectangle(cornerRadius: 16).fill(bg))
        .animation(.easeOut(duration: 0.15), value: session.feedback)
        .padding(.horizontal)
    }

    private var heardLabel: some View {
        HStack(spacing: 10) {
            Image(systemName: "ear").foregroundStyle(.secondary)
            Text("Entendu :").foregroundStyle(.secondary)
            Text(session.detectedLabel ?? "—").font(.title3.monospaced().bold())
            if let c = session.cents {
                TunerNeedle(cents: c).frame(width: 90, height: 10)
            }
            Spacer()
            Text("Note \(min(session.index + 1, session.steps.count)) / \(session.steps.count)").monospacedDigit()
            if let a = session.accuracy {
                Text("Précision \(Int(a * 100)) %").monospacedDigit().foregroundStyle(a > 0.8 ? .green : .orange)
            }
        }
        .font(.callout)
        .padding(.horizontal)
    }

    private var staffColumns: [StaffView.Column] {
        let prev = session.previous(2).map { StaffView.Column(id: $0.id, pitches: $0.pitches, hands: $0.hands, state: .done) }
        let next = session.upcoming(8).enumerated().map { i, s in
            StaffView.Column(id: s.id, pitches: s.pitches, hands: s.hands, state: i == 0 ? .current : .upcoming)
        }
        return prev + next
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: 10) {
            Button { session.back() } label: { Image(systemName: "backward.fill") }
                .keyboardShortcut(.leftArrow, modifiers: [])
                .help("Note précédente (←)")
            Button { session.playTarget() } label: { Label("Écouter la note", systemImage: "speaker.wave.2.fill") }
                .keyboardShortcut("e", modifiers: [])
                .help("Faire entendre la note à jouer (E). Le micro est mis en pause pendant ce temps.")
            Button { session.skip() } label: { Image(systemName: "forward.fill") }
                .keyboardShortcut(.rightArrow, modifiers: [])
                .help("Passer cette note (→)")
            Button { session.restartLoop() } label: { Image(systemName: "backward.end.fill") }
                .keyboardShortcut(.space, modifiers: [])
                .help("Revenir au début de la boucle, ou du morceau s'il n'y a pas de boucle (espace)")
            Button { session.restart() } label: { Label("Recommencer", systemImage: "arrow.counterclockwise") }

            Divider().frame(height: 20)
            if session.isPlayingPiece {
                Button { session.stopPiece() } label: { Label("Arrêter", systemImage: "stop.fill") }
                    .keyboardShortcut("p", modifiers: [])
                    .help("Arrêter l'écoute et revenir à la note de départ (P)")
            } else {
                Button { playPiece() } label: { Label("Écouter le morceau", systemImage: "play.fill") }
                    .keyboardShortcut("p", modifiers: [])
                    .help("Jouer le morceau dans son rythme à partir de la note actuelle, ou le passage en boucle (P). La portée et le clavier suivent.")
            }
            Picker("Tempo", selection: $tempo) {
                ForEach([0.4, 0.5, 0.6, 0.75, 0.9, 1.0, 1.1, 1.25], id: \.self) { t in
                    Text("\(Int((t * 100).rounded())) %").tag(t)
                }
                if ![0.4, 0.5, 0.6, 0.75, 0.9, 1.0, 1.1, 1.25].contains(tempo) {
                    Text("\(Int((tempo * 100).rounded())) %").tag(tempo)
                }
            }
            .fixedSize()
            .help("Vitesse de l'écoute et du métronome (100 % = tempo du morceau)")
            Toggle(isOn: Binding(get: { metronome.isRunning }, set: { _ in toggleMetronome() })) {
                Label("Métronome", systemImage: "metronome.fill")
            }
            .toggleStyle(.button)
            .keyboardShortcut("m", modifiers: [])
            .help("Métronome avec balancier animé (M). Il bat la mesure du morceau.")

            Spacer(minLength: 0)
            if let loop = session.loopRange {
                Button { session.loopRange = nil; loopStart = nil } label: {
                    Label("Boucle \(loop.lowerBound + 1)–\(loop.upperBound + 1) ✕", systemImage: "repeat")
                }
                .tint(.purple)
            } else if let start = loopStart {
                Button {
                    let end = max(start, session.index)
                    session.loopRange = min(start, session.index)...end
                    loopStart = nil
                    session.jump(to: min(start, end))
                } label: { Label("Fin de boucle ici", systemImage: "repeat") }
                .help("Répéter le passage entre le début de boucle et la note actuelle")
            } else {
                Button { loopStart = session.index } label: { Label("Début de boucle", systemImage: "repeat") }
                    .help("Travailler un passage difficile en boucle")
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    /// Moves through the piece: on its own line, across the whole window.
    private var progressSlider: some View {
        Slider(value: Binding(get: { Double(session.index) },
                              set: { session.jump(to: Int($0)) }),
               in: 0...Double(max(session.steps.count - 1, 1)))
            .frame(maxWidth: .infinity)
            .padding(.horizontal)
            .padding(.bottom, 6)
    }

    private var keyboard: some View {
        var highlights: [Int: Color] = [:]
        var labels: [Int: String] = [:]
        if session.isPlayingPiece {
            // Keys light up as the piece plays.
            (highlights, labels) = KeyboardView.playing(sound.activeNotes)
        } else if let step = session.currentStep {
            for p in step.pitches {
                highlights[p] = (step.hands[p] ?? .right).color.opacity(0.75)
                if showNoteNames { labels[p] = p.noteLabel }
            }
        }
        for d in session.detectedNotes where highlights[d] == nil {
            highlights[d] = .orange.opacity(0.7)
        }
        switch session.feedback {
        case .wrong(let n): highlights[n] = .red.opacity(0.8)
        case .correct: break
        case .none: break
        }
        // Always the full 88 keys, like a real piano, so the keyboard never shifts under the notes.
        return VStack(spacing: 2) {
            HandLegend().frame(maxWidth: .infinity, alignment: .trailing)
            KeyboardView(highlights: highlights, labels: labels) { pitch in
                session.keyPressed(pitch)
            }
        }
        .frame(height: 166)
        .padding(.horizontal, 6)
        .padding(.bottom, 6)
    }

    // MARK: - Finished

    private var finishedOverlay: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
            VStack(spacing: 14) {
                Text("🎉").font(.system(size: 64))
                Text("Morceau terminé !").font(.largeTitle.bold())
                if let a = session.accuracy {
                    Text("Précision : \(Int(a * 100)) %").font(.title2)
                    let stars = a >= 0.95 ? 3 : (a >= 0.8 ? 2 : 1)
                    HStack {
                        ForEach(0..<3) { i in
                            Image(systemName: i < stars ? "star.fill" : "star")
                                .foregroundStyle(.yellow).font(.title)
                        }
                    }
                }
                Text("\(session.correctCount) notes justes · \(session.wrongCount) erreurs · \(formatDuration(session.elapsed))")
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Recommencer") { session.restart() }.keyboardShortcut(.defaultAction)
                    if session.options.hands != .both {
                        Button("Essayer à deux mains") { session.options.hands = .both; session.restart() }
                    }
                    Button("Retour à la collection", action: onClose)
                }
                .controlSize(.large)
            }
            .padding(40)
            .background(RoundedRectangle(cornerRadius: 24).fill(.regularMaterial))
        }
    }
}

struct LevelMeter: View {
    let level: Float
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.2))
                Capsule().fill(level > 0.8 ? Color.red : Color.green)
                    .frame(width: geo.size.width * CGFloat(min(1, max(0, level))))
            }
        }
    }
}

/// Small tuning indicator (cents off the nearest note).
struct TunerNeedle: View {
    let cents: Double
    var body: some View {
        GeometryReader { geo in
            ZStack {
                Capsule().fill(Color.secondary.opacity(0.2))
                Rectangle().fill(Color.secondary).frame(width: 1)
                Circle()
                    .fill(abs(cents) < 15 ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                    .offset(x: CGFloat(max(-50, min(50, cents)) / 50) * geo.size.width / 2)
            }
        }
        .help(String(format: "%+.0f cents", cents))
    }
}
