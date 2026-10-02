import PianoCore
import SwiftUI
import UniformTypeIdentifiers

/// The user's collection: downloaded and imported pieces.
struct LibraryView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var catalog: CatalogService
    @EnvironmentObject private var app: AppState

    @State private var search = ""
    @State private var showImporter = false
    @State private var isDropTarget = false

    private var filtered: [Piece] {
        library.pieces.filter {
            search.isEmpty || CatalogParser.normalize("\($0.title) \($0.composer)").contains(CatalogParser.normalize(search))
        }
    }

    var body: some View {
        HSplitView {
            list
                .frame(minWidth: 240, idealWidth: 280, maxWidth: 360)
            Group {
                if let id = app.selectedPieceID, let piece = library.piece(withID: id) {
                    PieceDetailView(piece: piece)
                        .id(piece.id)
                } else {
                    placeholder
                }
            }
            .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Ma collection")
        .searchable(text: $search, prompt: "Rechercher dans ma collection")
        .toolbar {
            ToolbarItem {
                Button { showImporter = true } label: {
                    Label("Importer PDF / MIDI", systemImage: "square.and.arrow.down")
                }
                .help("Ajouter des fichiers PDF, MIDI ou MusicXML à la collection")
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: LibraryStore.importTypes, allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { importFiles(urls) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .importFiles)) { _ in showImporter = true }
        .onDrop(of: [.fileURL], isTargeted: $isDropTarget) { providers in
            loadDroppedURLs(providers) { importFiles($0) }
            return true
        }
        .overlay {
            if isDropTarget {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8]))
                    .background(Color.accentColor.opacity(0.08))
                    .overlay(Text("Déposez vos fichiers PDF / MIDI ici").font(.title2.bold()))
                    .padding()
            }
        }
        .alert("Import", isPresented: Binding(get: { library.lastMessage != nil }, set: { if !$0 { library.lastMessage = nil } })) {
            Button("OK") { library.lastMessage = nil }
        } message: {
            Text(library.lastMessage ?? "")
        }
    }

    private var list: some View {
        List(selection: $app.selectedPieceID) {
            if library.pieces.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Votre collection est vide").font(.headline)
                    Text("Ajoutez des morceaux depuis le catalogue en ligne, ou importez vos propres fichiers PDF / MIDI (glisser-déposer accepté).")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Parcourir le catalogue") { app.sidebar = .catalog }
                    Button("Importer des fichiers…") { showImporter = true }
                }
                .padding(.vertical)
            }
            ForEach(filtered) { piece in
                PieceRow(piece: piece)
                    .tag(piece.id)
                    .contextMenu {
                        Button("Apprendre") { app.practicingPieceID = piece.id }.disabled(!piece.hasScore)
                        Button(piece.isFavorite ? "Retirer des favoris" : "Ajouter aux favoris") {
                            var p = piece; p.isFavorite.toggle(); library.update(p)
                        }
                        Button("Afficher dans le Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([library.folder(for: piece)])
                        }
                        Divider()
                        Button("Supprimer", role: .destructive) {
                            if app.selectedPieceID == piece.id { app.selectedPieceID = nil }
                            library.delete(piece)
                        }
                    }
            }
        }
    }

    private var placeholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "pianokeys").font(.system(size: 56)).foregroundStyle(.secondary)
            Text("Sélectionnez un morceau").font(.title3)
            Text("ou glissez-déposez des fichiers PDF / MIDI / MusicXML").foregroundStyle(.secondary)
        }
    }

    private func importFiles(_ urls: [URL]) {
        Task {
            let added = await library.importFiles(urls, catalog: catalog.entries)
            if let first = added.first { app.selectedPieceID = first.id }
        }
    }
}

func loadDroppedURLs(_ providers: [NSItemProvider], completion: @escaping ([URL]) -> Void) {
    let group = DispatchGroup()
    var urls: [URL] = []
    let lock = NSLock()
    for p in providers {
        group.enter()
        _ = p.loadObject(ofClass: URL.self) { url, _ in
            if let url { lock.lock(); urls.append(url); lock.unlock() }
            group.leave()
        }
    }
    group.notify(queue: .main) { completion(urls) }
}

private struct PieceRow: View {
    let piece: Piece
    var body: some View {
        HStack(spacing: 10) {
            LevelBadge(level: piece.level)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(piece.title).font(.headline).lineLimit(1)
                    if piece.isFavorite { Image(systemName: "star.fill").foregroundStyle(.yellow).font(.caption) }
                }
                if !piece.composer.isEmpty {
                    Text(piece.composer).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                HStack(spacing: 6) {
                    if piece.pdfFile != nil { Tag(text: "PDF", color: .red) }
                    if let s = piece.scoreFile { Tag(text: s.lowercased().hasSuffix("mid") || s.lowercased().hasSuffix("midi") ? "MIDI" : "XML", color: .blue) }
                    if piece.bestProgress > 0 {
                        ProgressView(value: piece.bestProgress).frame(width: 60)
                        Text("\(Int(piece.bestProgress * 100)) %").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.vertical, 3)
    }
}

struct Tag: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.18)))
            .foregroundStyle(color)
    }
}
