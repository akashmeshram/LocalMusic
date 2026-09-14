import Foundation

/// Strips upload-site noise from titles and splits "Artist - Title" patterns.
/// Conservative by design: anything it is unsure about is left as-is.
public enum TitleCleaner {
    public struct Result: Equatable, Sendable {
        public var title: String
        public var artist: String?
        public var year: Int?
        public var featuring: String?
    }

    /// Bracketed or trailing phrases that carry no musical information.
    static let noisePatterns: [String] = [
        #"official\s+(music\s+)?video"#, #"official\s+(audio|visuali[sz]er|lyric\s+video|lyrics|hd\s+video|version)"#,
        #"^official$"#, #"lyric\s*video"#, #"^lyrics?$"#, #"with\s+lyrics"#, #"^audio$"#, #"^visuali[sz]er$"#,
        #"^(hd|hq|4k|8k|1080p|720p|60fps)$"#, #"(hd|hq|4k|8k|1080p|720p)\s+(audio|video|quality)"#,
        #"^(remaster(ed)?|re-?master(ed)?)(\s+\d{4})?$"#, #"^\d{4}\s+remaster(ed)?$"#,
        #"^music\s+video$"#, #"^video\s+clip$"#, #"^clip\s+officiel$"#, #"^videoclip$"#,
        #"^full\s+(song|track|album|version)$"#, #"^free\s+download$"#, #"^new\s+\d{4}$"#, #"^premiere$"#,
        #"^explicit$"#, #"^clean(\s+version)?$"#, #"^high\s+quality$"#, #"^original\s+(mix|version)$"#,
    ]

    static let noiseRegexes: [NSRegularExpression] = noisePatterns.compactMap {
        try? NSRegularExpression(pattern: $0, options: [.caseInsensitive])
    }

    public static func clean(_ raw: String) -> String {
        var s = raw
        // Remove bracketed groups that are pure noise; keep ones that carry meaning (feat., remix, live…).
        for (open, close) in [("(", ")"), ("[", "]"), ("{", "}"), ("【", "】")] {
            s = removeNoiseGroups(in: s, open: open, close: close)
        }
        // Trailing " - Official Video", " | Official Audio", " HD" etc. Always cut at the
        // rightmost separator so "Artist - Song | Official Video" keeps "Artist - Song".
        let separators = [" - ", " – ", " — ", " | ", " // ", " ~ "]
        while true {
            let ranges = separators.compactMap { s.range(of: $0, options: .backwards) }
            guard let last = ranges.max(by: { $0.lowerBound < $1.lowerBound }) else { break }
            let tail = String(s[last.upperBound...])
            if isNoise(tail) { s = String(s[..<last.lowerBound]) } else { break }
        }
        // Standalone trailing tokens.
        var words = s.split(separator: " ").map(String.init)
        while let last = words.last, isNoise(last), words.count > 1 { words.removeLast() }
        s = words.joined(separator: " ")
        s = s.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: " -–—|~:,.\t"))
        s = s.replacingOccurrences(of: #"^["“”']+|["“”']+$"#, with: "", options: .regularExpression)
        return s.isEmpty ? raw.trimmingCharacters(in: .whitespaces) : s
    }

    static func isNoise(_ fragment: String) -> Bool {
        let t = fragment.trimmingCharacters(in: CharacterSet(charactersIn: " -–—|~:.,"))
        guard !t.isEmpty else { return true }
        let range = NSRange(t.startIndex..., in: t)
        for regex in noiseRegexes {
            if let m = regex.firstMatch(in: t, range: range) {
                // Anchored patterns must cover the whole fragment; unanchored ones may match anywhere.
                if regex.pattern.hasPrefix("^") { if m.range == range { return true } } else { return true }
            }
        }
        return false
    }

    static func removeNoiseGroups(in s: String, open: String, close: String) -> String {
        var result = ""
        var rest = Substring(s)
        while let o = rest.range(of: open) {
            guard let c = rest[o.upperBound...].range(of: close) else { break }
            let inner = String(rest[o.upperBound..<c.lowerBound])
            result += rest[..<o.lowerBound]
            if !isNoise(inner) { result += open + inner + close }
            rest = rest[c.upperBound...]
        }
        result += rest
        return result
    }

    /// Cleans the title and, when it follows "Artist - Title", splits it. `uploader` (channel name)
    /// is used to decide which side is the artist when both are plausible.
    public static func parse(_ raw: String, uploader: String? = nil) -> Result {
        var title = clean(raw)
        var artist: String?
        var year: Int?
        var featuring: String?

        if let m = title.firstMatch(of: #/\((19|20)\d{2}\)$/#) {
            year = Int(String(m.output.0).trimmingCharacters(in: CharacterSet(charactersIn: "()")))
            title = String(title[..<m.range.lowerBound]).trimmingCharacters(in: .whitespaces)
        }

        let separators = [" - ", " – ", " — ", " | ", ": ", " // "]
        for sep in separators {
            let parts = title.components(separatedBy: sep)
            guard parts.count >= 2 else { continue }
            let left = parts[0].trimmingCharacters(in: .whitespaces)
            let right = parts.dropFirst().joined(separator: sep).trimmingCharacters(in: .whitespaces)
            guard !left.isEmpty, !right.isEmpty, left.count <= 60 else { continue }
            let cleanedUploader = cleanUploader(uploader)
            if let u = cleanedUploader, similar(u, right), !similar(u, left) {
                // "Title - Artist" (rare); uploader matches the right side.
                artist = right; title = left
            } else {
                artist = left; title = right
            }
            break
        }

        if let m = title.firstMatch(of: #/(?:\s+|\s*[\(\[])(?:feat\.?|ft\.?|featuring)\s+([^\)\]]+)[\)\]]?\s*$/#.ignoresCase()) {
            featuring = String(m.output.1).trimmingCharacters(in: .whitespaces)
            title = String(title[..<m.range.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        if var a = artist, let m = a.firstMatch(of: #/\s+(?:feat\.?|ft\.?|featuring|x|&)\s+.+$/#.ignoresCase()), featuring == nil {
            featuring = String(a[m.range]).replacingOccurrences(of: #"^\s+(feat\.?|ft\.?|featuring|x|&)\s+"#, with: "", options: [.regularExpression, .caseInsensitive])
            a = String(a[..<m.range.lowerBound]).trimmingCharacters(in: .whitespaces)
            artist = a
        }
        return Result(title: title, artist: artist, year: year, featuring: featuring)
    }

    /// Normalizes a channel name into a plausible artist name ("Daft Punk - Topic" → "Daft Punk").
    public static func cleanUploader(_ name: String?) -> String? {
        guard var s = name?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        for suffix in [" - Topic", " – Topic", "VEVO", " Official", "Official", " Music", " TV", " Records"] where s.hasSuffix(suffix) && s.count > suffix.count {
            s = String(s.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
        }
        return s.isEmpty ? nil : s
    }

    /// Loose comparison used for artist matching: case-, punctuation- and whitespace-insensitive.
    public static func normalized(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: "", options: .regularExpression)
    }

    static func similar(_ a: String, _ b: String) -> Bool {
        let na = normalized(a), nb = normalized(b)
        guard !na.isEmpty, !nb.isEmpty else { return false }
        return na == nb || na.contains(nb) || nb.contains(na)
    }
}
