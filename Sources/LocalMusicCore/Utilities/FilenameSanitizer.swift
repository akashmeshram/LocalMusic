import Foundation

/// Produces file-system-safe path components from untrusted strings.
///
/// Rules:
/// - `/` and `:` (both illegal or ambiguous on macOS) become ` - ` style separators.
/// - Control characters, NUL and Unicode line separators are removed.
/// - Leading dots are stripped so nothing becomes a hidden file.
/// - Trailing dots and whitespace are removed; runs of whitespace collapse.
/// - The result is limited to `maxComponentBytes` bytes of UTF-8, cut on a grapheme boundary,
///   so that a suffix such as ` (2).m4a` still fits within APFS's 255-byte limit.
/// - Emoji and other Unicode are preserved.
public enum FilenameSanitizer {
    /// Conservative limit that leaves headroom for collision suffixes and extensions.
    public static let maxComponentBytes = 200

    public static func sanitize(_ raw: String, fallback: String = "Untitled", maxBytes: Int = maxComponentBytes) -> String {
        var s = raw.precomposedStringWithCanonicalMapping

        // Path separators and the classic-Mac separator.
        s = s.replacingOccurrences(of: "/", with: " - ")
        s = s.replacingOccurrences(of: ":", with: " - ")
        s = s.replacingOccurrences(of: "\\", with: " - ")

        // Control characters and line/paragraph separators become spaces (collapsed below).
        s = String(String.UnicodeScalarView(s.unicodeScalars.map { scalar in
            CharacterSet.controlCharacters.contains(scalar) || scalar == "\u{2028}" || scalar == "\u{2029}" || scalar == "\u{0}"
                ? " " : scalar
        }))

        // Collapse whitespace.
        s = s.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")

        // Collapse repeated separators produced above, e.g. "a -  - b".
        while s.contains(" -  - ") { s = s.replacingOccurrences(of: " -  - ", with: " - ") }

        // No hidden files, no trailing dots (Finder hides them) or dashes.
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: ". -"))

        if s.isEmpty { s = fallback }
        return truncate(s, toBytes: maxBytes)
    }

    /// Cuts a string so its UTF-8 encoding is at most `maxBytes`, never splitting a grapheme cluster.
    public static func truncate(_ s: String, toBytes maxBytes: Int) -> String {
        guard s.utf8.count > maxBytes else { return s }
        var result = ""
        var bytes = 0
        for ch in s {
            let len = ch.utf8.count
            if bytes + len > maxBytes { break }
            result.append(ch)
            bytes += len
        }
        return result.trimmingCharacters(in: CharacterSet(charactersIn: ". -")).isEmpty ? String(s.prefix(1)) : result.trimmingCharacters(in: CharacterSet(charactersIn: ". -"))
    }

    /// Sanitizes a file extension: lowercase alphanumerics only, no dot, max 8 characters.
    public static func sanitizeExtension(_ ext: String, fallback: String = "bin") -> String {
        let cleaned = ext.lowercased().filter { $0.isLetter || $0.isNumber }
        if cleaned.isEmpty { return fallback }
        return String(cleaned.prefix(8))
    }
}
