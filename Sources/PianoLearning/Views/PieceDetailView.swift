import PianoCore
import SwiftUI
import UniformTypeIdentifiers

struct PieceDetailView: View {
    let piece: Piece
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var catalog: CatalogService
    @EnvironmentObject private var app: AppState
    @ObservedObject private var sound = SoundEngine.shared
    @ObservedObject private var preview = PreviewPlayer.shared

    @State private var showScoreImporter = false
    @State private var showPDFImporter = false
    @State private var omrRunning = false
    @State private var omrStatus: String?
    @State private var confirmInstall = false
    @State private var omrInstalled = OMRService.isAvailable
    @State private var message: String?
    @State private var tempo = 1.0

    private var score: Score? { try? library.score(for: piece) }
    private var catalogMatch: CatalogEntry? {
        guard !piece.hasScore else { return nil }
        if let id = piece.catalogID, let e = catalog.entries.first(where: { $0.id == id }) { return e }
        return CatalogParser.bestMatch(forFileName: piece.title, in: catalog.entries)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding()
            Divider()
            if let pdf = library.pdfURL(for: piece) {
                PDFKitView(url: pdf)
            } else if let score {
                ScoreOverview(score: score).padding()
            } else {
                Spacer()
            }
        }
        .fileImporter(isPresented: $showScoreImporter, allowedContentTypes: LibraryStore.importTypes.filter { $0 != .pdf }) { result in
            if case .success(let url) = result {
                do { try library.attachScore(url, to: piece) } catch { message = error.localizedDescription }
            }
        }
        .fileImporter(isPresented: $showPDFImporter, allowedContentTypes: [.pdf]) { result in
            if case .success(let url) = result {
                do { try library.attachPDF(url, to: piece) } catch { message = error.localizedDescription }
            }
        }
        .confirmationDialog("Installer Audiveris ?", isPresented: $confirmInstall) {
            Button("Télécharger et installer (~85 Mo)") { installOMR() }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Audiveris est un logiciel libre (licence AGPL) de reconnaissance de partitions. Il sera installé dans ~/Applications et utilisé pour transformer vos PDF en notes à apprendre. En continuant, vous acceptez sa licence.")
        }
        .alert("Information", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") { message = nil }
        } message: { Text(message ?? "") }
        .onDisappear { if sound.isPlaying(id: piece.id.uuidString) { sound.stop() } }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                LevelBadge(level: piece.level)
                VStack(alignment: .leading, spacing: 2) {
                    Text(piece.title).font(.title2.bold())
                    if !piece.composer.isEmpty { Text(piece.composer).foregroundStyle(.secondary) }
                    if !piece.info.isEmpty { Text(piece.info).font(.caption).foregroundStyle(.tertiary) }
                }
                Spacer()
                stats
            }

            HStack(spacing: 10) {
                if piece.hasScore {
                    Button {
                        sound.stop(); preview.stop()
                        app.practicingPieceID = piece.id
                    } label: {
                        Label(piece.resumeStep != nil ? "Reprendre l'apprentissage" : "Apprendre", systemImage: "graduationcap.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .fixedSize()
                    .keyboardShortcut(.return, modifiers: .command)

                    if let score {
                        let playing = sound.isPlaying(id: piece.id.uuidString)
                        Button {
                            if playing { sound.stop() } else {
                                preview.stop()
                                sound.play(score: score, id: piece.id.uuidString, tempo: tempo)
                            }
                        } label: {
                            Label(playing ? "Arrêter" : "Écouter (MIDI)", systemImage: playing ? "stop.fill" : "play.fill")
                        }
                        .controlSize(.large)
                        .fixedSize()
                        Picker("Tempo", selection: $tempo) {
                            Text("50 %").tag(0.5); Text("75 %").tag(0.75); Text("100 %").tag(1.0)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 170)
                        .labelsHidden()
                        .help("Vitesse de lecture")
                    }
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 10) {
                if let url = piece.previewURL {
                    let on = preview.playingURL == url
                    Button {
                        sound.stop(); preview.toggle(url)
                    } label: {
                        Label(on ? "Stop" : "Aperçu audio", systemImage: on ? "stop.circle" : "waveform")
                    }
                    .controlSize(.large)
                }
                Spacer(minLength: 0)
                Menu {
                    Button("Associer un fichier MIDI / MusicXML…") { showScoreImporter = true }
                    Button(piece.pdfFile == nil ? "Ajouter la partition PDF…" : "Remplacer la partition PDF…") { showPDFImporter = true }
                    Divider()
                    Button("Afficher dans le Finder") { NSWorkspace.shared.activateFileViewerSelecting([library.folder(for: piece)]) }
                } label: {
                    Label("Fichiers", systemImage: "ellipsis.circle")
                }
                .fixedSize()
            }
            if sound.isPlaying(id: piece.id.uuidString) {
                VStack(spacing: 4) {
                    ProgressView(value: min(sound.position, sound.duration), total: max(sound.duration, 0.01))
                    KeyboardView(highlights: Dictionary(uniqueKeysWithValues: sound.activeNotes.map { ($0, Color.accentColor) }), showCLabels: false)
                        .frame(height: 60)
                }
            }
            if !piece.hasScore { missingScoreBanner }
        }
    }

    private var stats: some View {
        VStack(alignment: .trailing, spacing: 2) {
            if piece.practiceCount > 0 {
                Text("\(piece.practiceCount) séance\(piece.practiceCount > 1 ? "s" : "")").font(.caption)
                Text("Progression max : \(Int(piece.bestProgress * 100)) %").font(.caption)
                if let a = piece.bestAccuracy { Text("Meilleure précision : \(Int(a * 100)) %").font(.caption) }
            }
            if let score {
                Text("\(score.notes.count) notes · \(formatDuration(score.duration))").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var missingScoreBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Ce morceau n'a qu'une partition PDF.", systemImage: "info.circle.fill").font(.headline)
            Text("Pour l'apprentissage note par note avec le micro, l'application a besoin des notes sous forme numérique (MIDI ou MusicXML). Vous pouvez :")
                .font(.callout)
            VStack(alignment: .leading, spacing: 6) {
                if let match = catalogMatch, match.midiURL != nil {
                    Button("Télécharger le MIDI de « \(match.title) »") {
                        Task {
                            do { try await library.attachCatalogMIDI(match, to: piece) } catch { message = error.localizedDescription }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
                Button("Associer un fichier MIDI / MusicXML…") { showScoreImporter = true }
                if piece.pdfFile != nil {
                    if omrInstalled {
                        Button {
                            runOMR()
                        } label: {
                            Label("Reconnaître les notes du PDF", systemImage: "doc.viewfinder")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(omrRunning)
                        .help("Convertit la partition PDF en notes (Audiveris). Environ 10 secondes par page.")
                    } else {
                        Button {
                            confirmInstall = true
                        } label: {
                            Label("Installer la reconnaissance de partitions…", systemImage: "arrow.down.app")
                        }
                        .disabled(omrRunning)
                        .help("Télécharge Audiveris, un logiciel libre qui lit les partitions PDF.")
                    }
                    if let status = omrStatus {
                        HStack(spacing: 6) {
                            if omrRunning { ProgressView().controlSize(.small) }
                            Text(status).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Button("Lire la partition en pratique libre") { app.freePlayPieceID = piece.id; app.sidebar = .freePlay }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.12)))
    }

    private func runOMR() {
        guard let pdf = library.pdfURL(for: piece) else { return }
        omrRunning = true
        omrStatus = "Lecture de la partition en cours… (environ 10 s par page)"
        Task {
            defer { omrRunning = false }
            do {
                let score = try await OMRService.recognize(pdf: pdf) { page, total in
                    Task { @MainActor in omrStatus = "Lecture de la partition : page \(page) / \(total)…" }
                }
                try library.attachRecognizedScore(score, to: piece)
                omrStatus = nil
                message = "Partition reconnue : \(score.notes.count) notes. Écoutez-la pour vérifier : la reconnaissance automatique peut comporter des erreurs (surtout sur les partitions chargées). Un fichier MIDI reste la source la plus fiable."
            } catch {
                omrStatus = nil
                message = error.localizedDescription
            }
        }
    }

    private func installOMR() {
        omrRunning = true
        Task {
            defer { omrRunning = false }
            do {
                try await OMRService.install { text in
                    Task { @MainActor in omrStatus = text }
                }
                omrInstalled = OMRService.isAvailable
                omrStatus = nil
                runOMR()
            } catch {
                omrStatus = nil
                message = error.localizedDescription
            }
        }
    }
}

func formatDuration(_ seconds: Double) -> String {
    let s = Int(seconds.rounded())
    return String(format: "%d:%02d", s / 60, s % 60)
}

/// Fallback when there is no PDF: a compact piano-roll overview of the piece.
struct ScoreOverview: View {
    let score: Score
    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                let pitches = score.notes.map(\.pitch)
                guard let lo = pitches.min(), let hi = pitches.max(), score.duration > 0 else { return }
                let rowH = size.height / CGFloat(hi - lo + 1)
                let handOf = PracticeSequence.handAssignment(for: score)
                for n in score.notes {
                    let x = CGFloat(n.start / score.duration) * size.width
                    let w = max(2, CGFloat(n.duration / score.duration) * size.width)
                    let y = size.height - CGFloat(n.pitch - lo + 1) * rowH
                    let color: Color = handOf(n) == .right ? .blue : .green
                    ctx.fill(Path(roundedRect: CGRect(x: x, y: y, width: w, height: max(2, rowH - 1)), cornerSize: CGSize(width: 1, height: 1)),
                             with: .color(color.opacity(0.7)))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .overlay(alignment: .topLeading) {
            Text("Aperçu des notes (bleu : main droite, vert : main gauche)").font(.caption).foregroundStyle(.secondary)
        }
    }
}
