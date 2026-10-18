import PianoCore
import SwiftUI

/// Browse, preview and download the free scores of partition-piano-gratuite.fr and the bundled public-domain pieces.
struct CatalogView: View {
    @EnvironmentObject private var catalog: CatalogService
    @EnvironmentObject private var library: LibraryStore
    @ObservedObject private var preview = PreviewPlayer.shared
    @EnvironmentObject private var app: AppState

    @State private var search = ""
    @State private var level: Int? = nil
    @State private var composer: String? = nil
    @State private var source: String? = nil
    @State private var pdfPreview: CatalogEntry?
    @State private var errorMessage: String?

    private var sources: [String] {
        Array(Set(catalog.entries.map(\.sourceName))).sorted()
    }

    private var composers: [String] {
        Array(Set(catalog.entries.map(\.composer).filter { !$0.isEmpty })).sorted()
    }

    private var filtered: [CatalogEntry] {
        catalog.entries.filter { e in
            (level == nil || e.level == level) &&
            (composer == nil || e.composer == composer) &&
            (source == nil || e.sourceName == source) &&
            (search.isEmpty || CatalogParser.normalize("\(e.title) \(e.composer) \(e.info)").contains(CatalogParser.normalize(search)))
        }
        .sorted { ($0.level ?? 9, $0.title) < ($1.level ?? 9, $1.title) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if catalog.entries.isEmpty {
                emptyState
            } else {
                List(filtered) { entry in
                    CatalogRow(entry: entry,
                               inLibrary: library.contains(catalogID: entry.id),
                               isDownloading: library.downloading.contains(entry.id),
                               isPreviewing: preview.playingURL == entry.previewURL && entry.previewURL != nil,
                               previewProgress: preview.progress,
                               onPreview: { if let u = entry.previewURL { preview.toggle(u) } },
                               onShowPDF: { pdfPreview = entry },
                               onAdd: { add(entry, thenLearn: false) },
                               onLearn: { add(entry, thenLearn: true) })
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
        }
        .navigationTitle("Catalogue en ligne")
        .searchable(text: $search, prompt: "Titre, compositeur…")
        .toolbar {
            ToolbarItem {
                Button {
                    Task { await catalog.refresh() }
                } label: {
                    Label("Actualiser", systemImage: "arrow.clockwise")
                }
                .disabled(catalog.isLoading)
            }
        }
        .task { await catalog.refreshIfNeeded() }
        .sheet(item: $pdfPreview) { entry in
            VStack(spacing: 0) {
                HStack {
                    Text(entry.title).font(.headline)
                    Spacer()
                    Button("Fermer") { pdfPreview = nil }.keyboardShortcut(.cancelAction)
                }
                .padding()
                if let url = entry.pdfURL { PDFKitView(url: url) }
            }
            .frame(minWidth: 700, minHeight: 800)
        }
        .alert("Erreur", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .onDisappear { preview.stop() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Picker("Niveau", selection: $level) {
                Text("Tous les niveaux").tag(Int?.none)
                ForEach(1...5, id: \.self) { l in
                    Text("\(l) – \(CatalogEntry.levelLabel(l))").tag(Int?.some(l))
                }
            }
            .frame(maxWidth: 220)
            Picker("Compositeur", selection: $composer) {
                Text("Tous").tag(String?.none)
                ForEach(composers, id: \.self) { Text($0).tag(String?.some($0)) }
            }
            .frame(maxWidth: 260)
            Picker("Source", selection: $source) {
                Text("Toutes").tag(String?.none)
                ForEach(sources, id: \.self) { Text($0).tag(String?.some($0)) }
            }
            .frame(maxWidth: 280)
            Spacer()
            if catalog.isLoading { ProgressView().controlSize(.small) }
            if let e = catalog.error { Text(e).font(.caption).foregroundStyle(.orange) }
            Text("\(filtered.count) partitions").font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            if catalog.isLoading {
                ProgressView("Chargement des partitions…")
            } else {
                Image(systemName: "wifi.exclamationmark").font(.largeTitle).foregroundStyle(.secondary)
                Text(catalog.error ?? "Catalogue vide").foregroundStyle(.secondary)
                Button("Réessayer") { Task { await catalog.refresh() } }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func add(_ entry: CatalogEntry, thenLearn: Bool) {
        Task {
            do {
                let piece = try await library.add(entry)
                app.selectedPieceID = piece.id
                if thenLearn { app.sidebar = .library }
            } catch {
                errorMessage = "Téléchargement impossible : \(error.localizedDescription)"
            }
        }
    }
}

struct LevelBadge: View {
    let level: Int?
    var body: some View {
        let colors: [Color] = [.green, .mint, .blue, .orange, .red]
        let color = level.map { colors[max(0, min(4, $0 - 1))] } ?? .gray
        Text(level.map(String.init) ?? "?")
            .font(.system(.callout, design: .rounded).bold())
            .foregroundStyle(.white)
            .frame(width: 26, height: 26)
            .background(Circle().fill(color))
            .help(CatalogEntry.levelLabel(level))
    }
}

private struct CatalogRow: View {
    let entry: CatalogEntry
    let inLibrary: Bool
    let isDownloading: Bool
    let isPreviewing: Bool
    let previewProgress: Double
    let onPreview: () -> Void
    let onShowPDF: () -> Void
    let onAdd: () -> Void
    let onLearn: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            LevelBadge(level: entry.level)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title).font(.headline)
                Text(entry.composer).font(.subheadline).foregroundStyle(.secondary)
                    + Text("  ·  \(entry.sourceName)").font(.caption).foregroundStyle(.tertiary)
                if !entry.info.isEmpty {
                    Text(entry.info).font(.caption).foregroundStyle(.tertiary).lineLimit(2)
                }
                if isPreviewing {
                    ProgressView(value: previewProgress).frame(maxWidth: 240)
                }
            }
            Spacer()
            if entry.previewURL != nil {
                Button(action: onPreview) {
                    Label(isPreviewing ? "Stop" : "Écouter", systemImage: isPreviewing ? "stop.fill" : "play.fill")
                }
                .help("Écouter l'aperçu audio")
            }
            if entry.pdfURL != nil {
                Button(action: onShowPDF) { Label("Partition", systemImage: "doc.richtext") }
                    .help("Voir la partition PDF")
            }
            if isDownloading {
                ProgressView().controlSize(.small).frame(width: 90)
            } else if inLibrary {
                Button(action: onLearn) { Label("Apprendre", systemImage: "graduationcap.fill") }
                    .buttonStyle(.borderedProminent)
            } else {
                Button(action: onAdd) { Label("Ajouter", systemImage: "arrow.down.circle.fill") }
                    .buttonStyle(.borderedProminent)
                    .help("Télécharger la partition PDF et le fichier MIDI dans ma collection")
            }
        }
        .labelStyle(.titleAndIcon)
        .padding(.vertical, 4)
    }
}
