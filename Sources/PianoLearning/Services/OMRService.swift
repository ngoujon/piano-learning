import Foundation
import PDFKit
import PianoCore

/// Optical music recognition (PDF -> notes) through Audiveris, a free and open-source OMR engine
/// (https://audiveris.github.io). The app can download and install it on demand.
enum OMRService {
    static let installedAppURL = URL(fileURLWithPath: NSHomeDirectory() + "/Applications/Audiveris.app")

    static var audiverisExecutable: URL? {
        var candidates = [
            "/Applications/Audiveris.app/Contents/MacOS/Audiveris",
            installedAppURL.path + "/Contents/MacOS/Audiveris",
            "/opt/homebrew/bin/audiveris",
            "/usr/local/bin/audiveris",
        ]
        if let custom = ProcessInfo.processInfo.environment["AUDIVERIS_PATH"] { candidates.insert(custom, at: 0) }
        return candidates.map(URL.init(fileURLWithPath:)).first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static var isAvailable: Bool { audiverisExecutable != nil }

    static let releasesPage = URL(string: "https://github.com/Audiveris/audiveris/releases")!

    enum OMRError: LocalizedError {
        case notInstalled
        case noMusicFound(String)
        case installFailed(String)

        var errorDescription: String? {
            switch self {
            case .notInstalled:
                return "Audiveris n'est pas installé."
            case .noMusicFound(let log):
                return "Aucune portée n'a pu être reconnue dans ce PDF. La reconnaissance fonctionne avec des partitions imprimées nettes (pas manuscrites ni photographiées de travers).\n\n\(log.suffix(400))"
            case .installFailed(let reason):
                return "L'installation d'Audiveris a échoué : \(reason)"
            }
        }
    }

    // MARK: - Recognition

    /// Recognises every page of a PDF and returns the merged score.
    /// Pages are processed separately so that a cover page without staves does not abort everything.
    static func recognize(pdf: URL, progress: (@Sendable (Int, Int) -> Void)? = nil) async throws -> Score {
        guard let exe = audiverisExecutable else { throw OMRError.notInstalled }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("omr-\(UUID().uuidString)", isDirectory: true)
        let output = work.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let pages = try splitPages(of: pdf, into: work)
        // Report progress by watching the per-page project files Audiveris writes.
        let watcher = Task.detached {
            while !Task.isCancelled {
                let done = ((try? FileManager.default.contentsOfDirectory(atPath: output.path)) ?? []).filter { $0.hasSuffix(".omr") }.count
                progress?(min(done + 1, pages.count), pages.count)
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        defer { watcher.cancel() }
        let log = try await run(exe, arguments: ["-batch", "-export", "-output", output.path, "--"] + pages.map(\.path),
                                logURL: work.appendingPathComponent("audiveris.log"))

        var scores: [Score] = []
        for page in pages {
            let stem = page.deletingPathExtension().lastPathComponent
            let files = FileManager.default.enumerator(at: output, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
            // Audiveris names outputs after the input (multi-movement pages get ".mvt1", ".mvt2"…).
            let mxls = files.filter {
                ["mxl", "musicxml"].contains($0.pathExtension.lowercased()) && $0.lastPathComponent.hasPrefix(stem + ".")
            }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            for mxl in mxls {
                if let s = try? MusicXMLParser.parse(url: mxl), !s.notes.isEmpty { scores.append(s) }
            }
        }
        guard !scores.isEmpty else { throw OMRError.noMusicFound(log) }
        return MIDIFileWriter.concatenate(scores)
    }

    /// Writes one PDF per page (page-001.pdf, …).
    static func splitPages(of pdf: URL, into dir: URL) throws -> [URL] {
        guard let doc = PDFDocument(url: pdf), doc.pageCount > 0 else {
            throw OMRError.noMusicFound("PDF illisible")
        }
        var urls: [URL] = []
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            let single = PDFDocument()
            single.insert(page, at: 0)
            let url = dir.appendingPathComponent(String(format: "page-%03d.pdf", i + 1))
            if single.write(to: url) { urls.append(url) }
        }
        return urls
    }

    @discardableResult
    private static func run(_ exe: URL, arguments: [String], logURL: URL) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            let p = Process()
            p.executableURL = exe
            p.arguments = arguments
            // Log to a file: Audiveris is verbose and a pipe could fill up and block it.
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
            let handle = try? FileHandle(forWritingTo: logURL)
            p.standardOutput = handle
            p.standardError = handle
            p.terminationHandler = { _ in
                try? handle?.close()
                // A non-zero exit is expected when some pages (e.g. a cover) contain no music.
                cont.resume(returning: (try? String(contentsOf: logURL, encoding: .utf8)) ?? "")
            }
            do { try p.run() } catch { cont.resume(throwing: error) }
        }
    }

    // MARK: - Installation

    /// Downloads the latest Audiveris release for this Mac and installs it in ~/Applications.
    static func install(progress: @escaping @Sendable (String) -> Void) async throws {
        progress("Recherche de la dernière version…")
        let api = URL(string: "https://api.github.com/repos/Audiveris/audiveris/releases/latest")!
        let (data, _) = try await URLSession.shared.data(from: api)
        struct Release: Decodable {
            struct Asset: Decodable { let name: String; let browser_download_url: URL }
            let tag_name: String
            let assets: [Asset]
        }
        let release = try JSONDecoder().decode(Release.self, from: data)
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x86_64"
        #endif
        guard let asset = release.assets.first(where: { $0.name.contains("macosx") && $0.name.contains(arch) && $0.name.hasSuffix(".dmg") }) else {
            throw OMRError.installFailed("aucune version macOS trouvée")
        }

        progress("Téléchargement d'Audiveris \(release.tag_name) (~85 Mo)…")
        let (tmp, _) = try await URLSession.shared.download(from: asset.browser_download_url)
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("audiveris-install-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let dmg = work.appendingPathComponent("Audiveris.dmg")
        try FileManager.default.moveItem(at: tmp, to: dmg)

        progress("Installation…")
        let mount = work.appendingPathComponent("mnt").path
        // The disk image shows the AGPL licence: the user accepted it by confirming the installation.
        try shell("yes | /usr/bin/hdiutil attach -nobrowse -readonly -mountpoint '\(mount)' '\(dmg.path)' > /dev/null")
        defer { try? shell("/usr/bin/hdiutil detach -force '\(mount)' > /dev/null") }

        let source = URL(fileURLWithPath: mount).appendingPathComponent("Audiveris.app")
        guard FileManager.default.fileExists(atPath: source.path) else { throw OMRError.installFailed("image disque inattendue") }
        try FileManager.default.createDirectory(at: installedAppURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: installedAppURL.path) { try FileManager.default.removeItem(at: installedAppURL) }
        try shell("/usr/bin/ditto '\(source.path)' '\(installedAppURL.path)'")
        guard isAvailable else { throw OMRError.installFailed("exécutable introuvable après copie") }
        progress("Audiveris est installé.")
    }

    private static func shell(_ command: String) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", command]
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 { throw OMRError.installFailed("commande en échec (\(p.terminationStatus))") }
    }
}
