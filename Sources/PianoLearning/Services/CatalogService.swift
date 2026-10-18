import Foundation
import PianoCore

/// Loads the list of free scores from partition-piano-gratuite.fr (with an offline cache),
/// alongside the public-domain pieces bundled in `ClassicsCatalog`.
@MainActor
final class CatalogService: ObservableObject {
    @Published private(set) var siteEntries: [CatalogEntry] = []
    var entries: [CatalogEntry] { siteEntries + ClassicsCatalog.entries }
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?
    @Published private(set) var lastUpdated: Date?

    private let cacheURL: URL

    init(cacheDirectory: URL) {
        cacheURL = cacheDirectory.appendingPathComponent("catalog-cache.json")
        if let data = try? Data(contentsOf: cacheURL),
           let cached = try? JSONDecoder().decode([CatalogEntry].self, from: data) {
            siteEntries = cached
            lastUpdated = (try? FileManager.default.attributesOfItem(atPath: cacheURL.path)[.modificationDate]) as? Date
        }
    }

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            var request = URLRequest(url: CatalogParser.siteURL)
            request.setValue("Mozilla/5.0 (Macintosh) PianoLearning/1.0", forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 30
            let (data, _) = try await URLSession.shared.data(for: request)
            let html = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
            let parsed = CatalogParser.parse(html: html)
            guard !parsed.isEmpty else {
                error = "partition-piano-gratuite.fr a répondu mais aucune partition n'a été trouvée."
                return
            }
            siteEntries = parsed
            lastUpdated = Date()
            if let data = try? JSONEncoder().encode(parsed) { try? data.write(to: cacheURL, options: .atomic) }
        } catch {
            self.error = siteEntries.isEmpty
                ? "Impossible de charger partition-piano-gratuite.fr : \(error.localizedDescription)"
                : "Hors ligne – affichage du catalogue en cache."
        }
    }

    func refreshIfNeeded() async {
        if siteEntries.isEmpty || (lastUpdated.map { Date().timeIntervalSince($0) > 86_400 } ?? true) {
            await refresh()
        }
    }
}
