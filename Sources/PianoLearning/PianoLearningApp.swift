import AppKit
import PianoCore
import SwiftUI

enum SidebarItem: String, Hashable, CaseIterable, Identifiable {
    case library, catalog, freePlay
    var id: String { rawValue }

    var title: String {
        switch self {
        case .library: return "Ma collection"
        case .catalog: return "Catalogue en ligne"
        case .freePlay: return "Pratique libre"
        }
    }

    var icon: String {
        switch self {
        case .library: return "music.note.list"
        case .catalog: return "globe"
        case .freePlay: return "waveform.and.mic"
        }
    }
}

@MainActor
final class AppState: ObservableObject {
    @Published var sidebar: SidebarItem? = .library
    @Published var selectedPieceID: UUID?
    @Published var practicingPieceID: UUID?
    @Published var freePlayPieceID: UUID?
}

extension Notification.Name {
    static let importFiles = Notification.Name("PianoLearning.importFiles")
    static let openFiles = Notification.Name("PianoLearning.openFiles")
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare executable (swift run) rather than from the .app bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Files opened from the Finder ("Open with…", dropped on the Dock icon).
    static var pendingFiles: [URL] = []

    func application(_ application: NSApplication, open urls: [URL]) {
        AppDelegate.pendingFiles.append(contentsOf: urls)
        NotificationCenter.default.post(name: .openFiles, object: nil)
    }
}

@main
struct PianoLearningApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var library: LibraryStore
    @StateObject private var catalog: CatalogService
    @StateObject private var app = AppState()

    init() {
        let store = LibraryStore()
        _library = StateObject(wrappedValue: store)
        _catalog = StateObject(wrappedValue: CatalogService(cacheDirectory: store.rootURL))
    }

    var body: some Scene {
        Window("Piano Learning", id: "main") {
            ContentView()
                .environmentObject(library)
                .environmentObject(catalog)
                .environmentObject(app)
                .frame(minWidth: 1000, minHeight: 680)
        }
        .defaultSize(width: 1280, height: 840)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Importer des partitions (PDF, MIDI, MusicXML)…") {
                    app.sidebar = .library
                    DispatchQueue.main.async { NotificationCenter.default.post(name: .importFiles, object: nil) }
                }
                .keyboardShortcut("o")
            }
        }

        Settings {
            SettingsView()
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var catalog: CatalogService
    @EnvironmentObject private var app: AppState

    var body: some View {
        mainContent
            .onAppear(perform: importPendingFiles)
            .onReceive(NotificationCenter.default.publisher(for: .openFiles)) { _ in importPendingFiles() }
    }

    private func importPendingFiles() {
        let urls = AppDelegate.pendingFiles
        guard !urls.isEmpty else { return }
        AppDelegate.pendingFiles = []
        Task {
            if catalog.entries.isEmpty { await catalog.refresh() }
            let added = await library.importFiles(urls, catalog: catalog.entries)
            app.practicingPieceID = nil
            app.sidebar = .library
            if let first = added.first { app.selectedPieceID = first.id }
        }
    }

    @ViewBuilder
    private var mainContent: some View {
        if let id = app.practicingPieceID, let piece = library.piece(withID: id), let score = try? library.score(for: piece) {
            PracticeView(piece: piece, score: score, pdfURL: library.pdfURL(for: piece),
                         onFinish: { progress, accuracy, step in
                             library.recordPractice(pieceID: id, progress: progress, accuracy: accuracy, step: step)
                         },
                         onClose: { app.practicingPieceID = nil })
                .id(id)
        } else {
            NavigationSplitView {
                List(SidebarItem.allCases, selection: $app.sidebar) { item in
                    Label(item.title, systemImage: item.icon).tag(item)
                }
                .navigationSplitViewColumnWidth(min: 180, ideal: 200)
                .safeAreaInset(edge: .bottom) { SidebarFooter() }
            } detail: {
                switch app.sidebar ?? .library {
                case .library: LibraryView()
                case .catalog: CatalogView()
                case .freePlay: FreePlayView()
                }
            }
        }
    }
}

private struct SidebarFooter: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Partitions gratuites :").font(.caption2).foregroundStyle(.secondary)
            Link("partition-piano-gratuite.fr", destination: CatalogParser.siteURL).font(.caption2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
    }
}

struct SettingsView: View {
    @AppStorage("noteNaming") private var noteNaming = "fr"
    @AppStorage("micSensitivity") private var micSensitivity = 1.0
    @AppStorage("ignoreOctave") private var ignoreOctave = false
    @AppStorage("showNoteNames") private var showNoteNames = true

    var body: some View {
        Form {
            Picker("Nom des notes", selection: $noteNaming) {
                Text("Do, Ré, Mi…").tag("fr")
                Text("C, D, E…").tag("en")
            }
            InputDevicePicker()
            Toggle("Afficher le nom des notes pendant l'apprentissage", isOn: $showNoteNames)
            Toggle("Accepter la bonne note dans n'importe quelle octave", isOn: $ignoreOctave)
            VStack(alignment: .leading) {
                Text("Seuil du micro : \(micSensitivity, specifier: "%.1f")")
                Slider(value: $micSensitivity, in: 0.4...2.5) {
                    EmptyView()
                } minimumValueLabel: { Text("Sensible") } maximumValueLabel: { Text("Strict") }
                Text("Augmentez le seuil si des bruits sont pris pour des notes, diminuez-le si vos notes ne sont pas entendues.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Reconnaissance des PDF") {
                if OMRService.isAvailable {
                    Label("Audiveris est installé : les PDF peuvent être convertis en notes.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Text("Pour apprendre un morceau à partir d'un PDF seul, l'application utilise le logiciel libre Audiveris. Installez-le depuis la fiche d'un morceau PDF (bouton « Installer la reconnaissance de partitions »).")
                    Link("Site d'Audiveris", destination: OMRService.releasesPage)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .padding()
    }
}
