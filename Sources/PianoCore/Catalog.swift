import Foundation

/// A piece listed on partition-piano-gratuite.fr.
public struct CatalogEntry: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var composer: String
    public var level: Int?
    public var info: String
    public var previewURL: URL?
    public var pdfURL: URL?
    public var midiURL: URL?
    public var zipURL: URL?

    public init(id: String, title: String, composer: String, level: Int?, info: String,
                previewURL: URL?, pdfURL: URL?, midiURL: URL?, zipURL: URL?) {
        self.id = id
        self.title = title
        self.composer = composer
        self.level = level
        self.info = info
        self.previewURL = previewURL
        self.pdfURL = pdfURL
        self.midiURL = midiURL
        self.zipURL = zipURL
    }

    public static func levelLabel(_ level: Int?) -> String {
        switch level {
        case 1: return "Débutant"
        case 2: return "Facile"
        case 3: return "Intermédiaire"
        case 4: return "Avancé"
        case 5: return "Expert"
        default: return "Niveau ?"
        }
    }
}

/// Parses the catalogue page of partition-piano-gratuite.fr.
public enum CatalogParser {
    public static let siteURL = URL(string: "https://www.partition-piano-gratuite.fr/")!

    public static func parse(html: String, base: URL = siteURL) -> [CatalogEntry] {
        // Each piece is rendered as its own <table> containing level, title, preview and downloads.
        let tables = html.components(separatedBy: "<table")
        var entries: [CatalogEntry] = []
        var seen = Set<String>()
        for chunk in tables.dropFirst() {
            let table = chunk.components(separatedBy: "</table>").first ?? chunk
            guard table.contains("column2") else { continue }

            let titleHTML = firstMatch(#"<td class="column2">(.*?)</td>"#, in: table) ?? ""
            let title = clean(firstMatch(#"<strong>(.*?)</strong>"#, in: titleHTML) ?? "")
            guard !title.isEmpty else { continue }
            var composer = titleHTML
            if let r = composer.range(of: "</strong>") { composer = String(composer[r.upperBound...]) }
            composer = clean(composer)
            while composer.hasPrefix("/") || composer.hasPrefix("-") { composer = String(composer.dropFirst()).trimmingCharacters(in: .whitespaces) }

            let level = firstMatch(#"niveau-(\d)-off"#, in: table).flatMap { Int($0) }
            let info = clean(firstMatch(#"<span class="tooltipgc_inner">(.*?)</span>"#, in: table) ?? "")

            func url(_ ext: String) -> URL? {
                let pattern = #"(?:href|src)="([^"]+\."# + ext + #")""#
                guard let raw = firstMatch(pattern, in: table) else { return nil }
                return absolute(raw, base: base)
            }
            let pdf = url("pdf"), mid = url("mid"), mp3 = url("mp3"), zip = url("zip")
            guard pdf != nil || mid != nil else { continue }
            let id = (mid ?? pdf)!.path
            guard seen.insert(id).inserted else { continue }
            entries.append(CatalogEntry(id: id, title: title, composer: composer, level: level, info: info,
                                        previewURL: mp3, pdfURL: pdf, midiURL: mid, zipURL: zip))
        }
        return entries
    }

    static func absolute(_ raw: String, base: URL) -> URL? {
        let decoded = raw.replacingOccurrences(of: "&amp;", with: "&")
        guard let u = URL(string: decoded, relativeTo: base)?.absoluteURL else {
            let escaped = decoded.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? decoded
            return URL(string: escaped, relativeTo: base)?.absoluteURL
        }
        // Force HTTPS (the site serves the same files over TLS).
        if u.scheme == "http", var c = URLComponents(url: u, resolvingAgainstBaseURL: false) {
            c.scheme = "https"
            return c.url
        }
        return u
    }

    static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators, .caseInsensitive]),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }

    static func clean(_ html: String) -> String {
        var s = html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        let entities = ["&amp;": "&", "&nbsp;": " ", "&quot;": "\"", "&#39;": "'", "&rsquo;": "’", "&eacute;": "é",
                        "&egrave;": "è", "&agrave;": "à", "&ccedil;": "ç", "&ecirc;": "ê", "&ocirc;": "ô", "&laquo;": "«", "&raquo;": "»"]
        for (k, v) in entities { s = s.replacingOccurrences(of: k, with: v) }
        s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Normalised form used to match file names with catalogue titles.
    public static func normalize(_ s: String) -> String {
        let folded = s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "fr_FR"))
        return folded.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? String($0) : " " }.joined()
            .split(separator: " ").joined(separator: " ")
    }

    /// Best catalogue match for an imported file name, if similar enough.
    public static func bestMatch(forFileName name: String, in entries: [CatalogEntry]) -> CatalogEntry? {
        let target = normalize(name)
        guard !target.isEmpty else { return nil }
        // "op25" -> "op 25", so numbers compare the same way in "op. 25" and "op25".
        func words(_ s: String) -> Set<String> {
            Set(normalize(s).replacingOccurrences(of: "(?<=[a-z])(?=[0-9])|(?<=[0-9])(?=[a-z])", with: " ", options: .regularExpression)
                .split(separator: " ").map(String.init))
        }
        let targetWords = words(name)
        // Opus / catalogue numbers identify the work: "Prélude op. 28 n°4" is not "Prélude en Do majeur".
        let romanNumerals: Set<String> = ["i", "ii", "iii", "iv", "v", "vi", "vii", "viii", "ix", "x", "xi", "xii"]
        let targetNumbers = targetWords.filter { $0.allSatisfy(\.isNumber) || romanNumerals.contains($0) }
        let significant = targetWords.filter { $0.count > 2 }
        var best: (CatalogEntry, Double)?
        for e in entries {
            let fileStem = normalize(((e.midiURL ?? e.pdfURL)?.deletingPathExtension().lastPathComponent) ?? "")
            if fileStem == target || normalize(e.title) == target { return e }
            let pieceWords = words(e.title).union(words(fileStem))
            guard targetNumbers.isSubset(of: pieceWords) else { continue }
            let titleWords = words(e.title).filter { $0.count > 2 }
            let titleCommon = significant.intersection(pieceWords).count
            // The composer only breaks ties ("Clair de lune (Debussy)"); it never matches on its own.
            let common = Double(titleCommon + significant.intersection(words(e.composer)).subtracting(pieceWords).count)
            guard titleCommon >= 1, common >= 2 || (significant.count == 1 && !significant.isDisjoint(with: titleWords)) else { continue }
            let score = common / Double(max(min(significant.count, titleWords.count), 1))
            if score > (best?.1 ?? 0) { best = (e, score) }
        }
        if let b = best, b.1 >= 0.75 { return b.0 }
        return nil
    }
}
