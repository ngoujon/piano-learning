import Foundation
import PianoCore
import UniformTypeIdentifiers

/// A piece in the user's collection.
struct Piece: Codable, Identifiable, Hashable {
    var id = UUID()
    var title: String
    var composer: String = ""
    var level: Int?
    var info: String = ""
    var catalogID: String?
    var previewURL: URL?
    /// File names inside the piece folder.
    var pdfFile: String?
    var scoreFile: String?
    var addedAt = Date()
    var lastPracticed: Date?
    var practiceCount = 0
    /// Best completion ratio reached in practice (0...1).
    var bestProgress: Double = 0
    /// Best accuracy (correct steps / attempts) on a full run.
    var bestAccuracy: Double?
    /// Index of the step where the student stopped last time.
    var resumeStep: Int?
    var isFavorite = false

    var hasScore: Bool { scoreFile != nil }
}

enum ImportError: LocalizedError {
    case unsupported(String)
    var errorDescription: String? {
        switch self {
        case .unsupported(let ext): return "Format non pris en charge : .\(ext). Formats acceptés : PDF, MIDI, MusicXML."
        }
    }
}

@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var pieces: [Piece] = []
    @Published var downloading: Set<String> = []
    @Published var lastMessage: String?

    static let scoreExtensions = ["mid", "midi", "kar", "musicxml", "xml", "mxl"]
    static let importTypes: [UTType] = {
        var types: [UTType] = [.pdf, .midi]
        for ext in ["mid", "midi", "kar", "musicxml", "mxl", "xml"] {
            if let t = UTType(filenameExtension: ext) { types.append(t) }
        }
        return types
    }()

    let rootURL: URL
    private var libraryFile: URL { rootURL.appendingPathComponent("library.json") }
    private var scoreCache: [UUID: Score] = [:]

    init(rootURL: URL? = nil) {
        let base = rootURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PianoLearning", isDirectory: true)
        self.rootURL = base
        try? FileManager.default.createDirectory(at: base.appendingPathComponent("Pieces"), withIntermediateDirectories: true)
        load()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: libraryFile) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        pieces = (try? decoder.decode([Piece].self, from: data)) ?? []
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(pieces) {
            try? data.write(to: libraryFile, options: .atomic)
        }
    }

    func folder(for piece: Piece) -> URL {
        rootURL.appendingPathComponent("Pieces/\(piece.id.uuidString)", isDirectory: true)
    }

    func pdfURL(for piece: Piece) -> URL? {
        piece.pdfFile.map { folder(for: piece).appendingPathComponent($0) }
    }

    func scoreURL(for piece: Piece) -> URL? {
        piece.scoreFile.map { folder(for: piece).appendingPathComponent($0) }
    }

    func piece(withID id: UUID) -> Piece? { pieces.first { $0.id == id } }

    func update(_ piece: Piece) {
        guard let i = pieces.firstIndex(where: { $0.id == piece.id }) else { return }
        pieces[i] = piece
        save()
    }

    func delete(_ piece: Piece) {
        try? FileManager.default.removeItem(at: folder(for: piece))
        pieces.removeAll { $0.id == piece.id }
        scoreCache[piece.id] = nil
        save()
    }

    func score(for piece: Piece) throws -> Score {
        if let cached = scoreCache[piece.id] { return cached }
        guard let url = scoreURL(for: piece) else { throw ScoreError.empty }
        let ext = url.pathExtension.lowercased()
        let score = ["mid", "midi", "kar"].contains(ext) ? try MIDIFileParser.parse(url: url) : try MusicXMLParser.parse(url: url)
        scoreCache[piece.id] = score
        return score
    }

    func contains(catalogID: String) -> Bool {
        pieces.contains { $0.catalogID == catalogID }
    }

    func recordPractice(pieceID: UUID, progress: Double, accuracy: Double?, step: Int?) {
        guard var p = piece(withID: pieceID) else { return }
        p.lastPracticed = Date()
        p.practiceCount += 1
        p.bestProgress = max(p.bestProgress, progress)
        if let a = accuracy, progress >= 0.999 { p.bestAccuracy = max(p.bestAccuracy ?? 0, a) }
        p.resumeStep = (progress >= 0.999) ? nil : step
        update(p)
    }

    // MARK: - Adding pieces

    private func copy(_ source: URL, into piece: Piece, as name: String? = nil) throws -> String {
        let dir = folder(for: piece)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileName = name ?? source.lastPathComponent
        let dest = dir.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
        try FileManager.default.copyItem(at: source, to: dest)
        return fileName
    }

    private func download(_ url: URL) async throws -> URL {
        var request = URLRequest(url: url)
        request.setValue("PianoLearning/1.0 (macOS)", forHTTPHeaderField: "User-Agent")
        let (tmp, response) = try await URLSession.shared.download(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        let named = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)-\(url.lastPathComponent)")
        try FileManager.default.moveItem(at: tmp, to: named)
        return named
    }

    /// Downloads the PDF and MIDI of a catalogue entry and adds them to the collection.
    @discardableResult
    func add(_ entry: CatalogEntry) async throws -> Piece {
        if let existing = pieces.first(where: { $0.catalogID == entry.id }) { return existing }
        downloading.insert(entry.id)
        defer { downloading.remove(entry.id) }

        var piece = Piece(title: entry.title, composer: entry.composer, level: entry.level, info: entry.info,
                          catalogID: entry.id, previewURL: entry.previewURL)
        if let mid = entry.midiURL {
            let file = try await download(mid)
            piece.scoreFile = try copy(file, into: piece, as: mid.lastPathComponent)
            try? FileManager.default.removeItem(at: file)
        }
        if let pdf = entry.pdfURL {
            let file = try await download(pdf)
            piece.pdfFile = try copy(file, into: piece, as: pdf.lastPathComponent)
            try? FileManager.default.removeItem(at: file)
        }
        pieces.insert(piece, at: 0)
        save()
        return piece
    }

    /// Imports user files. Files sharing the same base name (e.g. `song.pdf` + `song.mid`) become one piece.
    /// For a PDF without a score, tries a sibling file, then the online catalogue.
    @discardableResult
    func importFiles(_ urls: [URL], catalog: [CatalogEntry]) async -> [Piece] {
        var groups: [String: [URL]] = [:]
        var order: [String] = []
        var errors: [String] = []
        for url in urls {
            let ext = url.pathExtension.lowercased()
            guard ext == "pdf" || Self.scoreExtensions.contains(ext) else {
                errors.append(ImportError.unsupported(ext).localizedDescription)
                continue
            }
            let key = url.deletingPathExtension().lastPathComponent.lowercased()
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(url)
        }

        var added: [Piece] = []
        var notes: [String] = []
        for key in order {
            let files = groups[key] ?? []
            let access = files.map { $0.startAccessingSecurityScopedResource() }
            defer { for (u, ok) in zip(files, access) where ok { u.stopAccessingSecurityScopedResource() } }

            var pdf = files.first { $0.pathExtension.lowercased() == "pdf" }
            var scoreFile = files.first { Self.scoreExtensions.contains($0.pathExtension.lowercased()) }
            let baseName = (pdf ?? scoreFile)!.deletingPathExtension().lastPathComponent

            // Look for a sibling score/PDF next to the imported file.
            if scoreFile == nil, let p = pdf {
                scoreFile = Self.sibling(of: p, extensions: Self.scoreExtensions)
            }
            if pdf == nil, let s = scoreFile {
                pdf = Self.sibling(of: s, extensions: ["pdf"])
            }

            var piece = Piece(title: Self.prettyTitle(baseName))
            do {
                if let s = scoreFile {
                    let parsed: Score
                    if ["mid", "midi", "kar"].contains(s.pathExtension.lowercased()) {
                        parsed = try MIDIFileParser.parse(url: s)
                    } else {
                        parsed = try MusicXMLParser.parse(url: s)
                    }
                    if let t = parsed.title, !t.isEmpty, t.count < 80, pdf == nil { piece.title = t }
                    piece.scoreFile = try copy(s, into: piece)
                }
                if let p = pdf { piece.pdfFile = try copy(p, into: piece) }
            } catch {
                errors.append("\(baseName) : \(error.localizedDescription)")
                try? FileManager.default.removeItem(at: folder(for: piece))
                continue
            }

            // Enrich from the online catalogue when the name matches a known piece.
            if let match = CatalogParser.bestMatch(forFileName: baseName, in: catalog) {
                piece.title = match.title
                piece.composer = match.composer
                piece.level = match.level
                piece.info = match.info
                piece.previewURL = match.previewURL
                if piece.scoreFile == nil, let mid = match.midiURL, let file = try? await download(mid) {
                    piece.scoreFile = try? copy(file, into: piece, as: mid.lastPathComponent)
                    try? FileManager.default.removeItem(at: file)
                    if piece.scoreFile != nil {
                        notes.append("« \(match.title) » : fichier MIDI récupéré automatiquement sur partition-piano-gratuite.fr.")
                    }
                }
            }
            if piece.scoreFile == nil {
                notes.append("« \(piece.title) » : PDF ajouté. Pour l'apprendre note par note, associez-lui un fichier MIDI/MusicXML ou lancez la reconnaissance de partition (Audiveris).")
            }
            pieces.insert(piece, at: 0)
            added.append(piece)
        }
        save()
        let all = errors + notes
        lastMessage = all.isEmpty ? nil : all.joined(separator: "\n")
        return added
    }

    /// Attaches (or replaces) the playable score of a piece.
    func attachScore(_ url: URL, to piece: Piece) throws {
        let ok = url.startAccessingSecurityScopedResource()
        defer { if ok { url.stopAccessingSecurityScopedResource() } }
        let ext = url.pathExtension.lowercased()
        guard Self.scoreExtensions.contains(ext) else { throw ImportError.unsupported(ext) }
        _ = ["mid", "midi", "kar"].contains(ext) ? try MIDIFileParser.parse(url: url) : try MusicXMLParser.parse(url: url)
        var p = piece
        if let old = p.scoreFile { try? FileManager.default.removeItem(at: folder(for: p).appendingPathComponent(old)) }
        p.scoreFile = try copy(url, into: p)
        scoreCache[p.id] = nil
        update(p)
    }

    /// Stores notes recognised from the PDF (optical music recognition) as the piece's MIDI file.
    func attachRecognizedScore(_ score: Score, to piece: Piece) throws {
        var p = piece
        let dir = folder(for: p)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let old = p.scoreFile { try? FileManager.default.removeItem(at: dir.appendingPathComponent(old)) }
        let name = ((p.pdfFile as NSString?)?.deletingPathExtension ?? "partition") + " (reconnu).mid"
        try MIDIFileWriter.data(for: score).write(to: dir.appendingPathComponent(name), options: .atomic)
        p.scoreFile = name
        scoreCache[p.id] = nil
        update(p)
    }

    func attachPDF(_ url: URL, to piece: Piece) throws {
        let ok = url.startAccessingSecurityScopedResource()
        defer { if ok { url.stopAccessingSecurityScopedResource() } }
        var p = piece
        p.pdfFile = try copy(url, into: p)
        update(p)
    }

    /// Downloads the catalogue MIDI for an existing piece.
    func attachCatalogMIDI(_ entry: CatalogEntry, to piece: Piece) async throws {
        guard let mid = entry.midiURL else { return }
        let file = try await download(mid)
        defer { try? FileManager.default.removeItem(at: file) }
        try attachScore(file, to: piece)
    }

    static func sibling(of url: URL, extensions: [String]) -> URL? {
        let base = url.deletingPathExtension()
        for ext in extensions {
            for candidate in [base.appendingPathExtension(ext), base.appendingPathExtension(ext.uppercased())]
            where FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    static func prettyTitle(_ fileName: String) -> String {
        let spaced = fileName.replacingOccurrences(of: "[_-]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        guard let first = spaced.first else { return fileName }
        return first.uppercased() + spaced.dropFirst()
    }
}
